//! Name resolution, type checking and semantic validation.
//!
//! The semantic pass runs in phases:
//!   1. declare every top-level name;
//!   2. resolve signatures, struct layouts and enum values;
//!   3. check function bodies and global initializers.
//!
//! The pass annotates AST expressions with resolved types and AST identifiers
//! with resolved symbols. Those annotations are the contract consumed by the
//! static analyzer and the code generator.

const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");
const symbol = @import("symbol.zig");
const diagnostics = @import("diagnostics.zig");
const source = @import("source.zig");
const analyzer_mod = @import("analyzer.zig");

pub const Span = source.Span;
pub const Type = types.Type;
pub const Symbol = symbol.Symbol;

pub const Error = error{OutOfMemory};

const Scope = struct {
    parent: ?*Scope,
    symbols: std.StringHashMap(*Symbol),
};

pub const Sema = struct {
    allocator: std.mem.Allocator,
    reporter: *diagnostics.Reporter,
    prims: *types.Primitives,
    globals: std.StringHashMap(*Symbol),
    scope: ?*Scope = null,
    next_symbol_id: u32 = 1,
    loop_depth: u32 = 0,
    current_fn: ?*ast.FnDecl = null,

    pub fn init(
        allocator: std.mem.Allocator,
        reporter: *diagnostics.Reporter,
        prims: *types.Primitives,
    ) Sema {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .prims = prims,
            .globals = std.StringHashMap(*Symbol).init(allocator),
        };
    }

    pub fn analyze(self: *Sema, program: *ast.Program) Error!void {
        try self.declareTopLevel(program);
        try self.resolveTopLevel(program);
        try self.checkBodies(program);
    }

    // ------------------------------------------------------------------
    // Phase 1: top-level names
    // ------------------------------------------------------------------

    fn declareTopLevel(self: *Sema, program: *ast.Program) Error!void {
        for (program.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |sd| {
                    const info = try self.allocator.create(types.StructInfo);
                    info.* = .{ .name = sd.name };
                    const ty = try self.allocator.create(Type);
                    ty.* = .{ .struct_type = info };
                    sd.ty = ty;
                    sd.sym = try self.declareGlobal(sd.name, .struct_type, ty, decl.span);
                },
                .enum_decl => |ed| {
                    const info = try self.allocator.create(types.EnumInfo);
                    info.* = .{ .name = ed.name, .backing = self.prims.u32 };
                    const ty = try self.allocator.create(Type);
                    ty.* = .{ .enum_type = info };
                    ed.ty = ty;
                    ed.sym = try self.declareGlobal(ed.name, .enum_type, ty, decl.span);
                },
                .fn_decl => |fd| {
                    if (fd.body == null and !fd.is_extern) {
                        try self.reporter.err("E0402", decl.span, "function '{s}' has no body; mark it 'extern'", .{fd.name});
                    }
                    const placeholder = try self.allocator.create(Type);
                    placeholder.* = .invalid;
                    fd.sym = try self.declareGlobal(fd.name, .function, placeholder, decl.span);
                    if (fd.sym) |sym| {
                        sym.is_extern = fd.is_extern;
                        sym.is_export = fd.is_export;
                    }
                },
                .var_decl => |vd| {
                    const placeholder = try self.allocator.create(Type);
                    placeholder.* = .invalid;
                    vd.sym = try self.declareGlobal(vd.name, .global, placeholder, decl.span);
                },
            }
        }
    }

    fn declareGlobal(
        self: *Sema,
        name: []const u8,
        kind: symbol.Kind,
        ty: *Type,
        span: Span,
    ) Error!*Symbol {
        if (self.globals.get(name)) |existing| {
            try self.reporter.err("E0401", span, "duplicate top-level declaration '{s}' (previous kind: {s})", .{
                name,
                @tagName(existing.kind),
            });
            return existing;
        }
        const sym = try self.allocator.create(Symbol);
        sym.* = .{
            .id = self.nextId(),
            .name = name,
            .kind = kind,
            .ty = ty,
        };
        try self.globals.put(name, sym);
        return sym;
    }

    fn nextId(self: *Sema) u32 {
        const id = self.next_symbol_id;
        self.next_symbol_id += 1;
        return id;
    }

    // ------------------------------------------------------------------
    // Phase 2: signatures and layouts
    // ------------------------------------------------------------------

    fn resolveTopLevel(self: *Sema, program: *ast.Program) Error!void {
        // Structs and enums first: function signatures and globals may use them.
        for (program.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |sd| try self.resolveStruct(sd),
                .enum_decl => |ed| try self.resolveEnum(ed),
                else => {},
            }
        }
        for (program.decls) |decl| {
            switch (decl.kind) {
                .fn_decl => |fd| try self.resolveSignature(fd),
                .var_decl => |vd| try self.resolveGlobal(vd),
                else => {},
            }
        }
    }

    fn resolveStruct(self: *Sema, sd: *ast.StructDecl) Error!void {
        const info = sd.ty.?.struct_type;
        if (info.complete) return;
        if (info.resolving) {
            try self.reporter.err("E0403", sd.span, "struct '{s}' contains itself by value", .{sd.name});
            return;
        }
        info.resolving = true;

        var fields = try self.allocator.alloc(types.Field, sd.fields.len);
        var seen = std.StringHashMap(void).init(self.allocator);
        for (sd.fields, 0..) |*field, i| {
            if (seen.contains(field.name)) {
                try self.reporter.err("E0404", field.span, "duplicate field '{s}' in struct '{s}'", .{ field.name, sd.name });
            } else {
                try seen.put(field.name, {});
            }
            const ty = try self.resolveType(field.ty_expr);
            if (containsIncompleteByValue(ty)) {
                try self.reporter.err("E0403", field.span, "struct '{s}' contains itself by value", .{sd.name});
            }
            field.ty = ty;
            fields[i] = .{ .name = field.name, .ty = ty, .index = @intCast(i) };
        }
        info.fields = fields;
        info.resolving = false;
        info.complete = true;
    }

    fn resolveEnum(self: *Sema, ed: *ast.EnumDecl) Error!void {
        const info = ed.ty.?.enum_type;
        if (info.complete) return;

        if (ed.backing_expr) |backing_expr| {
            const backing = try self.resolveType(backing_expr);
            if (!backing.isInteger()) {
                try self.reporter.err("E0405", backing_expr.span, "enum backing type must be an integer type", .{});
            } else {
                info.backing = backing;
            }
        }

        var variants = try self.allocator.alloc(types.Variant, ed.variants.len);
        var seen = std.StringHashMap(void).init(self.allocator);
        var next_value: i128 = 0;
        for (ed.variants, 0..) |*variant, i| {
            if (seen.contains(variant.name)) {
                try self.reporter.err("E0406", variant.span, "duplicate variant '{s}' in enum '{s}'", .{ variant.name, ed.name });
            } else {
                try seen.put(variant.name, {});
            }
            if (variant.value_expr) |value_expr| {
                if (try self.evalConstInt(value_expr)) |value| {
                    next_value = value;
                } else {
                    try self.reporter.err("E0407", value_expr.span, "enum variant value must be a constant integer", .{});
                }
            }
            if (!fitsInt(info.backing.intInfo(), next_value)) {
                try self.reporter.err("E0408", variant.span, "value {d} does not fit enum backing type '{s}'", .{
                    next_value,
                    self.typeName(info.backing),
                });
            }
            variant.value = next_value;
            variants[i] = .{ .name = variant.name, .value = next_value };
            next_value += 1;
        }
        info.variants = variants;
        info.complete = true;
    }

    fn resolveSignature(self: *Sema, fd: *ast.FnDecl) Error!void {
        var params = try self.allocator.alloc(*Type, fd.params.len);
        var seen = std.StringHashMap(void).init(self.allocator);
        const is_c_boundary = fd.is_extern or fd.is_export;
        for (fd.params, 0..) |*param, i| {
            if (seen.contains(param.name)) {
                try self.reporter.err("E0409", param.span, "duplicate parameter '{s}'", .{param.name});
            } else {
                try seen.put(param.name, {});
            }
            const ty = if (param.ty_expr.resolved) |ty| ty else try self.resolveType(param.ty_expr);
            param.ty = ty;
            const param_sym = try self.allocator.create(Symbol);
            param_sym.* = .{
                .id = self.nextId(),
                .name = param.name,
                .kind = .local,
                .ty = ty,
                .mutable = true,
            };
            param.sym = param_sym;
            if (ty.* == .void) {
                try self.reporter.err("E0410", param.span, "parameter '{s}' cannot have type 'void'", .{param.name});
            } else if (is_c_boundary and ty.isAggregate()) {
                try self.reporter.err("E0410", param.span, "aggregate parameter '{s}' is not supported across the C ABI yet; pass a pointer", .{param.name});
            }
            params[i] = ty;
        }

        const ret = if (fd.ret_expr) |ret_expr| blk: {
            const ty = try self.resolveType(ret_expr);
            break :blk ty;
        } else self.prims.void;

        if (is_c_boundary and ret.isAggregate()) {
            try self.reporter.err("E0410", fd.span, "aggregate return type is not supported across the C ABI yet; return a pointer", .{});
        }
        const fn_ty = try types.makeFn(self.allocator, params, ret);
        fd.ty = fn_ty;
        if (fd.sym) |sym| {
            sym.ty = fn_ty;
            sym.is_extern = fd.is_extern;
            sym.is_export = fd.is_export;
        }
    }

    fn resolveGlobal(self: *Sema, vd: *ast.VarDecl) Error!void {
        const explicit_ty: ?*Type = if (vd.ty_expr) |te| try self.resolveType(te) else null;
        if (explicit_ty) |ty| {
            if (ty.* == .void) {
                try self.reporter.err("E0411", vd.ty_expr.?.span, "variable '{s}' cannot have type 'void'", .{vd.name});
            }
            vd.ty = ty;
            if (vd.sym) |sym| sym.ty = ty;
        }

        if (vd.init) |init_expr| {
            if (explicit_ty) |ty| {
                const init_ty = try self.checkExpr(init_expr, ty);
                try self.requireAssignable(ty, init_expr, init_ty, true);
            } else {
                const init_ty = try self.checkExpr(init_expr, null);
                const concrete = self.materialize(init_ty, init_expr.span);
                vd.ty = concrete;
                if (vd.sym) |sym| sym.ty = concrete;
            }
            if (!isConstInitializer(init_expr)) {
                try self.reporter.err("E0412", init_expr.span, "global initializer for '{s}' must be a constant expression", .{vd.name});
            }
        } else {
            try self.reporter.err("E0413", vd.span, "global '{s}' must have an initializer", .{vd.name});
            if (explicit_ty == null) {
                vd.ty = self.prims.invalid;
                if (vd.sym) |sym| sym.ty = self.prims.invalid;
            }
        }
    }

    // ------------------------------------------------------------------
    // Phase 3: bodies
    // ------------------------------------------------------------------

    fn checkBodies(self: *Sema, program: *ast.Program) Error!void {
        for (program.decls) |decl| {
            switch (decl.kind) {
                .fn_decl => |fd| {
                    if (fd.body) |body| try self.checkFunction(fd, body);
                },
                else => {},
            }
        }
    }

    fn checkFunction(self: *Sema, fd: *ast.FnDecl, body: *ast.Block) Error!void {
        self.scope = null;
        const previous_fn = self.current_fn;
        self.current_fn = fd;
        defer self.current_fn = previous_fn;
        try self.pushScope();
        defer self.popScope();

        for (fd.params) |*param| {
            if (param.sym) |sym| try self.declareLocal(sym, param.span);
        }
        try self.checkBlock(body);

        const ret = fd.ty.?.fn_type.ret;
        if (ret.* != .void and !blockAlwaysReturns(body) and !self.reporter.hasErrors()) {
            try self.reporter.err("E0414", fd.span, "function '{s}' may reach the end without returning a value", .{fd.name});
        }
    }

    fn checkBlock(self: *Sema, block: *ast.Block) Error!void {
        try self.pushScope();
        defer self.popScope();
        for (block.stmts) |stmt| try self.checkStmt(stmt);
    }

    fn checkStmt(self: *Sema, stmt: *ast.Stmt) Error!void {
        switch (stmt.kind) {
            .expr => |expr| _ = try self.checkExpr(expr, null),
            .var_decl => |vd| try self.checkLocal(vd),
            .block => |block| try self.checkBlock(block),
            .if_stmt => |if_stmt| {
                const cond_ty = try self.checkExpr(if_stmt.cond, self.prims.bool);
                try self.requireBool(if_stmt.cond, cond_ty);
                try self.checkBlock(if_stmt.then_branch);
                if (if_stmt.else_branch) |else_stmt| try self.checkStmt(else_stmt);
            },
            .while_stmt => |while_stmt| {
                const cond_ty = try self.checkExpr(while_stmt.cond, self.prims.bool);
                try self.requireBool(while_stmt.cond, cond_ty);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(while_stmt.body);
            },
            .return_stmt => |ret_stmt| try self.checkReturn(stmt.span, ret_stmt.value),
            .break_stmt, .continue_stmt => {
                if (self.loop_depth == 0) {
                    try self.reporter.err("E0415", stmt.span, "'{s}' is only valid inside a loop", .{
                        if (stmt.kind == .break_stmt) "break" else "continue",
                    });
                }
            },
            .empty => {},
        }
    }

    fn checkReturn(self: *Sema, span: Span, value: ?*ast.Expr) Error!void {
        const fn_decl = self.currentFunction() orelse {
            try self.reporter.err("E0416", span, "return outside a function", .{});
            return;
        };
        const ret = fn_decl.ty.?.fn_type.ret;
        if (value) |expr| {
            if (ret.* == .void) {
                try self.reporter.err("E0417", expr.span, "void function cannot return a value", .{});
                _ = try self.checkExpr(expr, null);
                return;
            }
            const value_ty = try self.checkExpr(expr, ret);
            try self.requireAssignable(ret, expr, value_ty, true);
        } else {
            if (ret.* != .void) {
                try self.reporter.err("E0418", span, "function must return a value of type '{s}'", .{
                    self.typeName(ret),
                });
            }
        }
    }

    fn currentFunction(self: *Sema) ?*ast.FnDecl {
        return self.current_fn;
    }

    fn checkLocal(self: *Sema, vd: *ast.VarDecl) Error!void {
        var explicit_ty: ?*Type = null;
        if (vd.ty_expr) |te| {
            explicit_ty = try self.resolveType(te);
            if (explicit_ty.?.* == .void) {
                try self.reporter.err("E0419", te.span, "variable '{s}' cannot have type 'void'", .{vd.name});
            }
            vd.ty = explicit_ty;
        }

        if (vd.init) |init_expr| {
            if (explicit_ty) |ty| {
                const init_ty = try self.checkExpr(init_expr, ty);
                try self.requireAssignable(ty, init_expr, init_ty, true);
            } else {
                const init_ty = try self.checkExpr(init_expr, null);
                const concrete = self.materialize(init_ty, init_expr.span);
                vd.ty = concrete;
            }
        } else if (explicit_ty == null) {
            try self.reporter.err("E0420", vd.span, "variable '{s}' needs a type or an initializer", .{vd.name});
            vd.ty = self.prims.invalid;
        }

        const ty = vd.ty orelse self.prims.invalid;
        vd.ty = ty;
        const sym = try self.allocator.create(Symbol);
        sym.* = .{
            .id = self.nextId(),
            .name = vd.name,
            .kind = .local,
            .ty = ty,
            .mutable = vd.mutable,
        };
        vd.sym = sym;
        try self.declareLocal(sym, vd.span);
    }

    // ------------------------------------------------------------------
    // Scopes
    // ------------------------------------------------------------------

    fn pushScope(self: *Sema) Error!void {
        const scope = try self.allocator.create(Scope);
        scope.* = .{ .parent = self.scope, .symbols = std.StringHashMap(*Symbol).init(self.allocator) };
        self.scope = scope;
    }

    fn popScope(self: *Sema) void {
        if (self.scope) |scope| self.scope = scope.parent;
    }

    fn declareLocal(self: *Sema, sym: *Symbol, span: Span) Error!void {
        const scope = self.scope orelse return;
        if (scope.symbols.get(sym.name) != null) {
            try self.reporter.err("E0421", span, "duplicate local variable '{s}' in this scope", .{sym.name});
            return;
        }
        try scope.symbols.put(sym.name, sym);
    }

    fn lookup(self: *Sema, name: []const u8) ?*Symbol {
        var scope = self.scope;
        while (scope) |s| {
            if (s.symbols.get(name)) |sym| return sym;
            scope = s.parent;
        }
        return self.globals.get(name);
    }

    // ------------------------------------------------------------------
    // Type resolution
    // ------------------------------------------------------------------

    pub fn resolveType(self: *Sema, te: *ast.TypeExpr) Error!*Type {
        if (te.resolved) |ty| return ty;
        const ty: *Type = switch (te.kind) {
            .name => |name| blk: {
                if (self.primitiveByName(name)) |prim| break :blk prim;
                if (self.globals.get(name)) |sym| {
                    if (sym.kind == .struct_type or sym.kind == .enum_type) break :blk sym.ty;
                }
                try self.reporter.err("E0422", te.span, "unknown type '{s}'", .{name});
                break :blk self.prims.invalid;
            },
            .pointer => |p| blk: {
                const elem = try self.resolveType(p.elem);
                break :blk try types.makePointer(self.allocator, elem, p.is_const);
            },
            .slice => |s| blk: {
                const elem = try self.resolveType(s.elem);
                break :blk try types.makeSlice(self.allocator, elem, s.is_const);
            },
            .array => |a| blk: {
                const elem = try self.resolveType(a.elem);
                if (a.len) |len_expr| {
                    const value = (try self.evalConstInt(len_expr)) orelse {
                        try self.reporter.err("E0423", len_expr.span, "array length must be a constant integer", .{});
                        break :blk self.prims.invalid;
                    };
                    if (value <= 0) {
                        try self.reporter.err("E0424", len_expr.span, "array length must be greater than zero", .{});
                        break :blk self.prims.invalid;
                    }
                    break :blk try types.makeArray(self.allocator, elem, @intCast(value));
                }
                try self.reporter.err("E0425", te.span, "array type requires an explicit length", .{});
                break :blk self.prims.invalid;
            },
        };
        te.resolved = ty;
        return ty;
    }

    fn primitiveByName(self: *Sema, name: []const u8) ?*Type {
        const p = self.prims;
        const map = .{
            .{ "void", p.void },
            .{ "bool", p.bool },
            .{ "char", p.char },
            .{ "i8", p.i8 },
            .{ "i16", p.i16 },
            .{ "i32", p.i32 },
            .{ "i64", p.i64 },
            .{ "i128", p.i128 },
            .{ "u8", p.u8 },
            .{ "u16", p.u16 },
            .{ "u32", p.u32 },
            .{ "u64", p.u64 },
            .{ "u128", p.u128 },
            .{ "f32", p.f32 },
            .{ "f64", p.f64 },
            .{ "usize", p.usize },
            .{ "isize", p.isize },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    fn checkExpr(self: *Sema, expr: *ast.Expr, expected: ?*Type) Error!*Type {
        const ty: *Type = switch (expr.kind) {
            .int_lit => |lit| try self.checkIntLiteral(expr, lit.value, expected),
            .float_lit => |lit| blk: {
                _ = lit;
                if (expected) |e| {
                    if (e.* == .float) {
                        expr.ty = e;
                        break :blk e;
                    }
                }
                expr.ty = self.prims.comptime_float;
                break :blk self.prims.comptime_float;
            },
            .bool_lit => blk: {
                expr.ty = self.prims.bool;
                break :blk self.prims.bool;
            },
            .char_lit => blk: {
                expr.ty = self.prims.char;
                break :blk self.prims.char;
            },
            .string_lit => blk: {
                const ty = try types.makePointer(self.allocator, self.prims.u8, true);
                expr.ty = ty;
                break :blk ty;
            },
            .null_lit => blk: {
                expr.ty = self.prims.null_type;
                break :blk self.prims.null_type;
            },
            .ident => |*ident| try self.checkIdent(expr, ident),
            .unary => |unary| try self.checkUnary(expr, unary),
            .binary => |binary| try self.checkBinary(expr, binary),
            .assign => |assign| try self.checkAssign(expr, assign),
            .call => |call| try self.checkCall(expr, call),
            .cast => |cast| try self.checkCast(expr, cast),
            .field => |*field| try self.checkField(expr, field),
            .index => |index| try self.checkIndex(expr, index),
            .struct_init => |struct_init| try self.checkStructInit(expr, struct_init),
            .array_lit => |elements| try self.checkArrayLiteral(expr, elements, expected),
        };
        var final_ty = ty;
        if (expected) |e| {
            if (final_ty.* == .comptime_int and e.isInteger()) {
                // Type the whole constant expression with the expected type;
                // the static analyzer reports provable overflow.
                final_ty = e;
            } else if (final_ty.* == .comptime_float and e.* == .float) {
                final_ty = e;
            }
        }
        expr.ty = final_ty;
        return final_ty;
    }

    fn checkIntLiteral(self: *Sema, expr: *ast.Expr, value: u128, expected: ?*Type) Error!*Type {
        if (expected) |e| {
            if (e.isInteger()) {
                const info = e.intInfo();
                if (value > @as(u128, @intCast(info.max())) and !(info.signed and value == @as(u128, @intCast(-(info.min()))))) {
                    try self.reporter.err("E0426", expr.span, "integer literal {d} does not fit type '{s}'", .{ value, self.typeName(e) });
                }
                expr.ty = e;
                return e;
            }
        }
        expr.ty = self.prims.comptime_int;
        return self.prims.comptime_int;
    }

    fn checkIdent(self: *Sema, expr: *ast.Expr, ident: *ast.Expr.Kind.Ident) Error!*Type {
        const sym = self.lookup(ident.name) orelse {
            try self.reporter.err("E0427", expr.span, "unknown identifier '{s}'", .{ident.name});
            expr.ty = self.prims.invalid;
            return self.prims.invalid;
        };
        ident.sym = sym;
        expr.ty = sym.ty;
        return sym.ty;
    }

    fn checkUnary(self: *Sema, expr: *ast.Expr, unary: ast.Expr.Kind.Unary) Error!*Type {
        switch (unary.op) {
            .address_of => {
                const operand_ty = try self.checkExpr(unary.operand, null);
                const mutable = self.lvalueMutable(unary.operand);
                const ptr = try types.makePointer(self.allocator, operand_ty, !mutable);
                return ptr;
            },
            .dereference => {
                const operand_ty = try self.checkExpr(unary.operand, null);
                switch (operand_ty.*) {
                    .pointer => |p| return p.elem,
                    else => {
                        try self.reporter.err("E0428", expr.span, "cannot dereference value of type '{s}'", .{self.typeName(operand_ty)});
                        return self.prims.invalid;
                    },
                }
            },
            .negate => {
                const operand_ty = try self.checkExpr(unary.operand, null);
                if (!operand_ty.isNumeric()) {
                    try self.reporter.err("E0429", expr.span, "unary '-' requires a numeric operand, found '{s}'", .{self.typeName(operand_ty)});
                    return self.prims.invalid;
                }
                return operand_ty;
            },
            .logical_not => {
                const operand_ty = try self.checkExpr(unary.operand, self.prims.bool);
                try self.requireBool(unary.operand, operand_ty);
                return self.prims.bool;
            },
            .bit_not => {
                const operand_ty = try self.checkExpr(unary.operand, null);
                if (!operand_ty.isInteger()) {
                    try self.reporter.err("E0430", expr.span, "unary '~' requires an integer operand, found '{s}'", .{self.typeName(operand_ty)});
                    return self.prims.invalid;
                }
                return operand_ty;
            },
        }
    }

    fn checkBinary(self: *Sema, expr: *ast.Expr, binary: ast.Expr.Kind.Binary) Error!*Type {
        if (binary.op == .logical_and or binary.op == .logical_or) {
            const lhs_ty = try self.checkExpr(binary.lhs, self.prims.bool);
            try self.requireBool(binary.lhs, lhs_ty);
            const rhs_ty = try self.checkExpr(binary.rhs, self.prims.bool);
            try self.requireBool(binary.rhs, rhs_ty);
            return self.prims.bool;
        }

        var lhs_ty = try self.checkExpr(binary.lhs, null);
        var rhs_ty = try self.checkExpr(binary.rhs, null);
        try self.unifyLiterals(binary.lhs, &lhs_ty, binary.rhs, &rhs_ty, expr.span);
        if (lhs_ty.* == .invalid or rhs_ty.* == .invalid) return self.prims.invalid;

        switch (binary.op) {
            .eq, .ne => {
                if (lhs_ty.* == .null_type and rhs_ty.isPointer()) {
                    binary.lhs.ty = rhs_ty;
                    return self.prims.bool;
                }
                if (rhs_ty.* == .null_type and lhs_ty.isPointer()) {
                    binary.rhs.ty = lhs_ty;
                    return self.prims.bool;
                }
                if (!Type.eql(lhs_ty, rhs_ty)) {
                    try self.reporter.err("E0431", expr.span, "cannot compare '{s}' with '{s}'", .{
                        self.typeName(lhs_ty), self.typeName(rhs_ty),
                    });
                    return self.prims.invalid;
                }
                if (!(lhs_ty.isNumeric() or lhs_ty.isPointer() or lhs_ty.* == .bool or lhs_ty.* == .enum_type)) {
                    try self.reporter.err("E0432", expr.span, "type '{s}' cannot be compared for equality", .{self.typeName(lhs_ty)});
                    return self.prims.invalid;
                }
                return self.prims.bool;
            },
            .lt, .le, .gt, .ge => {
                if (!Type.eql(lhs_ty, rhs_ty)) {
                    try self.reporter.err("E0433", expr.span, "cannot compare '{s}' with '{s}'", .{
                        self.typeName(lhs_ty), self.typeName(rhs_ty),
                    });
                    return self.prims.invalid;
                }
                if (!(lhs_ty.isNumeric() or lhs_ty.isPointer())) {
                    try self.reporter.err("E0434", expr.span, "type '{s}' does not support ordering", .{self.typeName(lhs_ty)});
                    return self.prims.invalid;
                }
                return self.prims.bool;
            },
            .add, .sub => {
                if (lhs_ty.isPointer() and self.isIntegerType(rhs_ty) and binary.op == .add) {
                    return lhs_ty;
                }
                if (lhs_ty.isPointer() and self.isIntegerType(rhs_ty) and binary.op == .sub) {
                    return lhs_ty;
                }
                if (lhs_ty.isPointer() and rhs_ty.isPointer() and binary.op == .sub) {
                    if (!Type.eql(lhs_ty.pointer.elem, rhs_ty.pointer.elem)) {
                        try self.reporter.err("E0435", expr.span, "pointer subtraction requires identical element types", .{});
                        return self.prims.invalid;
                    }
                    return self.prims.isize;
                }
                return self.numericBinary(expr, binary, lhs_ty, rhs_ty);
            },
            .mul, .div, .mod => return self.numericBinary(expr, binary, lhs_ty, rhs_ty),
            .bit_and, .bit_or, .bit_xor => {
                if (!self.isIntegerType(lhs_ty) or !self.isIntegerType(rhs_ty)) {
                    try self.reporter.err("E0436", expr.span, "bitwise operator requires integer operands", .{});
                    return self.prims.invalid;
                }
                return self.unifyNumericResult(expr, binary, lhs_ty, rhs_ty);
            },
            .shl, .shr => {
                if (!self.isIntegerType(lhs_ty) or !self.isIntegerType(rhs_ty)) {
                    try self.reporter.err("E0437", expr.span, "shift operator requires integer operands", .{});
                    return self.prims.invalid;
                }
                return lhs_ty;
            },
            .logical_and, .logical_or => unreachable,
        }
    }

    fn numericBinary(self: *Sema, expr: *ast.Expr, binary: ast.Expr.Kind.Binary, lhs_ty: *Type, rhs_ty: *Type) Error!*Type {
        if (!lhs_ty.isNumeric() or !rhs_ty.isNumeric()) {
            try self.reporter.err("E0438", expr.span, "operator '{s}' requires numeric operands, found '{s}' and '{s}'", .{
                @tagName(binary.op), self.typeName(lhs_ty), self.typeName(rhs_ty),
            });
            return self.prims.invalid;
        }
        return self.unifyNumericResult(expr, binary, lhs_ty, rhs_ty);
    }

    fn unifyNumericResult(self: *Sema, expr: *ast.Expr, binary: ast.Expr.Kind.Binary, lhs_ty: *Type, rhs_ty: *Type) Error!*Type {
        if (Type.eql(lhs_ty, rhs_ty)) return lhs_ty;
        if (lhs_ty.* == .comptime_int and self.isIntegerType(rhs_ty)) {
            binary.lhs.ty = rhs_ty;
            return rhs_ty;
        }
        if (rhs_ty.* == .comptime_int and self.isIntegerType(lhs_ty)) {
            binary.rhs.ty = lhs_ty;
            return lhs_ty;
        }
        if (lhs_ty.* == .comptime_float and rhs_ty.* == .comptime_int) return self.prims.comptime_float;
        if (rhs_ty.* == .comptime_float and lhs_ty.* == .comptime_int) return self.prims.comptime_float;
        try self.reporter.err("E0439", expr.span, "mismatched operand types '{s}' and '{s}'; use an explicit cast", .{
            self.typeName(lhs_ty), self.typeName(rhs_ty),
        });
        return self.prims.invalid;
    }

    fn unifyLiterals(
        self: *Sema,
        lhs: *ast.Expr,
        lhs_ty: **Type,
        rhs: *ast.Expr,
        rhs_ty: **Type,
        span: Span,
    ) Error!void {
        if (lhs_ty.*.* == .comptime_int and self.isIntegerType(rhs_ty.*) and rhs_ty.*.* != .comptime_int) {
            if (try self.applyLiteralType(lhs, lhs_ty.*, rhs_ty.*)) {
                lhs_ty.* = rhs_ty.*;
            } else {
                try self.reporter.err("E0440", span, "integer literal does not fit type '{s}'", .{self.typeName(rhs_ty.*)});
            }
        } else if (rhs_ty.*.* == .comptime_int and self.isIntegerType(lhs_ty.*) and lhs_ty.*.* != .comptime_int) {
            if (try self.applyLiteralType(rhs, rhs_ty.*, lhs_ty.*)) {
                rhs_ty.* = lhs_ty.*;
            } else {
                try self.reporter.err("E0440", span, "integer literal does not fit type '{s}'", .{self.typeName(lhs_ty.*)});
            }
        } else if (lhs_ty.*.* == .comptime_float and rhs_ty.*.isFloat() and rhs_ty.*.* != .comptime_float) {
            lhs.ty = rhs_ty.*;
            lhs_ty.* = rhs_ty.*;
        } else if (rhs_ty.*.* == .comptime_float and lhs_ty.*.isFloat() and lhs_ty.*.* != .comptime_float) {
            rhs.ty = lhs_ty.*;
            rhs_ty.* = lhs_ty.*;
        }
    }

    fn applyLiteralType(self: *Sema, expr: *ast.Expr, from: *Type, to: *Type) Error!bool {
        _ = self;
        if (from.* != .comptime_int) return false;
        const value = literalIntValue(expr) orelse return false;
        if (!fitsInt(to.intInfo(), value)) return false;
        expr.ty = to;
        return true;
    }

    fn checkAssign(self: *Sema, expr: *ast.Expr, assign: ast.Expr.Kind.Assign) Error!*Type {
        const target_ty = try self.checkExpr(assign.target, null);
        if (!self.isLvalue(assign.target)) {
            try self.reporter.err("E0441", assign.target.span, "assignment target is not an lvalue", .{});
            _ = try self.checkExpr(assign.value, null);
            return target_ty;
        }
        if (!self.lvalueMutable(assign.target)) {
            try self.reporter.err("E0442", assign.target.span, "cannot assign to immutable location", .{});
        }
        const value_ty = try self.checkExpr(assign.value, target_ty);

        if (assign.op == .assign) {
            try self.requireAssignable(target_ty, assign.value, value_ty, true);
            return target_ty;
        }

        // Compound assignment is typed like the corresponding binary operation.
        if (assign.op == .shl or assign.op == .shr) {
            if (!self.isIntegerType(target_ty) or !self.isIntegerType(value_ty)) {
                try self.reporter.err("E0443", expr.span, "shift assignment requires integer operands", .{});
                return self.prims.invalid;
            }
            return target_ty;
        }
        const op: ast.BinaryOp = switch (assign.op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .bit_and => .bit_and,
            .bit_or => .bit_or,
            .bit_xor => .bit_xor,
            else => unreachable,
        };
        const fake_binary: ast.Expr.Kind.Binary = .{ .op = op, .lhs = assign.target, .rhs = assign.value };
        _ = try self.numericBinary(expr, fake_binary, target_ty, value_ty);
        duplicateAssignCheck: {
            if (!Type.eql(target_ty, value_ty) and value_ty.* != .comptime_int and value_ty.* != .comptime_float) {
                try self.reporter.err("E0444", expr.span, "compound assignment operands have mismatched types '{s}' and '{s}'", .{
                    self.typeName(target_ty), self.typeName(value_ty),
                });
                break :duplicateAssignCheck;
            }
        }
        return target_ty;
    }

    fn checkCall(self: *Sema, expr: *ast.Expr, call: ast.Expr.Kind.Call) Error!*Type {
        const callee_ty = try self.checkExpr(call.callee, null);
        if (callee_ty.* != .fn_type) {
            try self.reporter.err("E0445", call.callee.span, "cannot call value of type '{s}'", .{self.typeName(callee_ty)});
            for (call.args) |arg| _ = try self.checkExpr(arg, null);
            return self.prims.invalid;
        }
        const fn_info = callee_ty.fn_type;
        if (call.args.len != fn_info.params.len) {
            try self.reporter.err("E0446", expr.span, "function expects {d} argument(s), found {d}", .{
                fn_info.params.len, call.args.len,
            });
        }
        const count = @min(call.args.len, fn_info.params.len);
        for (call.args, 0..) |arg, i| {
            if (i < count) {
                const param_ty = fn_info.params[i];
                const arg_ty = try self.checkExpr(arg, param_ty);
                try self.requireAssignable(param_ty, arg, arg_ty, false);
            } else {
                _ = try self.checkExpr(arg, null);
            }
        }
        return fn_info.ret;
    }

    fn checkCast(self: *Sema, expr: *ast.Expr, cast: ast.Expr.Kind.Cast) Error!*Type {
        const source_ty = try self.checkExpr(cast.operand, null);
        const target_ty = try self.resolveType(cast.target);
        if (source_ty.* == .invalid or target_ty.* == .invalid) return target_ty;

        const allowed = switch (source_ty.*) {
            .comptime_int, .comptime_float => target_ty.isNumeric() or target_ty.isPointer() or target_ty.* == .bool or target_ty.* == .enum_type,
            .int, .char => target_ty.isNumeric() or target_ty.* == .bool or target_ty.* == .enum_type or target_ty.isPointer(),
            .float => target_ty.isFloat() or self.isIntegerType(target_ty) or target_ty.* == .bool,
            .bool => self.isIntegerType(target_ty) or target_ty.isFloat() or target_ty.* == .bool,
            .enum_type => self.isIntegerType(target_ty) or target_ty.* == .enum_type,
            .pointer => self.isPointerCast(source_ty, target_ty),
            .null_type => target_ty.isPointer(),
            else => false,
        };
        if (!allowed) {
            try self.reporter.err("E0447", expr.span, "cannot cast '{s}' to '{s}'", .{
                self.typeName(source_ty), self.typeName(target_ty),
            });
        }
        return target_ty;
    }

    fn isPointerCast(self: *const Sema, source_ty: *Type, target_ty: *Type) bool {
        _ = self;
        if (target_ty.* == .slice) {
            const source_info = source_ty.pointer;
            if (source_info.elem.* != .array) return false;
            const array = source_info.elem.array;
            const target_info = target_ty.slice;
            if (target_info.is_const != source_info.is_const) return false;
            return Type.eql(target_info.elem, array.elem);
        }
        return target_ty.isPointer() or target_ty.isInteger() or target_ty.* == .bool;
    }

    fn checkField(self: *Sema, expr: *ast.Expr, field: *ast.Expr.Kind.Field) Error!*Type {
        const base_ty = try self.checkExpr(field.base, null);

        if (base_ty.* == .slice) {
            if (field.through_pointer) {
                try self.reporter.err("E0451", expr.span, "'->' requires a pointer operand", .{});
                return self.prims.invalid;
            }
            if (std.mem.eql(u8, field.name, "len")) {
                field.field_index = 1;
                return self.prims.usize;
            }
            try self.reporter.err("E0453", expr.span, "slice has no field '{s}'", .{field.name});
            return self.prims.invalid;
        }

        if (base_ty.* == .enum_type) {
            if (field.through_pointer) {
                try self.reporter.err("E0448", expr.span, "cannot use '->' on enum type '{s}'", .{self.typeName(base_ty)});
                return self.prims.invalid;
            }
            const info = base_ty.enum_type;
            for (info.variants) |variant| {
                if (std.mem.eql(u8, variant.name, field.name)) {
                    field.is_enum_variant = true;
                    field.variant_value = variant.value;
                    return base_ty;
                }
            }
            try self.reporter.err("E0449", expr.span, "enum '{s}' has no variant '{s}'", .{ info.name, field.name });
            return self.prims.invalid;
        }

        var struct_ty = base_ty;
        if (base_ty.* == .pointer) {
            if (!field.through_pointer) {
                try self.reporter.err("E0450", expr.span, "field access through pointer requires '->' or explicit dereference", .{});
                return self.prims.invalid;
            }
            struct_ty = base_ty.pointer.elem;
        } else if (field.through_pointer) {
            try self.reporter.err("E0451", expr.span, "'->' requires a pointer operand", .{});
            return self.prims.invalid;
        }

        if (struct_ty.* != .struct_type) {
            try self.reporter.err("E0452", expr.span, "type '{s}' has no fields", .{self.typeName(struct_ty)});
            return self.prims.invalid;
        }
        if (base_ty.* != .pointer and !self.isLvalue(field.base) and std.meta.activeTag(field.base.kind) != .struct_init) {
            try self.reporter.err("E0465", field.base.span, "field access requires an lvalue or a pointer", .{});
        }
        const info = struct_ty.struct_type;
        for (info.fields) |struct_field| {
            if (std.mem.eql(u8, struct_field.name, field.name)) {
                field.field_index = struct_field.index;
                return struct_field.ty;
            }
        }
        try self.reporter.err("E0453", expr.span, "struct '{s}' has no field '{s}'", .{ info.name, field.name });
        return self.prims.invalid;
    }

    fn checkIndex(self: *Sema, expr: *ast.Expr, index: ast.Expr.Kind.Index) Error!*Type {
        const base_ty = try self.checkExpr(index.base, null);
        const index_ty = try self.checkExpr(index.index, null);
        if (!self.isIntegerType(index_ty) and index_ty.* != .comptime_int) {
            try self.reporter.err("E0454", index.index.span, "array index must be an integer, found '{s}'", .{self.typeName(index_ty)});
        }
        if (base_ty.* != .pointer and base_ty.* != .slice and !self.isLvalue(index.base) and std.meta.activeTag(index.base.kind) != .array_lit) {
            try self.reporter.err("E0466", index.base.span, "indexing requires an lvalue array, an array literal or a pointer", .{});
        }
        return switch (base_ty.*) {
            .array => |a| a.elem,
            .pointer => |p| p.elem,
            .slice => |s| s.elem,
            else => blk: {
                try self.reporter.err("E0455", expr.span, "cannot index value of type '{s}'", .{self.typeName(base_ty)});
                break :blk self.prims.invalid;
            },
        };
    }

    fn checkStructInit(self: *Sema, expr: *ast.Expr, initializer: ast.Expr.Kind.StructInit) Error!*Type {
        const ty = try self.resolveType(initializer.type_expr);
        if (ty.* != .struct_type) {
            try self.reporter.err("E0456", initializer.type_expr.span, "type '{s}' is not a struct", .{self.typeName(ty)});
            for (initializer.fields) |field| _ = try self.checkExpr(field.value, null);
            return self.prims.invalid;
        }
        const info = ty.struct_type;
        var assigned = try self.allocator.alloc(bool, info.fields.len);
        @memset(assigned, false);

        for (initializer.fields) |*field| {
            var found = false;
            for (info.fields) |struct_field| {
                if (std.mem.eql(u8, struct_field.name, field.name)) {
                    field.index = struct_field.index;
                    const value_ty = try self.checkExpr(field.value, struct_field.ty);
                    try self.requireAssignable(struct_field.ty, field.value, value_ty, true);
                    assigned[struct_field.index] = true;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try self.reporter.err("E0457", field.span, "struct '{s}' has no field '{s}'", .{ info.name, field.name });
                _ = try self.checkExpr(field.value, null);
            }
        }
        for (info.fields, 0..) |struct_field, i| {
            if (!assigned[i]) {
                try self.reporter.err("E0458", expr.span, "missing field '{s}' in initializer for struct '{s}'", .{
                    struct_field.name, info.name,
                });
            }
        }
        return ty;
    }

    fn checkArrayLiteral(self: *Sema, expr: *ast.Expr, elements: []*ast.Expr, expected: ?*Type) Error!*Type {
        if (elements.len == 0) {
            try self.reporter.err("E0459", expr.span, "array literal cannot be empty", .{});
            return self.prims.invalid;
        }
        var elem_expected: ?*Type = null;
        if (expected) |e| {
            if (e.* == .array) elem_expected = e.array.elem;
        }

        var first_ty: ?*Type = null;
        for (elements) |element| {
            const ty = try self.checkExpr(element, elem_expected);
            if (first_ty == null) {
                first_ty = ty;
            } else if (first_ty.?.* == .comptime_int and self.isIntegerType(ty)) {
                if (!try self.applyLiteralType(elements[0], first_ty.?, ty)) {
                    try self.reporter.err("E0460", elements[0].span, "array literal element does not fit type '{s}'", .{self.typeName(ty)});
                }
                first_ty = ty;
            } else if (ty.* == .comptime_int and self.isIntegerType(first_ty.?)) {
                if (!try self.applyLiteralType(element, ty, first_ty.?)) {
                    try self.reporter.err("E0460", element.span, "array literal element does not fit type '{s}'", .{self.typeName(first_ty.?)});
                }
            } else if (!Type.eql(first_ty.?, ty)) {
                try self.reporter.err("E0461", element.span, "array literal elements must share a type; found '{s}' and '{s}'", .{
                    self.typeName(first_ty.?), self.typeName(ty),
                });
            }
        }
        var elem_ty = first_ty orelse self.prims.invalid;
        if (elem_ty.* == .comptime_int) elem_ty = self.prims.i64;
        if (elem_ty.* == .comptime_float) elem_ty = self.prims.f64;
        return try types.makeArray(self.allocator, elem_ty, elements.len);
    }

    // ------------------------------------------------------------------
    // Assignment compatibility
    // ------------------------------------------------------------------

    pub fn requireAssignable(
        self: *Sema,
        target: *Type,
        value_expr: *ast.Expr,
        value_ty: *Type,
        report: bool,
    ) Error!void {
        if (self.isAssignable(target, value_expr, value_ty)) return;
        if (report) {
            try self.reporter.err("E0462", value_expr.span, "cannot assign '{s}' to '{s}' without an explicit cast", .{
                self.typeName(value_ty), self.typeName(target),
            });
        }
    }

    fn isAssignable(self: *Sema, target: *Type, value_expr: *ast.Expr, value_ty: *Type) bool {
        _ = self;
        if (Type.eql(target, value_ty)) return true;
        if (value_ty.* == .comptime_int and target.isInteger()) {
            const value = literalIntValue(value_expr) orelse return false;
            return fitsInt(target.intInfo(), value);
        }
        if (value_ty.* == .comptime_float and target.* == .float) return true;
        if (value_ty.* == .null_type and target.isPointer()) return true;
        // String literals have type *const u8 already; no other implicit
        // conversions are permitted.
        return false;
    }

    fn materialize(self: *Sema, ty: *Type, span: Span) *Type {
        _ = span;
        return switch (ty.*) {
            .comptime_int => self.prims.i64,
            .comptime_float => self.prims.f64,
            .null_type => blk: {
                break :blk self.prims.invalid;
            },
            else => ty,
        };
    }

    fn requireBool(self: *Sema, expr: *ast.Expr, ty: *Type) Error!void {
        if (ty.* != .bool) {
            try self.reporter.err("E0463", expr.span, "condition must have type 'bool', found '{s}'", .{self.typeName(ty)});
        }
    }

    fn isIntegerType(self: *const Sema, ty: *Type) bool {
        _ = self;
        return ty.isInteger();
    }

    // ------------------------------------------------------------------
    // Lvalues
    // ------------------------------------------------------------------

    fn isLvalue(self: *Sema, expr: *ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| if (ident.sym) |sym| sym.kind == .local or sym.kind == .global else false,
            .unary => |unary| unary.op == .dereference,
            .field => |field| !field.is_enum_variant and self.isLvalue(field.base),
            .index => |index| blk: {
                if (index.base.ty) |base_ty| {
                    if (base_ty.* == .slice) break :blk !base_ty.slice.is_const;
                }
                break :blk self.isLvalue(index.base) or self.isPointerExpr(index.base);
            },
            else => false,
        };
    }

    fn lvalueMutable(self: *Sema, expr: *ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| if (ident.sym) |sym| sym.mutable else false,
            .unary => |unary| blk: {
                if (unary.op != .dereference) break :blk false;
                const ty = unary.operand.ty orelse break :blk false;
                break :blk ty.* == .pointer and !ty.pointer.is_const;
            },
            .field => |field| blk: {
                if (field.is_enum_variant) break :blk false;
                if (field.through_pointer) {
                    const base_ty = field.base.ty orelse break :blk false;
                    if (base_ty.* == .pointer and !base_ty.pointer.is_const) break :blk true;
                }
                break :blk self.lvalueMutable(field.base);
            },
            .index => |index| blk: {
                if (self.isPointerExpr(index.base)) {
                    const base_ty = index.base.ty orelse break :blk false;
                    break :blk base_ty.* == .pointer and !base_ty.pointer.is_const;
                }
                const base_ty = index.base.ty orelse break :blk self.lvalueMutable(index.base);
                if (base_ty.* == .slice) break :blk !base_ty.slice.is_const;
                break :blk self.lvalueMutable(index.base);
            },
            else => false,
        };
    }

    fn isPointerExpr(self: *Sema, expr: *ast.Expr) bool {
        _ = self;
        return if (expr.ty) |ty| ty.isPointer() else false;
    }

    // ------------------------------------------------------------------
    // Constant evaluation
    // ------------------------------------------------------------------

    pub fn evalConstInt(self: *Sema, expr: *ast.Expr) Error!?i128 {
        switch (expr.kind) {
            .int_lit => |lit| {
                if (lit.value > @as(u128, @intCast(std.math.maxInt(i128)))) return null;
                return @intCast(lit.value);
            },
            .bool_lit => |value| return if (value) 1 else 0,
            .char_lit => |value| return @intCast(value),
            .unary => |unary| {
                const value = (try self.evalConstInt(unary.operand)) orelse return null;
                return switch (unary.op) {
                    .negate => -value,
                    .bit_not => ~value,
                    .logical_not => if (value == 0) 1 else 0,
                    else => null,
                };
            },
            .binary => |binary| {
                const lhs = (try self.evalConstInt(binary.lhs)) orelse return null;
                const rhs = (try self.evalConstInt(binary.rhs)) orelse return null;
                return switch (binary.op) {
                    .add => lhs +% rhs,
                    .sub => lhs -% rhs,
                    .mul => lhs *% rhs,
                    .div => if (rhs == 0) null else @divTrunc(lhs, rhs),
                    .mod => if (rhs == 0) null else @rem(lhs, rhs),
                    .shl => if (rhs < 0 or rhs > 127) null else lhs << @intCast(rhs),
                    .shr => if (rhs < 0 or rhs > 127) null else lhs >> @intCast(rhs),
                    .bit_and => lhs & rhs,
                    .bit_or => lhs | rhs,
                    .bit_xor => lhs ^ rhs,
                    .eq => if (lhs == rhs) 1 else 0,
                    .ne => if (lhs != rhs) 1 else 0,
                    .lt => if (lhs < rhs) 1 else 0,
                    .le => if (lhs <= rhs) 1 else 0,
                    .gt => if (lhs > rhs) 1 else 0,
                    .ge => if (lhs >= rhs) 1 else 0,
                    .logical_and => if (lhs != 0 and rhs != 0) 1 else 0,
                    .logical_or => if (lhs != 0 or rhs != 0) 1 else 0,
                };
            },
            .cast => |cast| {
                const value = (try self.evalConstInt(cast.operand)) orelse return null;
                const target = try self.resolveType(cast.target);
                if (!target.isInteger()) return null;
                const info = target.intInfo();
                if (info.bits >= 128) return value;
                if (info.signed) {
                    const mask = (@as(i128, 1) << @intCast(info.bits)) - 1;
                    var truncated = value & mask;
                    if ((truncated & (@as(i128, 1) << @intCast(info.bits - 1))) != 0) {
                        truncated -= (@as(i128, 1) << @intCast(info.bits));
                    }
                    return truncated;
                }
                return value & ((@as(i128, 1) << @intCast(info.bits)) - 1);
            },
            .field => |field| {
                if (field.is_enum_variant) return field.variant_value;
                return null;
            },
            else => return null,
        }
    }

    // ------------------------------------------------------------------
    // Diagnostics helpers
    // ------------------------------------------------------------------

    pub fn typeName(self: *const Sema, ty: *Type) []const u8 {
        _ = self;
        return switch (ty.*) {
            .invalid => "invalid",
            .void => "void",
            .bool => "bool",
            .char => "char",
            .int => |info| info.name(),
            .float => |bits| if (bits == 32) "f32" else "f64",
            .pointer => |p| if (p.is_const) "*const ?" else "*?",
            .array => "[?]?",
            .slice => "slice",
            .struct_type => |s| s.name,
            .enum_type => |e| e.name,
            .fn_type => "fn",
            .comptime_int => "integer literal",
            .comptime_float => "float literal",
            .null_type => "null",
        };
    }
};

