//! LLVM backend: lowers Kyn IR to textual LLVM IR and emits it.
//!
//! The compiler does not link against LLVM's C++ libraries. It produces
//! standard LLVM IR accepted by `clang`/`llc`, which keeps the compiler
//! binary small and the build reproducible. Kyn semantics remain defined by
//! this repository, not by LLVM.

const std = @import("std");
const ast = @import("../ast.zig");
const ir = @import("../ir.zig");
const types = @import("../types.zig");
const diagnostics = @import("../diagnostics.zig");
const analyzer = @import("../analyzer.zig");
const symbol = @import("../symbol.zig");
const sema_mod = @import("../sema.zig");

pub const Error = error{OutOfMemory};

const FnCtx = struct {
    function: *ir.Function,
    current: u32 = 0,
    break_stack: std.ArrayList(u32) = .empty,
    continue_stack: std.ArrayList(u32) = .empty,
};

const BoundaryClass = enum {
    none,
    small_1,
    small_2,
    sse_float,
    sse_double,
    sse_f32x2,
    sse_f32x3,
    sse_f32x4,
    sse_f64x2,
    sse_f64_i32,
    sse_i32_f64,
    sse_f32_f64,
    sse_f64_f32,
    sse_f32_i64,
    sse_i64_f32,
    sse_f64_i64,
    sse_i64_f64,
    sse_f32x2_i32,
    sse_i8_f64,
    sse_i16_f64,
    sse_f64_i8,
    sse_f64_i16,
    sse_f32x2_i64,
    sse_i64_f32x,
    sse_i64_f64x,
    sse_f64_i64x,
    sse_i64_v2f32,
    sse_f64_v2f32,
    sse_v2f32_f64,
    memory,
};

