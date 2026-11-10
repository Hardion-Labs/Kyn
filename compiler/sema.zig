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
const builtin = @import("builtin");
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

const NameResolution = union(enum) {
    missing,
    found: *Symbol,
    private: *Symbol,
    ambiguous,
};

pub const Sema = struct {
    allocator: std.mem.Allocator,
    reporter: *diagnostics.Reporter,
    prims: *types.Primitives,
    module_globals: std.AutoHashMap(u32, std.StringHashMap(*Symbol)),
    module_aliases: std.AutoHashMap(u32, std.StringHashMap(u32)),
    module_open_imports: std.AutoHashMap(u32, std.ArrayList(u32)),
    module_name_cache: std.AutoHashMap(u32, std.StringHashMap(NameResolution)),
    module_visit_marks: []u32 = &.{},
    module_visit_generation: u32 = 0,
    module_walk_stack: std.ArrayList(u32) = .empty,
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
            .module_globals = std.AutoHashMap(u32, std.StringHashMap(*Symbol)).init(allocator),
            .module_aliases = std.AutoHashMap(u32, std.StringHashMap(u32)).init(allocator),
            .module_open_imports = std.AutoHashMap(u32, std.ArrayList(u32)).init(allocator),
            .module_name_cache = std.AutoHashMap(u32, std.StringHashMap(NameResolution)).init(allocator),
        };
    }

    pub fn analyze(self: *Sema, program: *ast.Program) Error!void {
        try self.registerImports(program.imports);
        try self.declareTopLevel(program);
        try self.resolveTopLevel(program);
        try self.checkExternalSymbols(program);
        try self.checkBodies(program);
    }

    // ------------------------------------------------------------------
    // Phase 1: top-level names
    // ------------------------------------------------------------------

    fn moduleSymbol(self: *const Sema, module_id: u32, name: []const u8) ?*Symbol {
        const symbols = self.module_globals.get(module_id) orelse return null;
        return symbols.get(name);
    }

    fn moduleAliasTarget(self: *const Sema, module_id: u32, alias: []const u8) ?u32 {
        const aliases = self.module_aliases.get(module_id) orelse return null;
        return aliases.get(alias);
    }

    fn registerImports(self: *Sema, imports: []const ast.ImportDecl) Error!void {
        var max_module_id: u32 = 0;
        for (imports) |imp| {
            max_module_id = @max(max_module_id, @max(imp.span.source_id, imp.target_module_id));
            if (imp.alias) |alias| {
                if (self.module_aliases.getPtr(imp.span.source_id)) |aliases| {
                    if (aliases.contains(alias)) {
                        try self.reporter.err("E0468", imp.span, "duplicate module alias '{s}'", .{alias});
                        continue;
                    }
                    try aliases.put(alias, imp.target_module_id);
                } else {
                    var aliases = std.StringHashMap(u32).init(self.allocator);
                    try aliases.put(alias, imp.target_module_id);
                    try self.module_aliases.put(imp.span.source_id, aliases);
                }
            } else if (self.module_open_imports.getPtr(imp.span.source_id)) |targets| {
                try targets.append(self.allocator, imp.target_module_id);
            } else {
                var targets: std.ArrayList(u32) = .empty;
                try targets.append(self.allocator, imp.target_module_id);
                try self.module_open_imports.put(imp.span.source_id, targets);
            }
        }

        self.module_visit_marks = try self.allocator.alloc(u32, @as(usize, max_module_id) + 1);
        @memset(self.module_visit_marks, 0);
    }

    fn cacheModuleName(self: *Sema, module_id: u32, name: []const u8, result: NameResolution) Error!NameResolution {
        if (self.module_name_cache.getPtr(module_id)) |cache| {
            try cache.put(name, result);
        } else {
            var cache = std.StringHashMap(NameResolution).init(self.allocator);
            try cache.put(name, result);
            try self.module_name_cache.put(module_id, cache);
        }
        return result;
    }

    fn resolveModuleName(self: *Sema, module_id: u32, name: []const u8) Error!NameResolution {
        if (self.module_name_cache.get(module_id)) |cache| {
            if (cache.get(name)) |cached| return cached;
        }
        if (self.moduleSymbol(module_id, name)) |local| {
            return try self.cacheModuleName(module_id, name, .{ .found = local });
        }
        if (module_id >= self.module_visit_marks.len) {
            return try self.cacheModuleName(module_id, name, .missing);
        }

        if (self.module_visit_generation == std.math.maxInt(u32)) {
            @memset(self.module_visit_marks, 0);
            self.module_visit_generation = 1;
        } else {
            self.module_visit_generation += 1;
        }
        const generation = self.module_visit_generation;
        self.module_walk_stack.clearRetainingCapacity();
        try self.pushOpenTargets(module_id);

        var visible: ?*Symbol = null;
        var inaccessible: ?*Symbol = null;
        var ambiguous = false;
        while (self.module_walk_stack.pop()) |imported_id| {
            if (self.module_visit_marks[imported_id] == generation) continue;
            self.module_visit_marks[imported_id] = generation;
            if (self.moduleSymbol(imported_id, name)) |candidate| {
                if (candidate.is_public) {
                    if (visible) |previous| {
                        if (previous != candidate) {
                            ambiguous = true;
                            break;
                        }
                    } else {
                        visible = candidate;
                    }
                } else if (inaccessible == null) {
                    inaccessible = candidate;
                }
            }
            try self.pushOpenTargets(imported_id);
        }
        if (ambiguous) return try self.cacheModuleName(module_id, name, .ambiguous);
        if (visible) |candidate| return try self.cacheModuleName(module_id, name, .{ .found = candidate });
        if (inaccessible) |candidate| return try self.cacheModuleName(module_id, name, .{ .private = candidate });
        return try self.cacheModuleName(module_id, name, .missing);
    }

    fn pushOpenTargets(self: *Sema, module_id: u32) Error!void {
        const targets = self.module_open_imports.get(module_id) orelse return;
        var index = targets.items.len;
        while (index > 0) {
            index -= 1;
            try self.module_walk_stack.append(self.allocator, targets.items[index]);
        }
    }

    fn lookupValue(self: *Sema, name: []const u8, source_id: u32, span: Span) Error!?*Symbol {
        return self.lookupLocal(name) orelse switch (try self.resolveModuleName(source_id, name)) {
            .found => |sym| sym,
            .missing => null,
            .private => |sym| blk: {
                try self.reporter.err("E0467", span, "declaration '{s}' is private to another module", .{name});
                _ = sym;
                break :blk null;
            },
            .ambiguous => blk: {
                try self.reporter.err("E0471", span, "unqualified name '{s}' is ambiguous; use an import alias", .{name});
                break :blk null;
            },
        };
    }

    fn checkExternalSymbols(self: *Sema, program: *ast.Program) Error!void {
        const External = struct { symbol: *Symbol, is_definition: bool };
        var names = std.StringHashMap(External).init(self.allocator);
        for (program.decls) |decl| {
            const fd = switch (decl.kind) {
                .fn_decl => |fd| fd,
                else => continue,
            };
            const sym = fd.sym orelse continue;
            const is_root_main = sym.owner_module_id == 0 and std.mem.eql(u8, sym.name, "main");
            if (!fd.is_extern and !fd.is_export and !is_root_main) continue;
            const link_name = sym.link_name;
            const is_definition = fd.is_export or is_root_main;
            if (names.get(link_name)) |previous| {
                if (!Type.eql(previous.symbol.ty, sym.ty) or (previous.is_definition and is_definition)) {
                    try self.reporter.err("E0472", decl.span, "incompatible or duplicate external function symbol '{s}'", .{link_name});
                } else if (is_definition) {
                    try names.put(link_name, .{ .symbol = sym, .is_definition = true });
                }
            } else {
                try names.put(link_name, .{ .symbol = sym, .is_definition = is_definition });
            }
        }
    }

    fn declareTopLevel(self: *Sema, program: *ast.Program) Error!void {
        for (program.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |sd| {
                    const info = try self.allocator.create(types.StructInfo);
                    info.* = .{
                        .name = sd.name,
                        .llvm_name = try std.fmt.allocPrint(self.allocator, "__kyn_s_m{d}_{s}", .{ decl.span.source_id, sd.name }),
                        .owner_module_id = decl.span.source_id,
                        .is_public = decl.is_public,
                    };
                    const ty = try self.allocator.create(Type);
                    ty.* = .{ .struct_type = info };
                    sd.ty = ty;
                    sd.sym = try self.declareGlobal(sd.name, .struct_type, ty, decl.span, decl.is_public, false);
                },
                .enum_decl => |ed| {
                    const info = try self.allocator.create(types.EnumInfo);
                    info.* = .{ .name = ed.name, .backing = self.prims.i32, .owner_module_id = decl.span.source_id, .is_public = decl.is_public };
                    const ty = try self.allocator.create(Type);
                    ty.* = .{ .enum_type = info };
                    ed.ty = ty;
                    ed.sym = try self.declareGlobal(ed.name, .enum_type, ty, decl.span, decl.is_public, false);
                },
                .fn_decl => |fd| {
                    if (fd.body == null and !fd.is_extern) {
                        try self.reporter.err("E0402", decl.span, "function '{s}' has no body; mark it 'extern'", .{fd.name});
                    }
                    const placeholder = try self.allocator.create(Type);
                    placeholder.* = .invalid;
                    fd.sym = try self.declareGlobal(fd.name, .function, placeholder, decl.span, decl.is_public, fd.is_extern or fd.is_export or (decl.span.source_id == 0 and std.mem.eql(u8, fd.name, "main")));
                    if (fd.sym) |sym| {
                        sym.is_extern = fd.is_extern;
                        sym.is_export = fd.is_export;
                    }
                },
                .var_decl => |vd| {
                    const placeholder = try self.allocator.create(Type);
                    placeholder.* = .invalid;
                    const existed = self.moduleSymbol(decl.span.source_id, vd.name) != null;
                    vd.sym = try self.declareGlobal(vd.name, .global, placeholder, decl.span, decl.is_public, false);
                    if (!existed) {
                        if (vd.sym) |sym| sym.mutable = vd.mutable;
                    }
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
        is_public: bool,
        is_external_name: bool,
    ) Error!*Symbol {
        if (self.moduleSymbol(span.source_id, name)) |existing| {
            try self.reporter.err("E0401", span, "duplicate declaration '{s}' in this module (previous kind: {s})", .{
                name,
                @tagName(existing.kind),
            });
            return existing;
        }
        const link_name = if (is_external_name)
            name
        else switch (kind) {
            .global => try std.fmt.allocPrint(self.allocator, "__kyn_g_m{d}_{s}", .{ span.source_id, name }),
            .function => try std.fmt.allocPrint(self.allocator, "__kyn_f_m{d}_{s}", .{ span.source_id, name }),
            else => name,
        };
        const sym = try self.allocator.create(Symbol);
        sym.* = .{
            .id = self.nextId(),
            .name = name,
            .link_name = link_name,
            .kind = kind,
            .ty = ty,
            .owner_module_id = span.source_id,
            .is_public = is_public,
        };
        if (self.module_globals.getPtr(span.source_id)) |symbols| {
            try symbols.put(name, sym);
        } else {
            var symbols = std.StringHashMap(*Symbol).init(self.allocator);
            try symbols.put(name, sym);
            try self.module_globals.put(span.source_id, symbols);
        }
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
            } else if (is_c_boundary and ty.isAggregate() and aggregateBoundaryClass(ty) == null) {
                try self.reporter.err("E0473", param.span, "aggregate parameter '{s}' is not supported by the current C ABI target; pass a pointer or use a supported aggregate layout", .{param.name});
            }
            params[i] = ty;
        }

        const ret = if (fd.ret_expr) |ret_expr| blk: {
            const ty = try self.resolveType(ret_expr);
            break :blk ty;
        } else self.prims.void;

        if (is_c_boundary and ret.isAggregate() and aggregateBoundaryClass(ret) == null) {
            try self.reporter.err("E0473", fd.span, "aggregate return type is not supported by the current C ABI target; return a pointer or use a supported aggregate layout", .{});
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

    fn isSymbolVisible(self: *const Sema, sym: *const Symbol, from_module_id: u32) bool {
        _ = self;
        return sym.is_public or sym.owner_module_id == from_module_id;
    }

    fn isTypeAccessible(self: *const Sema, ty: *Type, from_module_id: u32) bool {
        return switch (ty.*) {
            .pointer => |p| self.isTypeAccessible(p.elem, from_module_id),
            .array => |a| self.isTypeAccessible(a.elem, from_module_id),
            .slice => |s| self.isTypeAccessible(s.elem, from_module_id),
            .struct_type => |info| info.is_public or info.owner_module_id == from_module_id,
            .enum_type => |info| info.is_public or info.owner_module_id == from_module_id,
            else => true,
        };
    }

    fn lookupLocal(self: *const Sema, name: []const u8) ?*Symbol {
        var scope = self.scope;
        while (scope) |s| {
            if (s.symbols.get(name)) |sym| return sym;
            scope = s.parent;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Type resolution
    // ------------------------------------------------------------------

    pub fn resolveType(self: *Sema, te: *ast.TypeExpr) Error!*Type {
        if (te.resolved) |ty| return ty;
        const ty: *Type = switch (te.kind) {
            .name => |name| blk: {
                if (self.primitiveByName(name)) |prim| break :blk prim;
                const resolved = if (std.mem.indexOfScalar(u8, name, '.')) |dot| blk2: {
                    const alias = name[0..dot];
                    const member = name[dot + 1 ..];
                    const target = self.moduleAliasTarget(te.span.source_id, alias) orelse {
                        try self.reporter.err("E0469", te.span, "unknown module alias '{s}'", .{alias});
                        break :blk self.prims.invalid;
                    };
                    const member_sym = self.moduleSymbol(target, member) orelse {
                        try self.reporter.err("E0470", te.span, "module '{s}' has no type named '{s}'", .{ alias, member });
                        break :blk self.prims.invalid;
                    };
                    if (member_sym.kind != .struct_type and member_sym.kind != .enum_type) {
                        try self.reporter.err("E0422", te.span, "'{s}' is not a type in module '{s}'", .{ member, alias });
                        break :blk self.prims.invalid;
                    }
                    if (!self.isSymbolVisible(member_sym, te.span.source_id)) {
                        try self.reporter.err("E0467", te.span, "type '{s}' is private to another module", .{name});
                        break :blk self.prims.invalid;
                    }
                    break :blk2 member_sym.ty;
                } else blk2: {
                    switch (try self.resolveModuleName(te.span.source_id, name)) {
                        .found => |sym| {
                            if (sym.kind == .struct_type or sym.kind == .enum_type) break :blk2 sym.ty;
                            try self.reporter.err("E0422", te.span, "'{s}' is not a type", .{name});
                        },
                        .private => try self.reporter.err("E0467", te.span, "type '{s}' is private to another module", .{name}),
                        .ambiguous => try self.reporter.err("E0471", te.span, "unqualified type name '{s}' is ambiguous; use an import alias", .{name}),
                        .missing => try self.reporter.err("E0422", te.span, "unknown type '{s}'", .{name}),
                    }
                    break :blk2 self.prims.invalid;
                };
                break :blk resolved;
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
            .slice => |slice| try self.checkSlice(expr, slice, expected),
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
        const prior_errors = self.reporter.error_count;
        const sym = (try self.lookupValue(ident.name, expr.span.source_id, expr.span)) orelse {
            if (self.reporter.error_count == prior_errors) {
                try self.reporter.err("E0427", expr.span, "unknown identifier '{s}'", .{ident.name});
            }
            expr.ty = self.prims.invalid;
            return self.prims.invalid;
        };
        if (!self.isSymbolVisible(sym, expr.span.source_id)) {
            try self.reporter.err("E0467", expr.span, "declaration '{s}' is private to another module", .{ident.name});
            expr.ty = self.prims.invalid;
            return self.prims.invalid;
        }
        if (sym.kind != .function and !self.isTypeAccessible(sym.ty, expr.span.source_id)) {
            try self.reporter.err("E0467", expr.span, "type of declaration '{s}' is private to another module", .{ident.name});
            expr.ty = self.prims.invalid;
            return self.prims.invalid;
        }
        ident.sym = sym;
        expr.ty = sym.ty;
        return sym.ty;
    }

    fn checkUnary(self: *Sema, expr: *ast.Expr, unary: ast.Expr.Kind.Unary) Error!*Type {
        switch (unary.op) {
            .address_of => {
                const operand_ty = try self.checkExpr(unary.operand, null);
                if (operand_ty.* != .invalid and !self.isLvalue(unary.operand)) {
                    try self.reporter.err("E0464", expr.span, "cannot take address of non-lvalue", .{});
                    return self.prims.invalid;
                }
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
                if (lhs_ty.isPointer() and rhs_ty.* == .comptime_int) {
                    if (try self.applyLiteralType(binary.rhs, rhs_ty, self.prims.isize)) {
                        rhs_ty = self.prims.isize;
                    } else {
                        try self.reporter.err("E0440", expr.span, "integer literal does not fit type 'isize'", .{});
                        return self.prims.invalid;
                    }
                }
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
        if (callee_ty.* == .invalid) {
            for (call.args) |arg| _ = try self.checkExpr(arg, null);
            return self.prims.invalid;
        }
        if (callee_ty.* != .fn_type) {
            try self.reporter.err("E0445", call.callee.span, "cannot call value of type '{s}'", .{self.typeName(callee_ty)});
            for (call.args) |arg| _ = try self.checkExpr(arg, null);
            return self.prims.invalid;
        }
        const fn_info = callee_ty.fn_type;
        if (!self.isTypeAccessible(fn_info.ret, expr.span.source_id)) {
            try self.reporter.err("E0467", call.callee.span, "function return type is private to another module", .{});
        }
        if (call.args.len != fn_info.params.len) {
            try self.reporter.err("E0446", expr.span, "function expects {d} argument(s), found {d}", .{
                fn_info.params.len, call.args.len,
            });
        }
        const count = @min(call.args.len, fn_info.params.len);
        for (call.args, 0..) |arg, i| {
            if (i < count) {
                const param_ty = fn_info.params[i];
                if (!self.isTypeAccessible(param_ty, arg.span.source_id)) {
                    try self.reporter.err("E0467", arg.span, "function parameter type is private to another module", .{});
                }
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
            .slice => self.isSliceCast(source_ty, target_ty),
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
            if (source_info.is_const and !target_info.is_const) return false;
            return Type.eql(target_info.elem, array.elem);
        }
        return target_ty.isPointer() or target_ty.isInteger() or target_ty.* == .bool;
    }

    fn isSliceCast(self: *const Sema, source_ty: *Type, target_ty: *Type) bool {
        _ = self;
        if (source_ty.* != .slice or target_ty.* != .slice) return false;
        const source_info = source_ty.slice;
        const target_info = target_ty.slice;
        if (source_info.is_const and !target_info.is_const) return false;
        return Type.eql(source_info.elem, target_info.elem);
    }

    fn checkSlice(
        self: *Sema,
        expr: *ast.Expr,
        slice_expr: ast.Expr.Kind.SliceAccess,
        expected: ?*Type,
    ) Error!*Type {
        const base_ty = try self.checkExpr(slice_expr.base, null);
        if (slice_expr.start) |start_expr| {
            const start_ty = try self.checkExpr(start_expr, null);
            if (!self.isIntegerType(start_ty) and start_ty.* != .comptime_int) {
                try self.reporter.err("E0454", start_expr.span, "slice start must be an integer, found '{s}'", .{self.typeName(start_ty)});
            }
        }
        if (slice_expr.end) |end_expr| {
            const end_ty = try self.checkExpr(end_expr, null);
            if (!self.isIntegerType(end_ty) and end_ty.* != .comptime_int) {
                try self.reporter.err("E0454", end_expr.span, "slice end must be an integer, found '{s}'", .{self.typeName(end_ty)});
            }
        }

        var elem: *Type = self.prims.invalid;
        var is_const = false;
        switch (base_ty.*) {
            .array => |array| {
                if (!self.isLvalue(slice_expr.base)) {
                    try self.reporter.err("E0466", slice_expr.base.span, "slicing requires an lvalue array, a pointer to an array or a slice", .{});
                }
                elem = array.elem;
                is_const = !self.lvalueMutable(slice_expr.base);
            },
            .pointer => |pointer| {
                if (pointer.elem.* != .array) {
                    try self.reporter.err("E0455", slice_expr.base.span, "slicing a pointer requires a pointer to an array", .{});
                    return self.prims.invalid;
                }
                elem = pointer.elem.array.elem;
                is_const = pointer.is_const;
            },
            .slice => |slice| {
                elem = slice.elem;
                is_const = slice.is_const;
            },
            .invalid => return self.prims.invalid,
            else => {
                try self.reporter.err("E0455", slice_expr.base.span, "cannot slice value of type '{s}'", .{self.typeName(base_ty)});
                return self.prims.invalid;
            },
        }

        if (!is_const) {
            if (expected) |exp| {
                if (exp.* == .slice and exp.slice.is_const and Type.eql(exp.slice.elem, elem)) {
                    is_const = true;
                }
            }
        }

        const ty = try types.makeSlice(self.allocator, elem, is_const);
        expr.ty = ty;
        return ty;
    }

    fn checkField(self: *Sema, expr: *ast.Expr, field: *ast.Expr.Kind.Field) Error!*Type {
        if (field.base.kind == .ident) {
            const alias = field.base.kind.ident.name;
            const shadowed_by_name = self.lookupLocal(alias) != null or switch (try self.resolveModuleName(expr.span.source_id, alias)) {
                .found, .ambiguous => true,
                .missing, .private => false,
            };
            if (!shadowed_by_name) {
                if (self.moduleAliasTarget(expr.span.source_id, alias)) |target| {
                    if (field.through_pointer) {
                        try self.reporter.err("E0451", expr.span, "module alias access uses '.', not '->'", .{});
                        return self.prims.invalid;
                    }
                    const sym = self.moduleSymbol(target, field.name) orelse {
                        try self.reporter.err("E0470", expr.span, "module '{s}' has no declaration named '{s}'", .{ alias, field.name });
                        return self.prims.invalid;
                    };
                    if (!self.isSymbolVisible(sym, expr.span.source_id) or
                        (sym.kind != .function and !self.isTypeAccessible(sym.ty, expr.span.source_id)))
                    {
                        try self.reporter.err("E0467", expr.span, "declaration '{s}.{s}' is private to another module", .{ alias, field.name });
                        return self.prims.invalid;
                    }
                    field.sym = sym;
                    return sym.ty;
                }
            }
        }
        const base_ty = try self.checkExpr(field.base, null);
        if (base_ty.* == .invalid) return self.prims.invalid;

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

        if (struct_ty.* == .slice) {
            if (std.mem.eql(u8, field.name, "ptr")) {
                field.field_index = 0;
                return types.makePointer(self.allocator, struct_ty.slice.elem, struct_ty.slice.is_const);
            }
            if (std.mem.eql(u8, field.name, "len")) {
                field.field_index = 1;
                return self.prims.usize;
            }
            try self.reporter.err("E0453", expr.span, "slice has no field '{s}'", .{field.name});
            return self.prims.invalid;
        }

        if (struct_ty.* == .array) {
            if (std.mem.eql(u8, field.name, "len")) {
                field.field_index = 1;
                return self.prims.usize;
            }
            try self.reporter.err("E0453", expr.span, "array has no field '{s}'", .{field.name});
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
                if (!self.isTypeAccessible(struct_field.ty, expr.span.source_id)) {
                    try self.reporter.err("E0467", expr.span, "field type is private to another module", .{});
                    return self.prims.invalid;
                }
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
        if (ty.* == .invalid) {
            for (initializer.fields) |field| _ = try self.checkExpr(field.value, null);
            return self.prims.invalid;
        }
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
                    if (!self.isTypeAccessible(struct_field.ty, expr.span.source_id)) {
                        try self.reporter.err("E0467", field.span, "field type is private to another module", .{});
                    }
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
        if (target.* == .invalid or value_ty.* == .invalid) return;
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
        if (target.* == .slice and value_ty.* == .slice) {
            if (target.slice.is_const and !value_ty.slice.is_const and
                Type.eql(target.slice.elem, value_ty.slice.elem))
            {
                return true;
            }
        }
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
            .field => |field| blk: {
                if (field.sym) |sym| break :blk sym.kind == .global;
                if (field.is_enum_variant) break :blk false;
                const base_ty = field.base.ty orelse break :blk false;
                const target_ty = if (field.through_pointer and base_ty.* == .pointer) base_ty.pointer.elem else base_ty;
                if (target_ty.* == .slice or target_ty.* == .array) break :blk false;
                if (field.through_pointer and base_ty.* == .pointer) break :blk true;
                break :blk self.isLvalue(field.base);
            },
            .index => |index| blk: {
                if (index.base.ty) |base_ty| {
                    if (base_ty.* == .slice) break :blk true;
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
                if (field.sym) |sym| break :blk sym.kind == .global and sym.mutable;
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
                if (!field.through_pointer and std.mem.eql(u8, field.name, "len")) {
                    if (field.base.ty) |bt| {
                        if (bt.* == .array) return @intCast(bt.array.len);
                    }
                    if (field.base.kind == .ident) {
                        if (self.lookupLocal(field.base.kind.ident.name)) |sym| {
                            if (sym.ty.* == .array) return @intCast(sym.ty.array.len);
                        } else switch (try self.resolveModuleName(field.base.span.source_id, field.base.kind.ident.name)) {
                            .found => |sym| if (sym.ty.* == .array) return @intCast(sym.ty.array.len),
                            else => {},
                        }
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    // ------------------------------------------------------------------
    // Diagnostics helpers
    // ------------------------------------------------------------------

    pub fn typeName(self: *const Sema, ty: *Type) []const u8 {
        return switch (ty.*) {
            .invalid => "invalid",
            .void => "void",
            .bool => "bool",
            .char => "char",
            .int => |info| info.name(),
            .float => |bits| if (bits == 32) "f32" else "f64",
            .abi_vec2_f32 => "<internal ABI vector>",
            .abi_v2f32_f32 => "<internal ABI pair>",
            .abi_v2f32_v2f32 => "<internal ABI pair>",
            .abi_pair_f64 => "<internal ABI pair>",
            .abi_f64_i32 => "<internal ABI pair>",
            .abi_i32_f64 => "<internal ABI pair>",
            .pointer => |p| std.fmt.allocPrint(self.allocator, "*{s}{s}", .{
                if (p.is_const) "const " else "",
                self.typeName(p.elem),
            }) catch (if (p.is_const) "*const ?" else "*?"),
            .array => |a| std.fmt.allocPrint(self.allocator, "[{d}]{s}", .{
                a.len,
                self.typeName(a.elem),
            }) catch "[?]?",
            .slice => |s| std.fmt.allocPrint(self.allocator, "[]{s}{s}", .{
                if (s.is_const) "const " else "",
                self.typeName(s.elem),
            }) catch (if (s.is_const) "[]const ?" else "[]?"),
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

pub const BoundaryClass = enum {
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
    memory,
};

pub fn aggregateBoundaryClass(ty: *Type) ?BoundaryClass {
    if (builtin.target.os.tag != .linux or builtin.target.cpu.arch != .x86_64) return null;
    const layout = aggregateLayoutGuess(ty) orelse return null;
    if (layout.size <= 16) {
        var eightbytes = [_]AggregateEightbyte{ .{}, .{} };
        if (!classifyAggregateEightbytes(ty, 0, &eightbytes)) return null;
        if (ty.* == .struct_type and layout.size == 16) {
            const fields = ty.struct_type.fields;
            if (fields.len == 2 and
                fields[0].ty.* == .float and fields[0].ty.float == 64 and
                fields[1].ty.* == .float and fields[1].ty.float == 64)
            {
                // The System V ABI assigns the two eightbytes to separate XMM
                // registers; LLVM returns { double, double } and flattens the
                // two argument registers to scalar double parameters.
                return .sse_f64x2;
            }
            if (fields.len == 2 and
                fields[0].ty.* == .float and fields[0].ty.float == 64 and
                fields[1].ty.* == .int and fields[1].ty.int.bits == 32 and
                eightbytes[0].has_sse and !eightbytes[0].has_integer and
                eightbytes[1].has_integer and !eightbytes[1].has_sse)
            {
                // This exact natural layout merges to SSE in eightbyte 0 and
                // INTEGER in eightbyte 1: LLVM uses double/i32 parameters and
                // a { double, i32 } return coercion; signedness is irrelevant.
                return .sse_f64_i32;
            }
            if (fields.len == 2 and
                fields[0].ty.* == .int and fields[0].ty.int.bits == 32 and
                fields[1].ty.* == .float and fields[1].ty.float == 64 and
                eightbytes[0].has_integer and !eightbytes[0].has_sse and
                eightbytes[1].has_sse and !eightbytes[1].has_integer)
            {
                // The reverse exact layout is INTEGER then SSE. LLVM uses
                // i32/double parameters and a { i32, double } return value.
                // Integer signedness does not affect the register class.
                return .sse_i32_f64;
            }
        }
        const count: usize = @intCast((layout.size + 7) / 8);
        var sse_only_count: usize = 0;
        for (eightbytes[0..count]) |class| {
            if (class.has_sse and !class.has_integer) sse_only_count += 1;
        }
        if (sse_only_count != 0) {
            // At least one SSE-only eightbyte: accept only exact single-register
            // shapes (adjacent direct f32 runs, or one scalar float). Any other
            // mixture of SSE-only and INTEGER eightbytes is rejected.
            if (ty.* != .struct_type) return null;
            const fields = ty.struct_type.fields;
            var all_f32 = true;
            for (fields) |field| {
                if (field.ty.* != .float or field.ty.float != 32) {
                    all_f32 = false;
                    break;
                }
            }
            const field_count: usize = @intCast(fields.len);
            if (all_f32) {
                const expected_size: usize = field_count * 4;
                if (field_count == 1 and expected_size == 4 and sse_only_count == 1) return .sse_float;
                if (field_count == 2 and expected_size == 8 and sse_only_count == 1) return .sse_f32x2;
                if (field_count == 3 and expected_size == 12 and sse_only_count == 2) return .sse_f32x3;
                if (field_count == 4 and expected_size == 16 and sse_only_count == 2) return .sse_f32x4;
                return null;
            }
            if (fields.len == 1 and fields[0].ty.* == .float and sse_only_count == 1) {
                return switch (fields[0].ty.float) {
                    32 => .sse_float,
                    64 => .sse_double,
                    else => null,
                };
            }
            return null;
        }
    }
    if (layout.size <= 8) return .small_1;
    if (layout.size <= 16) return .small_2;
    return .memory;
}

const AggregateEightbyte = struct {
    has_integer: bool = false,
    has_sse: bool = false,
};

fn classifyAggregateEightbytes(
    ty: *Type,
    base_offset: u64,
    classes: *[2]AggregateEightbyte,
) bool {
    switch (ty.*) {
        .struct_type => |info| {
            var offset = base_offset;
            for (info.fields) |field| {
                const field_layout = aggregateLayoutGuess(field.ty) orelse return false;
                offset = std.mem.alignForward(u64, offset, field_layout.align_);
                if (!classifyAggregateEightbytes(field.ty, offset, classes)) return false;
                offset += field_layout.size;
            }
            return true;
        },
        .enum_type => |info| return classifyAggregateEightbytes(info.backing, base_offset, classes),
        .slice => return markAggregateEightbytes(classes, base_offset, 16, false),
        .float => |bits| return markAggregateEightbytes(classes, base_offset, bits / 8, true),
        .bool => return markAggregateEightbytes(classes, base_offset, 1, false),
        .char => return markAggregateEightbytes(classes, base_offset, 4, false),
        .int => |info| return markAggregateEightbytes(classes, base_offset, info.bits / 8, false),
        .pointer => return markAggregateEightbytes(classes, base_offset, 8, false),
        else => return false,
    }
}

fn markAggregateEightbytes(
    classes: *[2]AggregateEightbyte,
    offset: u64,
    size: u64,
    is_sse: bool,
) bool {
    if (size == 0) return true;
    const last_byte = offset + size - 1;
    if (last_byte >= 16) return false;
    const first: usize = @intCast(offset / 8);
    const last: usize = @intCast(last_byte / 8);
    for (classes[first .. last + 1]) |*class| {
        if (is_sse) {
            class.has_sse = true;
        } else {
            class.has_integer = true;
        }
    }
    return true;
}

pub const AggregateLayout = struct {
    size: u64,
    align_: u64,
};

pub fn aggregateLayoutGuess(ty: *Type) ?AggregateLayout {
    return switch (ty.*) {
        .slice => .{ .size = 16, .align_ = 8 },
        .struct_type => |info| blk: {
            var size: u64 = 0;
            var align_: u64 = 1;
            for (info.fields) |field| {
                const field_layout = aggregateLayoutGuess(field.ty) orelse return null;
                size = std.mem.alignForward(u64, size, field_layout.align_);
                size += field_layout.size;
                align_ = @max(align_, field_layout.align_);
            }
            size = std.mem.alignForward(u64, size, align_);
            break :blk .{ .size = size, .align_ = align_ };
        },
        .bool => .{ .size = 1, .align_ = 1 },
        .char => .{ .size = 4, .align_ = 4 },
        .int => |info| .{ .size = @intCast(info.bits / 8), .align_ = @intCast(@min(@as(u64, info.bits / 8), 16)) },
        .float => |bits| .{ .size = @intCast(bits / 8), .align_ = @intCast(bits / 8) },
        .pointer => .{ .size = 8, .align_ = 8 },
        .enum_type => |info| aggregateLayoutGuess(info.backing),
        else => null,
    };
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
        .field => |field| field.is_enum_variant or (!field.through_pointer and std.mem.eql(u8, field.name, "len") and blk: {
            const bt = field.base.ty orelse break :blk false;
            if (bt.* != .array) break :blk false;
            break :blk field.base.kind == .ident or isConstInitializer(field.base);
        }),
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

test "C ABI mixed INTEGER and SSE eightbytes accept exact direct layouts" {
    try expectSemanticError(
        \\struct Inner { count: i32 }
        \\struct Nested { inner: Inner, amount: f64 }
        \\extern fn c_take(value: Nested);
        \\fn main() i32 { return 0; }
    , "E0473");

    try expectSemanticError(
        \\struct WideInt { amount: f64, count: i64 }
        \\extern fn c_take(value: WideInt);
        \\fn main() i32 { return 0; }
    , "E0473");

    try expectSemanticError(
        \\struct WideInt { amount: f64, count: i64 }
        \\export fn kyn_make() WideInt { return WideInt { amount: 2.0, count: 1 }; }
        \\fn main() i32 { return 0; }
    , "E0473");

    try expectSemanticError(
        \\struct Inner { count: i32 }
        \\struct Nested { inner: Inner, amount: f64 }
        \\export fn kyn_make() Nested { return Nested { inner: Inner { count: 1 }, amount: 2.0 }; }
        \\fn main() i32 { return 0; }
    , "E0473");

    try expectClean(
        \\struct IntDouble { count: i32, amount: f64 }
        \\extern fn c_take(value: IntDouble) IntDouble;
        \\export fn kyn_identity(value: IntDouble) IntDouble { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct UIntDouble { count: u32, amount: f64 }
        \\extern fn c_take(value: UIntDouble) UIntDouble;
        \\export fn kyn_identity(value: UIntDouble) UIntDouble { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct DoubleInt { amount: f64, count: i32 }
        \\extern fn c_take(value: DoubleInt) DoubleInt;
        \\export fn kyn_identity(value: DoubleInt) DoubleInt { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct DoubleUInt { amount: f64, count: u32 }
        \\extern fn c_take(value: DoubleUInt) DoubleUInt;
        \\export fn kyn_identity(value: DoubleUInt) DoubleUInt { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct FloatInt { amount: f32, count: i32 }
        \\struct IntFloat { count: i32, amount: f32 }
        \\extern fn c_take_fi(value: FloatInt);
        \\extern fn c_take_if(value: IntFloat);
        \\export fn kyn_make_fi(amount: f32, count: i32) FloatInt {
        \\    return FloatInt { amount: amount, count: count };
        \\}
        \\export fn kyn_make_if(count: i32, amount: f32) IntFloat {
        \\    return IntFloat { count: count, amount: amount };
        \\}
        \\fn main() i32 { return 0; }
    );
}

test "unsupported C ABI aggregate parameters and returns use a dedicated diagnostic" {
    try expectSemanticError(
        \\fn takes_void(value: void) {}
        \\fn main() i32 { return 0; }
    , "E0410");

    try expectClean(
        \\struct FloatTriple { x: f32, y: f32, z: f32 }
        \\struct FloatQuad { x: f32, y: f32, z: f32, w: f32 }
        \\extern fn c_take_triple(value: FloatTriple) FloatTriple;
        \\extern fn c_take_quad(value: FloatQuad) FloatQuad;
        \\export fn kyn_identity_triple(value: FloatTriple) FloatTriple { return value; }
        \\export fn kyn_identity_quad(value: FloatQuad) FloatQuad { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectSemanticError(
        \\struct FloatIntFloat { x: f32, count: i32, y: f32 }
        \\extern fn c_take(value: FloatIntFloat);
        \\fn main() i32 { return 0; }
    , "E0473");

    try expectClean(
        \\struct FloatPair { x: f32, y: f32 }
        \\extern fn c_take(pair: FloatPair) FloatPair;
        \\export fn kyn_identity(pair: FloatPair) FloatPair { return pair; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct DoublePair { x: f64, y: f64 }
        \\extern fn c_take(pair: DoublePair) DoublePair;
        \\export fn kyn_identity(pair: DoublePair) DoublePair { return pair; }
        \\fn main() i32 { return 0; }
    );

    try expectSemanticError(
        \\struct DoublePair { x: f64, y: f64 }
        \\struct NestedPair { pair: DoublePair }
        \\extern fn c_take(pair: NestedPair);
        \\fn main() i32 { return 0; }
    , "E0473");

    try expectSemanticError(
        \\extern fn c_take(values: [2]i32);
        \\fn main() i32 { return 0; }
    , "E0473");
}

test "external functions accept aggregate parameters and returns in the C ABI" {
    try expectClean(
        \\struct Point { x: i32, y: i32 }
        \\extern fn c_sum(p: Point) i32;
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct Point { x: i32, y: i32 }
        \\export fn kyn_make(x: i32, y: i32) Point {
        \\    return Point { x: x, y: y };
        \\}
        \\fn main() i32 { return 0; }
    );
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

test "slices are accepted at C ABI boundaries with pointer+length layout" {
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

    try expectClean(
        \\extern fn c_sum(values: []i32) i32;
        \\fn main() i32 { return 0; }
    );
}

test "const slices can be created from immutable arrays and read" {
    try expectClean(
        \\fn sum(values: []const i32) i32 {
        \\    var total: i32 = 0;
        \\    var index: usize = 0;
        \\    while (index < values.len) {
        \\        total += values[index];
        \\        index += 1;
        \\    }
        \\    return total;
        \\}
        \\fn main() i32 {
        \\    let values: [3]i32 = [1, 2, 3];
        \\    let slice: []const i32 = &values as []const i32;
        \\    return sum(slice);
        \\}
    );
}

test "const slices can be assigned from mutable slices but not upgraded" {
    try expectClean(
        \\fn main() i32 {
        \\    var values: [3]i32 = [1, 2, 3];
        \\    let slice: []i32 = &values as []i32;
        \\    let read_only: []const i32 = slice as []const i32;
        \\    return read_only[0];
        \\}
    );

    try expectSemanticError(
        \\fn main() i32 {
        \\    let values: [3]i32 = [1, 2, 3];
        \\    let read_only: []const i32 = &values as []const i32;
        \\    let writable: []i32 = read_only as []i32;
        \\    return writable[0];
        \\}
    , "E0447");
}

test "const slices reject indexed assignment" {
    try expectSemanticError(
        \\fn main() i32 {
        \\    let values: [3]i32 = [1, 2, 3];
        \\    let slice: []const i32 = &values as []const i32;
        \\    slice[0] = 9;
        \\    return slice[0];
        \\}
    , "E0442");
}

test "mutable and immutable subslices are typed and bounds-checked" {
    try expectClean(
        \\fn main() i32 {
        \\    var values: [5]i32 = [1, 2, 3, 4, 5];
        \\    let whole: []i32 = &values as []i32;
        \\    let part: []i32 = whole[1..3];
        \\    part[0] = 20;
        \\    let empty: []i32 = whole[2..2];
        \\    return values[1] + empty.len as i32 + part[0];
        \\}
    );

    try expectSemanticError(
        \\fn main() i32 {
        \\    let values: [5]i32 = [1, 2, 3, 4, 5];
        \\    let part: []const i32 = values[1..3];
        \\    part[0] = 20;
        \\    return values[1];
        \\}
    , "E0442");
}

test "open-ended slicing and const-polymorphic slice coercion" {
    try expectClean(
        \\const GLOBAL_ARR: [4]i32 = [1, 2, 3, 4];
        \\fn sum(xs: []const i32) i32 {
        \\    return xs.len as i32;
        \\}
        \\fn main() i32 {
        \\    var a: [4]i32 = [10, 20, 30, 40];
        \\    let b: [4]i32 = [1, 2, 3, 4];
        \\    let rw: []i32 = a[..];
        \\    let ro1: []const i32 = rw;
        \\    let ro2: []const i32 = a[1..];
        \\    let ro3: []const i32 = b[..3];
        \\    let ro4: []const i32 = GLOBAL_ARR[..];
        \\    return sum(rw) + sum(ro1) + sum(ro2) + sum(ro3) + sum(ro4) + sum(a[..2]);
        \\}
    );

    try expectSemanticError(
        \\fn main() i32 {
        \\    let b: [4]i32 = [1, 2, 3, 4];
        \\    let bad: []i32 = b[..];
        \\    return bad.len as i32;
        \\}
    , "E0462");

    try expectSemanticError(
        \\fn main() i32 {
        \\    var inner: [2]i32 = [1, 2];
        \\    var outer: [1][]i32 = [inner[..]];
        \\    let s: [][]i32 = outer[..];
        \\    let bad: [][]const i32 = s;
        \\    return bad.len as i32;
        \\}
    , "E0462");
}

test "slice ptr, array len, lvalue and address-of rules" {
    try expectClean(
        \\const DATA: [3]i32 = [4, 5, 6];
        \\const DATA_LEN: usize = DATA.len;
        \\fn main() i32 {
        \\    var a: [DATA.len]i32 = [10, 20, 30];
        \\    var s: []i32 = a[..];
        \\    let cs: []const i32 = a[..];
        \\    let p: *i32 = s.ptr;
        \\    let cp: *const i32 = cs.ptr;
        \\    *(p + 1) = 99;
        \\    let sp: *[]i32 = &s;
        \\    return (*cp) + a[1] + (sp->len as i32) + (*(sp->ptr) ) + (DATA_LEN as i32);
        \\}
    );

    try expectSemanticError(
        \\fn main() i32 {
        \\    var a: [2]i32 = [1, 2];
        \\    var s: []i32 = a[..];
        \\    s.len = 1;
        \\    return 0;
        \\}
    , "E0441");

    try expectSemanticError(
        \\fn main() i32 {
        \\    var a: [2]i32 = [1, 2];
        \\    var s: []i32 = a[..];
        \\    s.ptr = &a[0];
        \\    return 0;
        \\}
    , "E0441");

    try expectSemanticError(
        \\fn main() i32 {
        \\    let p = &42;
        \\    return *p;
        \\}
    , "E0464");

    try expectSemanticError(
        \\const IMMUT: i32 = 7;
        \\fn main() i32 {
        \\    IMMUT = 8;
        \\    return IMMUT;
        \\}
    , "E0442");

    try expectClean(
        \\enum Sign {
        \\    Neg = -1,
        \\    Zero = 0,
        \\    Pos = 1,
        \\}
        \\fn main() i32 {
        \\    return (Sign.Neg as i32) + (Sign.Pos as i32);
        \\}
    );
}