fn containsIncompleteByValue(ty: *Type) bool {
    return switch (ty.*) {
        .struct_type => |info| info.resolving,
        .array => |array| containsIncompleteByValue(array.elem),
        else => false,
    };
}

fn fitsInt(info: types.IntInfo, value: i128) bool {
    return value >= info.min() and value <= info.max();
}

/// Extract an integer literal value through unary minus/casts.
pub fn literalIntValue(expr: *ast.Expr) ?i128 {
    return analyzer_mod.constInt(expr);
}

pub fn isConstInitializer(expr: *ast.Expr) bool {
    return switch (expr.kind) {
        .int_lit, .float_lit, .bool_lit, .char_lit, .string_lit, .null_lit => true,
        .struct_init => |initializer| blk: {
            for (initializer.fields) |field| {
                if (!isConstInitializer(field.value)) break :blk false;
            }
            break :blk true;
        },
        .array_lit => |elements| blk: {
            for (elements) |element| {
                if (!isConstInitializer(element)) break :blk false;
            }
            break :blk true;
        },
        .unary => |unary| unary.op != .dereference and unary.op != .address_of and isConstInitializer(unary.operand),
        .binary => |binary| isConstInitializer(binary.lhs) and isConstInitializer(binary.rhs),
        .cast => |cast| isConstInitializer(cast.operand),
        .field => |field| field.is_enum_variant,
        else => false,
    };
}