pub const Lowering = struct {
    allocator: std.mem.Allocator,
    reporter: *diagnostics.Reporter,
    module: *ir.Module,
    checks: ir.RuntimeCheckPolicy,
    globals: std.AutoHashMap(u32, u32),
    ctx: ?*FnCtx = null,
    current_fd: ?*ast.FnDecl = null,

    pub fn init(
        allocator: std.mem.Allocator,
        reporter: *diagnostics.Reporter,
        module: *ir.Module,
        checks: ir.RuntimeCheckPolicy,
    ) Lowering {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .module = module,
            .checks = checks,
            .globals = std.AutoHashMap(u32, u32).init(allocator),
        };
    }

    pub fn lower(self: *Lowering, program: *ast.Program) Error!void {
        try self.collectTypes(program);

        // Globals must exist before function bodies are lowered.
        for (program.decls) |decl| {
            switch (decl.kind) {
                .var_decl => |vd| try self.lowerGlobal(vd, decl.span),
                .fn_decl => |fd| try self.createFunction(fd),
                .struct_decl, .enum_decl => {},
            }
        }

        for (program.decls) |decl| {
            switch (decl.kind) {
                .fn_decl => |fd| {
                    if (fd.body) |body| try self.lowerFunction(fd, body);
                },
                else => {},
            }
        }
    }

    fn collectTypes(self: *Lowering, program: *ast.Program) Error!void {
        for (program.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |sd| if (sd.ty) |ty| try self.module.addStruct(ty.struct_type),
                .enum_decl => |ed| if (ed.ty) |ty| try self.module.addEnum(ty.enum_type),
                else => {},
            }
        }
    }

    fn lowerGlobal(self: *Lowering, vd: *ast.VarDecl, span: @import("../source.zig").Span) Error!void {
        const sym = vd.sym orelse return;
        const ty = vd.ty orelse {
            try self.reporter.err("E0601", span, "internal: global '{s}' has no resolved type", .{vd.name});
            return;
        };
        const init_value = (try self.lowerConstant(vd.init.?, ty)) orelse {
            try self.reporter.err("E0602", span, "global initializer for '{s}' cannot be emitted as a constant", .{vd.name});
            return;
        };
        const index: u32 = @intCast(self.module.globals.items.len);
        try self.module.globals.append(self.allocator, .{
            .name = sym.link_name,
            .ty = ty,
            .init = init_value,
            .mutable = vd.mutable,
        });
        try self.globals.put(sym.id, index);
    }

    fn createFunction(self: *Lowering, fd: *ast.FnDecl) Error!void {
        const fn_sym = fd.sym orelse return;
        const fn_ty = fd.ty orelse return;
        const info = fn_ty.fn_type;
        if (fd.is_extern and findFunction(self.module, fn_sym.link_name) != null) return;
        if (!fd.is_extern) {
            for (self.module.functions.items, 0..) |existing, index| {
                if (existing.linkage == .declaration and std.mem.eql(u8, existing.name, fn_sym.link_name)) {
                    _ = self.module.functions.orderedRemove(index);
                    break;
                }
            }
        }
        const linkage: ir.Linkage = if (fd.is_extern)
            .declaration
        else if (fd.is_export or (fn_sym.owner_module_id == 0 and std.mem.eql(u8, fd.name, "main")))
            .external
        else
            .internal;

        if (!fd.is_extern and !fd.is_export) {
            var params = try self.allocator.alloc(ir.Param, fd.params.len);
            for (fd.params, 0..) |param, i| {
                const sym = param.sym orelse continue;
                params[i] = .{ .local = sym.id, .ty = info.params[i] };
            }
            const function = try self.allocator.create(ir.Function);
            function.* = .{
                .name = fn_sym.link_name,
                .params = params,
                .ret = info.ret,
                .linkage = linkage,
            };
            try self.module.functions.append(self.allocator, function);
            return;
        }

        var params_list: std.ArrayList(ir.Param) = .empty;
        var hidden_id: u32 = 100_000;
        const void_ty = try self.simpleType(.void);
        const ptr_ty = try self.makePointer(void_ty, false);
        const i64_ty = try self.simpleType(.{ .int = .{ .bits = 64, .signed = true } });
        const i128_ty = try self.simpleType(.{ .int = .{ .bits = 128, .signed = true } });

        const ret_expr = fd.ret_expr;
        const ret_aggregate: bool = if (ret_expr) |re| blk: {
            const ty = re.resolved orelse break :blk false;
            break :blk ty.isAggregate();
        } else false;
        const ret_class: BoundaryClass = if (ret_aggregate)
            self.aggregateBoundaryParam(ret_expr.?.resolved.?)
        else
            BoundaryClass.none;

        var sret_info: ?*types.StructInfo = null;
        if (ret_class == .memory) {
            if (ret_expr) |re| {
                if (re.resolved) |ty| {
                    if (ty.* == .struct_type) sret_info = ty.struct_type;
                }
            }
            try params_list.append(self.allocator, .{ .local = hidden_id, .ty = ptr_ty });
            hidden_id += 1;
        }

        for (fd.params) |param| {
            const ty = param.ty orelse (try self.simpleType(.invalid));
            const class = self.aggregateBoundaryParam(ty);
            switch (class) {
                .small_2 => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = i64_ty });
                    try params_list.append(self.allocator, .{ .local = hidden_id + 1, .ty = i64_ty });
                    hidden_id += 2;
                },
                .memory => {
                    const struct_info = if (ty.* == .struct_type) ty.struct_type else null;
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = ptr_ty, .byval_type = struct_info });
                    hidden_id += 1;
                },
                .small_1 => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = i64_ty });
                    hidden_id += 1;
                },
                .sse_float => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = try self.simpleType(.{ .float = 32 }) });
                    hidden_id += 1;
                },
                .sse_double => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = try self.simpleType(.{ .float = 64 }) });
                    hidden_id += 1;
                },
                .sse_f32x2 => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = try self.simpleType(.abi_vec2_f32) });
                    hidden_id += 1;
                },
                .sse_f32x3 => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = try self.simpleType(.abi_vec2_f32) });
                    try params_list.append(self.allocator, .{ .local = hidden_id + 1, .ty = try self.simpleType(.{ .float = 32 }) });
                    hidden_id += 2;
                },
                .sse_f32x4 => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = try self.simpleType(.abi_vec2_f32) });
                    try params_list.append(self.allocator, .{ .local = hidden_id + 1, .ty = try self.simpleType(.abi_vec2_f32) });
                    hidden_id += 2;
                },
                .sse_f64x2, .sse_f64_i32, .sse_i32_f64, .sse_f32_f64, .sse_f64_f32, .sse_f32_i64, .sse_i64_f32, .sse_f64_i64, .sse_i64_f64, .sse_i8_f64, .sse_i16_f64, .sse_f64_i8, .sse_f64_i16 => {
                    for (ty.struct_type.fields) |field| {
                        try params_list.append(self.allocator, .{ .local = hidden_id, .ty = try self.boundaryMemberType(field.ty) });
                        hidden_id += 1;
                    }
                },
                .sse_f32x2_i32, .sse_f32x2_i64, .sse_v2f32_f64 => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = try self.simpleType(.abi_vec2_f32) });
                    if (class == .sse_f32x2_i32) {
                        try params_list.append(self.allocator, .{ .local = hidden_id + 1, .ty = try self.simpleType(.{ .int = .{ .bits = 32, .signed = true } }) });
                    } else if (class == .sse_f32x2_i64) {
                        try params_list.append(self.allocator, .{ .local = hidden_id + 1, .ty = i64_ty });
                    } else {
                        try params_list.append(self.allocator, .{ .local = hidden_id + 1, .ty = try self.simpleType(.{ .float = 64 }) });
                    }
                    hidden_id += 2;
                },
                .sse_i64_f32x, .sse_i64_f64x, .sse_i64_v2f32 => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = i64_ty });
                    const second_ty = switch (class) {
                        .sse_i64_f32x => try self.simpleType(.{ .float = 32 }),
                        .sse_i64_f64x => try self.simpleType(.{ .float = 64 }),
                        .sse_i64_v2f32 => try self.simpleType(.abi_vec2_f32),
                        else => unreachable,
                    };
                    try params_list.append(self.allocator, .{ .local = hidden_id + 1, .ty = second_ty });
                    hidden_id += 2;
                },
                .sse_f64_i64x, .sse_f64_v2f32 => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = try self.simpleType(.{ .float = 64 }) });
                    const second_ty = switch (class) {
                        .sse_f64_i64x => i64_ty,
                        .sse_f64_v2f32 => try self.simpleType(.abi_vec2_f32),
                        else => unreachable,
                    };
                    try params_list.append(self.allocator, .{ .local = hidden_id + 1, .ty = second_ty });
                    hidden_id += 2;
                },
                .none => {
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = ty });
                    hidden_id += 1;
                },
            }
        }
        const params = try params_list.toOwnedSlice(self.allocator);

        const ret_ty = switch (ret_class) {
            .memory => void_ty,
            .none => if (fd.ret_expr == null) void_ty else info.ret,
            .small_1 => i64_ty,
            .small_2 => i128_ty,
            .sse_float => try self.simpleType(.{ .float = 32 }),
            .sse_double => try self.simpleType(.{ .float = 64 }),
            .sse_f32x2 => try self.simpleType(.abi_vec2_f32),
            .sse_f32x3 => try self.simpleType(.abi_v2f32_f32),
            .sse_f32x4 => try self.simpleType(.abi_v2f32_v2f32),
            .sse_f64x2 => try self.simpleType(.abi_pair_f64),
            .sse_f64_i32 => try self.simpleType(.abi_f64_i32),
            .sse_i32_f64 => try self.simpleType(.abi_i32_f64),
            .sse_f32_f64 => try self.simpleType(.abi_f32_f64),
            .sse_f64_f32 => try self.simpleType(.abi_f64_f32),
            .sse_f32_i64 => try self.simpleType(.abi_f32_i64),
            .sse_i64_f32 => try self.simpleType(.abi_i64_f32),
            .sse_f64_i64 => try self.simpleType(.abi_f64_i64),
            .sse_i64_f64 => try self.simpleType(.abi_i64_f64),
            .sse_f32x2_i32 => try self.simpleType(.abi_v2f32_i32),
            .sse_f32x2_i64 => try self.simpleType(.abi_v2f32_i64),
            .sse_i64_f32x => try self.simpleType(.abi_i64_f32),
            .sse_i64_f64x => try self.simpleType(.abi_i64_f64),
            .sse_f64_i64x => try self.simpleType(.abi_f64_i64),
            .sse_i64_v2f32 => try self.simpleType(.abi_i64_v2f32),
            .sse_f64_v2f32 => try self.simpleType(.abi_f64_v2f32),
            .sse_v2f32_f64 => try self.simpleType(.abi_v2f32_f64),
            .sse_i8_f64 => try self.simpleType(.abi_i8_f64),
            .sse_i16_f64 => try self.simpleType(.abi_i16_f64),
            .sse_f64_i8 => try self.simpleType(.abi_f64_i8),
            .sse_f64_i16 => try self.simpleType(.abi_f64_i16),
        };

        const function = try self.allocator.create(ir.Function);
        function.* = .{
            .name = fn_sym.link_name,
            .params = params,
            .ret = ret_ty,
            .linkage = linkage,
            .sret = ret_class == .memory,
            .sret_type = sret_info,
        };
        try self.module.functions.append(self.allocator, function);
    }

    fn currentFunction(self: *Lowering) *ir.Function {
        return self.ctx.?.function;
    }

    fn simpleType(self: *Lowering, value: types.Type) Error!*types.Type {
        const ty = try self.allocator.create(types.Type);
        ty.* = value;
        return ty;
    }

    /// Replaces a boundary-passing `bool` scalar with an unsigned byte: C ABI
    /// `_Bool` is a full `i8`, and Kyn's bit-level `bool` cannot be emitted as
    /// an `i1` parameter or load at the boundary.
    fn boundaryMemberType(self: *Lowering, field_ty: *types.Type) Error!*types.Type {
        if (field_ty.* != .bool) return field_ty;
        const i8_ty = try self.allocator.create(types.Type);
        i8_ty.* = .{ .int = .{ .bits = 8, .signed = false } };
        return i8_ty;
    }

    fn aggregateBoundaryParam(self: *Lowering, ty: *types.Type) BoundaryClass {
        _ = self;
        if (!ty.isAggregate()) return .none;
        const class = sema_mod.aggregateBoundaryClass(ty) orelse return .none;
        return switch (class) {
            .small_1 => .small_1,
            .small_2 => .small_2,
            .sse_float => .sse_float,
            .sse_double => .sse_double,
            .sse_f32x2 => .sse_f32x2,
            .sse_f32x3 => .sse_f32x3,
            .sse_f32x4 => .sse_f32x4,
            .sse_f64x2 => .sse_f64x2,
            .sse_f64_i32 => .sse_f64_i32,
            .sse_i32_f64 => .sse_i32_f64,
            .sse_f32_f64 => .sse_f32_f64,
            .sse_f64_f32 => .sse_f64_f32,
            .sse_f32_i64 => .sse_f32_i64,
            .sse_i64_f32 => .sse_i64_f32,
            .sse_f64_i64 => .sse_f64_i64,
            .sse_i64_f64 => .sse_i64_f64,
            .sse_f32x2_i32 => .sse_f32x2_i32,
            .sse_f32x2_i64 => .sse_f32x2_i64,
            .sse_i64_f32x => .sse_i64_f32x,
            .sse_i64_f64x => .sse_i64_f64x,
            .sse_f64_i64x => .sse_f64_i64x,
            .sse_i64_v2f32 => .sse_i64_v2f32,
            .sse_f64_v2f32 => .sse_f64_v2f32,
            .sse_v2f32_f64 => .sse_v2f32_f64,
            .sse_i8_f64 => .sse_i8_f64,
            .sse_i16_f64 => .sse_i16_f64,
            .sse_f64_i8 => .sse_f64_i8,
            .sse_f64_i16 => .sse_f64_i16,
            .memory => .memory,
        };
    }

    fn aggregateBoundaryRet(self: *Lowering, ret_expr: ?*ast.TypeExpr) BoundaryClass {
        const expr = ret_expr orelse return .none;
        const ty = expr.resolved orelse return .none;
        return self.aggregateBoundaryParam(ty);
    }

    fn addLocal(self: *Lowering, id: u32, name: []const u8, ty: *types.Type, padding: ?u16) Error!void {
        const hidden_padding: u16 = padding orelse blk: {
            if (!ty.isAggregate()) break :blk 0;
            const size = self.aggregateSize(ty) orelse break :blk 0;
            break :blk if (size <= 8) 8 else if (size <= 16) 16 else @intCast(size);
        };
        try self.currentFunction().addLocal(self.allocator, id, name, ty, hidden_padding);
    }

    fn newBlock(self: *Lowering) Error!u32 {
        const function = self.currentFunction();
        const index: u32 = @intCast(function.blocks.items.len);
        const block = try self.allocator.create(ir.Block);
        block.* = .{ .id = index };
        try function.blocks.append(self.allocator, block);
        return index;
    }

    fn switchBlock(self: *Lowering, index: u32) Error!void {
        self.ctx.?.current = index;
    }

    fn isTerminated(self: *Lowering) bool {
        const function = self.currentFunction();
        return function.block(self.ctx.?.current).terminated;
    }

    /// Stores `value` at `ptr` with type `ty`. Boolean stores are widened to a
    /// zero-extended `i8`: Kyn's bit-level `bool` (`i1`) would otherwise leak
    /// untouched upper byte bits into memory, and the C ABI requires the full
    /// byte to be defined for aggregate eightbytes (Clang's `_Bool` is a
    /// full `i8`).
    fn emitValueStore(self: *Lowering, args: struct { ptr: ir.Value, value: ir.Value, ty: *types.Type }) Error!void {
        if (args.ty.* != .bool) {
            try self.emit(.{ .store = .{ .ptr = args.ptr, .value = args.value, .ty = args.ty } });
            return;
        }
        const i8_ty = try self.simpleType(.{ .int = .{ .bits = 8, .signed = false } });
        const dst = try self.reg(i8_ty);
        try self.emit(.{ .cast = .{ .dst = dst, .kind = .bool_to_int, .from = args.ty, .to = i8_ty, .value = args.value } });
        try self.emit(.{ .store = .{ .ptr = args.ptr, .value = .{ .reg = dst }, .ty = i8_ty } });
    }

    fn emit(self: *Lowering, inst: ir.Inst) Error!void {
        const function = self.currentFunction();
        const block = function.block(self.ctx.?.current);
        if (block.terminated) return;
        try block.insts.append(self.allocator, inst);
        const tag = std.meta.activeTag(inst);
        if (tag == .br or tag == .cbr or tag == .ret or tag == .unreachable_ or tag == .trap_) {
            block.terminated = true;
        }
    }

    fn reg(self: *Lowering, ty: *types.Type) Error!u32 {
        const id = self.module.temp();
        try self.module.setRegType(id, ty);
        return id;
    }

    fn booleanType(self: *Lowering) Error!*types.Type {
        const ty = try self.allocator.create(types.Type);
        ty.* = .bool;
        return ty;
    }

    fn i128Type(self: *Lowering) Error!*types.Type {
        const ty = try self.allocator.create(types.Type);
        ty.* = .{ .int = .{ .bits = 128, .signed = true } };
        return ty;
    }

    fn emitTrapBranch(self: *Lowering, cond: u32) Error!void {
        const trap_block = try self.newBlock();
        const continue_block = try self.newBlock();
        try self.emit(.{ .cbr = .{
            .cond = .{ .reg = cond },
            .then_block = trap_block,
            .else_block = continue_block,
        } });
        try self.switchBlock(trap_block);
        try self.emit(.{ .trap_ = {} });
        try self.switchBlock(continue_block);
    }

    fn emitNullCheck(self: *Lowering, pointer_ty: *types.Type, pointer: ir.Value) Error!void {
        if (!self.checks.null_dereference or pointer_ty.* != .pointer) return;
        const bool_ty = try self.booleanType();
        const condition = try self.reg(bool_ty);
        try self.emit(.{ .icmp = .{ .dst = condition, .op = .eq, .ty = pointer_ty, .lhs = pointer, .rhs = .null_ptr } });
        try self.emitTrapBranch(condition);
    }

    fn emitArrayBoundsCheck(
        self: *Lowering,
        base_ty: *types.Type,
        index_value: ir.Value,
        index_ty: *types.Type,
    ) Error!void {
        if (!self.checks.bounds) return;
        const usize_ty = try self.allocator.create(types.Type);
        usize_ty.* = .{ .int = .{ .bits = 64, .signed = false } };
        return self.emitIndexBoundsCheck(index_value, index_ty, .{ .int = @intCast(base_ty.array.len) }, usize_ty);
    }

    fn emitIndexBoundsCheck(
        self: *Lowering,
        index_value: ir.Value,
        index_ty: *types.Type,
        input_len_value: ir.Value,
        len_ty: *types.Type,
    ) Error!void {
        if (!self.checks.bounds) return;
        const i128_ty = try self.i128Type();
        const bool_ty = try self.booleanType();
        const len_value = try self.castIntegerValue(input_len_value, len_ty, i128_ty);
        const zero_value: ir.Value = .{ .int = 0 };

        var normalized = index_value;
        if (index_ty.* != .int or index_ty.int.bits != 128) {
            const signed = index_ty.isInteger() and index_ty.intInfo().signed;
            const kind: ir.CastKind = if (signed) .sext else .zext;
            const dst = try self.reg(i128_ty);
            try self.emit(.{ .cast = .{ .dst = dst, .kind = kind, .from = index_ty, .to = i128_ty, .value = index_value } });
            normalized = .{ .reg = dst };
        }

        var cond: u32 = undefined;
        if (index_ty.isInteger() and index_ty.intInfo().signed) {
            const negative = try self.reg(bool_ty);
            try self.emit(.{ .icmp = .{ .dst = negative, .op = .lt, .ty = i128_ty, .lhs = normalized, .rhs = zero_value } });
            const too_large = try self.reg(bool_ty);
            try self.emit(.{ .icmp = .{ .dst = too_large, .op = .ge, .ty = i128_ty, .lhs = normalized, .rhs = len_value } });
            cond = try self.reg(bool_ty);
            try self.emit(.{ .binary = .{ .dst = cond, .op = .bit_or, .ty = bool_ty, .lhs = .{ .reg = negative }, .rhs = .{ .reg = too_large } } });
        } else {
            cond = try self.reg(bool_ty);
            try self.emit(.{ .icmp = .{ .dst = cond, .op = .ge, .ty = i128_ty, .lhs = normalized, .rhs = len_value } });
        }
        try self.emitTrapBranch(cond);
    }

    fn emitDivisionByZeroTrap(
        self: *Lowering,
        lhs: ir.Value,
        rhs: ir.Value,
        lhs_ty: *types.Type,
        rhs_ty: *types.Type,
    ) Error!void {
        if (!self.checks.division or !rhs_ty.isInteger()) return;
        const bool_ty = try self.booleanType();

        const is_zero = try self.reg(bool_ty);
        try self.emit(.{ .icmp = .{ .dst = is_zero, .op = .eq, .ty = rhs_ty, .lhs = rhs, .rhs = .{ .int = 0 } } });
        var cond = is_zero;

        if (rhs_ty.intInfo().signed) {
            const info = rhs_ty.intInfo();
            const min_value = -(@as(i128, 1) << @intCast(info.bits - 1));
            const lhs_is_min = try self.reg(bool_ty);
            try self.emit(.{ .icmp = .{ .dst = lhs_is_min, .op = .eq, .ty = lhs_ty, .lhs = lhs, .rhs = .{ .int = min_value } } });
            const rhs_is_neg_one = try self.reg(bool_ty);
            try self.emit(.{ .icmp = .{ .dst = rhs_is_neg_one, .op = .eq, .ty = rhs_ty, .lhs = rhs, .rhs = .{ .int = -1 } } });
            const is_min_div = try self.reg(bool_ty);
            try self.emit(.{ .binary = .{ .dst = is_min_div, .op = .bit_and, .ty = bool_ty, .lhs = .{ .reg = lhs_is_min }, .rhs = .{ .reg = rhs_is_neg_one } } });
            cond = try self.reg(bool_ty);
            try self.emit(.{ .binary = .{ .dst = cond, .op = .bit_or, .ty = bool_ty, .lhs = .{ .reg = is_zero }, .rhs = .{ .reg = is_min_div } } });
        }

        try self.emitTrapBranch(cond);
    }

    fn castIntegerValue(self: *Lowering, value: ir.Value, from_ty: *types.Type, to_ty: *types.Type) Error!ir.Value {
        if (types.Type.eql(from_ty, to_ty)) return value;
        if (!from_ty.isInteger() or !to_ty.isInteger()) return value;
        switch (value) {
            .int => return value,
            else => {},
        }
        const from_bits: u16 = if (from_ty.* == .comptime_int) 64 else from_ty.intInfo().bits;
        const to_bits: u16 = if (to_ty.* == .comptime_int) 64 else to_ty.intInfo().bits;
        const signed = from_ty.isInteger() and from_ty.intInfo().signed;
        const kind: ir.CastKind = if (from_bits < to_bits) (if (signed) .sext else .zext) else .trunc;
        const dst = try self.reg(to_ty);
        try self.emit(.{ .cast = .{ .dst = dst, .kind = kind, .from = from_ty, .to = to_ty, .value = value } });
        return .{ .reg = dst };
    }

    fn lowerCheckedBinary(
        self: *Lowering,
        op: ir.BinaryOp,
        lhs: ir.Value,
        lhs_ty: *types.Type,
        rhs: ir.Value,
        rhs_ty: *types.Type,
        ty: *types.Type,
    ) Error!ir.Value {
        var lhs_value = lhs;
        var rhs_value = rhs;
        const is_int_op = ty.isInteger() and (op == .add or op == .sub or op == .mul);
        lhs_value = try self.castIntegerValue(lhs_value, lhs_ty, ty);
        rhs_value = try self.castIntegerValue(rhs_value, rhs_ty, ty);

        if (!is_int_op or !self.checks.integer_overflow) {
            const dst = try self.reg(ty);
            try self.emit(.{ .binary = .{ .dst = dst, .op = op, .ty = ty, .lhs = lhs_value, .rhs = rhs_value } });
            return .{ .reg = dst };
        }
        const bool_ty = try self.booleanType();
        const dst = try self.reg(ty);
        const overflow = try self.reg(bool_ty);
        try self.emit(.{ .checked_binary = .{
            .dst = dst,
            .overflow = overflow,
            .op = op,
            .ty = ty,
            .lhs = lhs_value,
            .rhs = rhs_value,
        } });
        try self.emitTrapBranch(overflow);
        return .{ .reg = dst };
    }

    fn emitShiftBoundsCheck(
        self: *Lowering,
        lhs_ty: *types.Type,
        rhs: ir.Value,
        rhs_ty: *types.Type,
    ) Error!void {
        if (!self.checks.shifts or !lhs_ty.isInteger() or !rhs_ty.isInteger()) return;
        const i128_ty = try self.i128Type();
        const bool_ty = try self.booleanType();
        const bits: i128 = @intCast(lhs_ty.intInfo().bits);

        var normalized = rhs;
        if (rhs_ty.* != .int or rhs_ty.int.bits != 128) {
            const signed = rhs_ty.intInfo().signed;
            const kind: ir.CastKind = if (signed) .sext else .zext;
            const dst = try self.reg(i128_ty);
            try self.emit(.{ .cast = .{ .dst = dst, .kind = kind, .from = rhs_ty, .to = i128_ty, .value = rhs } });
            normalized = .{ .reg = dst };
        }

        var cond: u32 = undefined;
        const limit: ir.Value = .{ .int = bits };
        if (rhs_ty.intInfo().signed) {
            const negative = try self.reg(bool_ty);
            try self.emit(.{ .icmp = .{ .dst = negative, .op = .lt, .ty = i128_ty, .lhs = normalized, .rhs = .{ .int = 0 } } });
            const too_large = try self.reg(bool_ty);
            try self.emit(.{ .icmp = .{ .dst = too_large, .op = .ge, .ty = i128_ty, .lhs = normalized, .rhs = limit } });
            cond = try self.reg(bool_ty);
            try self.emit(.{ .binary = .{ .dst = cond, .op = .bit_or, .ty = bool_ty, .lhs = .{ .reg = negative }, .rhs = .{ .reg = too_large } } });
        } else {
            cond = try self.reg(bool_ty);
            try self.emit(.{ .icmp = .{ .dst = cond, .op = .ge, .ty = i128_ty, .lhs = normalized, .rhs = limit } });
        }
        try self.emitTrapBranch(cond);
    }

    fn lowerFunction(self: *Lowering, fd: *ast.FnDecl, body: *ast.Block) Error!void {
        const function = findFunction(self.module, fd.sym.?.link_name) orelse return;
        const ctx = try self.allocator.create(FnCtx);
        ctx.* = .{ .function = function };
        self.ctx = ctx;
        self.current_fd = fd;
        defer self.ctx = null;
        defer self.current_fd = null;

        _ = try self.newBlock();

        const boundary = fd.is_extern or fd.is_export;
        var visible_index: usize = if (boundary and self.aggregateBoundaryRet(fd.ret_expr) == .memory) 1 else 0;
        for (fd.params) |param| {
            const sym = param.sym orelse continue;
            const class = if (boundary) self.aggregateBoundaryParam(sym.ty) else BoundaryClass.none;
            const padding: ?u16 = switch (class) {
                .small_1, .small_2, .sse_float, .sse_double, .sse_f32x2, .sse_f32x3, .sse_f32x4, .sse_f64x2, .sse_f64_i32, .sse_i32_f64, .sse_f32_f64, .sse_f64_f32, .sse_f32_i64, .sse_i64_f32, .sse_f64_i64, .sse_i64_f64, .sse_f32x2_i32, .sse_f32x2_i64, .sse_i64_f32x, .sse_i64_f64x, .sse_f64_i64x, .sse_i64_v2f32, .sse_f64_v2f32, .sse_v2f32_f64, .sse_i8_f64, .sse_i16_f64, .sse_f64_i8, .sse_f64_i16 => @intCast(self.aggregateSize(sym.ty) orelse 8),
                .memory => @intCast(self.aggregateSize(sym.ty) orelse 16),
                .none => null,
            };
            try self.addLocal(sym.id, sym.name, sym.ty, padding);

            if (class != .none) {
                const class_size = self.aggregateSize(sym.ty) orelse 0;
                switch (class) {
                    .small_1 => {
                        if (function.params.len <= visible_index) break;
                        const base = function.params[visible_index].local;
                        try self.lowerPackedAggregate(.{ .local = sym.id }, class_size, .{ .param = base }, 0);
                        visible_index += 1;
                    },
                    .small_2 => {
                        if (function.params.len <= visible_index + 1) break;
                        const lo = function.params[visible_index].local;
                        const hi = function.params[visible_index + 1].local;
                        try self.lowerPackedAggregate(.{ .local = sym.id }, self.aggregateSize(sym.ty) orelse 8, .{ .param = lo }, 0);
                        try self.lowerPackedAggregate(.{ .local = sym.id }, self.aggregateSize(sym.ty) orelse 16, .{ .param = hi }, 8);
                        visible_index += 2;
                    },
                    .sse_float, .sse_double => {
                        if (function.params.len <= visible_index) break;
                        const field_ty = sym.ty.struct_type.fields[0].ty;
                        try self.emitValueStore(.{
                            .ptr = .{ .local = sym.id },
                            .value = .{ .param = function.params[visible_index].local },
                            .ty = field_ty,
                        });
                        visible_index += 1;
                    },
                    .sse_f32x2 => {
                        if (function.params.len <= visible_index) break;
                        const vector_ty = try self.simpleType(.abi_vec2_f32);
                        try self.emitValueStore(.{
                            .ptr = .{ .local = sym.id },
                            .value = .{ .param = function.params[visible_index].local },
                            .ty = vector_ty,
                        });
                        visible_index += 1;
                    },
                    .sse_f32x3 => {
                        if (function.params.len <= visible_index + 1) break;
                        const vector_ty = try self.simpleType(.abi_vec2_f32);
                        try self.emitValueStore(.{
                            .ptr = .{ .local = sym.id },
                            .value = .{ .param = function.params[visible_index].local },
                            .ty = vector_ty,
                        });
                        const elem_i8 = try self.simpleType(.char);
                        const tail_ptr = try self.byteOffset(.{ .local = sym.id }, 8, elem_i8);
                        const float_ty = try self.simpleType(.{ .float = 32 });
                        try self.emitValueStore(.{
                            .ptr = tail_ptr,
                            .value = .{ .param = function.params[visible_index + 1].local },
                            .ty = float_ty,
                        });
                        visible_index += 2;
                    },
                    .sse_f32x4 => {
                        if (function.params.len <= visible_index + 1) break;
                        const vector_ty = try self.simpleType(.abi_vec2_f32);
                        try self.emitValueStore(.{
                            .ptr = .{ .local = sym.id },
                            .value = .{ .param = function.params[visible_index].local },
                            .ty = vector_ty,
                        });
                        const elem_i8 = try self.simpleType(.char);
                        const tail_ptr = try self.byteOffset(.{ .local = sym.id }, 8, elem_i8);
                        try self.emitValueStore(.{
                            .ptr = tail_ptr,
                            .value = .{ .param = function.params[visible_index + 1].local },
                            .ty = vector_ty,
                        });
                        visible_index += 2;
                    },
                    .sse_f64x2, .sse_f64_i32, .sse_i32_f64, .sse_f32_f64, .sse_f64_f32, .sse_f32_i64, .sse_i64_f32, .sse_f64_i64, .sse_i64_f64, .sse_i8_f64, .sse_i16_f64, .sse_f64_i8, .sse_f64_i16 => {
                        const info = sym.ty.struct_type;
                        if (function.params.len < visible_index + info.fields.len) break;
                        for (0..info.fields.len) |field_index| {
                            const field_ptr = try self.aggregateFieldPointer(.{ .local = sym.id }, info, @intCast(field_index));
                            try self.emitValueStore(.{
                                .ptr = field_ptr,
                                .value = .{ .param = function.params[visible_index + field_index].local },
                                .ty = function.params[visible_index + field_index].ty,
                            });
                        }
                        visible_index += info.fields.len;
                    },
                    .sse_f32x2_i32, .sse_f32x2_i64, .sse_v2f32_f64, .sse_i64_f32x, .sse_i64_f64x, .sse_f64_i64x, .sse_i64_v2f32, .sse_f64_v2f32 => {
                        // Two-slot transport: bytes 0-7 then bytes 8-15 in field order.
                        if (function.params.len <= visible_index + 1) break;
                        const first_ty = function.params[visible_index].ty;
                        try self.emitValueStore(.{
                            .ptr = .{ .local = sym.id },
                            .value = .{ .param = function.params[visible_index].local },
                            .ty = first_ty,
                        });
                        const elem_i8 = try self.simpleType(.char);
                        const tail_ptr = try self.byteOffset(.{ .local = sym.id }, 8, elem_i8);
                        const second_ty = function.params[visible_index + 1].ty;
                        try self.emitValueStore(.{
                            .ptr = tail_ptr,
                            .value = .{ .param = function.params[visible_index + 1].local },
                            .ty = second_ty,
                        });
                        visible_index += 2;
                    },
                    .memory => {
                        if (function.params.len <= visible_index) break;
                        const base = function.params[visible_index].local;
                        try self.emit(.{ .copy_bytes = .{
                            .destination = .{ .local = sym.id },
                            .source = .{ .param = base },
                            .length = @intCast(class_size),
                        } });
                        visible_index += 1;
                    },
                    else => unreachable,
                }
            } else {
                if (function.params.len <= visible_index) break;
                try self.emitValueStore(.{
                    .ptr = .{ .local = sym.id },
                    .value = .{ .param = function.params[visible_index].local },
                    .ty = function.params[visible_index].ty,
                });
                visible_index += 1;
            }
        }

        try self.lowerBlock(body);

        if (!self.isTerminated()) {
            if (function.ret.* == .void) {
                try self.emit(.{ .ret = .{ .value = null } });
            } else {
                try self.emit(.{ .unreachable_ = {} });
            }
        }
    }

    fn aggregateSize(self: *Lowering, ty: *types.Type) ?usize {
        _ = self;
        const layout = sema_mod.aggregateLayoutGuess(ty) orelse return null;
        return @intCast(layout.size);
    }

    fn aggregateFieldPointer(
        self: *Lowering,
        base: ir.Value,
        info: *types.StructInfo,
        field_index: u32,
    ) Error!ir.Value {
        const field_ty = info.fields[field_index].ty;
        const pointer_ty = try self.makePointer(field_ty, false);
        const pointer = try self.reg(pointer_ty);
        try self.emit(.{ .field_ptr = .{
            .dst = pointer,
            .base = base,
            .struct_ty = info,
            .field = field_index,
        } });
        return .{ .reg = pointer };
    }

    fn lowerPackedAggregate(
        self: *Lowering,
        destination: ir.Value,
        size: usize,
        source: ir.Value,
        offset: usize,
    ) Error!void {
        if (size <= offset) return;
        const i64_ty = try self.simpleType(.{ .int = .{ .bits = 64, .signed = true } });
        const temp = self.module.ephemeral();
        try self.addLocal(temp, "pack", i64_ty, null);
        try self.emitValueStore(.{
            .ptr = .{ .local = temp },
            .value = source,
            .ty = i64_ty,
        });

        var destination_value = destination;
        if (offset > 0) {
            const offset_reg = try self.reg(i64_ty);
            try self.emit(.{ .byte_offset = .{
                .dst = offset_reg,
                .base = destination,
                .offset = @intCast(offset),
            } });
            destination_value = .{ .reg = offset_reg };
        }
        try self.emit(.{ .copy_bytes = .{
            .destination = destination_value,
            .source = .{ .local = temp },
            .length = @intCast(@min(@as(usize, 8), size - offset)),
        } });
    }

    // ------------------------------------------------------------------
    // Statements
    // ------------------------------------------------------------------

    fn lowerBlock(self: *Lowering, block: *ast.Block) Error!void {
        for (block.stmts) |stmt| {
            if (self.isTerminated()) return;
            try self.lowerStmt(stmt);
        }
    }

    fn lowerStmt(self: *Lowering, stmt: *ast.Stmt) Error!void {
        switch (stmt.kind) {
            .expr => |expr| _ = try self.lowerExpr(expr),
            .var_decl => |vd| try self.lowerVarDecl(vd),
            .block => |block| try self.lowerBlock(block),
            .if_stmt => |if_stmt| try self.lowerIf(if_stmt),
            .while_stmt => |while_stmt| try self.lowerWhile(while_stmt),
            .return_stmt => |ret_stmt| {
                if (ret_stmt.value) |expr| {
                    const function = self.currentFunction();
                    const boundary = if (self.current_fd) |fd| fd.is_extern or fd.is_export else false;
                    const ret_class = if (self.current_fd) |fd| blk: {
                        const ret = fd.ret_expr orelse break :blk BoundaryClass.none;
                        const ret_ty = ret.resolved orelse break :blk BoundaryClass.none;
                        if (!boundary) break :blk BoundaryClass.none;
                        break :blk self.aggregateBoundaryParam(ret_ty);
                    } else BoundaryClass.none;
                    const sse_abi_return = ret_class == .sse_float or ret_class == .sse_double or ret_class == .sse_f32x2 or ret_class == .sse_f32x3 or ret_class == .sse_f32x4 or ret_class == .sse_f64x2 or ret_class == .sse_f64_i32 or ret_class == .sse_i32_f64 or ret_class == .sse_f32_f64 or ret_class == .sse_f64_f32 or ret_class == .sse_f32_i64 or ret_class == .sse_i64_f32 or ret_class == .sse_f64_i64 or ret_class == .sse_i64_f64 or ret_class == .sse_f32x2_i32 or ret_class == .sse_f32x2_i64 or ret_class == .sse_i64_f32x or ret_class == .sse_i64_f64x or ret_class == .sse_f64_i64x or ret_class == .sse_i64_v2f32 or ret_class == .sse_f64_v2f32 or ret_class == .sse_v2f32_f64 or ret_class == .sse_i8_f64 or ret_class == .sse_i16_f64 or ret_class == .sse_f64_i8 or ret_class == .sse_f64_i16;
                    const value: ir.Value = if (sse_abi_return) .none else try self.lowerExpr(expr);
                    const hidden_sret = boundary and ret_class == .memory;
                    if (hidden_sret) {
                        try self.emitValueStore(.{
                            .ptr = .{ .param = function.params[0].local },
                            .value = value,
                            .ty = expr.ty.?,
                        });
                        try self.emit(.{ .ret = .{ .value = null } });
                    } else {
                        if (sse_abi_return) {
                            const aggregate_ptr = try self.lowerAggregateBase(expr, expr.ty.?);
                            const abi_ty = switch (ret_class) {
                                .sse_f32x2 => try self.simpleType(.abi_vec2_f32),
                                .sse_f32x3 => try self.simpleType(.abi_v2f32_f32),
                                .sse_f32x4 => try self.simpleType(.abi_v2f32_v2f32),
                                .sse_f64x2 => try self.simpleType(.abi_pair_f64),
                                .sse_f64_i32 => try self.simpleType(.abi_f64_i32),
                                .sse_i32_f64 => try self.simpleType(.abi_i32_f64),
                                .sse_f32_f64 => try self.simpleType(.abi_f32_f64),
                                .sse_f64_f32 => try self.simpleType(.abi_f64_f32),
                                .sse_f32_i64 => try self.simpleType(.abi_f32_i64),
                                .sse_i64_f32 => try self.simpleType(.abi_i64_f32),
                                .sse_f64_i64 => try self.simpleType(.abi_f64_i64),
                                .sse_i64_f64 => try self.simpleType(.abi_i64_f64),
                                .sse_f32x2_i32 => try self.simpleType(.abi_v2f32_i32),
                                .sse_f32x2_i64 => try self.simpleType(.abi_v2f32_i64),
                                .sse_i64_f32x => try self.simpleType(.abi_i64_f32),
                                .sse_i64_f64x => try self.simpleType(.abi_i64_f64),
                                .sse_f64_i64x => try self.simpleType(.abi_f64_i64),
                                .sse_i64_v2f32 => try self.simpleType(.abi_i64_v2f32),
                                .sse_f64_v2f32 => try self.simpleType(.abi_f64_v2f32),
                                .sse_v2f32_f64 => try self.simpleType(.abi_v2f32_f64),
                                .sse_i8_f64 => try self.simpleType(.abi_i8_f64),
                                .sse_i16_f64 => try self.simpleType(.abi_i16_f64),
                                .sse_f64_i8 => try self.simpleType(.abi_f64_i8),
                                .sse_f64_i16 => try self.simpleType(.abi_f64_i16),
                                else => expr.ty.?.struct_type.fields[0].ty,
                            };
                            const field_value = try self.reg(abi_ty);
                            try self.emit(.{ .load = .{
                                .dst = field_value,
                                .ptr = aggregate_ptr,
                                .ty = abi_ty,
                            } });
                            try self.emit(.{ .ret = .{ .value = .{ .reg = field_value } } });
                        } else if (ret_class == .small_1 or ret_class == .small_2) {
                            const storage_ty = if (ret_class == .small_1)
                                try self.simpleType(.{ .int = .{ .bits = 64, .signed = true } })
                            else
                                try self.simpleType(.{ .int = .{ .bits = 128, .signed = true } });
                            const temp = self.module.ephemeral();
                            try self.addLocal(temp, "pack", storage_ty, null);
                            try self.emitValueStore(.{
                                .ptr = .{ .local = temp },
                                .value = .{ .int = 0 },
                                .ty = storage_ty,
                            });
                            const storage_value_ty = expr.ty orelse try self.simpleType(.invalid);
                            try self.emitValueStore(.{
                                .ptr = .{ .local = temp },
                                .value = value,
                                .ty = storage_value_ty,
                            });
                            const loaded = try self.reg(storage_ty);
                            try self.emit(.{ .load = .{
                                .dst = loaded,
                                .ptr = .{ .local = temp },
                                .ty = storage_ty,
                            } });
                            try self.emit(.{ .ret = .{ .value = .{ .reg = loaded } } });
                        } else {
                            try self.emit(.{ .ret = .{ .value = value } });
                        }
                    }
                } else {
                    try self.emit(.{ .ret = .{ .value = null } });
                }
            },
            .break_stmt => {
                const target = self.ctx.?.break_stack.items[self.ctx.?.break_stack.items.len - 1];
                try self.emit(.{ .br = .{ .target = target } });
            },
            .continue_stmt => {
                const target = self.ctx.?.continue_stack.items[self.ctx.?.continue_stack.items.len - 1];
                try self.emit(.{ .br = .{ .target = target } });
            },
            .empty => {},
        }
    }

    fn lowerVarDecl(self: *Lowering, vd: *ast.VarDecl) Error!void {
        const sym = vd.sym orelse return;
        const ty = vd.ty orelse return;
        try self.addLocal(sym.id, sym.name, ty, null);
        const init_value = vd.init orelse return;

        if (ty.isAggregate() and isAggregateInitializer(init_value)) {
            try self.lowerAggregateInto(.{ .local = sym.id }, ty, init_value);
        } else {
            const value = try self.lowerExpr(init_value);
            try self.emitValueStore(.{ .ptr = .{ .local = sym.id }, .value = value, .ty = ty });
        }
    }

    fn lowerIf(self: *Lowering, if_stmt: *ast.Stmt.IfStmt) Error!void {
        const cond = try self.lowerExpr(if_stmt.cond);
        const then_block = try self.newBlock();
        const else_block = try self.newBlock();
        const merge_block = try self.newBlock();
        try self.emit(.{ .cbr = .{
            .cond = cond,
            .then_block = then_block,
            .else_block = else_block,
        } });

        try self.switchBlock(then_block);
        try self.lowerBlock(if_stmt.then_branch);
        if (!self.isTerminated()) try self.emit(.{ .br = .{ .target = merge_block } });

        try self.switchBlock(else_block);
        if (if_stmt.else_branch) |else_stmt| try self.lowerStmt(else_stmt);
        if (!self.isTerminated()) try self.emit(.{ .br = .{ .target = merge_block } });

        try self.switchBlock(merge_block);
    }

    fn lowerWhile(self: *Lowering, while_stmt: *ast.Stmt.WhileStmt) Error!void {
        const cond_block = try self.newBlock();
        const body_block = try self.newBlock();
        const end_block = try self.newBlock();
        try self.emit(.{ .br = .{ .target = cond_block } });

        try self.switchBlock(cond_block);
        const cond = try self.lowerExpr(while_stmt.cond);
        try self.emit(.{ .cbr = .{
            .cond = cond,
            .then_block = body_block,
            .else_block = end_block,
        } });

        try self.switchBlock(body_block);
        try self.ctx.?.break_stack.append(self.allocator, end_block);
        try self.ctx.?.continue_stack.append(self.allocator, cond_block);
        try self.lowerBlock(while_stmt.body);
        if (!self.isTerminated()) try self.emit(.{ .br = .{ .target = cond_block } });
        _ = self.ctx.?.break_stack.pop();
        _ = self.ctx.?.continue_stack.pop();

        try self.switchBlock(end_block);
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    fn lowerExpr(self: *Lowering, expr: *ast.Expr) Error!ir.Value {
        return switch (expr.kind) {
            .int_lit => |lit| .{ .int = @intCast(lit.value) },
            .float_lit => |lit| .{ .float = lit.value },
            .bool_lit => |value| .{ .boolean = value },
            .char_lit => |value| .{ .int = @intCast(value) },
            .string_lit => |lit| .{ .string = try self.module.addString(lit.bytes) },
            .null_lit => .null_ptr,
            .ident => |ident| try self.lowerIdent(expr, ident),
            .unary => |unary| try self.lowerUnary(expr, unary),
            .binary => |binary| try self.lowerBinary(expr, binary),
            .assign => |assign| try self.lowerAssign(expr, assign),
            .call => |call| try self.lowerCall(expr, call),
            .cast => |cast| try self.lowerCast(expr, cast),
            .field => |field| blk: {
                if (field.is_enum_variant) break :blk .{ .int = field.variant_value };
                if (field.sym) |sym| {
                    if (sym.kind == .global) {
                        const index = self.globals.get(sym.id) orelse return .none;
                        const ty = expr.ty orelse sym.ty;
                        const dst = try self.reg(ty);
                        try self.emit(.{ .load = .{ .dst = dst, .ptr = .{ .global = index }, .ty = ty } });
                        break :blk .{ .reg = dst };
                    }
                    break :blk .none;
                }
                if (field.base.ty) |base_ty| {
                    if (base_ty.* == .slice) {
                        const slice_ptr = try self.lowerAggregateBase(field.base, base_ty);
                        if (std.mem.eql(u8, field.name, "len")) {
                            break :blk try self.loadSliceLength(slice_ptr);
                        }
                        if (std.mem.eql(u8, field.name, "ptr")) {
                            break :blk try self.loadSliceData(slice_ptr, base_ty.slice.elem);
                        }
                    }
                    if (field.through_pointer and base_ty.* == .pointer and base_ty.pointer.elem.* == .slice) {
                        const slice_ptr = try self.lowerExpr(field.base);
                        try self.emitNullCheck(base_ty, slice_ptr);
                        const slice_ty = base_ty.pointer.elem;
                        if (std.mem.eql(u8, field.name, "len")) {
                            break :blk try self.loadSliceLength(slice_ptr);
                        }
                        if (std.mem.eql(u8, field.name, "ptr")) {
                            break :blk try self.loadSliceData(slice_ptr, slice_ty.slice.elem);
                        }
                    }
                    if (base_ty.* == .array and std.mem.eql(u8, field.name, "len")) {
                        if (field.base.kind != .ident) {
                            const lv = try self.lowerLvalue(field.base);
                            if (lv == .none) _ = try self.lowerExpr(field.base);
                        }
                        break :blk .{ .int = @intCast(base_ty.array.len) };
                    }
                    if (field.through_pointer and base_ty.* == .pointer and base_ty.pointer.elem.* == .array and std.mem.eql(u8, field.name, "len")) {
                        const arr_ptr = try self.lowerExpr(field.base);
                        try self.emitNullCheck(base_ty, arr_ptr);
                        break :blk .{ .int = @intCast(base_ty.pointer.elem.array.len) };
                    }
                }
                const ptr = try self.lowerLvalue(expr);
                const ty = expr.ty orelse return .none;
                const dst = try self.reg(ty);
                try self.emit(.{ .load = .{ .dst = dst, .ptr = ptr, .ty = ty } });
                break :blk .{ .reg = dst };
            },
            .index => blk: {
                const ptr = try self.lowerLvalue(expr);
                const ty = expr.ty orelse return .none;
                const dst = try self.reg(ty);
                try self.emit(.{ .load = .{ .dst = dst, .ptr = ptr, .ty = ty } });
                break :blk .{ .reg = dst };
            },
            .slice => |slice| try self.lowerSlice(expr, slice),
            .struct_init, .array_lit => blk: {
                const ty = expr.ty orelse return .none;
                const id = self.module.ephemeral();
                try self.addLocal(id, "tmp.agg", ty, null);
                try self.lowerAggregateInto(.{ .local = id }, ty, expr);
                const dst = try self.reg(ty);
                try self.emit(.{ .load = .{ .dst = dst, .ptr = .{ .local = id }, .ty = ty } });
                break :blk .{ .reg = dst };
            },
        };
    }

    fn lowerIdent(self: *Lowering, expr: *ast.Expr, ident: ast.Expr.Kind.Ident) Error!ir.Value {
        const sym = ident.sym orelse return .none;
        if (sym.kind == .function or sym.kind == .struct_type or sym.kind == .enum_type) return .none;
        const ty = expr.ty orelse sym.ty;
        const ptr: ir.Value = if (sym.kind == .global)
            .{ .global = self.globals.get(sym.id) orelse return .none }
        else
            .{ .local = sym.id };
        const dst = try self.reg(ty);
        try self.emit(.{ .load = .{ .dst = dst, .ptr = ptr, .ty = ty } });
        return .{ .reg = dst };
    }

    fn lowerUnary(self: *Lowering, expr: *ast.Expr, unary: ast.Expr.Kind.Unary) Error!ir.Value {
        switch (unary.op) {
            .address_of => return self.lowerLvalue(unary.operand),
            .dereference => {
                const ptr = try self.lowerExpr(unary.operand);
                if (unary.operand.ty) |pointer_ty| try self.emitNullCheck(pointer_ty, ptr);
                const ty = expr.ty orelse return .none;
                const dst = try self.reg(ty);
                try self.emit(.{ .load = .{ .dst = dst, .ptr = ptr, .ty = ty } });
                return .{ .reg = dst };
            },
            else => {},
        }
        const operand = try self.lowerExpr(unary.operand);
        const ty = expr.ty orelse return .none;
        if (unary.op == .negate and ty.isInteger()) {
            const operand_ty = unary.operand.ty orelse ty;
            return self.lowerCheckedBinary(.sub, .{ .int = 0 }, ty, operand, operand_ty, ty);
        }
        const dst = try self.reg(ty);
        const op: ir.UnOp = switch (unary.op) {
            .negate => .negate,
            .logical_not => .logical_not,
            .bit_not => .bit_not,
            else => unreachable,
        };
        try self.emit(.{ .unary = .{ .dst = dst, .op = op, .ty = ty, .operand = operand } });
        return .{ .reg = dst };
    }

    fn lowerBinary(self: *Lowering, expr: *ast.Expr, binary: ast.Expr.Kind.Binary) Error!ir.Value {
        if (binary.op == .logical_and or binary.op == .logical_or) {
            return self.lowerLogical(expr, binary);
        }

        const lhs_ty = binary.lhs.ty orelse return .none;
        const rhs_ty = binary.rhs.ty orelse return .none;

        if (lhs_ty.* == .pointer and rhs_ty.isInteger() and (binary.op == .add or binary.op == .sub)) {
            const base = try self.lowerExpr(binary.lhs);
            var index = try self.lowerExpr(binary.rhs);
            if (binary.op == .sub) index = try self.negateIndex(index, rhs_ty);
            const dst = try self.reg(lhs_ty);
            try self.emit(.{ .elem_ptr = .{
                .dst = dst,
                .base = base,
                .container = lhs_ty,
                .index = index,
                .index_ty = rhs_ty,
                .is_array = false,
            } });
            return .{ .reg = dst };
        }
        if (lhs_ty.* == .pointer and rhs_ty.* == .pointer and binary.op == .sub) {
            return self.lowerPointerDifference(expr, binary, lhs_ty, rhs_ty);
        }

        const lhs = try self.lowerExpr(binary.lhs);
        const rhs = try self.lowerExpr(binary.rhs);
        const ty = expr.ty orelse return .none;
        if (binary.op == .div or binary.op == .mod) {
            try self.emitDivisionByZeroTrap(lhs, rhs, lhs_ty, rhs_ty);
        }

        switch (binary.op) {
            .eq, .ne, .lt, .le, .gt, .ge => return self.lowerComparison(expr, binary, lhs, rhs, lhs_ty),
            .shl, .shr => try self.emitShiftBoundsCheck(ty, rhs, rhs_ty),
            else => {},
        }
        const op = binaryOp(binary.op) orelse return .none;
        return self.lowerCheckedBinary(op, lhs, lhs_ty, rhs, rhs_ty, ty);
    }

    fn lowerComparison(
        self: *Lowering,
        expr: *ast.Expr,
        binary: ast.Expr.Kind.Binary,
        lhs: ir.Value,
        rhs: ir.Value,
        operand_ty: *types.Type,
    ) Error!ir.Value {
        _ = expr;
        const bool_ty = try self.allocator.create(types.Type);
        bool_ty.* = .bool;
        const dst = try self.reg(bool_ty);
        const op: ir.CmpOp = switch (binary.op) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => unreachable,
        };
        if (operand_ty.isFloat()) {
            try self.emit(.{ .fcmp = .{ .dst = dst, .op = op, .ty = operand_ty, .lhs = lhs, .rhs = rhs } });
        } else {
            try self.emit(.{ .icmp = .{ .dst = dst, .op = op, .ty = operand_ty, .lhs = lhs, .rhs = rhs } });
        }
        return .{ .reg = dst };
    }

    fn lowerLogical(self: *Lowering, expr: *ast.Expr, binary: ast.Expr.Kind.Binary) Error!ir.Value {
        _ = expr;
        const bool_ty = try self.allocator.create(types.Type);
        bool_ty.* = .bool;
        const slot = self.module.ephemeral();
        try self.addLocal(slot, "tmp.cond", bool_ty, null);
        const default_value: ir.Value = .{ .boolean = binary.op == .logical_or };
        try self.emitValueStore(.{ .ptr = .{ .local = slot }, .value = default_value, .ty = bool_ty });

        const lhs = try self.lowerExpr(binary.lhs);
        const rhs_block = try self.newBlock();
        const end_block = try self.newBlock();
        try self.emit(.{ .cbr = .{
            .cond = lhs,
            .then_block = if (binary.op == .logical_and) rhs_block else end_block,
            .else_block = if (binary.op == .logical_and) end_block else rhs_block,
        } });

        try self.switchBlock(rhs_block);
        const rhs = try self.lowerExpr(binary.rhs);
        try self.emitValueStore(.{ .ptr = .{ .local = slot }, .value = rhs, .ty = bool_ty });
        try self.emit(.{ .br = .{ .target = end_block } });

        try self.switchBlock(end_block);
        const dst = try self.reg(bool_ty);
        try self.emit(.{ .load = .{ .dst = dst, .ptr = .{ .local = slot }, .ty = bool_ty } });
        return .{ .reg = dst };
    }

    fn negateIndex(self: *Lowering, value: ir.Value, ty: *types.Type) Error!ir.Value {
        if (value == .int) return .{ .int = -value.int };
        const dst = try self.reg(ty);
        try self.emit(.{ .unary = .{ .dst = dst, .op = .negate, .ty = ty, .operand = value } });
        return .{ .reg = dst };
    }

    fn lowerPointerDifference(
        self: *Lowering,
        expr: *ast.Expr,
        binary: ast.Expr.Kind.Binary,
        lhs_ty: *types.Type,
        rhs_ty: *types.Type,
    ) Error!ir.Value {
        _ = rhs_ty;
        const isize_ty = try self.allocator.create(types.Type);
        isize_ty.* = .{ .int = .{ .bits = 64, .signed = true } };

        const lhs_i = try self.reg(isize_ty);
        try self.emit(.{ .cast = .{ .dst = lhs_i, .kind = .ptrtoint, .from = lhs_ty, .to = isize_ty, .value = try self.lowerExpr(binary.lhs) } });
        const rhs_i = try self.reg(isize_ty);
        try self.emit(.{ .cast = .{ .dst = rhs_i, .kind = .ptrtoint, .from = lhs_ty, .to = isize_ty, .value = try self.lowerExpr(binary.rhs) } });

        const diff = try self.reg(isize_ty);
        try self.emit(.{ .binary = .{ .dst = diff, .op = .sub, .ty = isize_ty, .lhs = .{ .reg = lhs_i }, .rhs = .{ .reg = rhs_i } } });

        const size = sizeInBytes(lhs_ty.pointer.elem) orelse {
            try self.reporter.err("E0603", expr.span, "pointer difference requires an element type with a known scalar size", .{});
            return .none;
        };
        const result = try self.reg(isize_ty);
        try self.emit(.{ .binary = .{ .dst = result, .op = .div, .ty = isize_ty, .lhs = .{ .reg = diff }, .rhs = .{ .int = @intCast(size) } } });
        return .{ .reg = result };
    }

    fn lowerAssign(self: *Lowering, expr: *ast.Expr, assign: ast.Expr.Kind.Assign) Error!ir.Value {
        _ = expr;
        const target_ty = assign.target.ty orelse return .none;
        const ptr = try self.lowerLvalue(assign.target);

        if (assign.op == .assign) {
            if (target_ty.isAggregate() and isAggregateInitializer(assign.value)) {
                try self.lowerAggregateInto(ptr, target_ty, assign.value);
            } else {
                const value = try self.lowerExpr(assign.value);
                try self.emitValueStore(.{ .ptr = ptr, .value = value, .ty = target_ty });
            }
            const dst = try self.reg(target_ty);
            try self.emit(.{ .load = .{ .dst = dst, .ptr = ptr, .ty = target_ty } });
            return .{ .reg = dst };
        }

        const current = try self.reg(target_ty);
        try self.emit(.{ .load = .{ .dst = current, .ptr = ptr, .ty = target_ty } });
        const rhs = try self.lowerExpr(assign.value);
        const rhs_ty = assign.value.ty orelse return .none;
        const op: ir.BinaryOp = switch (assign.op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .bit_and => .bit_and,
            .bit_or => .bit_or,
            .bit_xor => .bit_xor,
            .shl => .shl,
            .shr => .shr,
            .assign => unreachable,
        };
        if (op == .div or op == .mod) {
            try self.emitDivisionByZeroTrap(.{ .reg = current }, rhs, target_ty, rhs_ty);
        } else if (op == .shl or op == .shr) {
            try self.emitShiftBoundsCheck(target_ty, rhs, rhs_ty);
        }
        const result = try self.lowerCheckedBinary(op, .{ .reg = current }, target_ty, rhs, rhs_ty, target_ty);
        try self.emitValueStore(.{ .ptr = ptr, .value = result, .ty = target_ty });
        return result;
    }

    fn lowerCall(self: *Lowering, expr: *ast.Expr, call: ast.Expr.Kind.Call) Error!ir.Value {
        const callee_sym = switch (call.callee.kind) {
            .ident => |ident| ident.sym,
            .field => |field| field.sym,
            else => null,
        };
        if (callee_sym == null or callee_sym.?.kind != .function) {
            try self.reporter.err("E0604", call.callee.span, "indirect calls are not supported yet", .{});
            return .none;
        }
        const name = callee_sym.?.link_name;
        const call_result = expr.ty orelse return .none;
        const callee_boundary = callee_sym.?.is_extern or callee_sym.?.is_export;

        if (!callee_boundary) {
            const ret = expr.ty orelse return .none;
            var args = try self.allocator.alloc(ir.Value, call.args.len);
            var arg_types = try self.allocator.alloc(*types.Type, call.args.len);
            for (call.args, 0..) |arg, i| {
                args[i] = try self.lowerExpr(arg);
                arg_types[i] = arg.ty orelse return .none;
            }
            var dst: ?u32 = null;
            if (ret.* != .void) dst = try self.reg(ret);
            try self.emit(.{ .call = .{
                .dst = dst,
                .name = name,
                .args = args,
                .arg_types = arg_types,
                .ret = ret,
            } });
            return if (dst) |id| .{ .reg = id } else .none;
        }

        const ret_class = self.aggregateBoundaryParam(call_result);

        var byval_list: std.ArrayList(?*types.StructInfo) = .empty;
        var args_list: std.ArrayList(ir.Value) = .empty;
        var types_list: std.ArrayList(*types.Type) = .empty;
        const i64_ty = try self.simpleType(.{ .int = .{ .bits = 64, .signed = true } });
        const i128_ty = try self.simpleType(.{ .int = .{ .bits = 128, .signed = true } });
        const void_ty = try self.simpleType(.void);
        const ptr_ty = try self.makePointer(void_ty, false);

        if (ret_class == .memory) {
            const temp = self.module.ephemeral();
            try self.addLocal(temp, "tmp.aggregate", call_result, null);
            try args_list.append(self.allocator, .{ .local = temp });
            try types_list.append(self.allocator, ptr_ty);
            try byval_list.append(self.allocator, null);
        }

        for (call.args) |arg| {
            const ty = arg.ty orelse try self.simpleType(.invalid);
            switch (self.aggregateBoundaryParam(ty)) {
                .none => {
                    try args_list.append(self.allocator, try self.lowerExpr(arg));
                    try types_list.append(self.allocator, ty);
                    try byval_list.append(self.allocator, null);
                },
                .small_1 => {
                    const slot = try self.lowerAggregateBase(arg, ty);
                    const size = self.aggregateSize(ty) orelse 8;
                    var pack_ptr = slot;
                    if (size < 8) {
                        const pack_id = self.module.ephemeral();
                        try self.addLocal(pack_id, "tmp.pack1", i64_ty, null);
                        try self.emitValueStore(.{ .ptr = .{ .local = pack_id }, .value = .{ .int = 0 }, .ty = i64_ty });
                        if (size > 0) {
                            try self.emit(.{ .copy_bytes = .{ .destination = .{ .local = pack_id }, .source = slot, .length = @intCast(size) } });
                        }
                        pack_ptr = .{ .local = pack_id };
                    }
                    const loaded = try self.reg(i64_ty);
                    try self.emit(.{ .load = .{ .dst = loaded, .ptr = pack_ptr, .ty = i64_ty } });
                    try args_list.append(self.allocator, .{ .reg = loaded });
                    try types_list.append(self.allocator, i64_ty);
                    try byval_list.append(self.allocator, null);
                },
                .sse_float, .sse_double => {
                    const slot = try self.lowerAggregateBase(arg, ty);
                    const field_ty = ty.struct_type.fields[0].ty;
                    const field_value = try self.reg(field_ty);
                    try self.emit(.{ .load = .{
                        .dst = field_value,
                        .ptr = slot,
                        .ty = field_ty,
                    } });
                    try args_list.append(self.allocator, .{ .reg = field_value });
                    try types_list.append(self.allocator, field_ty);
                    try byval_list.append(self.allocator, null);
                },
                .sse_f32x2 => {
                    const slot = try self.lowerAggregateBase(arg, ty);
                    const vector_ty = try self.simpleType(.abi_vec2_f32);
                    const vector_value = try self.reg(vector_ty);
                    try self.emit(.{ .load = .{
                        .dst = vector_value,
                        .ptr = slot,
                        .ty = vector_ty,
                    } });
                    try args_list.append(self.allocator, .{ .reg = vector_value });
                    try types_list.append(self.allocator, vector_ty);
                    try byval_list.append(self.allocator, null);
                },
                .sse_f32x3 => {
                    const slot = try self.lowerAggregateBase(arg, ty);
                    const vector_ty = try self.simpleType(.abi_vec2_f32);
                    const vector_value = try self.reg(vector_ty);
                    try self.emit(.{ .load = .{
                        .dst = vector_value,
                        .ptr = slot,
                        .ty = vector_ty,
                    } });
                    try args_list.append(self.allocator, .{ .reg = vector_value });
                    try types_list.append(self.allocator, vector_ty);
                    try byval_list.append(self.allocator, null);
                    const elem_i8 = try self.simpleType(.char);
                    const tail_ptr = try self.byteOffset(slot, 8, elem_i8);
                    const float_ty = try self.simpleType(.{ .float = 32 });
                    const tail_value = try self.reg(float_ty);
                    try self.emit(.{ .load = .{
                        .dst = tail_value,
                        .ptr = tail_ptr,
                        .ty = float_ty,
                    } });
                    try args_list.append(self.allocator, .{ .reg = tail_value });
                    try types_list.append(self.allocator, float_ty);
                    try byval_list.append(self.allocator, null);
                },
                .sse_f32x4 => {
                    const slot = try self.lowerAggregateBase(arg, ty);
                    const vector_ty = try self.simpleType(.abi_vec2_f32);
                    const first = try self.reg(vector_ty);
                    try self.emit(.{ .load = .{
                        .dst = first,
                        .ptr = slot,
                        .ty = vector_ty,
                    } });
                    try args_list.append(self.allocator, .{ .reg = first });
                    try types_list.append(self.allocator, vector_ty);
                    try byval_list.append(self.allocator, null);
                    const elem_i8 = try self.simpleType(.char);
                    const tail_ptr = try self.byteOffset(slot, 8, elem_i8);
                    const second = try self.reg(vector_ty);
                    try self.emit(.{ .load = .{
                        .dst = second,
                        .ptr = tail_ptr,
                        .ty = vector_ty,
                    } });
                    try args_list.append(self.allocator, .{ .reg = second });
                    try types_list.append(self.allocator, vector_ty);
                    try byval_list.append(self.allocator, null);
                },
                .sse_f32x2_i32, .sse_f32x2_i64, .sse_v2f32_f64, .sse_i64_f32x, .sse_i64_f64x, .sse_f64_i64x, .sse_i64_v2f32, .sse_f64_v2f32 => {
                    const slot = try self.lowerAggregateBase(arg, ty);
                    const class_tag = self.aggregateBoundaryParam(ty);
                    const slot0_ty = switch (class_tag) {
                        .sse_f32x2_i32, .sse_f32x2_i64, .sse_v2f32_f64 => try self.simpleType(.abi_vec2_f32),
                        .sse_i64_f32x, .sse_i64_f64x, .sse_i64_v2f32 => i64_ty,
                        .sse_f64_i64x, .sse_f64_v2f32 => try self.simpleType(.{ .float = 64 }),
                        else => unreachable,
                    };
                    const slot0_value = try self.reg(slot0_ty);
                    try self.emit(.{ .load = .{ .dst = slot0_value, .ptr = slot, .ty = slot0_ty } });
                    try args_list.append(self.allocator, .{ .reg = slot0_value });
                    try types_list.append(self.allocator, slot0_ty);
                    try byval_list.append(self.allocator, null);
                    const elem_i8 = try self.simpleType(.char);
                    const tail_ptr = try self.byteOffset(slot, 8, elem_i8);
                    const slot1_ty = switch (class_tag) {
                        .sse_f32x2_i32 => try self.simpleType(.{ .int = .{ .bits = 32, .signed = true } }),
                        .sse_f32x2_i64, .sse_f64_i64x => i64_ty,
                        .sse_v2f32_f64, .sse_i64_f64x => try self.simpleType(.{ .float = 64 }),
                        .sse_i64_f32x => try self.simpleType(.{ .float = 32 }),
                        .sse_i64_v2f32, .sse_f64_v2f32 => try self.simpleType(.abi_vec2_f32),
                        else => unreachable,
                    };
                    const slot1_value = try self.reg(slot1_ty);
                    try self.emit(.{ .load = .{ .dst = slot1_value, .ptr = tail_ptr, .ty = slot1_ty } });
                    try args_list.append(self.allocator, .{ .reg = slot1_value });
                    try types_list.append(self.allocator, slot1_ty);
                    try byval_list.append(self.allocator, null);
                },
                .sse_f64x2, .sse_f64_i32, .sse_i32_f64, .sse_f32_f64, .sse_f64_f32, .sse_f32_i64, .sse_i64_f32, .sse_f64_i64, .sse_i64_f64, .sse_i8_f64, .sse_i16_f64, .sse_f64_i8, .sse_f64_i16 => {
                    const slot = try self.lowerAggregateBase(arg, ty);
                    const info = ty.struct_type;
                    for (0..info.fields.len) |field_index| {
                        const field_ty = info.fields[field_index].ty;
                        const member_ty = try self.boundaryMemberType(field_ty);
                        const field_ptr = try self.aggregateFieldPointer(slot, info, @intCast(field_index));
                        const field_value = try self.reg(member_ty);
                        try self.emit(.{ .load = .{
                            .dst = field_value,
                            .ptr = field_ptr,
                            .ty = member_ty,
                        } });
                        try args_list.append(self.allocator, .{ .reg = field_value });
                        try types_list.append(self.allocator, member_ty);
                        try byval_list.append(self.allocator, null);
                    }
                },
                .small_2 => {
                    const slot = try self.lowerAggregateBase(arg, ty);
                    const size = self.aggregateSize(ty) orelse 16;
                    var pack_ptr = slot;
                    if (size < 16) {
                        const pack_id = self.module.ephemeral();
                        try self.addLocal(pack_id, "tmp.pack2", i128_ty, null);
                        try self.emitValueStore(.{ .ptr = .{ .local = pack_id }, .value = .{ .int = 0 }, .ty = i128_ty });
                        if (size > 0) {
                            try self.emit(.{ .copy_bytes = .{ .destination = .{ .local = pack_id }, .source = slot, .length = @intCast(size) } });
                        }
                        pack_ptr = .{ .local = pack_id };
                    }
                    const elem_i8 = try self.simpleType(.char);
                    const p0 = try self.byteOffset(pack_ptr, 0, elem_i8);
                    const p8 = try self.byteOffset(pack_ptr, 8, elem_i8);
                    const lo = try self.reg(i64_ty);
                    const hi = try self.reg(i64_ty);
                    try self.emit(.{ .load = .{ .dst = lo, .ptr = p0, .ty = i64_ty } });
                    try self.emit(.{ .load = .{ .dst = hi, .ptr = p8, .ty = i64_ty } });
                    try args_list.append(self.allocator, .{ .reg = lo });
                    try args_list.append(self.allocator, .{ .reg = hi });
                    try types_list.append(self.allocator, i64_ty);
                    try types_list.append(self.allocator, i64_ty);
                    try byval_list.append(self.allocator, null);
                    try byval_list.append(self.allocator, null);
                },
                .memory => {
                    const slot = try self.lowerAggregateBase(arg, ty);
                    try args_list.append(self.allocator, slot);
                    try types_list.append(self.allocator, ptr_ty);
                    if (ty.* == .struct_type) {
                        try byval_list.append(self.allocator, ty.struct_type);
                    } else {
                        try byval_list.append(self.allocator, null);
                    }
                },
            }
        }

        const hidden_result_ptr: ?ir.Value = if (ret_class == .memory) args_list.items[0] else null;
        const visible_types = try types_list.toOwnedSlice(self.allocator);
        const args = try args_list.toOwnedSlice(self.allocator);
        const byval_types = try byval_list.toOwnedSlice(self.allocator);
        const value_ty = switch (ret_class) {
            .small_1 => i64_ty,
            .small_2 => i128_ty,
            .sse_float => try self.simpleType(.{ .float = 32 }),
            .sse_double => try self.simpleType(.{ .float = 64 }),
            .sse_f32x2 => try self.simpleType(.abi_vec2_f32),
            .sse_f32x3 => try self.simpleType(.abi_v2f32_f32),
            .sse_f32x4 => try self.simpleType(.abi_v2f32_v2f32),
            .sse_f64x2 => try self.simpleType(.abi_pair_f64),
            .sse_f64_i32 => try self.simpleType(.abi_f64_i32),
            .sse_i32_f64 => try self.simpleType(.abi_i32_f64),
            .sse_f32_f64 => try self.simpleType(.abi_f32_f64),
            .sse_f64_f32 => try self.simpleType(.abi_f64_f32),
            .sse_f32_i64 => try self.simpleType(.abi_f32_i64),
            .sse_i64_f32 => try self.simpleType(.abi_i64_f32),
            .sse_f64_i64 => try self.simpleType(.abi_f64_i64),
            .sse_i64_f64 => try self.simpleType(.abi_i64_f64),
            .sse_f32x2_i32 => try self.simpleType(.abi_v2f32_i32),
            .sse_f32x2_i64 => try self.simpleType(.abi_v2f32_i64),
            .sse_i64_f32x => try self.simpleType(.abi_i64_f32),
            .sse_i64_f64x => try self.simpleType(.abi_i64_f64),
            .sse_f64_i64x => try self.simpleType(.abi_f64_i64),
            .sse_i64_v2f32 => try self.simpleType(.abi_i64_v2f32),
            .sse_f64_v2f32 => try self.simpleType(.abi_f64_v2f32),
            .sse_v2f32_f64 => try self.simpleType(.abi_v2f32_f64),
            .sse_i8_f64 => try self.simpleType(.abi_i8_f64),
            .sse_i16_f64 => try self.simpleType(.abi_i16_f64),
            .sse_f64_i8 => try self.simpleType(.abi_f64_i8),
            .sse_f64_i16 => try self.simpleType(.abi_f64_i16),
            .memory, .none => void_ty,
        };

        var dst: ?u32 = null;
        if (ret_class != .memory and ret_class != .none) dst = try self.reg(value_ty);
        if (ret_class == .none and call_result.* != .void) dst = try self.reg(call_result);

        try self.emit(.{ .call = .{
            .dst = dst,
            .name = name,
            .args = args,
            .arg_types = visible_types,
            .ret = if (ret_class == .none) call_result else value_ty,
            .sret = ret_class == .memory,
            .sret_type = if (ret_class == .memory) blk: {
                const ty = call_result;
                if (ty.* == .struct_type) break :blk ty.struct_type;
                break :blk null;
            } else null,
            .byval_types = byval_types,
        } });

        switch (ret_class) {
            .none => return if (dst) |id| .{ .reg = id } else .none,
            .sse_float, .sse_double, .sse_f32x2, .sse_f32x3, .sse_f32x4, .sse_f64x2, .sse_f64_i32, .sse_i32_f64, .sse_f32_f64, .sse_f64_f32, .sse_f32_i64, .sse_i64_f32, .sse_f64_i64, .sse_i64_f64, .sse_f32x2_i32, .sse_f32x2_i64, .sse_i64_f32x, .sse_i64_f64x, .sse_f64_i64x, .sse_i64_v2f32, .sse_f64_v2f32, .sse_v2f32_f64, .sse_i8_f64, .sse_i16_f64, .sse_f64_i8, .sse_f64_i16 => {
                const temp = self.module.ephemeral();
                try self.addLocal(temp, "tmp.aggregate", call_result, null);
                const abi_ty = switch (ret_class) {
                    .sse_f32x2 => try self.simpleType(.abi_vec2_f32),
                    .sse_f32x3 => try self.simpleType(.abi_v2f32_f32),
                    .sse_f32x4 => try self.simpleType(.abi_v2f32_v2f32),
                    .sse_f64x2 => try self.simpleType(.abi_pair_f64),
                    .sse_f64_i32 => try self.simpleType(.abi_f64_i32),
                    .sse_i32_f64 => try self.simpleType(.abi_i32_f64),
                    .sse_f32_f64 => try self.simpleType(.abi_f32_f64),
                    .sse_f64_f32 => try self.simpleType(.abi_f64_f32),
                    .sse_f32_i64 => try self.simpleType(.abi_f32_i64),
                    .sse_i64_f32 => try self.simpleType(.abi_i64_f32),
                    .sse_f64_i64 => try self.simpleType(.abi_f64_i64),
                    .sse_i64_f64 => try self.simpleType(.abi_i64_f64),
                    .sse_f32x2_i32 => try self.simpleType(.abi_v2f32_i32),
                    .sse_f32x2_i64 => try self.simpleType(.abi_v2f32_i64),
                    .sse_i64_f32x => try self.simpleType(.abi_i64_f32),
                    .sse_i64_f64x => try self.simpleType(.abi_i64_f64),
                    .sse_f64_i64x => try self.simpleType(.abi_f64_i64),
                    .sse_i64_v2f32 => try self.simpleType(.abi_i64_v2f32),
                    .sse_f64_v2f32 => try self.simpleType(.abi_f64_v2f32),
                    .sse_v2f32_f64 => try self.simpleType(.abi_v2f32_f64),
                    .sse_i8_f64 => try self.simpleType(.abi_i8_f64),
                    .sse_i16_f64 => try self.simpleType(.abi_i16_f64),
                    .sse_f64_i8 => try self.simpleType(.abi_f64_i8),
                    .sse_f64_i16 => try self.simpleType(.abi_f64_i16),
                    else => call_result.struct_type.fields[0].ty,
                };
                try self.emitValueStore(.{
                    .ptr = .{ .local = temp },
                    .value = .{ .reg = dst.? },
                    .ty = abi_ty,
                });
                const result = try self.reg(call_result);
                try self.emit(.{ .load = .{ .dst = result, .ptr = .{ .local = temp }, .ty = call_result } });
                return .{ .reg = result };
            },
            .small_1, .small_2 => {
                const temp = self.module.ephemeral();
                try self.addLocal(temp, "tmp.aggregate", call_result, null);
                try self.emitValueStore(.{
                    .ptr = .{ .local = temp },
                    .value = .{ .reg = dst.? },
                    .ty = value_ty,
                });
                const result = try self.reg(call_result);
                try self.emit(.{ .load = .{ .dst = result, .ptr = .{ .local = temp }, .ty = call_result } });
                return .{ .reg = result };
            },
            .memory => {
                const hidden_ptr = hidden_result_ptr orelse unreachable;
                const result = try self.reg(call_result);
                try self.emit(.{ .load = .{ .dst = result, .ptr = hidden_ptr, .ty = call_result } });
                return .{ .reg = result };
            },
        }
    }

    fn byteOffset(self: *Lowering, base: ir.Value, offset: usize, elem_i8: *types.Type) Error!ir.Value {
        _ = elem_i8;
        const id = self.module.temp();
        try self.emit(.{ .byte_offset = .{ .dst = id, .base = base, .offset = @intCast(offset) } });
        return .{ .reg = id };
    }

    fn lowerSliceCast(self: *Lowering, target: *types.Type, source: *types.Type, value: ir.Value) Error!ir.Value {
        try self.emitNullCheck(source, value);
        const array = source.pointer.elem.array;
        const id = self.module.ephemeral();
        try self.addLocal(id, "tmp.slice", target, null);

        const elem_ty = target.slice.elem;
        const pointer_slot_ty = try self.makePointer(elem_ty, false);
        const field0 = try self.reg(pointer_slot_ty);
        try self.emit(.{ .slice_field_ptr = .{ .dst = field0, .base = .{ .local = id }, .field = 0 } });
        try self.emitValueStore(.{ .ptr = .{ .reg = field0 }, .value = value, .ty = pointer_slot_ty });

        const usize_ty = try self.allocator.create(types.Type);
        usize_ty.* = .{ .int = .{ .bits = 64, .signed = false } };
        const field1 = try self.reg(usize_ty);
        try self.emit(.{ .slice_field_ptr = .{ .dst = field1, .base = .{ .local = id }, .field = 1 } });
        try self.emitValueStore(.{ .ptr = .{ .reg = field1 }, .value = .{ .int = @intCast(array.len) }, .ty = usize_ty });

        const dst = try self.reg(target);
        try self.emit(.{ .load = .{ .dst = dst, .ptr = .{ .local = id }, .ty = target } });
        return .{ .reg = dst };
    }

    fn lowerAggregateBase(self: *Lowering, expr: *ast.Expr, ty: *types.Type) Error!ir.Value {
        const lowered = try self.lowerLvalue(expr);
        switch (lowered) {
            .none => {},
            else => return lowered,
        }
        const value = try self.lowerExpr(expr);
        const id = self.module.ephemeral();
        try self.addLocal(id, "tmp.agg", ty, null);
        try self.emitValueStore(.{ .ptr = .{ .local = id }, .value = value, .ty = ty });
        return .{ .local = id };
    }

    fn loadSliceLength(self: *Lowering, slice_ptr: ir.Value) Error!ir.Value {
        const usize_ty = try self.allocator.create(types.Type);
        usize_ty.* = .{ .int = .{ .bits = 64, .signed = false } };
        const usize_slot = try self.makePointer(usize_ty, false);
        const len_slot = try self.reg(usize_slot);
        try self.emit(.{ .slice_field_ptr = .{ .dst = len_slot, .base = slice_ptr, .field = 1 } });
        const len_value = try self.reg(usize_ty);
        try self.emit(.{ .load = .{ .dst = len_value, .ptr = .{ .reg = len_slot }, .ty = usize_ty } });
        return .{ .reg = len_value };
    }

    fn loadSliceElementPointer(
        self: *Lowering,
        slice_ptr: ir.Value,
        elem_ty: *types.Type,
        index_value: ir.Value,
        index_ty: *types.Type,
    ) Error!ir.Value {
        const usize_ty = try self.allocator.create(types.Type);
        usize_ty.* = .{ .int = .{ .bits = 64, .signed = false } };

        const len_value = try self.loadSliceLength(slice_ptr);
        try self.emitIndexBoundsCheck(index_value, index_ty, len_value, usize_ty);

        const element_slot = try self.makePointer(elem_ty, false);
        const data_slot = try self.reg(element_slot);
        try self.emit(.{ .slice_field_ptr = .{ .dst = data_slot, .base = slice_ptr, .field = 0 } });
        const data = try self.reg(element_slot);
        try self.emit(.{ .load = .{ .dst = data, .ptr = .{ .reg = data_slot }, .ty = element_slot } });
        return .{ .reg = data };
    }

    fn lowerSlice(self: *Lowering, expr: *ast.Expr, slice_expr: ast.Expr.Kind.SliceAccess) Error!ir.Value {
        const target = expr.ty orelse return .none;
        const elem_ty = target.slice.elem;

        const i128_ty = try self.i128Type();
        const bool_ty = try self.booleanType();
        const usize_ty = try self.allocator.create(types.Type);
        usize_ty.* = .{ .int = .{ .bits = 64, .signed = false } };

        const base_ty = slice_expr.base.ty orelse return .none;
        var base_len: ir.Value = undefined;
        var base_len_ty: *types.Type = i128_ty;
        var base_data: ir.Value = undefined;

        switch (base_ty.*) {
            .array => {
                const base_ptr = try self.lowerLvalue(slice_expr.base);
                base_len = .{ .int = @intCast(base_ty.array.len) };
                base_len_ty = i128_ty;
                base_data = base_ptr;
            },
            .pointer => {
                const base_ptr = try self.lowerExpr(slice_expr.base);
                try self.emitNullCheck(base_ty, base_ptr);
                base_len = .{ .int = @intCast(base_ty.pointer.elem.array.len) };
                base_len_ty = i128_ty;
                base_data = base_ptr;
            },
            .slice => {
                const slice_ptr = try self.lowerAggregateBase(slice_expr.base, base_ty);
                base_len = try self.loadSliceLength(slice_ptr);
                base_len_ty = usize_ty;
                base_data = try self.loadSliceData(slice_ptr, elem_ty);
            },
            else => return .none,
        }

        // Fast path for full range `base[..]`: start = 0, end = len, no bounds branch needed.
        if (slice_expr.start == null and slice_expr.end == null) {
            var full_ptr: ir.Value = undefined;
            var full_len: ir.Value = undefined;
            switch (base_ty.*) {
                .array => {
                    const dst = try self.reg(try self.makePointer(elem_ty, target.slice.is_const));
                    try self.emit(.{ .elem_ptr = .{
                        .dst = dst,
                        .base = base_data,
                        .container = base_ty,
                        .index = .{ .int = 0 },
                        .index_ty = usize_ty,
                        .is_array = true,
                    } });
                    full_ptr = .{ .reg = dst };
                    full_len = .{ .int = @intCast(base_ty.array.len) };
                },
                .pointer => {
                    full_ptr = base_data;
                    full_len = .{ .int = @intCast(base_ty.pointer.elem.array.len) };
                },
                .slice => {
                    full_ptr = base_data;
                    full_len = base_len;
                },
                else => unreachable,
            }
            return self.makeSlice(target, full_ptr, full_len);
        }

        const normalized_len = try self.castIntegerValue(base_len, base_len_ty, i128_ty);

        var start: ir.Value = .{ .int = 0 };
        var start_ty: ?*types.Type = null;
        if (slice_expr.start) |start_expr| {
            const start_value = try self.lowerExpr(start_expr);
            const sty = start_expr.ty orelse return .none;
            start = try self.castIntegerValue(start_value, sty, i128_ty);
            start_ty = sty;
        }

        var end: ir.Value = normalized_len;
        var end_ty: ?*types.Type = null;
        if (slice_expr.end) |end_expr| {
            const end_value = try self.lowerExpr(end_expr);
            const ety = end_expr.ty orelse return .none;
            end = try self.castIntegerValue(end_value, ety, i128_ty);
            end_ty = ety;
        }

        if (self.checks.bounds) {
            const zero_value: ir.Value = .{ .int = 0 };
            var start_negative: ?u32 = null;
            var end_negative: ?u32 = null;
            if (start_ty) |sty| {
                if (sty.isInteger() and sty.intInfo().signed) {
                    const negative = try self.reg(bool_ty);
                    try self.emit(.{ .icmp = .{ .dst = negative, .op = .lt, .ty = i128_ty, .lhs = start, .rhs = zero_value } });
                    start_negative = negative;
                }
            }
            if (end_ty) |ety| {
                if (ety.isInteger() and ety.intInfo().signed) {
                    const negative = try self.reg(bool_ty);
                    try self.emit(.{ .icmp = .{ .dst = negative, .op = .lt, .ty = i128_ty, .lhs = end, .rhs = zero_value } });
                    end_negative = negative;
                }
            }

            const start_gt_end = try self.reg(bool_ty);
            try self.emit(.{ .icmp = .{ .dst = start_gt_end, .op = .gt, .ty = i128_ty, .lhs = start, .rhs = end } });

            var condition = start_gt_end;
            if (start_negative) |negative| {
                const combined = try self.reg(bool_ty);
                try self.emit(.{ .binary = .{ .dst = combined, .op = .bit_or, .ty = bool_ty, .lhs = .{ .reg = negative }, .rhs = .{ .reg = condition } } });
                condition = combined;
            }
            if (end_negative) |negative| {
                const combined = try self.reg(bool_ty);
                try self.emit(.{ .binary = .{ .dst = combined, .op = .bit_or, .ty = bool_ty, .lhs = .{ .reg = negative }, .rhs = .{ .reg = condition } } });
                condition = combined;
            }
            if (end_ty != null) {
                const end_too_large = try self.reg(bool_ty);
                try self.emit(.{ .icmp = .{ .dst = end_too_large, .op = .gt, .ty = i128_ty, .lhs = end, .rhs = normalized_len } });
                const invalid = try self.reg(bool_ty);
                try self.emit(.{ .binary = .{ .dst = invalid, .op = .bit_or, .ty = bool_ty, .lhs = .{ .reg = condition }, .rhs = .{ .reg = end_too_large } } });
                condition = invalid;
            }
            try self.emitTrapBranch(condition);
        }

        const start64 = try self.reg(usize_ty);
        try self.emit(.{ .cast = .{ .dst = start64, .kind = .trunc, .from = i128_ty, .to = usize_ty, .value = start } });
        const end64 = try self.reg(usize_ty);
        try self.emit(.{ .cast = .{ .dst = end64, .kind = .trunc, .from = i128_ty, .to = usize_ty, .value = end } });

        var data_pointer: ir.Value = undefined;
        if (base_ty.* == .array) {
            const dst = try self.reg(try self.makePointer(elem_ty, target.slice.is_const));
            try self.emit(.{ .elem_ptr = .{
                .dst = dst,
                .base = base_data,
                .container = base_ty,
                .index = .{ .reg = start64 },
                .index_ty = usize_ty,
                .is_array = true,
            } });
            data_pointer = .{ .reg = dst };
        } else if (base_ty.* == .slice) {
            const dst = try self.reg(try self.makePointer(elem_ty, base_ty.slice.is_const));
            try self.emit(.{ .elem_ptr = .{
                .dst = dst,
                .base = base_data,
                .container = try self.makePointer(elem_ty, base_ty.slice.is_const),
                .index = .{ .reg = start64 },
                .index_ty = usize_ty,
                .is_array = false,
            } });
            data_pointer = .{ .reg = dst };
        } else {
            const elem_of_pointer = base_ty.pointer.elem.array.elem;
            const pointer_container = try self.makePointer(elem_of_pointer, base_ty.pointer.is_const);
            const dst = try self.reg(pointer_container);
            try self.emit(.{ .elem_ptr = .{
                .dst = dst,
                .base = base_data,
                .container = pointer_container,
                .index = .{ .reg = start64 },
                .index_ty = usize_ty,
                .is_array = false,
            } });
            data_pointer = .{ .reg = dst };
        }

        const len = try self.reg(usize_ty);
        try self.emit(.{ .binary = .{ .dst = len, .op = .sub, .ty = usize_ty, .lhs = .{ .reg = end64 }, .rhs = .{ .reg = start64 } } });
        return self.makeSlice(target, data_pointer, .{ .reg = len });
    }

    fn makeSlice(self: *Lowering, target: *types.Type, pointer: ir.Value, length: ir.Value) Error!ir.Value {
        const id = self.module.ephemeral();
        try self.addLocal(id, "tmp.slice", target, null);

        const elem_ty = target.slice.elem;
        const element_slot = try self.makePointer(elem_ty, false);
        const field0 = try self.reg(element_slot);
        try self.emit(.{ .slice_field_ptr = .{ .dst = field0, .base = .{ .local = id }, .field = 0 } });
        try self.emitValueStore(.{ .ptr = .{ .reg = field0 }, .value = pointer, .ty = element_slot });

        const usize_ty = try self.allocator.create(types.Type);
        usize_ty.* = .{ .int = .{ .bits = 64, .signed = false } };
        const slot_ty = try self.makePointer(usize_ty, false);
        const field1 = try self.reg(slot_ty);
        try self.emit(.{ .slice_field_ptr = .{ .dst = field1, .base = .{ .local = id }, .field = 1 } });
        try self.emitValueStore(.{ .ptr = .{ .reg = field1 }, .value = length, .ty = usize_ty });

        const dst = try self.reg(target);
        try self.emit(.{ .load = .{ .dst = dst, .ptr = .{ .local = id }, .ty = target } });
        return .{ .reg = dst };
    }

    fn loadSliceData(self: *Lowering, slice_ptr: ir.Value, elem_ty: *types.Type) Error!ir.Value {
        const element_slot = try self.makePointer(elem_ty, false);
        const data_slot = try self.reg(element_slot);
        try self.emit(.{ .slice_field_ptr = .{ .dst = data_slot, .base = slice_ptr, .field = 0 } });
        const data = try self.reg(element_slot);
        try self.emit(.{ .load = .{ .dst = data, .ptr = .{ .reg = data_slot }, .ty = element_slot } });
        return .{ .reg = data };
    }

    fn lowerCast(self: *Lowering, expr: *ast.Expr, cast: ast.Expr.Kind.Cast) Error!ir.Value {
        const target = cast.target.resolved orelse return .none;
        const source = cast.operand.ty orelse return .none;
        const value = try self.lowerExpr(cast.operand);
        if (source.* == .null_type or target.* == .invalid) return value;
        if (source.* == .slice and target.* == .slice) return value;
        if (target.* == .slice) return self.lowerSliceCast(target, source, value);
        if (isSameRepresentation(source, target)) return value;
        const kind = castKind(source, target) orelse {
            try self.reporter.err("E0605", expr.span, "internal: unsupported cast from the semantic layer", .{});
            return .none;
        };
        const dst = try self.reg(target);
        try self.emit(.{ .cast = .{ .dst = dst, .kind = kind, .from = source, .to = target, .value = value } });
        return .{ .reg = dst };
    }

    fn lowerLvalue(self: *Lowering, expr: *ast.Expr) Error!ir.Value {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                const sym = ident.sym orelse return .none;
                if (sym.kind == .global) break :blk .{ .global = self.globals.get(sym.id) orelse return .none };
                break :blk .{ .local = sym.id };
            },
            .unary => |unary| if (unary.op == .dereference)
                self.lowerExpr(unary.operand)
            else
                .none,
            .field => |field| blk: {
                if (field.sym) |sym| {
                    if (sym.kind == .global) break :blk .{ .global = self.globals.get(sym.id) orelse return .none };
                    break :blk .none;
                }
                const base_ty = field.base.ty orelse return .none;
                const target_ty = if (base_ty.* == .pointer) base_ty.pointer.elem else base_ty;
                if (target_ty.* != .struct_type) break :blk .none;
                var struct_ty = base_ty;
                var base_ptr: ir.Value = undefined;
                if (base_ty.* == .pointer) {
                    struct_ty = base_ty.pointer.elem;
                    base_ptr = try self.lowerExpr(field.base);
                    try self.emitNullCheck(base_ty, base_ptr);
                } else {
                    base_ptr = try self.lowerLvalue(field.base);
                    if (base_ptr == .none) break :blk .none;
                }
                const dst = try self.reg(try self.makePointer(struct_ty, base_ty.* == .pointer and base_ty.pointer.is_const));
                try self.emit(.{ .field_ptr = .{
                    .dst = dst,
                    .base = base_ptr,
                    .struct_ty = struct_ty.struct_type,
                    .field = field.field_index,
                } });
                break :blk .{ .reg = dst };
            },
            .index => |index| blk: {
                const base_ty = index.base.ty orelse return .none;
                var base_ptr: ir.Value = undefined;
                var is_array = false;
                var is_slice = false;
                if (base_ty.* == .pointer) {
                    base_ptr = try self.lowerExpr(index.base);
                    try self.emitNullCheck(base_ty, base_ptr);
                } else if (base_ty.* == .slice) {
                    is_slice = true;
                } else {
                    base_ptr = try self.lowerLvalue(index.base);
                    is_array = true;
                }
                const index_ty = index.index.ty orelse return .none;
                const index_value = try self.lowerExpr(index.index);
                if (is_array) try self.emitArrayBoundsCheck(base_ty, index_value, index_ty);
                if (is_slice) {
                    const slice_ptr = try self.lowerAggregateBase(index.base, base_ty);
                    base_ptr = try self.loadSliceElementPointer(slice_ptr, base_ty.slice.elem, index_value, index_ty);
                }
                const element = if (is_array) base_ty.array.elem else if (is_slice) base_ty.slice.elem else base_ty.pointer.elem;
                const container = if (is_slice) try self.makePointer(element, base_ty.slice.is_const) else base_ty;
                const elem_ty = try self.makePointer(element, if (base_ty.* == .pointer) base_ty.pointer.is_const else base_ty.* == .slice and base_ty.slice.is_const);
                const dst = try self.reg(elem_ty);
                try self.emit(.{ .elem_ptr = .{
                    .dst = dst,
                    .base = base_ptr,
                    .container = container,
                    .index = index_value,
                    .index_ty = index_ty,
                    .is_array = is_array,
                } });
                break :blk .{ .reg = dst };
            },
            .struct_init, .array_lit => blk: {
                const ty = expr.ty orelse return .none;
                const id = self.module.ephemeral();
                try self.addLocal(id, "tmp.agg", ty, null);
                try self.lowerAggregateInto(.{ .local = id }, ty, expr);
                break :blk .{ .local = id };
            },
            else => .none,
        };
    }

    fn lowerAggregateInto(self: *Lowering, dest: ir.Value, ty: *types.Type, expr: *ast.Expr) Error!void {
        switch (expr.kind) {
            .struct_init => |initializer| {
                const info = ty.struct_type;
                for (initializer.fields) |field| {
                    const field_ty = info.fields[field.index].ty;
                    const field_ptr_ty = try self.makePointer(field_ty, false);
                    const dst = try self.reg(field_ptr_ty);
                    try self.emit(.{ .field_ptr = .{
                        .dst = dst,
                        .base = dest,
                        .struct_ty = info,
                        .field = field.index,
                    } });
                    if (field_ty.isAggregate()) {
                        try self.lowerAggregateInto(.{ .reg = dst }, field_ty, field.value);
                    } else {
                        const value = try self.lowerExpr(field.value);
                        try self.emitValueStore(.{ .ptr = .{ .reg = dst }, .value = value, .ty = field_ty });
                    }
                }
            },
            .array_lit => |elements| {
                const array_ty = ty.array;
                for (elements, 0..) |element, i| {
                    const index_ty = try self.allocator.create(types.Type);
                    index_ty.* = .{ .int = .{ .bits = 64, .signed = true } };
                    const dst = try self.reg(try self.makePointer(array_ty.elem, false));
                    try self.emit(.{ .elem_ptr = .{
                        .dst = dst,
                        .base = dest,
                        .container = ty,
                        .index = .{ .int = @intCast(i) },
                        .index_ty = index_ty,
                        .is_array = true,
                    } });
                    if (array_ty.elem.isAggregate()) {
                        try self.lowerAggregateInto(.{ .reg = dst }, array_ty.elem, element);
                    } else {
                        const value = try self.lowerExpr(element);
                        try self.emitValueStore(.{ .ptr = .{ .reg = dst }, .value = value, .ty = array_ty.elem });
                    }
                }
            },
            else => {
                try self.reporter.err("E0606", expr.span, "internal: expected an aggregate initializer", .{});
            },
        }
    }

    fn makePointer(self: *Lowering, elem: *types.Type, is_const: bool) Error!*types.Type {
        return types.makePointer(self.allocator, elem, is_const);
    }

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    fn lowerConst(self: *Lowering, expr: *ast.Expr, ty: *types.Type) Error!?ir.Value {
        switch (expr.kind) {
            .int_lit => |lit| return .{ .int = @intCast(lit.value) },
            .char_lit => |value| return .{ .int = @intCast(value) },
            .bool_lit => |value| return .{ .boolean = value },
            .float_lit => |lit| return .{ .float = lit.value },
            .string_lit => |lit| return .{ .string = try self.module.addString(lit.bytes) },
            .null_lit => return .null_ptr,
            .field => |field| {
                if (field.is_enum_variant) return .{ .int = field.variant_value };
                if (!field.through_pointer and std.mem.eql(u8, field.name, "len")) {
                    if (field.base.ty) |bt| {
                        if (bt.* == .array) return .{ .int = @intCast(bt.array.len) };
                    }
                }
            },
            .unary => |unary| {
                if (unary.op == .negate) {
                    if (try self.lowerConst(unary.operand, ty)) |value| {
                        return switch (value) {
                            .int => |number| .{ .int = -number },
                            .float => |number| .{ .float = -number },
                            else => null,
                        };
                    }
                }
                if (unary.op == .bit_not) {
                    if (try self.lowerConst(unary.operand, ty)) |value| {
                        if (value == .int) return .{ .int = ~value.int };
                    }
                }
                if (unary.op == .logical_not) {
                    if (try self.lowerConst(unary.operand, ty)) |value| {
                        if (value == .boolean) return .{ .boolean = !value.boolean };
                        if (value == .int) return .{ .boolean = value.int == 0 };
                    }
                }
                return null;
            },
            .binary => {
                if (analyzer.constInt(expr)) |value| {
                    return .{ .int = truncateInt(value, ty) };
                }
                if (constFloat(expr)) |value| return .{ .float = value };
                return null;
            },
            .cast => |cast| {
                if (try self.lowerConst(cast.operand, ty)) |value| {
                    switch (value) {
                        .int => |number| return .{ .int = truncateInt(number, ty) },
                        .float => |number| {
                            if (ty.isInteger()) return .{ .int = @intFromFloat(number) };
                            return .{ .float = number };
                        },
                        else => return value,
                    }
                }
                return null;
            },
            else => return null,
        }
        return null;
    }

    fn lowerConstant(self: *Lowering, expr: *ast.Expr, ty: *types.Type) Error!?ir.Constant {
        switch (ty.*) {
            .struct_type => |info| {
                if (expr.kind != .struct_init) return null;
                const initializer = expr.kind.struct_init;
                const values = try self.allocator.alloc(ir.Constant, info.fields.len);
                for (initializer.fields) |field| {
                    const field_ty = info.fields[field.index].ty;
                    const value = (try self.lowerConstant(field.value, field_ty)) orelse return null;
                    values[field.index] = value;
                }
                return .{ .struct_fields = values };
            },
            .array => |array| {
                if (expr.kind != .array_lit) return null;
                const elements = expr.kind.array_lit;
                if (elements.len != array.len) return null;
                const values = try self.allocator.alloc(ir.Constant, elements.len);
                for (elements, 0..) |element, i| {
                    const value = (try self.lowerConstant(element, array.elem)) orelse return null;
                    values[i] = value;
                }
                return .{ .array = values };
            },
            else => {
                const value = (try self.lowerConst(expr, ty)) orelse return null;
                return .{ .scalar = value };
            },
        }
    }
};

