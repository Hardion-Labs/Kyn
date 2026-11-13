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

/// The error set of the constant- and type-emitting helpers. Declared explicitly
/// rather than inferred: `emitConstant` and `emitEmittedMemberConstant` call each
/// other, and two inferred error sets that reference each other are a dependency
/// loop Zig rejects.
pub const ConstantError = error{ OutOfMemory, WriteFailed };

const FnCtx = struct {
    function: *ir.Function,
    /// Set when this function retrieves arguments with `va_arg()`, which is the
    /// only reason to pay for `va_start`/`va_end` bookkeeping.
    uses_va_arg: bool = false,
    current: u32 = 0,
    break_stack: std.ArrayList(u32) = .empty,
    continue_stack: std.ArrayList(u32) = .empty,
};

/// The boundary class of an aggregate, as decided by the semantic analyzer.
/// The backend never re-derives it, so the classification and the lowering
/// cannot drift apart.
const BoundaryClass = sema_mod.BoundaryClass;
const AbiPair = types.AbiPair;

/// Boundary class of a value that does not cross a C ABI boundary.
const no_boundary: BoundaryClass = .none;

pub const Lowering = struct {
    allocator: std.mem.Allocator,
    reporter: *diagnostics.Reporter,
    module: *ir.Module,
    checks: ir.RuntimeCheckPolicy,
    globals: std.AutoHashMap(u32, u32),
    ctx: ?*FnCtx = null,
    current_fd: ?*ast.FnDecl = null,
    /// Whether the compilation target has the System V aggregate ABI this
    /// back end lowers. A target without it never reaches here: the front end
    /// rejects such boundaries, so this only has to agree with `Sema`.
    target_supports_c_abi: bool = true,
    /// The bitfield reference of the last `field_ptr` `lowerLvalue` produced.
    /// `lowerLvalue` returns only the pointer and a bitfield store needs the bit
    /// position too; threading it through every lvalue call site would touch a
    /// dozen places for one case. Valid only immediately after `lowerLvalue`,
    /// which is how its two callers use it.
    pending_bitfield: ?ir.BitfieldRef = null,

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
            no_boundary;

        var sret_info: ?*types.StructInfo = null;
        if (ret_class.eql(.memory)) {
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
                    const bits = sema_mod.smallRegisterBits(self.aggregateSize(ty) orelse 8);
                    try params_list.append(self.allocator, .{ .local = hidden_id, .ty = try self.simpleType(.{ .int = .{ .bits = bits, .signed = true } }) });
                    hidden_id += 1;
                },
                .sse_float, .sse_double, .sse_f32x2, .sse_f32x3, .sse_f32x4, .sse_f64x2, .pair => {
                    const params = try self.sseBoundaryParams(class);
                    for (params.types[0..params.count]) |param_ty| {
                        try params_list.append(self.allocator, .{ .local = hidden_id, .ty = param_ty });
                        hidden_id += 1;
                    }
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
            .small_1 => try self.simpleType(.{ .int = .{ .bits = sema_mod.smallRegisterBits(self.aggregateSize(fd.ret_expr.?.resolved.?) orelse 8), .signed = true } }),
            .small_2 => i128_ty,
            .sse_float, .sse_double, .sse_f32x2, .sse_f32x3, .sse_f32x4, .sse_f64x2, .pair => try self.sseReturnTransport(ret_class),
        };

        const function = try self.allocator.create(ir.Function);
        function.* = .{
            .name = fn_sym.link_name,
            .params = params,
            .ret = ret_ty,
            .linkage = linkage,
            .variadic = fd.is_variadic,
            .sret = ret_class.eql(.memory),
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

    fn aggregateBoundaryParam(self: *Lowering, ty: *types.Type) BoundaryClass {
        if (!ty.isAggregate()) return no_boundary;
        return sema_mod.aggregateBoundaryClassFor(ty, self.target_supports_c_abi) orelse no_boundary;
    }

    fn aggregateBoundaryRet(self: *Lowering, ret_expr: ?*ast.TypeExpr) BoundaryClass {
        const expr = ret_expr orelse return no_boundary;
        const ty = expr.resolved orelse return no_boundary;
        return self.aggregateBoundaryParam(ty);
    }

    /// The argument registers a boundary class travels in.
    const BoundaryParams = struct {
        /// Number of argument registers.
        count: u2 = 0,
        /// Type of each argument register, in order.
        types: [2]*types.Type = undefined,
    };

    /// Returns the transport type a boundary class returns: the scalar for a
    /// single SSE register, the vector for a packed `f32` pair and the
    /// matching two-register pair otherwise.
    fn sseReturnTransport(self: *Lowering, class: BoundaryClass) Error!*types.Type {
        return switch (class) {
            .sse_float => try self.simpleType(.{ .float = 32 }),
            .sse_double => try self.simpleType(.{ .float = 64 }),
            .sse_f32x2 => try self.simpleType(.abi_vec2_f32),
            .sse_f32x3 => try self.simpleType(.abi_v2f32_f32),
            .sse_f32x4 => try self.simpleType(.abi_v2f32_v2f32),
            .sse_f64x2 => try self.simpleType(.abi_pair_f64),
            .pair => |pair| try self.pairTransport(pair),
            else => unreachable,
        };
    }

    /// Returns the scalar type a register transports. A `<2 x float>` slot is
    /// an SSE vector, not a scalar.
    fn abiSlotType(self: *Lowering, slot: types.AbiSlot) Error!*types.Type {
        return switch (slot) {
            .i8 => self.simpleType(.{ .int = .{ .bits = 8, .signed = false } }),
            .i16 => self.simpleType(.{ .int = .{ .bits = 16, .signed = false } }),
            .i32 => self.simpleType(.{ .int = .{ .bits = 32, .signed = true } }),
            .i64 => self.simpleType(.{ .int = .{ .bits = 64, .signed = true } }),
            .f32 => self.simpleType(.{ .float = 32 }),
            .f64 => self.simpleType(.{ .float = 64 }),
            .f32x2 => self.simpleType(.abi_vec2_f32),
            .pointer => blk: {
                const void_ty = try self.simpleType(.void);
                break :blk try self.makePointer(void_ty, false);
            },
        };
    }

    /// Returns the transport type of a two-register aggregate: the two slots
    /// in order, which is how Clang coerces the return.
    fn pairTransport(self: *Lowering, pair: types.AbiPair) Error!*types.Type {
        return self.simpleType(.{ .abi_pair = pair });
    }

    /// Returns the argument registers a boundary class travels in. The types
    /// come from the class, not from the aggregate members, because a member
    /// may be nested and Clang flattens it into its leaf.
    fn sseBoundaryParams(self: *Lowering, class: BoundaryClass) Error!BoundaryParams {
        const f32_ty = try self.simpleType(.{ .float = 32 });
        const f64_ty = try self.simpleType(.{ .float = 64 });
        const vec2_f32_ty = try self.simpleType(.abi_vec2_f32);
        return switch (class) {
            .sse_float => .{ .count = 1, .types = .{ f32_ty, undefined } },
            .sse_double => .{ .count = 1, .types = .{ f64_ty, undefined } },
            .sse_f32x2 => .{ .count = 1, .types = .{ vec2_f32_ty, undefined } },
            .sse_f32x3 => .{ .count = 2, .types = .{ vec2_f32_ty, f32_ty } },
            .sse_f32x4 => .{ .count = 2, .types = .{ vec2_f32_ty, vec2_f32_ty } },
            .sse_f64x2 => .{ .count = 2, .types = .{ f64_ty, f64_ty } },
            .pair => |pair| .{ .count = 2, .types = .{
                try self.abiSlotType(pair.first),
                try self.abiSlotType(pair.second),
            } },
            else => unreachable,
        };
    }

    fn addLocal(self: *Lowering, id: u32, name: []const u8, ty: *types.Type, padding: ?u16) Error!void {
        const hidden_padding: u16 = padding orelse blk: {
            if (!ty.isAggregate()) break :blk 0;
            const size = self.aggregateSize(ty) orelse break :blk 0;
            break :blk if (size <= 8) 8 else if (size <= 16) 16 else @intCast(size);
        };
        try self.currentFunction().addLocal(self.allocator, id, name, ty, hidden_padding);
    }

    /// Declares the storage `va_start` fills. Its type is the target's
    /// `va_list`, which is not a Kyn type: the emitter sizes and aligns it, and
    /// this only records that the local holds no value.
    fn addVaListLocal(self: *Lowering, id: u32) Error!void {
        const void_ty = try self.simpleType(.void);
        const function = self.currentFunction();
        try function.addLocal(self.allocator, id, "va_list", void_ty, 0);
        function.locals.items[function.locals.items.len - 1].is_va_list = true;
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
    /// A store to a location that may be a bitfield. `bitfield` is the reference
    /// the `field_ptr` carried, so this is the only place that has to know a
    /// write merges bits rather than overwriting storage.
    fn emitFieldStore(self: *Lowering, ptr: ir.Value, value: ir.Value, ty: *types.Type, bitfield: ?ir.BitfieldRef) Error!void {
        const ref = bitfield orelse return self.emitValueStore(.{ .ptr = ptr, .value = value, .ty = ty });
        const unit = ref.unit;
        const current = try self.reg(unit);
        try self.emit(.{ .load = .{ .dst = current, .ptr = ptr, .ty = unit } });
        // The value arrives as the field's own type; it has to be widened to the
        // unit before the shift, and `bit_insert` masks it to the field width.
        const widened = try self.reg(unit);
        try self.emit(.{ .cast = .{
            .dst = widened,
            .kind = .zext,
            .from = ty,
            .to = unit,
            .value = value,
        } });
        const merged = try self.reg(unit);
        try self.emit(.{ .bit_insert = .{
            .dst = merged,
            .current = .{ .reg = current },
            .value = .{ .reg = widened },
            .unit = unit,
            .bit_offset = ref.bit_offset,
            .width = ref.width,
        } });
        try self.emit(.{ .store = .{ .ptr = ptr, .value = .{ .reg = merged }, .ty = unit } });
    }

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
        // `va_end` is never written in source, so it is attached to the exits
        // themselves: hooking here covers an explicit `return`, the implicit end
        // of a `void` function and the trap path in one place, and cannot be
        // forgotten by a new emission path added later.
        const tag = std.meta.activeTag(inst);
        if ((tag == .ret or tag == .trap_) and self.currentFunction().va_list_local != null) {
            try self.appendInst(.{ .va_end = {} });
        }
        try self.appendInst(inst);
    }

    fn appendInst(self: *Lowering, inst: ir.Inst) Error!void {
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
        const is_pointer = pointer_ty.* == .pointer or pointer_ty.* == .fn_ptr;
        if (!self.checks.null_dereference or !is_pointer) return;
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
            // `1 << 127` does not fit in an `i128`, so the minimum comes from
            // the type and not from an arithmetic expression that overflows for
            // the widest signed type — the whole point of the `INT_MIN / -1`
            // trap is to catch that case, not to make the compiler panic on it.
            const min_value = info.min();
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
        const lhs_info = loweredIntInfo(lhs_ty) orelse return;
        const rhs_info = loweredIntInfo(rhs_ty) orelse return;
        if (!self.checks.shifts) return;
        const i128_ty = try self.i128Type();
        const bool_ty = try self.booleanType();
        const bits: i128 = @intCast(lhs_info.bits);

        var normalized = rhs;
        if (rhs_info.bits != 128) {
            const kind: ir.CastKind = if (rhs_info.signed) .sext else .zext;
            const dst = try self.reg(i128_ty);
            try self.emit(.{ .cast = .{ .dst = dst, .kind = kind, .from = rhs_ty, .to = i128_ty, .value = rhs } });
            normalized = .{ .reg = dst };
        }

        var cond: u32 = undefined;
        const limit: ir.Value = .{ .int = bits };
        if (rhs_info.signed) {
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

        // An exported variadic function is the one place a `va_list` exists:
        // C wrote trailing arguments into the register save area and this is
        // what lets `va_arg()` walk them. A declaration never reaches here.
        if (fd.is_variadic) {
            const id = self.module.ephemeral();
            try self.addVaListLocal(id);
            function.va_list_local = id;
            try self.emit(.{ .va_start = {} });
        }

        const boundary = fd.is_extern or fd.is_export;
        var visible_index: usize = if (boundary and self.aggregateBoundaryRet(fd.ret_expr) == .memory) 1 else 0;
        for (fd.params) |param| {
            const sym = param.sym orelse continue;
            const class = if (boundary) self.aggregateBoundaryParam(sym.ty) else no_boundary;
            const aggregate_size = self.aggregateSize(sym.ty) orelse 8;
            // An aggregate that crosses the boundary is unpacked into a slot
            // with room for its transport, so a sub-eightbyte class never
            // writes past the aggregate's own size (`{ f32, f32, i32 }` is
            // 12 bytes wide but its pair transport is 16).
            const transport_size: usize = if (class.isPair()) 16 else aggregate_size;
            const padding: ?u16 = switch (class) {
                .none => null,
                .small_1, .small_2, .sse_float, .sse_double, .sse_f32x2, .sse_f32x3, .sse_f32x4, .sse_f64x2, .pair => @intCast(transport_size),
                .memory => @intCast(aggregate_size),
            };
            try self.addLocal(sym.id, sym.name, sym.ty, padding);

            switch (class) {
                .none => {
                    if (function.params.len <= visible_index) break;
                    try self.emitValueStore(.{
                        .ptr = .{ .local = sym.id },
                        .value = .{ .param = function.params[visible_index].local },
                        .ty = function.params[visible_index].ty,
                    });
                    visible_index += 1;
                },
                .small_1 => {
                    if (function.params.len <= visible_index) break;
                    const base = function.params[visible_index].local;
                    try self.lowerPackedAggregate(.{ .local = sym.id }, aggregate_size, .{ .param = base }, 0, function.params[visible_index].ty);
                    visible_index += 1;
                },
                .small_2 => {
                    if (function.params.len <= visible_index + 1) break;
                    const lo = function.params[visible_index].local;
                    const hi = function.params[visible_index + 1].local;
                    try self.lowerPackedAggregate(.{ .local = sym.id }, aggregate_size, .{ .param = lo }, 0, function.params[visible_index].ty);
                    try self.lowerPackedAggregate(.{ .local = sym.id }, aggregate_size, .{ .param = hi }, 8, function.params[visible_index + 1].ty);
                    visible_index += 2;
                },
                .sse_float, .sse_double, .sse_f32x2, .sse_f32x3, .sse_f32x4, .sse_f64x2, .pair => {
                    // The aggregate travels in one or two registers, stored
                    // into the byte slots that hold them.
                    const params = try self.sseBoundaryParams(class);
                    if (function.params.len < visible_index + params.count) break;
                    for (0..params.count) |index| {
                        const slot_ptr = if (index == 0)
                            ir.Value{ .local = sym.id }
                        else
                            try self.byteOffset(.{ .local = sym.id }, 8);
                        try self.emitValueStore(.{
                            .ptr = slot_ptr,
                            .value = .{ .param = function.params[visible_index + index].local },
                            .ty = params.types[index],
                        });
                    }
                    visible_index += params.count;
                },
                .memory => {
                    if (function.params.len <= visible_index) break;
                    const base = function.params[visible_index].local;
                    try self.emit(.{ .copy_bytes = .{
                        .destination = .{ .local = sym.id },
                        .source = .{ .param = base },
                        .length = @intCast(aggregate_size),
                    } });
                    visible_index += 1;
                },
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
            .bitfield = bitfieldRefOf(info, field_index),
        } });
        return .{ .reg = pointer };
    }

    fn lowerPackedAggregate(
        self: *Lowering,
        destination: ir.Value,
        size: usize,
        source: ir.Value,
        offset: usize,
        source_ty: *types.Type,
    ) Error!void {
        if (size <= offset) return;
        const i64_ty = try self.simpleType(.{ .int = .{ .bits = 64, .signed = true } });
        const temp = self.module.ephemeral();
        try self.addLocal(temp, "pack", i64_ty, null);
        try self.emitValueStore(.{
            .ptr = .{ .local = temp },
            .value = source,
            .ty = source_ty,
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
        // A sub-eightbyte register stores only the bytes it carries, so a
        // 12-byte aggregate written at offset 8 never touches byte 12.
        const register_bits: usize = if (source_ty.* == .int) source_ty.int.bits else 8 * 8;
        const copy_length = @min(register_bits / 8, size - offset);
        try self.emit(.{ .copy_bytes = .{
            .destination = destination_value,
            .source = .{ .local = temp },
            .length = @intCast(copy_length),
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
                        const ret = fd.ret_expr orelse break :blk no_boundary;
                        const ret_ty = ret.resolved orelse break :blk no_boundary;
                        if (!boundary) break :blk no_boundary;
                        break :blk self.aggregateBoundaryParam(ret_ty);
                    } else no_boundary;
                    const sse_abi_return = ret_class.isPair() or ret_class.eql(.sse_float) or ret_class.eql(.sse_double) or ret_class.eql(.sse_f32x2);
                    const value: ir.Value = if (sse_abi_return) .none else try self.lowerExpr(expr);
                    const hidden_sret = boundary and ret_class.eql(.memory);
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
                            const abi_ty = try self.sseReturnTransport(ret_class);
                            const field_value = try self.reg(abi_ty);
                            try self.emit(.{ .load = .{
                                .dst = field_value,
                                .ptr = aggregate_ptr,
                                .ty = abi_ty,
                            } });
                            try self.emit(.{ .ret = .{ .value = .{ .reg = field_value } } });
                        } else if (ret_class.eql(.small_1) or ret_class.eql(.small_2)) {
                            const storage_ty = if (ret_class.eql(.small_1))
                                try self.simpleType(.{ .int = .{ .bits = sema_mod.smallRegisterBits(self.aggregateSize(expr.ty orelse try self.simpleType(.invalid)) orelse 8), .signed = true } })
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
            // A literal arrives as `u128`, which reaches one value past
            // `i128`'s maximum. Keep the two's-complement bit pattern, which
            // `emitValue` renders back according to the declared signedness.
            .int_lit => |lit| .{ .int = @bitCast(lit.value) },
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
            .va_arg => |va_arg| try self.lowerVaArg(expr, va_arg),
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
                if (try self.loadBitfield(expr, ptr)) |value| break :blk value;
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
        // A function name in value position is its address; in call position
        // `lowerCall` reads the symbol directly, so a direct call never goes
        // through this path.
        if (sym.kind == .function) return .{ .func = sym.link_name };
        if (sym.kind == .struct_type or sym.kind == .enum_type) return .none;
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
            // Negating a literal is folded rather than computed: the most
            // negative value of a signed type is written as `-` in front of its
            // magnitude, and `0 - 2^127` overflows in a checked build even
            // though the result is exactly the value the literal denotes. The
            // checker already accepts that spelling (`minMagnitude`), so the
            // lowering must produce it instead of trapping at run time.
            if (unary.operand.kind == .int_lit) {
                const magnitude = unary.operand.kind.int_lit.value;
                const info = ty.intInfo();
                if (info.signed and magnitude == info.minMagnitude()) {
                    // The value of the *type*, not of an `i128`: `-128` for an
                    // `i8`, `-2^127` for an `i128`. Only the widest case cannot
                    // be built by negating, because its magnitude has no
                    // positive counterpart.
                    const value: i128 = if (magnitude == (@as(u128, 1) << 127))
                        std.math.minInt(i128)
                    else
                        -@as(i128, @intCast(magnitude));
                    return .{ .int = value };
                }
            }
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
        const bitfield = self.pendingBitfieldRef();

        if (assign.op == .assign) {
            if (target_ty.isAggregate() and isAggregateInitializer(assign.value)) {
                try self.lowerAggregateInto(ptr, target_ty, assign.value);
            } else {
                const value = try self.lowerExpr(assign.value);
                try self.emitFieldStore(ptr, value, target_ty, bitfield);
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

    /// Lowers a call argument and converts it to the type the call passes. A
    /// variadic argument is already the promoted value of its expression, so
    /// only a genuine representation change emits a conversion.
    fn lowerArgument(self: *Lowering, expr: *ast.Expr, from: *types.Type, to: *types.Type) Error!ir.Value {
        const value = try self.lowerExpr(expr);
        if (types.Type.eql(from, to)) return value;
        if (from.* == .invalid or to.* == .invalid) return value;
        if (isSameRepresentation(from, to)) return value;
        const kind = castKind(from, to) orelse return value;
        const dst = try self.reg(to);
        try self.emit(.{ .cast = .{ .dst = dst, .kind = kind, .from = from, .to = to, .value = value } });
        return .{ .reg = dst };
    }

    /// Lowers a call through a function value. The callee is an ordinary
    /// pointer, so the value is converted to `ptr` and the call names its own
    /// signature: an indirect call has no declaration to read the parameter and
    /// return types from.
    fn lowerIndirectCall(self: *Lowering, call: ast.Expr.Kind.Call) Error!ir.Value {
        const signature = call.callee.ty orelse return .none;
        const info = switch (signature.*) {
            .fn_ptr => |fn_info| fn_info,
            else => {
                try self.reporter.err("E0604", call.callee.span, "callee has no function signature", .{});
                return .none;
            },
        };
        // A declared function lowers to a symbol address and a stored value to a
        // load; both already have `ptr` representation, so no conversion is
        // emitted. Calling through a null function pointer is the same fault as
        // dereferencing one, so it goes through the same check.
        const callee = try self.lowerExpr(call.callee);
        try self.emitNullCheck(signature, callee);

        var args = try self.allocator.alloc(ir.Value, call.args.len);
        var arg_types = try self.allocator.alloc(*types.Type, call.args.len);
        for (call.args, 0..) |arg, i| {
            const expressed = arg.ty orelse try self.simpleType(.invalid);
            const ty = if (i < call.arg_types.len) call.arg_types[i] else expressed;
            args[i] = try self.lowerArgument(arg, expressed, ty);
            arg_types[i] = ty;
        }
        const ret = info.ret;
        var dst: ?u32 = null;
        if (ret.* != .void) dst = try self.reg(ret);
        try self.emit(.{ .call = .{
            .dst = dst,
            .name = "",
            .callee = callee,
            .args = args,
            .arg_types = arg_types,
            .ret = ret,
        } });
        return if (dst) |id| .{ .reg = id } else .none;
    }

    /// `va_arg()` is one instruction: the retrieval type is the one the checker
    /// put on the expression, never a default, so a `double` is read as a
    /// `double` and an `i32` as an `i32`.
    fn lowerVaArg(self: *Lowering, expr: *ast.Expr, va_arg: ast.Expr.Kind.VaArg) Error!ir.Value {
        _ = expr;
        const ty = va_arg.ty orelse return .none;
        self.ctx.?.uses_va_arg = true;
        const dst = try self.reg(ty);
        try self.emit(.{ .va_arg = .{ .dst = dst, .ty = ty } });
        return .{ .reg = dst };
    }

    fn lowerCall(self: *Lowering, expr: *ast.Expr, call: ast.Expr.Kind.Call) Error!ir.Value {
        const callee_sym = switch (call.callee.kind) {
            .ident => |ident| ident.sym,
            .field => |field| field.sym,
            else => null,
        };
        // The callee denotes a declared function only when the syntax resolves
        // to one: a function name decays to a value so it can be passed around,
        // which means a call through a local, a field or a parameter is indirect
        // and needs no separate flag to say so.
        if (callee_sym == null or callee_sym.?.kind != .function) {
            return self.lowerIndirectCall(call);
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

        if (ret_class.eql(.memory)) {
            const temp = self.module.ephemeral();
            try self.addLocal(temp, "tmp.aggregate", call_result, null);
            try args_list.append(self.allocator, .{ .local = temp });
            try types_list.append(self.allocator, ptr_ty);
            try byval_list.append(self.allocator, null);
        }

        for (call.args, 0..) |arg, arg_index| {
            // The type the argument is passed as: the declared parameter type for
            // a fixed parameter, the promoted type for a variadic one. Lowering
            // the expression and then converting to that type keeps the C
            // default argument promotions in one place (the analyzer) while the
            // emitted value always matches the type the call site declares.
            const expressed = arg.ty orelse try self.simpleType(.invalid);
            const ty = if (arg_index < call.arg_types.len) call.arg_types[arg_index] else expressed;
            const class_tag = self.aggregateBoundaryParam(ty);
            switch (class_tag) {
                .none => {
                    try args_list.append(self.allocator, try self.lowerArgument(arg, expressed, ty));
                    try types_list.append(self.allocator, ty);
                    try byval_list.append(self.allocator, null);
                },
                .small_1 => {
                    const slot = try self.lowerAggregateBase(arg, ty);
                    const size: u64 = @intCast(self.aggregateSize(ty) orelse 8);
                    const bits: u16 = sema_mod.smallRegisterBits(size);
                    const sized_ty = try self.simpleType(.{ .int = .{ .bits = bits, .signed = true } });
                    var pack_ptr = slot;
                    if (size < bits / 8) {
                        const pack_id = self.module.ephemeral();
                        try self.addLocal(pack_id, "tmp.pack1", sized_ty, null);
                        try self.emitValueStore(.{ .ptr = .{ .local = pack_id }, .value = .{ .int = 0 }, .ty = sized_ty });
                        if (size > 0) {
                            try self.emit(.{ .copy_bytes = .{ .destination = .{ .local = pack_id }, .source = slot, .length = @intCast(size) } });
                        }
                        pack_ptr = .{ .local = pack_id };
                    }
                    const loaded = try self.reg(sized_ty);
                    try self.emit(.{ .load = .{ .dst = loaded, .ptr = pack_ptr, .ty = sized_ty } });
                    try args_list.append(self.allocator, .{ .reg = loaded });
                    try types_list.append(self.allocator, sized_ty);
                    try byval_list.append(self.allocator, null);
                },
                .sse_float, .sse_double, .sse_f32x2, .sse_f32x3, .sse_f32x4, .sse_f64x2, .pair => {
                    // The aggregate travels in one or two registers, loaded
                    // from the byte slots that hold them.
                    const slot = try self.lowerAggregateBase(arg, ty);
                    const params = try self.sseBoundaryParams(class_tag);
                    for (0..params.count) |index| {
                        const slot_ptr = if (index == 0)
                            slot
                        else
                            try self.byteOffset(slot, 8);
                        const value = try self.reg(params.types[index]);
                        try self.emit(.{ .load = .{ .dst = value, .ptr = slot_ptr, .ty = params.types[index] } });
                        try args_list.append(self.allocator, .{ .reg = value });
                        try types_list.append(self.allocator, params.types[index]);
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
                    const p0 = try self.byteOffset(pack_ptr, 0);
                    const p8 = try self.byteOffset(pack_ptr, 8);
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

        const hidden_result_ptr: ?ir.Value = if (ret_class.eql(.memory)) args_list.items[0] else null;
        const visible_types = try types_list.toOwnedSlice(self.allocator);
        const args = try args_list.toOwnedSlice(self.allocator);
        const byval_types = try byval_list.toOwnedSlice(self.allocator);
        const value_ty = switch (ret_class) {
            .small_1 => try self.simpleType(.{ .int = .{ .bits = sema_mod.smallRegisterBits(self.aggregateSize(call_result) orelse 8), .signed = true } }),
            .small_2 => i128_ty,
            .sse_float, .sse_double, .sse_f32x2, .sse_f32x3, .sse_f32x4, .sse_f64x2, .pair => try self.sseReturnTransport(ret_class),
            .none, .memory => call_result,
        };

        const crosses_boundary = ret_class.crosses();
        var dst: ?u32 = null;
        if (crosses_boundary and !ret_class.eql(.memory)) dst = try self.reg(value_ty);
        if (!crosses_boundary and call_result.* != .void) dst = try self.reg(call_result);

        try self.emit(.{ .call = .{
            .dst = dst,
            .name = name,
            .args = args,
            .arg_types = visible_types,
            .ret = if (crosses_boundary) value_ty else call_result,
            .sret = ret_class.eql(.memory),
            .sret_type = if (ret_class.eql(.memory)) blk: {
                const ty = call_result;
                if (ty.* == .struct_type) break :blk ty.struct_type;
                break :blk null;
            } else null,
            .byval_types = byval_types,
        } });

        switch (ret_class) {
            .none => return if (dst) |id| .{ .reg = id } else .none,
            .sse_float, .sse_double, .sse_f32x2, .sse_f32x3, .sse_f32x4, .sse_f64x2, .pair => {
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

    fn byteOffset(self: *Lowering, base: ir.Value, offset: usize) Error!ir.Value {
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

    /// The field a `field` expression names, when that field is a bitfield. The
    /// lvalue path has already produced a GEP to the storage unit, so the read is
    /// a load and a slice; returning null means "not a bitfield" and the caller
    /// takes the ordinary load path.
    fn loadBitfield(self: *Lowering, expr: *ast.Expr, ptr: ir.Value) Error!?ir.Value {
        const field = switch (expr.kind) {
            .field => |f| f,
            else => return null,
        };
        const base_ty = field.base.ty orelse return null;
        const struct_ty = if (base_ty.* == .pointer) base_ty.pointer.elem else base_ty;
        if (struct_ty.* != .struct_type) return null;
        const info = struct_ty.struct_type;
        if (info.placed.len <= field.field_index) return null;
        const placed = info.placed[field.field_index];
        if (placed.bit_offset == 0 and !sema_mod.isBitfield(info.fields[field.field_index].ty)) return null;
        const field_ty = info.fields[field.field_index].ty;
        if (!sema_mod.isBitfield(field_ty)) return null;

        const unit_ty = placed.storage_ty orelse return null;
        const unit = try self.reg(unit_ty);
        try self.emit(.{ .load = .{ .dst = unit, .ptr = ptr, .ty = unit_ty } });
        // The slice happens in the unit's width, so the result carries the unit's
        // type; narrowing it to the field's own type is what makes the rest of
        // the expression see `u3` rather than `u8`.
        const sliced = try self.reg(unit_ty);
        try self.emit(.{ .bit_extract = .{
            .dst = sliced,
            .value = .{ .reg = unit },
            .unit = unit_ty,
            .bit_offset = placed.bit_offset,
            .width = @intCast(field_ty.int.bits),
            .signed = field_ty.int.signed,
        } });
        const wide = try self.reg(field_ty);
        try self.emit(.{ .cast = .{
            .dst = wide,
            .kind = .trunc,
            .from = unit_ty,
            .to = field_ty,
            .value = .{ .reg = sliced },
        } });
        return .{ .reg = wide };
    }

    /// The bit position of a field, when it is a bitfield. Kept next to the
    /// `field_ptr` producers so both of them derive it the same way, from the one
    /// place that computed it.
    fn bitfieldRefOf(info: *types.StructInfo, field_index: u32) ?ir.BitfieldRef {
        if (info.is_union) return null;
        if (info.placed.len <= field_index) return null;
        const placed = info.placed[field_index];
        if (!sema_mod.isBitfield(info.fields[field_index].ty)) return null;
        const field_ty = info.fields[field_index].ty;
        return .{
            .unit = placed.storage_ty.?,
            .bit_offset = placed.bit_offset,
            .width = @intCast(field_ty.int.bits),
            .signed = field_ty.int.signed,
        };
    }

    fn pendingBitfieldRef(self: *Lowering) ?ir.BitfieldRef {
        return self.pending_bitfield;
    }

    fn lowerLvalue(self: *Lowering, expr: *ast.Expr) Error!ir.Value {
        self.pending_bitfield = null;
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
                const bitfield_ref = bitfieldRefOf(struct_ty.struct_type, field.field_index);
                try self.emit(.{ .field_ptr = .{
                    .dst = dst,
                    .base = base_ptr,
                    .struct_ty = struct_ty.struct_type,
                    .field = field.field_index,
                    .bitfield = bitfield_ref,
                } });
                // Only a *direct* field lvalue can be a bitfield target; an index
                // or a dereference produces no `field_ptr`, so the flag stays
                // cleared and the ordinary store path is taken.
                self.pending_bitfield = if (std.meta.activeTag(expr.kind) == .field) bitfield_ref else null;
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
                    const bitfield_ref = bitfieldRefOf(info, field.index);
                    try self.emit(.{ .field_ptr = .{
                        .dst = dst,
                        .base = dest,
                        .struct_ty = info,
                        .field = field.index,
                        .bitfield = bitfield_ref,
                    } });
                    if (field_ty.isAggregate()) {
                        try self.lowerAggregateInto(.{ .reg = dst }, field_ty, field.value);
                    } else {
                        const value = try self.lowerExpr(field.value);
                        try self.emitFieldStore(.{ .reg = dst }, value, field_ty, bitfield_ref);
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
                // A value of the aggregate's own type, not a literal: an
                // aggregate initializer can take any expression that produces
                // one — a variable, a field, a call result. The copy is the same
                // byte-wise move the C ABI uses for a by-memory aggregate, so
                // there is no second representation to keep in step.
                const source = try self.lowerLvalue(expr);
                const size = sizeInBytes(ty) orelse {
                    try self.reporter.err("E0606", expr.span, "internal: expected an aggregate initializer", .{});
                    return;
                };
                try self.emit(.{ .copy_bytes = .{
                    .destination = dest,
                    .source = source,
                    .length = @intCast(size),
                } });
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
            // A literal above `i128`'s maximum (a `u128` constant) has no
            // `i128` spelling, so preserve its bit pattern instead of trapping.
            // The emitter renders it back in the unsigned domain when the
            // expected type is an unsigned 128-bit integer.
            .int_lit => |lit| return .{ .int = @bitCast(lit.value) },
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
            // A constant cast is resolved into the *destination* category, not
            // the source one: `3 as f64` is a float constant and `1.5 as i32`
            // is an integer one. Returning the source value unchanged emitted
            // an integer constant where the destination type was a float, and
            // the module then failed to assemble.
            .cast => |cast| {
                // The operand folds in its own type, not the destination one: a
                // chain like `3.9 as i32 as f64` truncates first and converts
                // the truncated value, so passing the outer destination inward
                // would turn it into 3.9.
                const operand_ty = cast.operand.ty orelse ty;
                const value = (try self.lowerConst(cast.operand, operand_ty)) orelse return null;
                return switch (value) {
                    .int => |number| if (ty.isFloat())
                        .{ .float = @floatFromInt(number) }
                    else if (ty.* == .bool)
                        .{ .boolean = number != 0 }
                    else
                        .{ .int = truncateInt(number, ty) },
                    .float => |number| if (ty.* == .bool)
                        // A NaN is nonzero, so it is true, as in C.
                        .{ .boolean = !(number == 0.0) }
                    else if (ty.isInteger())
                        .{ .int = truncateInt(@intFromFloat(number), ty) }
                    else
                        .{ .float = number },
                    .boolean => |flag| if (ty.isFloat())
                        .{ .float = if (flag) 1.0 else 0.0 }
                    else if (ty.* == .bool)
                        .{ .boolean = flag }
                    else
                        .{ .int = if (flag) 1 else 0 },
                    else => value,
                };
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
    // A function value is one `ptr` at the ABI level, so converting between it
    // and a raw pointer is a change of meaning, not of representation: nothing
    // is emitted and the value keeps travelling in the same register.
    if ((from.* == .fn_ptr and to.isPointer()) or (from.isPointer() and to.* == .fn_ptr)) return true;
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

/// The width and signedness an integer is *lowered* with. A `comptime_int`
/// carries neither in the type: it is an unfolded constant. At lowering time it
/// is a signed 64-bit value — that is what `typeString` names it — so the
/// overflow and shift checks have to use those numbers. Reading `intInfo()`
/// directly yields `bits = 0, signed = false`, which made `1 - 2 + 3` emit an
/// unsigned `usub` that traps on the negative result, and made a shift by a
/// constant check its amount against zero and always trap.
fn loweredIntInfo(ty: *types.Type) ?types.IntInfo {
    return switch (ty.*) {
        .comptime_int => .{ .bits = 64, .signed = true },
        .int => |info| info,
        .char => .{ .bits = 32, .signed = false },
        .enum_type => |info| loweredIntInfo(info.backing),
        else => null,
    };
}

fn castKind(from: *types.Type, to: *types.Type) ?ir.CastKind {
    if (to.* == .bool) {
        if (from.isInteger() or from.isPointer()) return .int_to_bool;
        // `x != 0` is the same predicate for a float, with an ordered compare so
        // that NaN follows the IEEE rule a C `(_Bool)` conversion follows: a NaN
        // is nonzero, so it converts to true.
        if (from.isFloat()) return .float_to_bool;
        return null;
    }
    // A `bool` is one bit, which no floating conversion instruction accepts, so
    // it widens to `i32` first and the result is exact. `zext i1 ... to float`
    // is not valid IR, which is what an earlier emitter produced here.
    if (from.* == .bool) {
        if (to.isFloat()) return .bool_to_float;
        return .bool_to_int;
    }
    // A function value has the same representation as a raw pointer, so both
    // directions of that pair are a bitcast; the integer directions are the
    // address erasure `ptrtoint`/`inttoptr` spell.
    if (from.isPointer() or from.* == .fn_ptr) {
        if (to.isPointer() or to.* == .fn_ptr) return .bitcast;
        if (to.isInteger()) return .ptrtoint;
        return null;
    }
    if (to.isPointer() or to.* == .fn_ptr) {
        if (from.isInteger()) return .inttoptr;
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

        // A struct/union/array is laid out in exactly one place — the semantic
        // analyzer's guess, which the classifier and the ABI read too — so the
        // backend cannot drift from it. Re-deriving it here would need a second
        // copy of the union and packed rules.
        .struct_type, .array => blk: {
            const layout = sema_mod.aggregateLayoutGuess(ty) orelse break :blk null;
            break :blk @intCast(layout.size);
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
    /// The `va_list` of the definition being emitted, so `va_start`, `va_arg`
    /// and `va_end` all address the same storage.
    current_va_list: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, module: *ir.Module) Emitter {
        return .{ .allocator = allocator, .module = module };
    }

    pub fn emit(self: *Emitter, writer: *std.Io.Writer) !void {
        try writer.writeAll("; ModuleID = 'kyn'\n");
        try writer.writeAll("; Generated by the Kyn compiler. Do not edit.\n\n");
        try writer.writeAll("declare void @llvm.trap() noreturn nounwind\n\n");
        try writer.writeAll("declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1) nounwind\n\n");
        try writer.writeAll("%kyn.slice = type { ptr, i64 }\n");
        // Only an exported variadic body needs these, and their names are part of
        // the emitted module: declaring them unconditionally would change the
        // IR of every existing program, so the module stays byte-identical
        // unless a `va_arg()` can actually appear in it.
        if (self.hasVariadicBody()) {
            try writer.print("{s}\n", .{vaListDecl()});
            // The suffix-free spelling: `llvm.va_start.p0` only exists from
            // LLVM 19 on, so emitting it makes the object unlinkable when the
            // assembler is older. The unsuffixed name is the same intrinsic in
            // every version Kyn targets.
            try writer.writeAll("declare void @llvm.va_start(ptr)\n");
            try writer.writeAll("declare void @llvm.va_end(ptr)\n");
        }
        if (self.module.structs.items.len > 0) try writer.writeByte('\n');
        for ([_]u16{ 8, 16, 32, 64, 128 }) |bits| {
            for ([_][]const u8{ "add", "sub", "mul" }) |op| {
                try writer.print("declare {{ i{d}, i1 }} @llvm.s{s}.with.overflow.i{d}(i{d}, i{d})\n", .{ bits, op, bits, bits, bits });
                try writer.print("declare {{ i{d}, i1 }} @llvm.u{s}.with.overflow.i{d}(i{d}, i{d})\n", .{ bits, op, bits, bits, bits });
            }
        }
        try writer.writeByte('\n');

        for (self.module.structs.items) |info| {
            if (info.is_union) {
                // A union has no LLVM type. It is emitted as a struct holding one
                // aggregate of the member with the greatest alignment, which is
                // enough bytes: every member then sits at offset 0 and LLVM's
                // layout of this type matches the measured size and alignment.
                try self.emitUnionType(writer, info);
                continue;
            }
            // `packed` must reach the definition as `<{ ... }>`; a plain `{ }`
            // would make LLVM re-insert the padding the source removed. The
            // field GEPs are unchanged, so the two forms are interchangeable to
            // the rest of the emitter.
            const open: []const u8 = if (info.is_packed) "type <{ " else "type { ";
            const close: []const u8 = if (info.is_packed) " }>" else " }";
            try writer.print("%struct.{s} = {s}", .{ structLlvmName(info), open });
            // The emitted members are *units*, not source fields: a bitfield run
            // is one integer and a gap is an explicit padding array, so LLVM's
            // layout of this type reproduces the bit positions sema computed.
            // Emitting one member per source field would give every bitfield its
            // own byte and silently disagree with `aggregateLayoutGuess`.
            for (info.emitted, 0..) |member, i| {
                if (i > 0) try writer.writeAll(", ");
                try self.emitType(writer, member);
            }
            // `align(N)` raises the aggregate's alignment, and LLVM derives a
            // struct's alignment from its members -- so the annotation alone would
            // not do it. An explicit trailing padding array brings the type's size
            // up to a multiple of N, which is exactly the layout rule and is what
            // makes LLVM align the type to N as well.
            if (info.explicit_align > 0) {
                // Only when there is a real gap: a `[0 x i8]` member would be
                // emitted text that says nothing and that a reader has to
                // discount.
                const padding = try self.explicitAlignPadding(info);
                if (padding > 0) {
                    if (info.emitted.len > 0) try writer.writeAll(", ");
                    try writer.print("[{d} x i8]", .{padding});
                } else if (info.emitted.len == 0) {
                    try writer.writeAll("i8");
                }
            } else if (info.emitted.len == 0) {
                try writer.writeAll("i8");
            }
            try writer.print("{s}\n", .{close});
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
                // The trailing marker is what makes the declaration variadic to
                // LLVM; without it a call carrying extra arguments would not
                // match this declaration.
                if (function.variadic) {
                    if (function.params.len > 0) try writer.writeAll(", ");
                    try writer.writeAll("...");
                }
                try writer.writeAll(")\n");
            } else {
                try self.emitFunction(writer, function);
            }
        }
    }

    fn hasVariadicBody(self: *Emitter) bool {
        for (self.module.functions.items) |function| {
            if (function.linkage != .declaration and function.variadic) return true;
        }
        return false;
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

    /// The C `va_list` of the targets Kyn emits for. The x86_64 System V ABI spells
    /// it as a one-element array of the register-save descriptor; the intrinsics
    /// take a pointer to that array, which is why the definition is an array and
    /// not the struct.
    fn vaListDecl() []const u8 {
        return "%struct.__va_list_tag = type { i32, i32, ptr, ptr }\n%kyn.va_list = type [1 x %struct.__va_list_tag]";
    }

    /// The type the alloca, `va_start`, `va_arg` and `va_end` all name.
    const va_list_name = "%kyn.va_list";

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
            .abi_v2f32_i32 => 8,
            .abi_v2f32_i64 => 8,
            .abi_i64_v2f32 => 8,
            .abi_f64_v2f32 => 8,
            .abi_v2f32_f64 => 8,
            .abi_pair => 8,
            .pointer => 8,
            .enum_type => |info| llvmAlignmentOfType(info.backing),
            .array => |array| llvmAlignmentOfType(array.elem),
            .struct_type => |info| blk: {
                // Delegated, not re-derived: this used to compute the maximum of
                // the fields' alignments, which ignores `packed` (alignment 1) and
                // `align(N)`, so an alloca or a `byval` would have been annotated
                // with an alignment the layout does not have. There is one layout
                // implementation and this reads it.
                _ = info;
                const layout = sema_mod.aggregateLayoutGuess(ty) orelse break :blk 1;
                break :blk @intCast(@min(layout.align_, 16));
            },
            .slice => 8,
            else => 8,
        };
    }

    fn emitFunction(self: *Emitter, writer: *std.Io.Writer, function: *ir.Function) !void {
        self.current_ret_ty = function.ret;
        self.current_va_list = function.va_list_local orelse 0;
        const linkage = if (function.linkage == .internal) "internal " else "dso_local ";
        try writer.print("define {s}{s} @{s}(", .{ linkage, try self.typeString(function.ret), function.name });
        try self.emitParameters(writer, function);
        // A definition C calls carries the same trailing marker as a
        // declaration: without it the emitted function is not a varargs
        // function, and `llvm.va_start` is rejected by the verifier.
        if (function.variadic) {
            if (function.params.len > 0) try writer.writeAll(", ");
            try writer.writeAll("...");
        }
        try writer.writeAll(") {\n");

        for (function.blocks.items, 0..) |block, index| {
            if (index == 0) {
                try writer.writeAll("entry:\n");
            } else {
                try writer.print(".b{d}:\n", .{block.id});
            }
            if (index == 0) {
                for (function.locals.items) |local| {
                    if (local.is_va_list) {
                        // `va_list` is the one-element array, and the intrinsics
                        // take a pointer to it rather than to the tag inside.
                        try writer.print("  %v{d} = alloca {s}, align 16\n", .{ local.id, va_list_name });
                    } else if (local.padding > 0) {
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
                const signed = if (loweredIntInfo(checked.ty)) |info| info.signed else false;
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
                    .float_to_bool => "fcmp une",
                    .bool_to_float => "uitofp",
                };
                if (cast.kind == .int_to_bool) {
                    try writer.print("  %t{d} = icmp ne {s} ", .{ cast.dst, from });
                    try self.emitValue(writer, cast.value, cast.from);
                    try writer.writeAll(if (cast.from.isPointer()) ", null\n" else ", 0\n");
                    return;
                }
                if (cast.kind == .float_to_bool) {
                    // `une` is unordered-or-not-equal, so a NaN converts to
                    // true, matching the C `(_Bool)` conversion.
                    try writer.print("  %t{d} = fcmp une {s} ", .{ cast.dst, from });
                    try self.emitValue(writer, cast.value, cast.from);
                    try writer.writeAll(", 0.000000e+00\n");
                    return;
                }
                if (cast.kind == .bool_to_float) {
                    // One bit cannot be converted directly: no floating
                    // conversion accepts an `i1`, so the value widens to `i32`
                    // first (exact, since a bool is 0 or 1) and converts
                    // unsigned from there. The intermediate register carries no
                    // type of its own — `i32` is spelled here and in the second
                    // instruction, which is the whole of what it needs.
                    try writer.print("  %w{d} = zext i1 ", .{cast.dst});
                    try self.emitValue(writer, cast.value, cast.from);
                    try writer.print(" to i32\n  %t{d} = uitofp i32 %w{d} to {s}\n", .{ cast.dst, cast.dst, to });
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
            .bit_extract => |extract| {
                // Two shifts in the unit's own width put the field's low bit at
                // bit 0 and its top bit at the unit's top, so the second shift
                // decides the extension: `lshr` for `uN`, `ashr` for `iN`. Doing
                // it in the unit width is what makes a 3-bit field of an 8-bit
                // unit need no mask constant.
                const unit_bits = unitBitWidth(extract.unit);
                // Both shifts are computed from the *field* width, so a field
                // that fills its whole unit gives shift_up = 0 rather than
                // underflowing, and `i128` fields are as valid as `u3` ones.
                const shift_down: u16 = unit_bits - extract.width;
                // The field must lie inside its unit by construction; computing
                // the shift this way makes a violation a visible trap instead of
                // a silent wrap, which is how the 128-bit unit bug was found.
                const shift_up: u16 = std.math.sub(u16, std.math.sub(u16, unit_bits, extract.width) catch unreachable, @intCast(extract.bit_offset)) catch unreachable;
                const shifted = self.module.ephemeral();
                try writer.print("  %t{d} = shl i{d} ", .{ shifted, unit_bits });
                try self.emitValue(writer, extract.value, null);
                try writer.print(", {d}\n", .{shift_up});
                try writer.print("  %t{d} = {s} i{d} %t{d}, {d}\n", .{
                    extract.dst,
                    if (extract.signed) "ashr" else "lshr",
                    unit_bits,
                    shifted,
                    shift_down,
                });
            },
            .bit_insert => |insert| {
                // `(current & ~mask) | ((value << offset) & mask)`: the only way to
                // write one field without disturbing its neighbours in the unit.
                // Spelled as separate instructions because LLVM's textual IR takes
                // one operand pair per instruction.
                const unit_bits = unitBitWidth(insert.unit);
                const mask: u64 = bitMask(insert.width) << @intCast(insert.bit_offset);
                const keep = self.module.ephemeral();
                try writer.print("  %t{d} = and i{d} ", .{ keep, unit_bits });
                try self.emitValue(writer, insert.current, null);
                try writer.print(", {d}\n", .{(~mask) & bitMaskAll(unit_bits)});
                const placed = self.module.ephemeral();
                try writer.print("  %t{d} = shl i{d} ", .{ placed, unit_bits });
                try self.emitValue(writer, insert.value, null);
                try writer.print(", {d}\n", .{insert.bit_offset});
                const masked = self.module.ephemeral();
                try writer.print("  %t{d} = and i{d} %t{d}, {d}\n", .{ masked, unit_bits, placed, mask });
                try writer.print("  %t{d} = or i{d} %t{d}, %t{d}\n", .{ insert.dst, unit_bits, keep, masked });
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
                // A `sret` call returns void: the hidden pointer already names
                // the destination, so the call has no result value. Printing
                // the aggregate type here would declare a second, conflicting
                // result for the same call, which makes the result undefined.
                const call_ret = if (call.sret) "void" else try self.typeString(call.ret);
                // An indirect call has no declaration to take the signature
                // from, so the return and parameter types are spelled out at the
                // call site: `call i32 %v3(i32 21)`. A direct call keeps naming
                // the symbol, which is what lets the module stay declarative.
                if (call.callee) |callee| {
                    try writer.print("call {s} ", .{call_ret});
                    try self.emitValue(writer, callee, null);
                    try writer.writeByte('(');
                } else {
                    try writer.print("call {s} @{s}(", .{ call_ret, call.name });
                }
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
                // Every union member lives in the single emitted member, so the
                // declared index becomes 0 there, and a bitfield shares the unit
                // its run collapsed into. This is the one place that knows the
                // representation, so no producer has to.
                const index: u32 = if (field.struct_ty.is_union)
                    0
                else if (field.struct_ty.placed.len > field.field)
                    field.struct_ty.placed[field.field].emitted_index
                else
                    field.field;
                try writer.print(", i32 0, i32 {d}\n", .{index});
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
                if (isAbiTransport(load.ty)) try writer.print(", align {d}", .{abiTransportAlignment(load.ty)});
                try writer.writeByte('\n');
            },
            .store => |store| {
                try writer.print("  store {s} ", .{try self.typeString(store.ty)});
                try self.emitValue(writer, store.value, store.ty);
                try writer.writeAll(", ptr ");
                try self.emitValue(writer, store.ptr, null);
                if (isAbiTransport(store.ty)) try writer.print(", align {d}", .{abiTransportAlignment(store.ty)});
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
            .va_start => {
                try writer.print("  call void @llvm.va_start(ptr %v{d})\n", .{self.current_va_list});
            },
            .va_arg => |va_arg| {
                try writer.print("  %t{d} = va_arg ptr %v{d}, {s}\n", .{
                    va_arg.dst,
                    self.current_va_list,
                    try self.typeString(va_arg.ty),
                });
            },
            .va_end => {
                try writer.print("  call void @llvm.va_end(ptr %v{d})\n", .{self.current_va_list});
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
    fn emitConstant(self: *Emitter, writer: *std.Io.Writer, constant: ir.Constant, ty: *types.Type) ConstantError!void {
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
                // Keyed by the *emitted* member, because that is the LLVM type:
                // a bitfield's value goes into its run's unit (shifted and
                // masked) and a padding member is zeros. Indexing `fields` by
                // declaration would emit the wrong number of initializers the
                // moment a run collapsed two fields into one unit.
                const info = ty.struct_type;
                try writer.writeAll("{ ");
                for (info.emitted, 0..) |member, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.emitType(writer, member);
                    try writer.writeByte(' ');
                    try self.emitEmittedMemberConstant(writer, info, fields, i);
                }
                // The explicit-alignment padding is a real member of the emitted
                // type, so a constant of that type needs an initializer for it too.
                if (info.explicit_align > 0) {
                    const padding = try self.explicitAlignPadding(info);
                    if (padding > 0) {
                        if (info.emitted.len > 0) try writer.writeAll(", ");
                        try writer.print("[{d} x i8] zeroinitializer", .{padding});
                    }
                }
                try writer.writeAll(" }");
            },
        }
    }

    /// The initializer for one *emitted* member of an aggregate. Ordinarily this
    /// is the declared field's own constant; for a bitfield run it is the unit
    /// with every field of that run shifted and masked into place.
    fn emitEmittedMemberConstant(
        self: *Emitter,
        writer: *std.Io.Writer,
        info: *types.StructInfo,
        fields: []ir.Constant,
        emitted_index: usize,
    ) ConstantError!void {
        var unit: u64 = 0;
        var any_bitfield = false;
        for (info.fields, 0..) |field, i| {
            if (i >= info.placed.len) break;
            const placed = info.placed[i];
            if (placed.emitted_index != emitted_index) continue;
            if (!sema_mod.isBitfield(field.ty)) {
                // The member is this very field: emit it directly.
                try self.emitConstant(writer, fields[i], field.ty);
                return;
            }
            any_bitfield = true;
            const value: u64 = switch (fields[i]) {
                .scalar => |v| switch (v) {
                    .int => |bits| @bitCast(@as(i64, @truncate(bits))),
                    else => 0,
                },
                else => 0,
            };
            const width: u6 = @intCast(field.ty.int.bits);
            const mask: u64 = if (width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << width) - 1;
            unit |= (value & mask) << @intCast(placed.bit_offset);
        }
        if (any_bitfield) {
            try writer.print("{d}", .{unit});
            return;
        }
        // A padding member, or a member with no initializer of its own.
        try writer.writeAll("zeroinitializer");
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
                    // An unsigned 128-bit value can exceed `i128`'s maximum, so
                    // render its stored bit pattern in the unsigned domain.
                    if (ty.* == .int and !ty.int.signed and ty.int.bits == 128) {
                        try writer.print("{d}", .{@as(u128, @bitCast(number))});
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
            .func => |name| try writer.print("@{s}", .{name}),
        }
    }

    fn emitType(self: *Emitter, writer: *std.Io.Writer, ty: *types.Type) !void {
        try writer.writeAll(try self.typeString(ty));
    }

    /// Emits a union as a struct with one member placed so that the struct's
    /// measured size and alignment are the union's. Choosing the member with the
    /// greatest alignment (ties broken by size) needs no padding array: that
    /// member alone already gives the union's size and alignment, because both
    /// are maxima over the same members.
    fn emitUnionType(self: *Emitter, writer: *std.Io.Writer, info: *types.StructInfo) !void {
        var chosen: ?*types.Type = null;
        var chosen_align: usize = 0;
        var chosen_size: usize = 0;
        for (info.fields) |field| {
            const size = sizeInBytes(field.ty) orelse 0;
            const align_ = llvmAlignmentOfType(field.ty);
            const better = align_ > chosen_align or (align_ == chosen_align and size > chosen_size);
            if (chosen == null or better) {
                chosen = field.ty;
                chosen_align = align_;
                chosen_size = size;
            }
        }
        // An explicit alignment applies to a union exactly as it does to a struct:
        // the chosen member already gives the size and alignment of the largest
        // member, and `align(N)` may raise both, so the same trailing padding is
        // needed here or the emitted type would disagree with the layout.
        try writer.print("%struct.{s} = type {{ ", .{structLlvmName(info)});
        if (chosen) |ty| try writer.writeAll(try self.typeString(ty)) else try writer.writeAll("i8");
        if (info.explicit_align > 0) {
            const padding = try self.explicitAlignPadding(info);
            if (padding > 0) try writer.print(", [{d} x i8]", .{padding});
        }
        try writer.writeAll(" }\n");
    }

    /// The LLVM spelling of a register scalar.
    fn abiSlotName(self: *Emitter, slot: types.AbiSlot) ![]const u8 {
        _ = self;
        return switch (slot) {
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .f32 => "float",
            .f64 => "double",
            .f32x2 => "<2 x float>",
            .pointer => "ptr",
        };
    }

    /// True when `ty` is an aggregate transport that is loaded from and
    /// stored into an aggregate slot.
    fn isAbiTransport(ty: *types.Type) bool {
        return switch (ty.*) {
            .abi_vec2_f32, .abi_v2f32_f32, .abi_v2f32_v2f32, .abi_pair_f64, .abi_v2f32_i32, .abi_v2f32_i64, .abi_i64_v2f32, .abi_f64_v2f32, .abi_v2f32_f64, .abi_pair => true,
            else => false,
        };
    }

    /// The alignment of a transport slot. A `<2 x float>` value needs only 4
    /// bytes and may start at offset 0 of a 12-byte aggregate; every other
    /// transport is a pair or a `double`, which is 8-byte aligned.
    fn abiTransportAlignment(ty: *types.Type) u16 {
        return switch (ty.*) {
            .abi_vec2_f32, .abi_v2f32_f32, .abi_v2f32_v2f32 => 4,
            else => 8,
        };
    }

    /// Padding bytes needed after the emitted members for the type's size to be a
    /// multiple of its explicit alignment.
    fn explicitAlignPadding(self: *Emitter, info: *types.StructInfo) !u64 {
        _ = self;
        // The layout `placeFields` computed and stored; not re-derived here.
        if (info.layout.align_ == 0) return 0;
        const layout = info.layout;
        // The bytes the emitted members occupy *as LLVM will lay them out*: a
        // packed struct inserts no inter-member padding, an ordinary one does. A
        // union emits one member -- the largest -- and `placeFields` leaves
        // `emitted` empty for it, so the layout's own pre-rounding size is the
        // figure to compare against.
        var used: u64 = 0;
        if (info.is_union) {
            for (info.fields) |field| {
                const member = sema_mod.aggregateLayoutGuess(field.ty) orelse continue;
                used = @max(used, member.size);
            }
            if (layout.size <= used) return 0;
            return layout.size - used;
        }
        for (info.emitted) |member| {
            const member_layout = sema_mod.aggregateLayoutGuess(member) orelse return 0;
            if (!info.is_packed) used = std.mem.alignForward(u64, used, member_layout.align_);
            used += member_layout.size;
        }
        if (layout.size <= used) return 0;
        return layout.size - used;
    }

    fn unitBitWidth(ty: *types.Type) u16 {
        return switch (ty.*) {
            .int => |info| info.bits,
            else => 8,
        };
    }

    fn bitMask(width: u16) u64 {
        if (width >= 64) return std.math.maxInt(u64);
        return (@as(u64, 1) << @intCast(width)) - 1;
    }

    fn bitMaskAll(unit_bits: u16) u64 {
        if (unit_bits >= 64) return std.math.maxInt(u64);
        return (@as(u64, 1) << @intCast(unit_bits)) - 1;
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
            .abi_v2f32_i32 => "{ <2 x float>, i32 }",
            .abi_v2f32_i64 => "{ <2 x float>, i64 }",
            .abi_i64_v2f32 => "{ i64, <2 x float> }",
            .abi_f64_v2f32 => "{ double, <2 x float> }",
            .abi_v2f32_f64 => "{ <2 x float>, double }",
            .abi_pair => |pair| try std.fmt.allocPrint(self.allocator, "{{ {s}, {s} }}", .{
                try self.abiSlotName(pair.first),
                try self.abiSlotName(pair.second),
            }),
            .pointer => "ptr",
            .array => |array| try std.fmt.allocPrint(self.allocator, "[{d} x {s}]", .{
                array.len,
                try self.typeString(array.elem),
            }),
            .slice => "%kyn.slice",
            .struct_type => |info| try std.fmt.allocPrint(self.allocator, "%struct.{s}", .{structLlvmName(info)}),
            .enum_type => |info| try self.typeString(info.backing),
            .fn_type, .fn_ptr => "ptr",
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
    try testing.expect(std.mem.indexOf(u8, ll, "call i32 @take_small(i32 ") != null);
}

test "lowering emits a direct call by name and an indirect call through the value" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `direct` must stay a call by symbol: routing it through the address would
    // still work but would lose the declaration and defeat the linker's ability
    // to resolve it. `via_value` must be indirect, and through a checked
    // pointer, because calling a null callback is a fault not a silent `undef`.
    const text =
        \\fn direct(v: i32) i32 { return v + 1; }
        \\fn main() i32 {
        \\    let via_value: fn(i32) i32 = direct;
        \\    return direct(1) + via_value(2);
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

    try testing.expect(std.mem.indexOf(u8, ll, "call i32 @__kyn_f_m0_direct(i32 1)") != null);
    // An indirect call spells out its signature: there is no declaration to
    // read it from.
    try testing.expect(std.mem.indexOf(u8, ll, "call i32 %t") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "icmp eq ptr %t") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "@llvm.trap()") != null);
    // No redundant pointer-to-pointer cast is emitted for the callee.
    try testing.expect(std.mem.indexOf(u8, ll, "bitcast ptr %t") == null);
}

test "lowering declares a variadic extern and passes promoted arguments" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `flag` is a `bool` (one byte) and `ratio` an `f32`; both must reach the
    // call as `i32` and `double`. A `bool` that stayed `i1` would leave the
    // register half-defined, and an `f32` that stayed `float` would be read by
    // `%f` as a double, so the emitted argument types are the contract.
    const text =
        \\extern fn printf(format: *const u8, ...) i32;
        \\fn main() i32 {
        \\    let flag: bool = true;
        \\    let ratio: f32 = 1.5;
        \\    return printf("%d %f", flag, ratio);
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

    // Without the trailing marker LLVM rejects a call that carries more
    // arguments than the declaration lists.
    try testing.expect(std.mem.indexOf(u8, ll, "declare i32 @printf(ptr %arg100000, ...)") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "call i32 @printf(ptr ") != null);
    try testing.expect(std.mem.indexOf(u8, ll, ", i32 ") != null);
    try testing.expect(std.mem.indexOf(u8, ll, ", double ") != null);
    // No half-width or half-filled argument survives to the call site.
    try testing.expect(std.mem.indexOf(u8, ll, "call i32 @printf(ptr %t0, i1 ") == null);
    try testing.expect(std.mem.indexOf(u8, ll, ", float ") == null);
}

test "bitfields collapse into one storage unit and read/write through masks" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        \\struct Wire { kind: u3, tag: u5 }
        \\struct Three { a: u3, b: u5, c: u12 }
        \\fn main() i32 {
        \\    var w: Wire = Wire { kind: 5, tag: 21 };
        \\    w.tag = 3;
        \\    return (w.kind as i32) + (w.tag as i32);
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

    // 3 + 5 bits fit one 8-bit unit, so the two declarations are one member.
    // Emitting `{ i3, i5 }` would give each field its own byte.
    try testing.expect(std.mem.indexOf(u8, ll, "%struct.__kyn_s_m0_Wire = type { i8 }") != null);
    // The second field is at bit 3, so its mask is 0b00000111 shifted by 3.
    try testing.expect(std.mem.indexOf(u8, ll, "and i8 %t") != null);
    try testing.expect(std.mem.indexOf(u8, ll, ", 248") != null);
    // A read shifts the field down and narrows; a write merges with `or`.
    try testing.expect(std.mem.indexOf(u8, ll, "lshr i8") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "or i8") != null);
    // A bitfield has no storage of its own, so no store or load may name its
    // width. The value still passes through `i3` in casts, which is the field's
    // own type and is what makes `w.kind + 1` mean what it says.
    try testing.expect(std.mem.indexOf(u8, ll, "store i3") == null);
    try testing.expect(std.mem.indexOf(u8, ll, "load i3") == null);
    try testing.expect(std.mem.indexOf(u8, ll, "store i8") != null);
}

test "a union is emitted as one member and a packed struct as <{ }>" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        \\union U { c: u8, i: i32 }
        \\packed struct P { c: u8, i: i32 }
        \\fn main() i32 {
        \\    var u: U = U { i: 7 };
        \\    var p: P = P { c: 1, i: 2 };
        \\    u.c = 3;
        \\    return (u.i + p.i) as i32;
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

    // The union is not an LLVM type: it is emitted as a struct holding its most
    // aligned member, which already has the union's size and alignment.
    try testing.expect(std.mem.indexOf(u8, ll, "%struct.__kyn_s_m0_U = type { i32 }") != null);
    // `packed` must reach the definition, or LLVM re-inserts the padding.
    try testing.expect(std.mem.indexOf(u8, ll, "%struct.__kyn_s_m0_P = type <{ i8, i32 }>") != null);
    // Every union member is at index 0 of the emitted single member, so a field
    // access through either name uses the same index and never goes out of range.
    try testing.expect(std.mem.indexOf(u8, ll, "getelementptr inbounds %struct.__kyn_s_m0_U, ptr %v4, i32 0, i32 0") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "%struct.__kyn_s_m0_U, ptr %v4, i32 0, i32 1") == null);
    try testing.expect(std.mem.indexOf(u8, ll, "%struct.__kyn_s_m0_P, ptr %v5, i32 0, i32 1") != null);
}

test "lowering an exported variadic function emits va_start, va_arg and va_end" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        \\export fn sum(count: i32, ...) i32 {
        \\    var total: i32 = 0;
        \\    var i: i32 = 0;
        \\    while (i < count) {
        \\        let value: i32 = va_arg();
        \\        total += value;
        \\        i += 1;
        \\    }
        \\    return total;
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

    // The definition must carry `...`: without it the module is not a varargs
    // function and the verifier rejects `llvm.va_start`.
    try testing.expect(std.mem.indexOf(u8, ll, "define dso_local i32 @sum(i32 %arg100000, ...)") != null);
    // `va_list` is the one-element array, and the intrinsics take a pointer to
    // it rather than to the tag inside.
    try testing.expect(std.mem.indexOf(u8, ll, "%struct.__va_list_tag = type { i32, i32, ptr, ptr }") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "%kyn.va_list = type [1 x %struct.__va_list_tag]") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "alloca %kyn.va_list, align 16") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "call void @llvm.va_start(ptr ") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "= va_arg ptr ") != null);
    // The old spelling was removed from LLVM; emitting it would not assemble.
    try testing.expect(std.mem.indexOf(u8, ll, "llvm.va_arg") == null);
    // `va_end` runs before the returning instruction, not after it.
    const end_at = std.mem.indexOf(u8, ll, "call void @llvm.va_end(ptr ") orelse return error.MissingVaEnd;
    const ret_at = std.mem.lastIndexOf(u8, ll, "ret i32 ") orelse return error.MissingReturn;
    try testing.expect(end_at < ret_at);
}

test "a module without a variadic body keeps its IR unchanged" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A variadic *declaration* alone must not pull the `va_list` type into the
    // module: existing programs have to keep emitting the same bytes.
    const text =
        \\extern fn printf(format: *const u8, ...) i32;
        \\fn main() i32 { return printf("hi"); }
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

    try testing.expect(std.mem.indexOf(u8, ll, "declare i32 @printf(ptr %arg100000, ...)") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "__va_list_tag") == null);
    try testing.expect(std.mem.indexOf(u8, ll, "va_start") == null);
    try testing.expect(std.mem.indexOf(u8, ll, "va_end") == null);
}

test "bool and float casts lower through a valid intermediate type" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Neither direction is one LLVM instruction: `zext i1 ... to double` and
    // `double ... to i1` are both invalid, which is what the emitter produced
    // before. A `bool` widens to `i32` and converts unsigned; a float compares
    // unordered-or-not-equal against zero so that a NaN is true, as in C.
    const text =
        \\fn main() i32 {
        \\    let flag: bool = true;
        \\    let up: f64 = flag as f64;
        \\    let down: bool = up as bool;
        \\    let narrow: f32 = flag as f32;
        \\    let back: bool = narrow as bool;
        \\    if (down && back) { return 42; }
        \\    return 1;
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

    // The widening is `zext i1 ... to i32` followed by `uitofp i32 ...`.
    try testing.expect(std.mem.indexOf(u8, ll, "zext i1 ") != null);
    try testing.expect(std.mem.indexOf(u8, ll, " to i32\n") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "uitofp i32 ") != null);
    try testing.expect(std.mem.indexOf(u8, ll, " to double\n") != null);
    try testing.expect(std.mem.indexOf(u8, ll, " to float\n") != null);
    // And the narrowing is an ordered-except-unordered compare, which is what
    // makes a NaN convert to true.
    try testing.expect(std.mem.indexOf(u8, ll, "fcmp une double ") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "fcmp une float ") != null);
    // No single instruction jumps from one bit to a float: every `zext i1`
    // that feeds a floating conversion names `i32` as its destination. The
    // `%w` registers are the ones this cast emits, so the check looks at those
    // and not at the unrelated `zext i1 ... to i8` a bool store produces.
    var widening: usize = 0;
    var lines = std.mem.splitScalar(u8, ll, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "%w") != null and std.mem.indexOf(u8, line, "= zext i1 ") != null) {
            try testing.expect(std.mem.endsWith(u8, line, " to i32"));
            widening += 1;
        }
    }
    // Two widenings: one for `f64`, one for `f32`.
    try testing.expectEqual(@as(usize, 2), widening);
}

test "a constant cast folds into the destination category" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A global initializer is folded, not lowered: returning the source value
    // emitted `constant i32 3` where a `double` was declared, and the module
    // then failed to assemble. Each constant has to arrive in the destination
    // category, and a cast chain truncates at each step.
    const text =
        \\const WIDE: f64 = 3 as f64;
        \\const FLAG: bool = 1.5 as bool;
        \\const ZERO: bool = 0.0 as bool;
        \\const BACK: f64 = true as f64;
        \\const TRUNCATED: i32 = 3.9 as i32;
        \\const CHAINED: f64 = 3.9 as i32 as f64;
        \\fn main() i32 { return 42; }
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

    // Each constant carries the value in its own category. Floats are printed
    // in hexadecimal, which is the bit pattern: 3.0 is 0x4008..., 1.0 is
    // 0x3FF0... and 3.9 is 0x400F333333333333.
    try testing.expect(std.mem.indexOf(u8, ll, "constant double 0x4008000000000000") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "constant i1 true") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "constant i1 false") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "constant double 0x3FF0000000000000") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "constant i32 3") != null);
    // The chain truncates at `as i32` before widening back to `double`, so the
    // fractional part is gone rather than surviving to the outer cast: the
    // chained constant holds 3.0, never 3.9's bit pattern.
    try testing.expect(std.mem.indexOf(u8, ll, "constant double 0x400F333333333333") == null);
}

test "a folded constant uses the signedness it is lowered with" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `comptime_int` has no width or sign in the type system, but at lowering
    // time it is a signed 64-bit value. Reading `intInfo()` directly yields
    // `bits = 0, signed = false`, which made every folded `-` emit an unsigned
    // `usub` — trapping on any negative intermediate — and made a shift by a
    // constant compare its amount against `0`, so it always trapped.
    const text =
        \\fn main() i32 {
        \\    let a: i32 = 1 - 2 + 3;
        \\    let b: i32 = 3 | 1 << 2;
        \\    return a + b;
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

    // The constant arithmetic is signed, so a negative intermediate is a
    // defined result rather than an unsigned overflow.
    try testing.expect(std.mem.indexOf(u8, ll, "ssub.with.overflow.i64(i64 1, i64 2)") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "usub.with.overflow.i64(i64 1, i64 2)") == null);
    // And the shift amount is checked against the operand width, not against
    // zero: a bound of `2` for a 64-bit value is legal.
    try testing.expect(std.mem.indexOf(u8, ll, "icmp sge i128 ") != null);
    try testing.expect(std.mem.indexOf(u8, ll, ", 64\n") != null);
}

test "the division trap is lowered for i128 without overflowing the compiler" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The `INT_MIN / -1` check needs the type's minimum. Computing it as
    // `-(1 << 127)` overflows while lowering an `i128` division, so the value
    // has to come from the type — this test fails with a panic, not an
    // assertion, if that regresses.
    const text =
        \\fn main() i32 {
        \\    var a: i128 = 1000;
        \\    var b: i128 = 7;
        \\    const q: i128 = a / b;
        \\    return (q % 10) as i32;
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

    // The guard compares against the minimum in the type's own width, and it is
    // `i128`'s minimum rather than a truncated value.
    try testing.expect(std.mem.indexOf(u8, ll, "icmp eq i128 %t") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "i128 %t1, -170141183460469231731687303715884105728") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "sdiv i128") != null);
}

test "the most negative literal of a signed type folds to that type's minimum" {
    const lexer = @import("../lexer.zig");
    const parser = @import("../parser.zig");
    const source = @import("../source.zig");
    const analyzer_mod = @import("../analyzer.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `-128` for an `i8` and `-2^127` for an `i128` are both written as a unary
    // minus in front of the magnitude. Lowering them as `0 - magnitude` would
    // overflow in a checked build, so each must reach the IR as the value it
    // denotes — and at its own width, not as a truncated `i128`.
    const text =
        \\fn main() i32 {
        \\    var byte_min: i8 = -128;
        \\    var int_min: i32 = -2147483648;
        \\    var huge_min: i128 = -170141183460469231731687303715884105728;
        \\    if (byte_min == -128) { return 1; }
        \\    if (int_min == -2147483648) { return 2; }
        \\    return 3;
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

    try testing.expect(std.mem.indexOf(u8, ll, "store i8 -128, ptr") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "store i32 -2147483648, ptr") != null);
    try testing.expect(std.mem.indexOf(u8, ll, "i128 -170141183460469231731687303715884105728") != null);
}

test "the lowered integer info names the width a constant is emitted with" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prims = try types.Primitives.init(a);

    // The helper is the single place that answers "how wide and how signed is
    // this at lowering time", so the answer for a folded constant is pinned.
    const folded = loweredIntInfo(prims.comptime_int).?;
    try testing.expectEqual(@as(u16, 64), folded.bits);
    try testing.expect(folded.signed);
    // A named type reports its own answer, and `char` stays unsigned.
    const i8_info = loweredIntInfo(prims.i8).?;
    try testing.expectEqual(@as(u16, 8), i8_info.bits);
    try testing.expect(i8_info.signed);
    const u64_info = loweredIntInfo(prims.u64).?;
    try testing.expectEqual(@as(u16, 64), u64_info.bits);
    try testing.expect(!u64_info.signed);
    const char_info = loweredIntInfo(prims.char).?;
    try testing.expectEqual(@as(u16, 32), char_info.bits);
    try testing.expect(!char_info.signed);
    // A non-integer has no such answer.
    try testing.expect(loweredIntInfo(prims.f64) == null);
}