/// Conservative backwards reachability check used for missing-return errors.
pub fn blockAlwaysReturns(block: *ast.Block) bool {
    for (block.stmts) |stmt| {
        if (stmtAlwaysReturns(stmt)) return true;
    }
    return false;
}

fn stmtAlwaysReturns(stmt: *ast.Stmt) bool {
    return switch (stmt.kind) {
        .return_stmt => true,
        .block => |block| blockAlwaysReturns(block),
        .if_stmt => |if_stmt| if (if_stmt.else_branch) |else_stmt|
            blockAlwaysReturns(if_stmt.then_branch) and stmtAlwaysReturns(else_stmt)
        else
            false,
        .while_stmt => |while_stmt| blk: {
            // `while (true)` with no break is treated as non-returning only for
            // the purpose of reachability; we keep this conservative.
            _ = while_stmt;
            break :blk false;
        },
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const SemTest = struct {
    arena: std.heap.ArenaAllocator,
    src: *source.Source,
    reporter: diagnostics.Reporter,
    prims: types.Primitives,
    program: ?*ast.Program = null,

    fn init(self: *SemTest, text: []const u8) !void {
        const lexer = @import("lexer.zig");
        const parser = @import("parser.zig");
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena.allocator();
        self.src = try a.create(source.Source);
        self.src.* = try source.Source.init(a, "test.kyn", text);
        self.reporter = diagnostics.Reporter.init(a, self.src);
        self.prims = try types.Primitives.init(a);
        var lx = lexer.Lexer.init(a, self.src, &self.reporter);
        const tokens = try lx.tokenize();
        var p = parser.Parser.init(a, tokens, &self.reporter);
        self.program = try p.parse();
    }

    fn run(self: *SemTest) !void {
        var sema = Sema.init(self.arena.allocator(), &self.reporter, &self.prims);
        try sema.analyze(self.program.?);
    }

    fn deinit(self: *SemTest) void {
        self.arena.deinit();
    }
};

fn expectSemanticError(text: []const u8, code: []const u8) !void {
    var ctx: SemTest = undefined;
    try ctx.init(text);
    defer ctx.deinit();
    try ctx.run();
    try testing.expect(ctx.reporter.hasErrors());
    for (ctx.reporter.list.items) |diag| {
        if (std.mem.eql(u8, diag.code, code)) return;
    }
    std.debug.print("expected {s}, got:\n", .{code});
    for (ctx.reporter.list.items) |diag| std.debug.print("  {s}: {s}\n", .{ diag.code, diag.message });
    return error.ExpectedDiagnostic;
}

fn expectClean(text: []const u8) !void {
    var ctx: SemTest = undefined;
    try ctx.init(text);
    defer ctx.deinit();
    try ctx.run();
    if (ctx.reporter.hasErrors()) {
        for (ctx.reporter.list.items) |diag| std.debug.print("  {s}: {s}\n", .{ diag.code, diag.message });
        return error.UnexpectedDiagnostic;
    }
}

test "semantic accepts functions, locals, arithmetic" {
    try expectClean(
        \\fn add(a: i32, b: i32) i32 { return a + b; }
        \\fn main() i32 {
        \\    var x: i32 = add(1, 2);
        \\    let y: i32 = x * 2;
        \\    if (y > 3) { x = y; } else { x = 0; }
        \\    while (x < 10) { x += 1; }
        \\    return x;
        \\}
    );
}

test "semantic accepts structs, pointers, enums, arrays" {
    try expectClean(
        \\struct Point { x: i32, y: i32 }
        \\enum Color: u8 { Red, Green, Blue }
        \\fn main() i32 {
        \\    var p: Point = Point { x: 1, y: 2 };
        \\    let q: *Point = &p;
        \\    q->x = 10;
        \\    let c: Color = Color.Blue;
        \\    var values: [3]i32 = [1, 2, 3];
        \\    values[0] = 4;
        \\    return q->x + values[1];
        \\}
    );
}

test "semantic accepts extern C function" {
    try expectClean(
        \\extern fn puts(s: *const u8) i32;
        \\fn main() i32 { return puts("hello"); }
    );
}

test "semantic rejects unknown identifier" {
    try expectSemanticError(
        \\fn main() i32 { return missing; }
    , "E0427");
}

test "semantic rejects type mismatch" {
    try expectSemanticError(
        \\fn main() i32 { let x: i32 = 1.5; return x; }
    , "E0462");
}

test "semantic rejects assignment to let" {
    try expectSemanticError(
        \\fn main() i32 { let x: i32 = 1; x = 2; return x; }
    , "E0442");
}

test "semantic rejects implicit narrowing" {
    try expectSemanticError(
        \\fn main() i32 { let x: u8 = 300; return 0; }
    , "E0426");
}

test "semantic rejects bad function call" {
    try expectSemanticError(
        \\fn f(a: i32) i32 { return a; }
        \\fn main() i32 { return f(1, 2); }
    , "E0446");
}

test "semantic rejects missing return" {
    try expectSemanticError(
        \\fn f(x: bool) i32 { if (x) { return 1; } }
        \\fn main() i32 { return f(true); }
    , "E0414");
}

test "semantic rejects duplicate top-level declaration" {
    try expectSemanticError(
        \\fn main() i32 { return 0; }
        \\fn main() i32 { return 1; }
    , "E0401");
}

test "semantic rejects by-value recursive struct" {
    try expectSemanticError(
        \\struct Node { next: Node }
        \\fn main() i32 { return 0; }
    , "E0403");
}

test "semantic allows pointer-recursive struct" {
    try expectClean(
        \\struct Node { value: i32, next: *Node }
        \\fn main() i32 { return 0; }
    );
}

test "semantic rejects non-bool condition" {
    try expectSemanticError(
        \\fn main() i32 { if (1) { return 1; } return 0; }
    , "E0463");
}

test "semantic rejects bad cast" {
    try expectSemanticError(
        \\struct S { x: i32 }
        \\fn main() i32 { let s = S { x: 1 }; return s as i32; }
    , "E0447");
}

test "semantic accepts explicit numeric casts" {
    try expectClean(
        \\fn main() i32 {
        \\    let a: u8 = 200;
        \\    let b: i32 = a as i32;
        \\    let c: u8 = 300 as u8;
        \\    return b;
        \\}
    );
}

test "aggregate parameters and returns are supported within Kyn" {
    try expectClean(
        \\struct Point { x: i32, y: i32 }
        \\fn sum(p: Point) i32 {
        \\    return p.x + p.y;
        \\}
        \\fn make(x: i32, y: i32) Point {
        \\    return Point { x: x, y: y };
        \\}
        \\fn main() i32 {
        \\    let p: Point = make(3, 4);
        \\    let q: Point = p;
        \\    return sum(q);
        \\}
    );
}

test "external functions reject aggregate parameters and returns" {
    try expectSemanticError(
        \\struct Point { x: i32, y: i32 }
        \\extern fn c_sum(p: Point) i32;
        \\fn main() i32 { return 0; }
    , "E0410");

    try expectSemanticError(
        \\struct Point { x: i32, y: i32 }
        \\export fn kyn_make(x: i32, y: i32) Point {
        \\    return Point { x: x, y: y };
        \\}
        \\fn main() i32 { return 0; }
    , "E0410");
}

test "global enum and aggregate constants are accepted" {
    try expectClean(
        \\enum Color: u8 { Red = 2 }
        \\struct Point { x: i32, y: i32 }
        \\const C: Color = Color.Red;
        \\const P: Point = Point { x: 3, y: 4 };
        \\const VALUES: [2]i32 = [5, 6];
        \\fn main() i32 {
        \\    return C as i32 + P.x + P.y + VALUES[0] + VALUES[1];
        \\}
    );
}

test "global initializer with a function call is rejected" {
    try expectSemanticError(
        \\fn make() i32 { return 1; }
        \\const VALUE: i32 = make();
        \\fn main() i32 { return VALUE; }
    , "E0412");
}

test "slices are accepted inside Kyn and rejected at C ABI boundaries" {
    try expectClean(
        \\fn sum(values: []i32) i32 {
        \\    var total: i32 = 0;
        \\    var index: usize = 0;
        \\    while (index < values.len) {
        \\        total += values[index];
        \\        index += 1;
        \\    }
        \\    return total;
        \\}
        \\fn main() i32 {
        \\    var values: [3]i32 = [1, 2, 3];
        \\    return sum(&values as []i32);
        \\}
    );

    try expectSemanticError(
        \\extern fn c_sum(values: []i32) i32;
        \\fn main() i32 { return 0; }
    , "E0410");
}