fn structLlvmName(info: *types.StructInfo) []const u8 {
    return if (info.llvm_name.len > 0) info.llvm_name else info.name;
}

fn findFunction(module: *ir.Module, name: []const u8) ?*ir.Function {
    for (module.functions.items) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn isAggregateInitializer(expr: *ast.Expr) bool {
    return switch (expr.kind) {
        .struct_init, .array_lit => true,
        else => false,
    };
}

fn binaryOp(op: ast.BinaryOp) ?ir.BinaryOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        else => null,
    };
}

fn isSameRepresentation(from: *types.Type, to: *types.Type) bool {
    if (types.Type.eql(from, to)) return true;
    if (from.isPointer() and to.isPointer()) return true;
    if (from.* == .slice and to.* == .slice) return types.Type.eql(from.slice.elem, to.slice.elem);
    const from_bits = intBits(from);
    const to_bits = intBits(to);
    if (from_bits != null and to_bits != null and from_bits.? == to_bits.?) return true;
    if (from.isFloat() and to.isFloat() and floatBits(from) == floatBits(to)) return true;
    return false;
}

fn intBits(ty: *types.Type) ?u16 {
    return switch (ty.*) {
        .int => |info| info.bits,
        .char => 32,
        .bool => 1,
        .enum_type => |info| intBits(info.backing),
        else => null,
    };
}

fn floatBits(ty: *types.Type) u16 {
    return switch (ty.*) {
        .float => |bits| bits,
        else => 64,
    };
}

fn signedInt(ty: *types.Type) bool {
    return switch (ty.*) {
        .int => |info| info.signed,
        .enum_type => |info| signedInt(info.backing),
        else => false,
    };
}

fn castKind(from: *types.Type, to: *types.Type) ?ir.CastKind {
    if (to.* == .bool) {
        if (from.isInteger() or from.isPointer()) return .int_to_bool;
        return null;
    }
    if (from.* == .bool) return .bool_to_int;
    if (from.isPointer()) {
        if (to.isPointer()) return .bitcast;
        if (to.isInteger()) return .ptrtoint;
        return null;
    }
    const from_int = intBits(from);
    const to_int = intBits(to);
    if (from_int != null and to_int != null) {
        if (from_int.? == to_int.?) return null;
        if (from_int.? > to_int.?) return .trunc;
        if (signedInt(from)) return .sext;
        return .zext;
    }
    if (from.isFloat() and to.isFloat()) {
        if (floatBits(from) == floatBits(to)) return null;
        return if (floatBits(from) < floatBits(to)) .fpext else .fptrunc;
    }
    if (from.isInteger() and to.isFloat()) {
        return if (signedInt(from)) .sitofp else .uitofp;
    }
    if (from.isFloat() and to.isInteger()) {
        return if (signedInt(to)) .fptosi else .fptoui;
    }
    return null;
}

fn truncateInt(value: i128, ty: *types.Type) i128 {
    const bits = intBits(ty) orelse return value;
    if (bits >= 128) return value;
    if (signedInt(ty)) {
        const mask = (@as(i128, 1) << @intCast(bits)) - 1;
        var truncated = value & mask;
        if ((truncated & (@as(i128, 1) << @intCast(bits - 1))) != 0) {
            truncated -= (@as(i128, 1) << @intCast(bits));
        }
        return truncated;
    }
    return value & ((@as(i128, 1) << @intCast(bits)) - 1);
}

fn constFloat(expr: *ast.Expr) ?f64 {
    return switch (expr.kind) {
        .float_lit => |lit| lit.value,
        .int_lit => |lit| @floatFromInt(lit.value),
        .unary => |unary| if (unary.op == .negate) if (constFloat(unary.operand)) |value| -value else null else null,
        .binary => |binary| blk: {
            const lhs = constFloat(binary.lhs) orelse break :blk null;
            const rhs = constFloat(binary.rhs) orelse break :blk null;
            break :blk switch (binary.op) {
                .add => lhs + rhs,
                .sub => lhs - rhs,
                .mul => lhs * rhs,
                .div => if (rhs == 0) null else lhs / rhs,
                else => null,
            };
        },
        else => null,
    };
}

fn sizeInBytes(ty: *types.Type) ?usize {
    return switch (ty.*) {
        .bool => 1,
        .char => 4,
        .int => |info| @intCast(info.bits / 8),
        .float => |bits| @intCast(bits / 8),
        .pointer => 8,
        .slice => 16,
        .enum_type => |info| sizeInBytes(info.backing),
        .array => |array| (sizeInBytes(array.elem) orelse return null) * array.len,
        .struct_type => |info| blk: {
            var size: usize = 0;
            var alignment: usize = 1;
            for (info.fields) |field| {
                const fsize = sizeInBytes(field.ty) orelse break :blk null;
                const falign: usize = Emitter.llvmAlignmentOfType(field.ty);
                size = std.mem.alignForward(usize, size, falign);
                size += fsize;
                alignment = @max(alignment, falign);
            }
            break :blk std.mem.alignForward(usize, size, alignment);
        },
        else => null,
    };
}

// ---------------------------------------------------------------------------
// LLVM IR emitter
// ---------------------------------------------------------------------------

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    module: *ir.Module,
    current_ret_ty: *types.Type = undefined,

    pub fn init(allocator: std.mem.Allocator, module: *ir.Module) Emitter {
        return .{ .allocator = allocator, .module = module };
    }

    pub fn emit(self: *Emitter, writer: *std.Io.Writer) !void {
        try writer.writeAll("; ModuleID = 'kyn'\n");
        try writer.writeAll("; Generated by the Kyn compiler. Do not edit.\n\n");
        try writer.writeAll("declare void @llvm.trap() noreturn nounwind\n\n");
        try writer.writeAll("declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1) nounwind\n\n");
        try writer.writeAll("%kyn.slice = type { ptr, i64 }\n");
        if (self.module.structs.items.len > 0) try writer.writeByte('\n');
        for ([_]u16{ 8, 16, 32, 64, 128 }) |bits| {
            for ([_][]const u8{ "add", "sub", "mul" }) |op| {
                try writer.print("declare {{ i{d}, i1 }} @llvm.s{s}.with.overflow.i{d}(i{d}, i{d})\n", .{ bits, op, bits, bits, bits });
                try writer.print("declare {{ i{d}, i1 }} @llvm.u{s}.with.overflow.i{d}(i{d}, i{d})\n", .{ bits, op, bits, bits, bits });
            }
        }
        try writer.writeByte('\n');

        for (self.module.structs.items) |info| {
            try writer.print("%struct.{s} = type {{ ", .{structLlvmName(info)});
            for (info.fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(", ");
                try self.emitType(writer, field.ty);
            }
            if (info.fields.len == 0) try writer.writeAll("i8");
            try writer.writeAll(" }\n");
        }
        if (self.module.structs.items.len > 0) try writer.writeByte('\n');

        for (self.module.strings.items) |string| {
            try writer.print("@.str{d} = private unnamed_addr constant [{d} x i8] c\"", .{
                string.index,
                string.bytes.len + 1,
            });
            for (string.bytes) |byte| try emitEscapedByte(writer, byte);
            try writer.writeAll("\\00\"\n");
        }
        if (self.module.strings.items.len > 0) try writer.writeByte('\n');

        for (self.module.globals.items) |global| {
            try writer.print("@{s} = {s} ", .{ global.name, if (global.mutable) "global" else "constant" });
            try self.emitType(writer, global.ty);
            try writer.writeByte(' ');
            try self.emitConstant(writer, global.init, global.ty);
            try writer.writeByte('\n');
        }
        if (self.module.globals.items.len > 0) try writer.writeByte('\n');

        for (self.module.functions.items) |function| {
            if (function.linkage == .declaration) {
                try writer.print("declare {s} @{s}(", .{ try self.typeString(function.ret), function.name });
                try self.emitParameters(writer, function);
                try writer.writeAll(")\n");
            } else {
                try self.emitFunction(writer, function);
            }
        }
    }

    fn emitParameters(self: *Emitter, writer: *std.Io.Writer, function: *ir.Function) !void {
        for (function.params, 0..) |param, i| {
            if (i > 0) try writer.writeAll(", ");
            if (function.sret and i == 0) {
                const info = function.sret_type orelse return error.OutOfMemory;
                try writer.print("ptr sret(%struct.{s}) noalias writable %arg{d}", .{ structLlvmName(info), param.local });
                continue;
            }
            if (param.byval_type) |info| {
                try writer.print("ptr byval(%struct.{s}) align {d} %arg{d}", .{ structLlvmName(info), aggregateAlign(info), param.local });
                continue;
            }
            try writer.print("{s} %arg{d}", .{ try self.typeString(param.ty), param.local });
        }
    }

    fn aggregateAlign(info: *types.StructInfo) usize {
        var alignment: u16 = 1;
        for (info.fields) |field| {
            alignment = @max(alignment, llvmAlignmentOfType(field.ty));
        }
        return alignment;
    }

    pub fn llvmAlignmentOfType(ty: *types.Type) u16 {
        return switch (ty.*) {
            .bool => 1,
            .char => 4,
            .int => |info| @min(@as(u16, @intCast(info.bits / 8)), 16),
            .float => |bits| if (bits <= 32) 4 else 8,
            .abi_vec2_f32 => 4,
            .abi_v2f32_f32 => 4,
            .abi_v2f32_v2f32 => 4,
            .abi_pair_f64 => 8,
            .abi_f64_i32 => 8,
            .abi_i32_f64 => 8,
            .abi_f32_f64 => 8,
            .abi_f64_f32 => 8,
            .abi_f32_i64 => 8,
            .abi_i64_f32 => 8,
            .abi_f64_i64 => 8,
            .abi_i64_f64 => 8,
            .abi_v2f32_i32 => 8,
            .abi_v2f32_i64 => 8,
            .abi_i64_v2f32 => 8,
            .abi_f64_v2f32 => 8,
            .abi_v2f32_f64 => 8,
            .abi_i8_f64 => 8,
            .abi_i16_f64 => 8,
            .abi_f64_i8 => 8,
            .abi_f64_i16 => 8,
            .pointer => 8,
            .enum_type => |info| llvmAlignmentOfType(info.backing),
            .array => |array| llvmAlignmentOfType(array.elem),
            .struct_type => |info| blk: {
                var alignment: u16 = 1;
                for (info.fields) |field| {
                    alignment = @max(alignment, llvmAlignmentOfType(field.ty));
                }
                break :blk alignment;
            },
            .slice => 8,
            else => 8,
        };
    }

    fn emitFunction(self: *Emitter, writer: *std.Io.Writer, function: *ir.Function) !void {
        self.current_ret_ty = function.ret;
        const linkage = if (function.linkage == .internal) "internal " else "dso_local ";
        try writer.print("define {s}{s} @{s}(", .{ linkage, try self.typeString(function.ret), function.name });
        try self.emitParameters(writer, function);
        try writer.writeAll(") {\n");

        for (function.blocks.items, 0..) |block, index| {
            if (index == 0) {
                try writer.writeAll("entry:\n");
            } else {
                try writer.print(".b{d}:\n", .{block.id});
            }
            if (index == 0) {
                for (function.locals.items) |local| {
                    if (local.padding > 0) {
                        const alignment = @max(llvmAlignmentOfType(local.ty), 8);
                        try writer.print("  %v{d} = alloca [{d} x i8], align {d}\n", .{ local.id, local.padding, alignment });
                    } else {
                        try writer.print("  %v{d} = alloca {s}\n", .{ local.id, try self.typeString(local.ty) });
                    }
                }
            }
            for (block.insts.items) |inst| try self.emitInst(writer, inst);
            if (!block.terminated) try writer.writeAll("  unreachable\n");
        }
        try writer.writeAll("}\n\n");
    }

    fn emitInst(self: *Emitter, writer: *std.Io.Writer, inst: ir.Inst) !void {
        switch (inst) {
            .checked_binary => |checked| {
                const type_name = try self.typeString(checked.ty);
                const signed = checked.ty.isInteger() and checked.ty.intInfo().signed;
                const base: []const u8 = switch (checked.op) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    else => unreachable,
                };
                const prefix: []const u8 = if (signed) "s" else "u";
                const call_reg = self.module.temp();
                try writer.print("  %t{d} = call {{ {s}, i1 }} @llvm.{s}{s}.with.overflow.{s}({s} ", .{
                    call_reg, type_name, prefix, base, type_name, type_name,
                });
                try self.emitValue(writer, checked.lhs, checked.ty);
                try writer.writeAll(", ");
                try self.emitType(writer, checked.ty);
                try writer.writeByte(' ');
                try self.emitValue(writer, checked.rhs, checked.ty);
                try writer.writeAll(")\n");
                try writer.print("  %t{d} = extractvalue {{ {s}, i1 }} %t{d}, 0\n", .{ checked.dst, type_name, call_reg });
                try writer.print("  %t{d} = extractvalue {{ {s}, i1 }} %t{d}, 1\n", .{ checked.overflow, type_name, call_reg });
            },
            .binary => |binary| {
                const op = binaryName(binary.op, binary.ty);
                try writer.print("  %t{d} = {s} {s} ", .{ binary.dst, op, try self.typeString(binary.ty) });
                try self.emitValue(writer, binary.lhs, binary.ty);
                try writer.writeAll(", ");
                try self.emitValue(writer, binary.rhs, binary.ty);
                try writer.writeByte('\n');
            },
            .unary => |unary| {
                switch (unary.op) {
                    .negate => {
                        if (unary.ty.isFloat()) {
                            try writer.print("  %t{d} = fneg {s} ", .{ unary.dst, try self.typeString(unary.ty) });
                        } else {
                            try writer.print("  %t{d} = sub {s} 0, ", .{ unary.dst, try self.typeString(unary.ty) });
                        }
                        try self.emitValue(writer, unary.operand, unary.ty);
                        try writer.writeByte('\n');
                    },
                    .logical_not => {
                        try writer.print("  %t{d} = xor i1 ", .{unary.dst});
                        try self.emitValue(writer, unary.operand, unary.ty);
                        try writer.writeAll(", true\n");
                    },
                    .bit_not => {
                        try writer.print("  %t{d} = xor {s} ", .{ unary.dst, try self.typeString(unary.ty) });
                        try self.emitValue(writer, unary.operand, unary.ty);
                        try writer.writeAll(", -1\n");
                    },
                }
            },
            .icmp => |cmp| {
                const pred = icmpPredicate(cmp.op, cmp.ty);
                try writer.print("  %t{d} = icmp {s} {s} ", .{ cmp.dst, pred, try self.typeString(cmp.ty) });
                try self.emitValue(writer, cmp.lhs, cmp.ty);
                try writer.writeAll(", ");
                try self.emitValue(writer, cmp.rhs, cmp.ty);
                try writer.writeByte('\n');
            },
            .fcmp => |cmp| {
                const pred = fcmpPredicate(cmp.op);
                try writer.print("  %t{d} = fcmp {s} {s} ", .{ cmp.dst, pred, try self.typeString(cmp.ty) });
                try self.emitValue(writer, cmp.lhs, cmp.ty);
                try writer.writeAll(", ");
                try self.emitValue(writer, cmp.rhs, cmp.ty);
                try writer.writeByte('\n');
            },
            .cast => |cast| {
                const from = try self.typeString(cast.from);
                const to = try self.typeString(cast.to);
                const opname: []const u8 = switch (cast.kind) {
                    .trunc => "trunc",
                    .zext => "zext",
                    .sext => "sext",
                    .fptrunc => "fptrunc",
                    .fpext => "fpext",
                    .sitofp => "sitofp",
                    .uitofp => "uitofp",
                    .fptosi => "fptosi",
                    .fptoui => "fptoui",
                    .ptrtoint => "ptrtoint",
                    .inttoptr => "inttoptr",
                    .bitcast => "bitcast",
                    .int_to_bool => "icmp ne",
                    .bool_to_int => "zext",
                };
                if (cast.kind == .int_to_bool) {
                    try writer.print("  %t{d} = icmp ne {s} ", .{ cast.dst, from });
                    try self.emitValue(writer, cast.value, cast.from);
                    try writer.writeAll(if (cast.from.isPointer()) ", null\n" else ", 0\n");
                    return;
                }
                try writer.print("  %t{d} = {s} {s} ", .{ cast.dst, opname, from });
                try self.emitValue(writer, cast.value, cast.from);
                try writer.print(" to {s}\n", .{to});
            },
            .byte_offset => |offset| {
                try writer.print("  %t{d} = getelementptr i8, ptr ", .{offset.dst});
                try self.emitValue(writer, offset.base, null);
                try writer.print(", i64 {d}\n", .{offset.offset});
            },
            .copy_bytes => |copy| {
                try writer.writeAll("  call void @llvm.memcpy.p0.p0.i64(ptr ");
                try self.emitValue(writer, copy.destination, null);
                try writer.writeAll(", ptr ");
                try self.emitValue(writer, copy.source, null);
                try writer.print(", i64 {d}, i1 false)\n", .{copy.length});
            },
            .call => |call| {
                if (call.dst) |dst| try writer.print("  %t{d} = ", .{dst}) else try writer.writeAll("  ");
                try writer.print("call {s} @{s}(", .{ try self.typeString(call.ret), call.name });
                for (call.args, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    const byval_type = if (i < call.byval_types.len) call.byval_types[i] else null;
                    const local_id = switch (arg) {
                        .local => |id| id,
                        else => 0,
                    };
                    if (call.sret and i == 0) {
                        const info = call.sret_type orelse return error.OutOfMemory;
                        try writer.print("ptr sret(%struct.{s}) noalias writable %v{d}", .{ structLlvmName(info), local_id });
                    } else if (byval_type) |info| {
                        const alignment = aggregateAlign(info);
                        try writer.print("ptr byval(%struct.{s}) align {d} %v{d}", .{ structLlvmName(info), alignment, local_id });
                    } else {
                        try writer.print("{s} ", .{try self.typeString(call.arg_types[i])});
                        try self.emitValue(writer, arg, call.arg_types[i]);
                    }
                }
                try writer.writeAll(")\n");
            },
            .slice_field_ptr => |field| {
                try writer.print("  %t{d} = getelementptr inbounds %kyn.slice, ptr ", .{field.dst});
                try self.emitValue(writer, field.base, null);
                try writer.print(", i32 0, i32 {d}\n", .{field.field});
            },
            .field_ptr => |field| {
                try writer.print("  %t{d} = getelementptr inbounds %struct.{s}, ptr ", .{ field.dst, structLlvmName(field.struct_ty) });
                try self.emitValue(writer, field.base, null);
                try writer.print(", i32 0, i32 {d}\n", .{field.field});
            },
            .elem_ptr => |element| {
                if (element.is_array) {
                    try writer.print("  %t{d} = getelementptr inbounds {s}, ptr ", .{ element.dst, try self.typeString(element.container) });
                    try self.emitValue(writer, element.base, null);
                    try writer.writeAll(", i64 0, ");
                } else {
                    try writer.print("  %t{d} = getelementptr inbounds {s}, ptr ", .{ element.dst, try self.typeString(element.container.pointer.elem) });
                    try self.emitValue(writer, element.base, null);
                    try writer.writeByte(',');
                    try writer.writeByte(' ');
                }
                try writer.print("{s} ", .{try self.typeString(element.index_ty)});
                try self.emitValue(writer, element.index, element.index_ty);
                try writer.writeByte('\n');
            },
            .load => |load| {
                try writer.print("  %t{d} = load {s}, ptr ", .{ load.dst, try self.typeString(load.ty) });
                try self.emitValue(writer, load.ptr, null);
                if (load.ty.* == .abi_vec2_f32 or load.ty.* == .abi_v2f32_f32 or load.ty.* == .abi_v2f32_v2f32) try writer.writeAll(", align 4");
                if (load.ty.* == .abi_f32_f64 or load.ty.* == .abi_f64_f32 or load.ty.* == .abi_f32_i64 or load.ty.* == .abi_i64_f32 or load.ty.* == .abi_f64_i64 or load.ty.* == .abi_i64_f64 or load.ty.* == .abi_v2f32_i32 or load.ty.* == .abi_v2f32_i64 or load.ty.* == .abi_i64_v2f32 or load.ty.* == .abi_f64_v2f32 or load.ty.* == .abi_v2f32_f64 or load.ty.* == .abi_i8_f64 or load.ty.* == .abi_i16_f64 or load.ty.* == .abi_f64_i8 or load.ty.* == .abi_f64_i16) try writer.writeAll(", align 8");
                try writer.writeByte('\n');
            },
            .store => |store| {
                try writer.print("  store {s} ", .{try self.typeString(store.ty)});
                try self.emitValue(writer, store.value, store.ty);
                try writer.writeAll(", ptr ");
                try self.emitValue(writer, store.ptr, null);
                if (store.ty.* == .abi_vec2_f32 or store.ty.* == .abi_v2f32_f32 or store.ty.* == .abi_v2f32_v2f32) try writer.writeAll(", align 4");
                if (store.ty.* == .abi_f32_f64 or store.ty.* == .abi_f64_f32 or store.ty.* == .abi_f32_i64 or store.ty.* == .abi_i64_f32 or store.ty.* == .abi_f64_i64 or store.ty.* == .abi_i64_f64 or store.ty.* == .abi_v2f32_i32 or store.ty.* == .abi_v2f32_i64 or store.ty.* == .abi_i64_v2f32 or store.ty.* == .abi_f64_v2f32 or store.ty.* == .abi_v2f32_f64 or store.ty.* == .abi_i8_f64 or store.ty.* == .abi_i16_f64 or store.ty.* == .abi_f64_i8 or store.ty.* == .abi_f64_i16) try writer.writeAll(", align 8");
                try writer.writeByte('\n');
            },
            .br => |branch| {
                try writer.writeAll("  br label %");
                try self.emitLabel(writer, branch.target);
                try writer.writeByte('\n');
            },
            .cbr => |branch| {
                try writer.writeAll("  br i1 ");
                try self.emitValue(writer, branch.cond, null);
                try writer.writeAll(", label %");
                try self.emitLabel(writer, branch.then_block);
                try writer.writeAll(", label %");
                try self.emitLabel(writer, branch.else_block);
                try writer.writeByte('\n');
            },
            .ret => |ret| {
                if (ret.value) |value| {
                    const ret_ty = self.current_ret_ty;
                    try writer.print("  ret {s} ", .{try self.typeString(ret_ty)});
                    try self.emitValue(writer, value, ret_ty);
                    try writer.writeByte('\n');
                } else {
                    try writer.writeAll("  ret void\n");
                }
            },
            .unreachable_ => try writer.writeAll("  unreachable\n"),
            .trap_ => {
                try writer.writeAll("  call void @llvm.trap()\n");
                try writer.writeAll("  unreachable\n");
            },
        }
    }

    fn emitLabel(self: *Emitter, writer: *std.Io.Writer, index: u32) !void {
        _ = self;
        if (index == 0) {
            try writer.writeAll("entry");
        } else {
            try writer.print(".b{d}", .{index});
        }
    }

    // The label needs a formatted index; handled by a small buffer.
    fn emitConstant(self: *Emitter, writer: *std.Io.Writer, constant: ir.Constant, ty: *types.Type) !void {
        switch (constant) {
            .scalar => |value| try self.emitValue(writer, value, ty),
            .array => |elements| {
                const array_ty = ty.array;
                try writer.writeAll("[");
                for (elements, 0..) |element, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.emitType(writer, array_ty.elem);
                    try writer.writeByte(' ');
                    try self.emitConstant(writer, element, array_ty.elem);
                }
                try writer.writeAll("]");
            },
            .struct_fields => |fields| {
                const info = ty.struct_type;
                try writer.writeAll("{ ");
                for (fields, 0..) |field, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.emitType(writer, info.fields[i].ty);
                    try writer.writeByte(' ');
                    try self.emitConstant(writer, field, info.fields[i].ty);
                }
                try writer.writeAll(" }");
            },
        }
    }

    fn emitFloatValue(
        self: *Emitter,
        writer: *std.Io.Writer,
        number: f64,
        expected: ?*types.Type,
    ) !void {
        _ = self;
        const value = if (expected) |ty| if (ty.* == .float and ty.float == 32)
            @as(f64, @floatCast(@as(f32, @floatCast(number))))
        else
            number else number;
        const bits: u64 = @bitCast(value);
        const hex = "0123456789ABCDEF";
        try writer.writeAll("0x");
        var shift: u6 = 60;
        while (true) {
            const digit: usize = @intCast(@as(u4, @truncate(bits >> shift)));
            try writer.writeByte(hex[digit]);
            if (shift == 0) break;
            shift -= 4;
        }
    }

    fn emitValue(self: *Emitter, writer: *std.Io.Writer, value: ir.Value, expected: ?*types.Type) !void {
        switch (value) {
            .none => try writer.writeAll("undef"),
            .int => |number| {
                if (expected) |ty| {
                    if (ty.* == .bool) {
                        try writer.print("{d}", .{@intFromBool(number != 0)});
                        return;
                    }
                }
                try writer.print("{d}", .{number});
            },
            .float => |number| try self.emitFloatValue(writer, number, expected),
            .boolean => |flag| try writer.writeAll(if (flag) "true" else "false"),
            .null_ptr => try writer.writeAll("null"),

            .local => |id| try writer.print("%v{d}", .{id}),
            .global => |index| try writer.print("@{s}", .{self.module.globals.items[index].name}),
            .string => |index| try writer.print("@.str{d}", .{index}),
            .reg => |id| try writer.print("%t{d}", .{id}),
            .param => |id| try writer.print("%arg{d}", .{id}),
        }
    }

    fn emitType(self: *Emitter, writer: *std.Io.Writer, ty: *types.Type) !void {
        try writer.writeAll(try self.typeString(ty));
    }

    fn typeString(self: *Emitter, ty: *types.Type) ![]const u8 {
        return switch (ty.*) {
            .void => "void",
            .bool => "i1",
            .char => "i32",
            .int => |info| try std.fmt.allocPrint(self.allocator, "i{d}", .{info.bits}),
            .float => |bits| if (bits == 32) "float" else "double",
            .abi_vec2_f32 => "<2 x float>",
            .abi_v2f32_f32 => "{ <2 x float>, float }",
            .abi_v2f32_v2f32 => "{ <2 x float>, <2 x float> }",
            .abi_pair_f64 => "{ double, double }",
            .abi_f64_i32 => "{ double, i32 }",
            .abi_i32_f64 => "{ i32, double }",
            .abi_f32_f64 => "{ float, double }",
            .abi_f64_f32 => "{ double, float }",
            .abi_f32_i64 => "{ float, i64 }",
            .abi_i64_f32 => "{ i64, float }",
            .abi_f64_i64 => "{ double, i64 }",
            .abi_i64_f64 => "{ i64, double }",
            .abi_v2f32_i32 => "{ <2 x float>, i32 }",
            .abi_v2f32_i64 => "{ <2 x float>, i64 }",
            .abi_i64_v2f32 => "{ i64, <2 x float> }",
            .abi_f64_v2f32 => "{ double, <2 x float> }",
            .abi_v2f32_f64 => "{ <2 x float>, double }",
            .abi_i8_f64 => "{ i8, double }",
            .abi_i16_f64 => "{ i16, double }",
            .abi_f64_i8 => "{ double, i8 }",
            .abi_f64_i16 => "{ double, i16 }",
            .pointer => "ptr",
            .array => |array| try std.fmt.allocPrint(self.allocator, "[{d} x {s}]", .{
                array.len,
                try self.typeString(array.elem),
            }),
            .slice => "%kyn.slice",
            .struct_type => |info| try std.fmt.allocPrint(self.allocator, "%struct.{s}", .{structLlvmName(info)}),
            .enum_type => |info| try self.typeString(info.backing),
            .fn_type => "ptr",
            .comptime_int => "i64",
            .comptime_float => "double",
            .null_type => "ptr",
            .invalid => "i8",
        };
    }
};

fn binaryName(op: ir.BinaryOp, ty: *types.Type) []const u8 {
    if (ty.isFloat()) {
        return switch (op) {
            .add => "fadd",
            .sub => "fsub",
            .mul => "fmul",
            .div => "fdiv",
            .mod => "frem",
            else => "fadd",
        };
    }
    const signed = ty.* == .int and ty.int.signed;
    return switch (op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => if (signed) "sdiv" else "udiv",
        .mod => if (signed) "srem" else "urem",
        .bit_and => "and",
        .bit_or => "or",
        .bit_xor => "xor",
        .shl => "shl",
        .shr => if (signed) "ashr" else "lshr",
    };
}

fn icmpPredicate(op: ir.CmpOp, ty: *types.Type) []const u8 {
    const signed = ty.* == .int and ty.int.signed;
    return switch (op) {
        .eq => "eq",
        .ne => "ne",
        .lt => if (signed) "slt" else "ult",
        .le => if (signed) "sle" else "ule",
        .gt => if (signed) "sgt" else "ugt",
        .ge => if (signed) "sge" else "uge",
    };
}

fn fcmpPredicate(op: ir.CmpOp) []const u8 {
    return switch (op) {
        .eq => "oeq",
        .ne => "one",
        .lt => "olt",
        .le => "ole",
        .gt => "ogt",
        .ge => "oge",
    };
}

fn emitEscapedByte(writer: *std.Io.Writer, byte: u8) !void {
    if (byte == '"') {
        try writer.writeAll("\\22");
    } else if (byte == '\\') {
        try writer.writeAll("\\5C");
    } else if (byte >= 0x20 and byte <= 0x7e) {
        try writer.writeByte(byte);
    } else {
        try writer.print("\\{X:0>2}", .{byte});
    }
}

const testing = std.testing;

test "emitter prints a deterministic module and function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prims = try types.Primitives.init(a);

    var module = ir.Module.init(a);

    const function = try a.create(ir.Function);
    function.* = .{
        .name = "main",
        .params = &.{},
        .ret = prims.i32,
        .linkage = .external,
    };
    const block = try a.create(ir.Block);
    block.* = .{ .id = 0, .terminated = true };
    try block.insts.append(a, .{ .ret = .{ .value = .{ .int = 0 } } });
    try function.blocks.append(a, block);
    try module.functions.append(a, function);

    var output: std.Io.Writer.Allocating = .init(a);
    var emitter = Emitter.init(a, &module);
    try emitter.emit(&output.writer);
    const ll = try output.toOwnedSlice();

    try testing.expect(std.mem.indexOf(u8, ll, "ModuleID = 'kyn'") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "define dso_local i32 @main()") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "ret i32 0") != null);
}

test "emitter declares extern functions and escapes strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prims = try types.Primitives.init(a);

    var module = ir.Module.init(a);
    const string_index = try module.addString("a\"b\n");

    const put_fn = try a.create(ir.Function);
    put_fn.* = .{
        .name = "puts",
        .params = &.{},
        .ret = prims.i32,
        .linkage = .declaration,
    };
    try module.functions.append(a, put_fn);

    var output: std.Io.Writer.Allocating = .init(a);
    var emitter = Emitter.init(a, &module);
    try emitter.emit(&output.writer);
    const ll = try output.toOwnedSlice();

    try testing.expect(std.mem.indexOf(u8, ll, "declare i32 @puts()") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "@.str0") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "\\22") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "\\0A") != null);
    try testing.expect(string_index == 0);
}

test "lowering open-ended slices, slice.ptr and C ABI small global aggregates" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");

    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        \\struct Small { x: i32 }
        \\const G_SMALL: Small = Small { x: 9 };
        \\extern fn take_small(s: Small) i32;
        \\fn main() i32 {
        \\    var arr: [3]i32 = [1, 2, 3];
        \\    let full = arr[..];
        \\    let p = full.ptr;
        \\    return (*p) + take_small(G_SMALL);
        \\}
    ;
    var src = try source.Source.init(a, "test.kyn", text);
    var reporter = diagnostics.Reporter.init(a, &src);
    var prims = try types.Primitives.init(a);
    var lx = lexer.Lexer.init(a, &src, &reporter);
    const tokens = try lx.tokenize();
    var p = parser.Parser.init(a, tokens, &reporter);
    const program = try p.parse();
    var sema = sema_mod.Sema.init(a, &reporter, &prims);
    try sema.analyze(program);
    var analyzer_pass = analyzer_mod.Analyzer.init(a, &reporter);
    try analyzer_pass.analyze(program);
    try testing.expect(!reporter.hasErrors());

    var module = ir.Module.init(a);
    var lowering = Lowering.init(a, &reporter, &module, .all);
    try lowering.lower(program);
    try testing.expect(!reporter.hasErrors());

    var output: std.Io.Writer.Allocating = .init(a);
    var emitter = Emitter.init(a, &module);
    try emitter.emit(&output.writer);
    const ll = try output.toOwnedSlice();

    try testing.expect(std.mem.indexOf(u8, ll, ", align 8") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "@llvm.memcpy.p0.p0.i64") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "call i32 @take_small(i64 ") != null);
}
