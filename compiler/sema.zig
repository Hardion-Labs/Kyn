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
    /// The target whose C ABI the boundary checks apply. Defaults to the host,
    /// which is the only target the System V classifier is defined for; the
    /// driver sets it from `--target` so a cross-compilation rejects C
    /// boundaries it cannot lower instead of emitting the wrong convention.
    target_supports_c_abi: bool = builtin.target.os.tag == .linux and builtin.target.cpu.arch == .x86_64,

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
                        .is_union = sd.is_union,
                        .is_packed = sd.is_packed,
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
                        sym.is_variadic = fd.is_variadic;
                    }
                },
                .var_decl => |vd| {
                    const placeholder = try self.allocator.create(Type);
                    placeholder.* = .invalid;
                    const existed = self.moduleSymbol(decl.span.source_id, vd.name) != null;
                    // An exported global is link-visible, so its symbol is the
                    // source spelling rather than the module-mangled one a
                    // Kyn-only global gets.
                    vd.sym = try self.declareGlobal(vd.name, .global, placeholder, decl.span, decl.is_public, vd.is_export);
                    if (!existed) {
                        if (vd.sym) |sym| {
                            sym.mutable = vd.mutable;
                            sym.is_export = vd.is_export;
                        }
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

    /// What to call an aggregate in a diagnostic. A union is not a struct, and
    /// saying "struct 'V'" about a union sends the reader to the wrong
    /// declaration.
    fn aggregateLabel(self: *Sema, info: *types.StructInfo) []const u8 {
        _ = self;
        return if (info.is_union) "union" else "struct";
    }

    fn resolveStruct(self: *Sema, sd: *ast.StructDecl) Error!void {
        const info = sd.ty.?.struct_type;
        if (info.complete) return;
        if (info.resolving) {
            try self.reporter.err("E0403", sd.span, "{s} '{s}' contains itself by value", .{ self.aggregateLabel(info), sd.name });
            return;
        }
        info.resolving = true;

        var fields = try self.allocator.alloc(types.Field, sd.fields.len);
        var seen = std.StringHashMap(void).init(self.allocator);
        // Whether *this* declaration failed, as opposed to an earlier one in the
        // same file: a global "any error so far" check would skip the layout of
        // every later, perfectly valid type in a file with one bad line.
        var unusable = false;
        for (sd.fields, 0..) |*field, i| {
            if (seen.contains(field.name)) {
                try self.reporter.err("E0404", field.span, "duplicate field '{s}' in {s} '{s}'", .{ field.name, self.aggregateLabel(info), sd.name });
            } else {
                try seen.put(field.name, {});
            }
            const ty = try self.resolveType(field.ty_expr);
            if (containsIncompleteByValue(ty)) {
                try self.reporter.err("E0403", field.span, "{s} '{s}' contains itself by value", .{ self.aggregateLabel(info), sd.name });
                unusable = true;
            }
            field.ty = ty;
            fields[i] = .{ .name = field.name, .ty = ty, .index = @intCast(i) };
        }
        info.fields = fields;
        // If a field's type could not be resolved the aggregate has no layout to
        // compute, and walking it would recurse through the unfinished member --
        // a by-value cycle is exactly the case `E0403` above reported. Placement
        // is skipped and the aggregate stays incomplete, which every consumer
        // already treats as "not layoutable".
        if (unusable) {
            info.resolving = false;
            return;
        }
        if (info.is_union) {
            // A union's members overlap, so two runs would have no defined bit
            // positions: there is no layout to give them. Rejected here rather
            // than given a rule that would be a guess.
            for (info.fields) |f| {
                if (isBitfield(f.ty)) {
                    try self.reporter.err("E0487", sd.span, "a union member cannot be a bitfield: overlapping runs would have no defined bit positions", .{});
                    break;
                }
            }
        }
        // Placement is part of resolution because it walks the same fields the
        // checks above just saw, and because every later consumer -- the emitter,
        // the classifier, `field_ptr` -- reads `info.placed`.
        placeFields(self.allocator, info) catch |err| switch (err) {
            error.UnknownLayout => {
                try self.reporter.err("E0488", sd.span, "aggregate '{s}' has a member with no known size", .{info.name});
            },
            error.UnrepresentableBitfield => {
                try self.reporter.err("E0489", sd.span, "aggregate '{s}' has a bitfield layout the emitted type cannot mirror: a run would overlap storage already emitted", .{info.name});
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
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
        // A variadic declaration is C-only and inbound-unspecified: C is what
        // supplies the trailing arguments, so the declaration must either be
        // `extern` (Kyn calls out, promoting at each call site) or `export` (C
        // calls in and `va_arg()` retrieves). A plain Kyn function is called
        // only from Kyn, where the signature is fixed and checked.
        if (fd.is_variadic and !fd.is_extern and !fd.is_export) {
            try self.reporter.err("E0474", fd.span, "variadic function '{s}' must be 'export' or 'extern'; a Kyn function is called with a fixed signature", .{fd.name});
        }
        // ISO C requires a named parameter before the `...`, and the rule exists
        // for the same reason here: with no fixed parameter there is nothing to
        // anchor the call and every argument would be inferred.
        if (fd.is_variadic and fd.params.len == 0) {
            try self.reporter.err("E0474", fd.span, "variadic declaration '{s}' needs at least one fixed parameter before '...'", .{fd.name});
        }
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
            } else if (is_c_boundary and ty.isAggregate() and self.boundaryClass(ty) == null) {
                try self.reporter.err("E0473", param.span, "aggregate parameter '{s}' is not supported by the current C ABI target; pass a pointer or use a supported aggregate layout", .{param.name});
            }
            params[i] = ty;
        }

        const ret = if (fd.ret_expr) |ret_expr| blk: {
            const ty = try self.resolveType(ret_expr);
            break :blk ty;
        } else self.prims.void;

        if (is_c_boundary and ret.isAggregate() and self.boundaryClass(ret) == null) {
            try self.reporter.err("E0473", fd.span, "aggregate return type is not supported by the current C ABI target; return a pointer or use a supported aggregate layout", .{});
        }
        const fn_ty = try types.makeFn(self.allocator, params, ret);
        fd.ty = fn_ty;
        if (fd.sym) |sym| {
            sym.ty = fn_ty;
            sym.is_extern = fd.is_extern;
            sym.is_export = fd.is_export;
            sym.is_variadic = fd.is_variadic;
        }
        try self.checkEntryPoint(fd, params, ret);
    }

    /// The root module's `main` is the process entry point the C runtime calls,
    /// so its signature is not free: the caller passes `argc` and the vector of
    /// argument strings and reads an `int` back. Anything else links and then
    /// misbehaves at run time — a three-parameter `main` reads a register the
    /// loader never set, and a `f64` return makes the exit status meaningless —
    /// so it is diagnosed here instead of being discovered later. A library
    /// (`staticlib`/`sharedlib`) may legitimately expose a `main` with another
    /// shape, so only the unmarked root declaration is treated as the entry
    /// point; an `extern` one is a C declaration, not a definition.
    fn checkEntryPoint(self: *Sema, fd: *ast.FnDecl, params: []*Type, ret: *Type) Error!void {
        if (fd.is_extern or fd.is_export) return;
        if (fd.span.source_id != 0 or !std.mem.eql(u8, fd.name, "main")) return;
        if (fd.is_variadic) return;

        if (params.len > 2) {
            try self.reporter.err("E0477", fd.span, "entry point 'main' takes at most 'argc: i32' and 'argv: **u8', found {d} parameters", .{params.len});
            return;
        }
        if (params.len >= 1 and !(params[0].* == .int and params[0].int.bits == 32 and params[0].int.signed)) {
            try self.reporter.err("E0477", fd.span, "entry point 'main' parameter 1 must be 'i32', found '{s}'", .{self.typeName(params[0])});
        }
        if (params.len == 2 and !isArgvType(params[1])) {
            try self.reporter.err("E0477", fd.span, "entry point 'main' parameter 2 must be '**u8', found '{s}'", .{self.typeName(params[1])});
        }
        if (!(ret.* == .int and ret.int.bits == 32 and ret.int.signed)) {
            try self.reporter.err("E0477", fd.span, "entry point 'main' must return 'i32', found '{s}'", .{self.typeName(ret)});
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

        // An exported global is a C object, so its type is a boundary the same
        // way an exported function's parameter is: one the target cannot lay
        // out would be read at the wrong offsets by the C side. Only aggregates
        // need this filter. `void` is already rejected as storage by `E0411`,
        // and a function value is a plain pointer, which C represents natively.
        if (vd.is_export) {
            if (vd.ty) |ty| {
                if (ty.* != .invalid and ty.isAggregate() and self.boundaryClass(ty) == null) {
                    try self.reporter.err("E0476", vd.ty_expr.?.span, "exported global '{s}' has a layout that is not supported by the current C ABI target", .{vd.name});
                }
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
                // `u3`/`i7` are not keywords: a type name is the only place they
                // can appear, so they are recognised here rather than in the
                // lexer, where reserving every `u<digits>` spelling would also
                // steal ordinary identifiers such as `u1x`.
                if (types.parseIntWidthName(name)) |width| {
                    if (try self.prims.intOfWidth(width.bits, width.signed)) |width_ty| break :blk width_ty;
                    try self.reporter.err("E0486", te.span, "integer type '{s}' has no valid width: the width must be 1 to {d}", .{ name, types.max_int_bits });
                    break :blk self.prims.invalid;
                }
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
            .fn_type => |signature_expr| blk: {
                // The signature is resolved into the ordinary function type and
                // then wrapped as a first-class value, so there is exactly one
                // `FnInfo` shape in the compiler: a `fn(..) R` type and the
                // declaration it is initialised from compare equal.
                var params = try self.allocator.alloc(*Type, signature_expr.params.len);
                for (signature_expr.params, 0..) |param, i| {
                    params[i] = try self.resolveType(param.ty_expr);
                }
                const ret = if (signature_expr.ret) |ret_expr| try self.resolveType(ret_expr) else self.prims.void;
                const signature = try types.makeFn(self.allocator, params, ret);
                break :blk try types.makeFnPtr(self.allocator, signature);
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
            .call => |*call| try self.checkCall(expr, call),
            .va_arg => |*va_arg| try self.checkVaArg(expr, va_arg, expected),
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

    /// The boundary class of an aggregate for this compilation's target.
    fn boundaryClass(self: *Sema, ty: *Type) ?BoundaryClass {
        return aggregateBoundaryClassFor(ty, self.target_supports_c_abi);
    }

    fn checkIntLiteral(self: *Sema, expr: *ast.Expr, value: u128, expected: ?*Type) Error!*Type {
        if (expected) |e| {
            if (e.isInteger()) {
                const info = e.intInfo();
                if (value > info.max() and !(info.signed and value == info.minMagnitude())) {
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
        // A function name used in value position is its address: that is what
        // makes `let f: fn(i32) i32 = double;` and passing `double` as an
        // argument work. In call position `checkCall` reads the symbol
        // directly, so the decay never changes how a direct call lowers.
        if (sym.kind == .function and sym.ty.* == .fn_type) {
            const value_ty = try types.makeFnPtr(self.allocator, sym.ty);
            expr.ty = value_ty;
            return value_ty;
        }
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
                // A function value is a pointer, so a null comparison is the
                // ordinary "is this callback set?" test and must compare at the
                // pointer's own type.
                if (lhs_ty.* == .null_type and (rhs_ty.isPointer() or rhs_ty.* == .fn_ptr)) {
                    binary.lhs.ty = rhs_ty;
                    return self.prims.bool;
                }
                if (rhs_ty.* == .null_type and (lhs_ty.isPointer() or lhs_ty.* == .fn_ptr)) {
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
        // A literal above `i128`'s maximum has no `i128` spelling, so the
        // unsigned magnitude is consulted first; only when the expression is
        // not a bare literal does the signed path apply.
        if (literalUnsignedValue(expr)) |magnitude| {
            if (!to.intInfo().fitsUnsigned(magnitude)) return false;
            expr.ty = to;
            return true;
        }
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

    /// `va_arg()` retrieves one argument a C caller appended after the fixed
    /// parameters of a variadic `export fn`. It has no type of its own, so it
    /// takes the expected type at the position where it is written — the same
    /// rule integer literals follow. There is deliberately no default: guessing
    /// `i32` would read a `double` out of the wrong half of the register save
    /// area and produce a plausible wrong number instead of a diagnostic.
    fn checkVaArg(self: *Sema, expr: *ast.Expr, va_arg: *ast.Expr.Kind.VaArg, expected: ?*Type) Error!*Type {
        // The function that receives `...` is the only one whose frame has a
        // `va_list` to walk, so there is nothing to retrieve anywhere else.
        const fn_decl = self.currentFunction();
        if (fn_decl == null or !fn_decl.?.is_variadic) {
            try self.reporter.err("E0480", expr.span, "'va_arg()' is only valid inside a variadic function", .{});
            expr.ty = self.prims.invalid;
            return self.prims.invalid;
        }
        const want = expected orelse {
            try self.reporter.err("E0478", expr.span, "'va_arg()' needs to know the type it retrieves; annotate the binding or cast the result", .{});
            expr.ty = self.prims.invalid;
            return self.prims.invalid;
        };
        if (want.* == .invalid) {
            expr.ty = self.prims.invalid;
            return self.prims.invalid;
        }
        // Only a value that can actually travel through `...` can come back
        // out; an aggregate or a slice has no place in an argument list, and a
        // `void` or a literal type has no representation at all.
        switch (want.*) {
            .int, .float, .bool, .char, .enum_type, .pointer, .fn_type, .fn_ptr => {},
            else => {
                try self.reporter.err("E0478", expr.span, "'va_arg()' needs a concrete scalar type from context, found '{s}'", .{self.typeName(want)});
                expr.ty = self.prims.invalid;
                return self.prims.invalid;
            },
        }
        // The promotion table is the call site's, so "what C passes" is defined
        // in exactly one place on both sides of the boundary.
        var probe = ast.Expr{ .span = expr.span, .kind = .{ .call = .{ .callee = expr, .args = &.{} } } };
        const promoted = try self.promoteVariadic(&probe, want);
        if (promoted.* == .invalid) {
            expr.ty = self.prims.invalid;
            return self.prims.invalid;
        }
        // C promotes every variadic argument by default, so only the widths the
        // caller actually passed can be retrieved. Asking for `i8` would read a
        // register the caller wrote as `i32`.
        if (promoted != want) {
            try self.reporter.err("E0479", expr.span, "cannot retrieve '{s}' with 'va_arg()'; C passes it as '{s}', so retrieve '{s}'", .{
                self.typeName(want),
                self.typeName(promoted),
                self.typeName(promoted),
            });
            expr.ty = self.prims.invalid;
            return self.prims.invalid;
        }
        va_arg.ty = want;
        expr.ty = want;
        return want;
    }

    fn checkCall(self: *Sema, expr: *ast.Expr, call: *ast.Expr.Kind.Call) Error!*Type {
        const callee_ty = try self.checkExpr(call.callee, null);
        if (callee_ty.* == .invalid) {
            for (call.args) |arg| _ = try self.checkExpr(arg, null);
            return self.prims.invalid;
        }
        // A callee is either a declared function or a first-class function
        // value; both reduce to one signature, so the argument checks below run
        // once for either form.
        const fn_info = switch (callee_ty.*) {
            .fn_type => |info| info,
            .fn_ptr => |info| info,
            else => {
                try self.reporter.err("E0445", call.callee.span, "cannot call value of type '{s}'", .{self.typeName(callee_ty)});
                for (call.args) |arg| _ = try self.checkExpr(arg, null);
                return self.prims.invalid;
            },
        };
        const declares_variadic = switch (call.callee.kind) {
            .ident => |ident| if (ident.sym) |sym| sym.is_variadic else false,
            .field => |field| if (field.sym) |sym| sym.is_variadic else false,
            else => false,
        };
        call.is_variadic = declares_variadic;
        const is_variadic = declares_variadic;
        if (!self.isTypeAccessible(fn_info.ret, expr.span.source_id)) {
            try self.reporter.err("E0467", call.callee.span, "function return type is private to another module", .{});
        }
        if (!is_variadic and call.args.len != fn_info.params.len) {
            try self.reporter.err("E0446", expr.span, "function expects {d} argument(s), found {d}", .{
                fn_info.params.len, call.args.len,
            });
        } else if (is_variadic and call.args.len < fn_info.params.len) {
            try self.reporter.err("E0446", expr.span, "function expects at least {d} argument(s), found {d}", .{
                fn_info.params.len, call.args.len,
            });
        }
        const count = @min(call.args.len, fn_info.params.len);
        var arg_types = try self.allocator.alloc(*Type, call.args.len);
        for (call.args, 0..) |arg, i| {
            if (i < count) {
                const param_ty = fn_info.params[i];
                if (!self.isTypeAccessible(param_ty, arg.span.source_id)) {
                    try self.reporter.err("E0467", arg.span, "function parameter type is private to another module", .{});
                }
                const arg_ty = try self.checkExpr(arg, param_ty);
                try self.requireAssignable(param_ty, arg, arg_ty, false);
                arg_types[i] = param_ty;
            } else {
                // A variadic argument has no declared type, so it is checked
                // against none and then given the type the C default argument
                // promotions produce. That type is recorded as the type the call
                // passes, so the back end emits exactly the promoted value: a
                // struct, an array or a slice cannot be passed, mirroring C's
                // constraint.
                const arg_ty = try self.checkExpr(arg, null);
                arg_types[i] = try self.promoteVariadic(arg, arg_ty);
            }
        }
        call.arg_types = arg_types;
        return fn_info.ret;
    }

    /// The type an argument to a variadic `extern` call travels as, following
    /// the C default argument promotions: integer types narrower than `i32`
    /// widen to `i32` (keeping signedness), `f32` widens to `f64`, and every
    /// other scalar keeps its type. An aggregate has no default promotion, so
    /// passing one is rejected instead of being converted silently.
    fn promoteVariadic(self: *Sema, arg: *ast.Expr, ty: *Type) Error!*Type {
        return switch (ty.*) {
            .comptime_int => self.prims.i32,
            .comptime_float => self.prims.f64,
            .int => |info| blk: {
                if (info.bits < 32) break :blk if (info.signed) self.prims.i32 else self.prims.u32;
                break :blk ty;
            },
            .char => self.prims.u32,
            .bool => self.prims.i32,
            .enum_type => self.prims.i32,
            .float => |bits| if (bits < 64) self.prims.f64 else ty,
            .null_type => blk: {
                try self.reporter.err("E0475", arg.span, "null passed to a variadic function needs an explicit pointer type", .{});
                break :blk self.prims.invalid;
            },
            .slice => blk: {
                try self.reporter.err("E0475", arg.span, "a slice cannot be passed to a variadic function; pass `.ptr` or `.len`", .{});
                break :blk self.prims.invalid;
            },
            .struct_type, .array => blk: {
                try self.reporter.err("E0475", arg.span, "an aggregate cannot be passed to a variadic function; pass a pointer to it", .{});
                break :blk self.prims.invalid;
            },
            else => ty,
        };
    }

    fn checkCast(self: *Sema, expr: *ast.Expr, cast: ast.Expr.Kind.Cast) Error!*Type {
        const source_ty = try self.checkExpr(cast.operand, null);
        const target_ty = try self.resolveType(cast.target);
        if (source_ty.* == .invalid or target_ty.* == .invalid) return target_ty;

        // A function value is a pointer at the ABI level, and the two directions
        // are deliberately spelled differently: naming a raw pointer as a
        // function type with `as` is what a C callback retrieved from a table
        // needs, while a function *name* is written as a plain expression and
        // only a cast to `*T` explains which pointer it is.
        const is_callable_pointer = target_ty.* == .fn_ptr;
        const allowed = switch (source_ty.*) {
            .comptime_int, .comptime_float => target_ty.isNumeric() or target_ty.isPointer() or target_ty.* == .bool or target_ty.* == .enum_type or is_callable_pointer,
            .int, .char => target_ty.isNumeric() or target_ty.* == .bool or target_ty.* == .enum_type or target_ty.isPointer() or is_callable_pointer,
            .float => target_ty.isFloat() or self.isIntegerType(target_ty) or target_ty.* == .bool,
            .bool => self.isIntegerType(target_ty) or target_ty.isFloat() or target_ty.* == .bool,
            .enum_type => self.isIntegerType(target_ty) or target_ty.* == .enum_type,
            .pointer => self.isPointerCast(source_ty, target_ty) or is_callable_pointer,
            .fn_ptr => self.isFunctionPointerCast(source_ty, target_ty),
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

    /// A function value casts to the two things C erases it to: a raw pointer
    /// (`*T`, keeping its const-ness explicit) or an integer wide enough to hold
    /// an address. Function types and aggregates are not casts — the same rule
    /// already applies to `*T` in `isPointerCast` — because a signature is not
    /// a representation and an aggregate would be reinterpreting two words as
    /// one.
    fn isFunctionPointerCast(self: *const Sema, source_ty: *Type, target_ty: *Type) bool {
        _ = self;
        _ = source_ty;
        return target_ty.isPointer() or target_ty.isInteger();
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
            try self.reporter.err("E0456", initializer.type_expr.span, "type '{s}' is not a struct or union", .{self.typeName(ty)});
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
                    // "Every field exactly once" is the documented rule, and a
                    // repeated name would otherwise be accepted with the last
                    // value silently winning. The same diagnosis `E0404` covers
                    // a duplicate *declaration* field, so one code means one
                    // thing.
                    if (assigned[struct_field.index]) {
                        try self.reporter.err("E0404", field.span, "duplicate field '{s}' in initializer for struct '{s}'", .{ field.name, info.name });
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
        if (info.is_union) {
            // A union has no "all members set" state: naming one member is what
            // says which one is live, and naming two would claim both are. The
            // fields loop above already rejected a repeated or unknown name, so
            // what is left is counting what was written.
            if (initializer.fields.len == 0) {
                try self.reporter.err("E0485", expr.span, "union '{s}' initializer must name exactly one member", .{info.name});
            } else if (initializer.fields.len > 1) {
                try self.reporter.err("E0485", initializer.fields[1].span, "union '{s}' initializer must name exactly one member, found {d}", .{ info.name, initializer.fields.len });
            }
            return ty;
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
        if (value_ty.* == .null_type and (target.isPointer() or target.* == .fn_ptr)) return true;
        // A declared function and a function value with the same signature are
        // interchangeable, in either direction: the decay happens at the use
        // site, so neither side needs an explicit cast.
        if (target.* == .fn_ptr and value_ty.* == .fn_type) return types.fnInfoEql(target.fn_ptr, value_ty.fn_type);
        if (target.* == .fn_ptr and value_ty.* == .fn_ptr) return types.fnInfoEql(target.fn_ptr, value_ty.fn_ptr);
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

    /// Renders a signature as `fn(i32, i32) i32`, so a mismatch between two
    /// function types names the difference instead of printing `fn` twice.
    fn fnTypeName(self: *const Sema, info: *types.FnInfo) []const u8 {
        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);
        for (info.params, 0..) |param, i| {
            if (i > 0) params.appendSlice(self.allocator, ", ") catch return "fn";
            params.appendSlice(self.allocator, self.typeName(param)) catch return "fn";
        }
        return std.fmt.allocPrint(self.allocator, "fn({s}) {s}", .{
            params.items,
            self.typeName(info.ret),
        }) catch "fn";
    }

    pub fn typeName(self: *const Sema, ty: *Type) []const u8 {
        return switch (ty.*) {
            .invalid => "invalid",
            .void => "void",
            .bool => "bool",
            .char => "char",
            .int => |info| info.nameAlloc(self.allocator),
            .float => |bits| if (bits == 32) "f32" else "f64",
            .abi_vec2_f32 => "<internal ABI vector>",
            .abi_v2f32_f32 => "<internal ABI pair>",
            .abi_v2f32_v2f32 => "<internal ABI pair>",
            .abi_pair_f64 => "<internal ABI pair>",
            .abi_v2f32_i32 => "<internal ABI pair>",
            .abi_v2f32_i64 => "<internal ABI pair>",
            .abi_i64_v2f32 => "<internal ABI pair>",
            .abi_f64_v2f32 => "<internal ABI pair>",
            .abi_v2f32_f64 => "<internal ABI pair>",
            .abi_pair => "<internal ABI pair>",
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
            .fn_type => |info| self.fnTypeName(info),
            .fn_ptr => |info| self.fnTypeName(info),
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

/// `**u8` is the C `char **`: the vector of argument strings the entry point
/// receives. `**const u8` is accepted too, since the program is not supposed to
/// write through it.
fn isArgvType(ty: *Type) bool {
    if (ty.* != .pointer) return false;
    const inner = ty.pointer.elem;
    if (inner.* != .pointer) return false;
    const byte = inner.pointer.elem;
    return byte.* == .int and byte.int.bits == 8 and !byte.int.signed;
}

fn fitsInt(info: types.IntInfo, value: i128) bool {
    return info.fits(value);
}

/// Extract a non-negative integer literal magnitude, which may exceed `i128`.
/// Mirrors `literalIntValue` for the positive case only: a `u128` maximum is a
/// legal `u128` literal but has no signed spelling.
pub fn literalUnsignedValue(expr: *ast.Expr) ?u128 {
    return switch (expr.kind) {
        .int_lit => |lit| lit.value,
        else => null,
    };
}

/// Extract an integer literal value through unary minus/casts.
pub fn literalIntValue(expr: *ast.Expr) ?i128 {
    return analyzer_mod.constInt(expr);
}

/// How an aggregate travels across the C ABI boundary on `x86_64` Linux.
///
/// `small_1` and `small_2` pack the whole aggregate into one or two INTEGER
/// registers; the `sse_*` classes name the single-register SSE transports and
/// the three packed `f32` shapes whose second slot is an SSEUP continuation
/// of the first; `pair` carries the two registers of every other
/// two-eightbyte aggregate explicitly, so pointer-bearing eightbytes, narrow
/// integer leaves and the mixed SSE/INTEGER combinations share one
/// representation; `memory` uses `sret`/`byval`.
pub const BoundaryClass = union(enum) {
    /// The value does not cross a C ABI boundary.
    none,
    small_1,
    small_2,
    sse_float,
    sse_double,
    sse_f32x2,
    sse_f32x3,
    sse_f32x4,
    sse_f64x2,
    /// Two registers, in order, as classified from the aggregate's leaves.
    pair: types.AbiPair,
    memory,

    pub fn eql(a: BoundaryClass, b: BoundaryClass) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .pair => |ap| ap.first == b.pair.first and ap.second == b.pair.second,
            else => true,
        };
    }

    /// True when the class names a value that crosses the C ABI boundary.
    pub fn crosses(self: BoundaryClass) bool {
        return self != .none;
    }

    /// True when the class travels in two registers.
    pub fn isPair(self: BoundaryClass) bool {
        return switch (self) {
            .sse_f32x3, .sse_f32x4, .sse_f64x2, .pair => true,
            else => false,
        };
    }
};

/// Boundary classification for an explicitly chosen target. The System V rules
/// below are only defined for `x86_64` Linux, so any other target has no C
/// aggregate ABI here and callers must reject the boundary rather than guess.
/// There is deliberately no variant that reads the *build* target: the compile
/// target can differ from it under `--target`, and two sources of truth here
/// would let a cross-compilation lower the host convention silently.
pub fn aggregateBoundaryClassFor(ty: *Type, systemv: bool) ?BoundaryClass {
    if (!systemv) return null;
    // A bare array is not a by-value aggregate at the boundary: a C array
    // parameter decays to a pointer, so passing the elements in registers
    // would silently disagree with the callee. Only arrays nested inside a
    // struct are values, and those are flattened by the leaf walk below.
    if (ty.* == .array) return null;
    const layout = aggregateLayoutGuess(ty) orelse return null;
    if (layout.size > 16) return .memory;
    // A packed aggregate has no guaranteed alignment, so it crosses the boundary
    // by memory even when it is small — measured against clang, which emits
    // `sret`/`byval` for a 5-byte `{ char; int; }` that would otherwise travel in
    // one `i64`. Register transport would also be wrong: the loads it implies are
    // unaligned by construction.
    if (ty.* == .struct_type and ty.struct_type.is_packed) return .memory;
    if (ty.* != .struct_type) {
        // A non-struct aggregate (a slice) travels as one packed INTEGER
        // value, matching the C struct `{ T *ptr; size_t len; }`.
        if (layout.size <= 8) return .small_1;
        return .small_2;
    }

    var leaves = [_]EightbyteLeaf{ .{}, .{} };
    if (!collectAggregateLeaves(ty, 0, &leaves)) return null;

    if (layout.size > 8) {
        // A single leaf that fills both eightbytes is a 16-byte INTEGER, and
        // the two registers it occupies are exactly the halves of one `i128`.
        // Clang classifies `struct { __int128 a; }` as `i128` for that reason,
        // so the packed two-register transport is the right representation.
        // The leaf walk sees through nesting, so `{ a: Inner }` where
        // `Inner = { a: i128 }`, and `{ a: [1]i128 }`, land here as well.
        if (leaves[0].covering) return .small_2;
        // The aggregate spans both eightbytes and travels in two registers,
        // one per eightbyte. A lone leaf of each eightbyte decides its own
        // register width, so `struct { short x; long b; }` becomes `i16, i64`
        // exactly as Clang passes it.
        const first = eightbyteRegister(leaves[0]) orelse return null;
        const second = eightbyteRegister(leaves[1]) orelse return null;
        const a = eightbyteSlot(first) orelse return null;
        const b = eightbyteSlot(second) orelse return null;
        // Two full INTEGER registers keep the packed transport; anything
        // narrower or mixed travels in its own register at its own width.
        if (a == .i64 and b == .i64) return .small_2;
        if (a == .f64 and b == .f64) return .sse_f64x2;
        // A `<2 x float>` slot occupies an SSE register and its SSEUP
        // continuation, which only the packed three/four-`f32` shapes reuse.
        if (first == .f32x2 or second == .f32x2) {
            if (first == .f32x2 and second == .f32) return .sse_f32x3;
            if (first == .f32x2 and second == .f32x2) return .sse_f32x4;
        }
        return .{ .pair = .{ .first = a, .second = b } };
    }

    // The aggregate travels in a single register.
    if (isFloatOnly(leaves[0])) {
        if (leaves[0].count == 1) {
            const single = leaves[0].singleton orelse return null;
            return switch (single.bits) {
                32 => .sse_float,
                64 => .sse_double,
                else => null,
            };
        }
        if (leaves[0].count == 2) return .sse_f32x2;
        return null;
    }
    return .small_1;
}

/// The slot class an eightbyte register transports as.
fn eightbyteSlot(register: EightbyteRegister) ?types.AbiSlot {
    return switch (register) {
        .i8 => .i8,
        .i16 => .i16,
        .i32 => .i32,
        .i64 => .i64,
        .pointer => .pointer,
        .f32 => .f32,
        .f64 => .f64,
        .f32x2 => .f32x2,
    };
}

pub const AggregateLayout = struct {
    size: u64,
    align_: u64,
};

/// Width in bits of the INTEGER register that carries an eightbyte whose
/// occupied size fits `size` bytes. Matches Clang's choice of the smallest
/// register covering the eightbyte.
pub fn smallRegisterBits(size: u64) u16 {
    if (size <= 1) return 8;
    if (size <= 2) return 16;
    if (size <= 4) return 32;
    return 64;
}

/// Width in bits of an integer member at the C ABI boundary. `bool` travels
/// as a full `i8` because C's `_Bool` is one byte, `char` is a 32-bit type in
/// Kyn, and an enum travels as its backing integer.
pub fn memberBoundaryBits(ty: *Type) ?u16 {
    return switch (ty.*) {
        .int => |info| info.bits,
        .bool => 8,
        .char => 32,
        .enum_type => |info| info.backing.intInfo().bits,
        else => null,
    };
}

/// How a scalar leaf travels at the C ABI boundary.
pub const LeafKind = enum {
    /// An integer scalar, which travels in an INTEGER register.
    integer,
    /// A floating-point scalar, which travels in an SSE register.
    float,
    /// A pointer, which travels in an INTEGER register but is never coerced
    /// to an integer member width.
    pointer,
};

/// A single scalar leaf of an aggregate.
pub const AggregateLeaf = struct {
    /// How the leaf travels at the C ABI boundary.
    kind: LeafKind = .integer,
    /// Width in bits of the leaf at the C ABI boundary.
    bits: u16 = 0,
    /// Byte offset of the leaf inside the aggregate.
    offset: u64 = 0,
};

/// The scalar leaves carried by one eightbyte of an aggregate.
pub const EightbyteLeaf = struct {
    /// Number of scalar leaves in the eightbyte.
    count: u16 = 0,
    /// Number of floating-point leaves in the eightbyte.
    float_count: u16 = 0,
    /// The lone leaf of the eightbyte, when it carries exactly one.
    singleton: ?AggregateLeaf = null,
    /// True when one integer leaf covers the aggregate's whole sixteen bytes,
    /// which makes the aggregate a single 16-byte INTEGER rather than a pair of
    /// registers with a leaf of their own.
    covering: bool = false,
};

/// The kind of register an eightbyte travels in at the C ABI boundary.
pub const EightbyteRegister = enum {
    /// An INTEGER register holding an 8-bit integer.
    i8,
    /// An INTEGER register holding a 16-bit integer.
    i16,
    /// An INTEGER register holding a 32-bit integer.
    i32,
    /// An INTEGER register holding a 64-bit integer, or a pointer.
    i64,
    /// A pointer. It travels in an INTEGER register of the full width and is
    /// never narrowed, because a pointer is not an integer member.
    pointer,
    /// An SSE register holding one `float` value.
    f32,
    /// An SSE register holding one `double` value.
    f64,
    /// An SSE register holding two `float` values.
    f32x2,
};

/// Counts the scalar leaves of `ty` per eightbyte. Nested structs are walked
/// through, because Clang flattens them into their leaves when it decides the
/// register width of an eightbyte.
fn collectAggregateLeaves(ty: *Type, base_offset: u64, leaves: *[2]EightbyteLeaf) bool {
    switch (ty.*) {
        .struct_type => |info| {
            var offset = base_offset;
            for (info.fields) |field| {
                const layout = aggregateLayoutGuess(field.ty) orelse return false;
                // Every union member starts where the union does, so the walk
                // records them all at the same offset and the eightbyte merges
                // them — which is exactly how clang classifies a union.
                if (info.is_union) {
                    if (!collectAggregateLeaves(field.ty, base_offset, leaves)) return false;
                    continue;
                }
                if (!info.is_packed) offset = std.mem.alignForward(u64, offset, layout.align_);
                if (!collectAggregateLeaves(field.ty, offset, leaves)) return false;
                offset += layout.size;
            }
            return true;
        },
        .enum_type => |info| return collectAggregateLeaves(info.backing, base_offset, leaves),
        .array => |info| {
            // Each element contributes its own leaves, exactly as `len`
            // consecutive members would: Clang flattens an array the same way
            // it flattens a nested struct.
            const element = aggregateLayoutGuess(info.elem) orelse return false;
            var offset = base_offset;
            for (0..info.len) |_| {
                if (!collectAggregateLeaves(info.elem, offset, leaves)) return false;
                offset += element.size;
            }
            return true;
        },
        .bool => return recordIntegerLeaf(ty, base_offset, 1, leaves),
        .char => return recordIntegerLeaf(ty, base_offset, 4, leaves),
        .int => |info| return recordIntegerLeaf(ty, base_offset, @as(u64, info.bits / 8), leaves),
        .float => |bits| return recordFloatLeaf(base_offset, bits / 8, bits, leaves),
        .pointer => return recordPointerLeaf(base_offset, leaves),
        else => return false,
    }
}

/// Records an integer scalar leaf, whose boundary width comes from the shared
/// member width table.
fn recordIntegerLeaf(ty: *Type, offset: u64, size: u64, leaves: *[2]EightbyteLeaf) bool {
    const bits = memberBoundaryBits(ty) orelse return false;
    return recordAggregateLeaf(offset, size, .{ .kind = .integer, .bits = bits, .offset = offset }, leaves);
}

fn recordFloatLeaf(offset: u64, size: u64, bits: u16, leaves: *[2]EightbyteLeaf) bool {
    return recordAggregateLeaf(offset, size, .{ .kind = .float, .bits = bits, .offset = offset }, leaves);
}

fn recordPointerLeaf(offset: u64, leaves: *[2]EightbyteLeaf) bool {
    return recordAggregateLeaf(offset, 8, .{ .kind = .pointer, .bits = 64, .offset = offset }, leaves);
}

fn recordAggregateLeaf(offset: u64, size: u64, leaf: AggregateLeaf, leaves: *[2]EightbyteLeaf) bool {
    if (size == 0) return true;
    const last_byte = offset + size - 1;
    if (last_byte >= 16) return false;
    const first: usize = @intCast(offset / 8);
    const last: usize = @intCast(last_byte / 8);
    for (leaves[first .. last + 1]) |*eightbyte| {
        eightbyte.count += 1;
        if (leaf.kind == .float) eightbyte.float_count += 1;
        // A leaf spanning two eightbytes never travels alone in a register, so
        // it never becomes a `singleton`. The one exception is an integer that
        // covers the whole sixteen bytes: its two registers are the halves of a
        // single 16-byte INTEGER, which is what `covering` records.
        if (eightbyte.count == 1 and first == last) eightbyte.singleton = leaf;
        if (offset == 0 and size == 16 and leaf.kind != .float) eightbyte.covering = true;
    }
    return true;
}

/// True when the eightbyte carries only floating-point leaves, which is the
/// SSE class of the System V ABI.
fn isFloatOnly(leaf: EightbyteLeaf) bool {
    return leaf.count > 0 and leaf.float_count == leaf.count;
}

/// Returns the register an eightbyte travels in, or null when the shape has no
/// supported register.
fn eightbyteRegister(leaf: EightbyteLeaf) ?EightbyteRegister {
    if (leaf.count == 0) return null;
    if (isFloatOnly(leaf)) {
        if (leaf.count == 1) {
            const single = leaf.singleton orelse return null;
            return switch (single.bits) {
                32 => .f32,
                64 => .f64,
                else => null,
            };
        }
        // Two `float` leaves are the only pair that fits in one eightbyte.
        if (leaf.count == 2) return .f32x2;
        return null;
    }
    // The INTEGER class, possibly merged with a floating-point leaf.
    if (leaf.count == 1) {
        const single = leaf.singleton orelse return null;
        if (single.kind == .pointer) return .pointer;
        if (single.kind != .integer) return null;
        return switch (single.bits) {
            8 => .i8,
            16 => .i16,
            32 => .i32,
            64 => .i64,
            else => null,
        };
    }
    // A merged eightbyte always travels in a full 64-bit register.
    return .i64;
}

/// A bitfield is an integer narrower than a byte, or one that is not a whole
/// number of bytes. Such a type exists only as a struct field: it has no storage
/// of its own, so `aggregateLayoutGuess` gives it no size and every other
/// consumer has to go through the run layout instead.
pub fn isBitfield(ty: *Type) bool {
    return switch (ty.*) {
        // Only a width that is not a whole number of bytes is a bitfield. `u64`
        // and `u128` are ordinary members: they have their own storage, their own
        // alignment, and calling them bitfields would claim they can share a unit
        // with a neighbour. A `u3`..`u63` field always fits one of the 1/2/4/8-byte
        // units, so a run never asks for a unit wider than 8 bytes.
        .int => |info| info.bits % 8 != 0 and info.bits < 64,
        else => false,
    };
}

/// Whether a struct's bitfield layout is representable. A run whose cursor is not
/// at the start of its unit would need an emitted integer starting mid-block,
/// which LLVM cannot express without moving the members after it; rather than
/// emit a type that disagrees with `aggregateLayoutGuess`, the aggregate is
/// rejected with `E0489`.
pub fn bitfieldLayoutIsRepresentable(info: types.StructInfo) bool {
    var bits: u64 = 0;
    var emitted_bytes: u64 = 0;
    for (info.fields) |field| {
        const field_layout = aggregateLayoutGuess(field.ty) orelse return false;
        if (!isBitfield(field.ty)) {
            bits = std.mem.alignForward(u64, bits, 8);
            const start = if (info.is_packed) bits / 8 else std.mem.alignForward(u64, bits / 8, field_layout.align_);
            emitted_bytes = @max(emitted_bytes, start + field_layout.size);
            bits = emitted_bytes * 8;
            continue;
        }
        const width: u64 = field.ty.int.bits;
        const unit = bitfieldUnitWidth(field.ty);
        if (!info.is_packed) {
            const boundary = unit * 8;
            if ((bits % boundary) + width > boundary) bits = std.mem.alignForward(u64, bits, boundary);
        }
        const field_byte = bits / 8;
        // The unit must start on a byte the field does reach: an aligned block
        // that begins at or before it, or the next block when it does not fit.
        const block_end = std.mem.alignForward(u64, field_byte + 1, unit);
        if ((bits + width + 7) / 8 > block_end) return false;
        const unit_start = block_end - unit;
        if (unit_start > emitted_bytes) return false;
        emitted_bytes = @max(emitted_bytes, block_end);
        bits += width;
    }
    return true;
}

/// The width of the storage unit a bitfield sits in: the smallest of 8/16/32/64
/// that holds its width. This is the unit whose boundaries the field may not
/// straddle, and the alignment it contributes to the aggregate.
/// The smallest of 8/16/32/64 bits that holds `bits`, as a unit width in bytes.
fn bitfieldUnitWidthForBits(bits: u64) u64 {
    if (bits <= 8) return 1;
    if (bits <= 16) return 2;
    if (bits <= 32) return 4;
    return 8;
}

pub fn bitfieldUnitWidth(ty: *Type) u64 {
    const bits: u64 = switch (ty.*) {
        .int => |info| info.bits,
        else => 8,
    };
    if (bits <= 8) return 1;
    if (bits <= 16) return 2;
    if (bits <= 32) return 4;
    return 8;
}

pub fn aggregateLayoutGuess(ty: *Type) ?AggregateLayout {
    return switch (ty.*) {
        .slice => .{ .size = 16, .align_ = 8 },
        .struct_type => |info| if (info.layout.align_ != 0) .{
            .size = info.layout.size,
            .align_ = info.layout.align_,
        } else null,
        .array => |info| blk: {
            // A fixed array is `len` element copies, aligned to its element.
            // No size cap here: an aggregate wider than 16 bytes is still a
            // valid aggregate, it simply travels by memory (see
            // `aggregateBoundaryClass`), so only the multiplication has to be
            // guarded against overflow.
            const element = aggregateLayoutGuess(info.elem) orelse return null;
            const len: u64 = @intCast(info.len);
            const size = std.math.mul(u64, element.size, len) catch return null;
            break :blk .{ .size = size, .align_ = element.align_ };
        },
        .bool => .{ .size = 1, .align_ = 1 },
        .char => .{ .size = 4, .align_ = 4 },
        // A width that is not a whole number of bytes still occupies a whole
        // number of them; `u3` is one byte of storage, as a bitfield member.
        .int => |info| .{
            .size = @intCast((info.bits + 7) / 8),
            .align_ = @intCast(@min(@as(u64, (info.bits + 7) / 8), 16)),
        },
        .float => |bits| .{ .size = @intCast(bits / 8), .align_ = @intCast(bits / 8) },
        .pointer => .{ .size = 8, .align_ = 8 },
        // A function type has no storage of its own; in an aggregate it is a
        // pointer to the code, which is what its lowering produces.
        .fn_type, .fn_ptr => .{ .size = 8, .align_ = 8 },
        .enum_type => |info| aggregateLayoutGuess(info.backing),
        else => null,
    };
}

/// `UnknownLayout` never escapes `resolveStruct`: it is turned into `E0488` at
/// the one call site, because an unknown layout is a program error the reporter
/// owns, not an internal failure.
pub const PlaceError = error{ OutOfMemory, UnknownLayout, UnrepresentableBitfield };

/// Lays out `info` once: the bit cursor produces the byte position of every
/// member **and** the emitted LLVM members (bitfield runs collapse into a unit,
/// gaps become explicit padding). Doing it in one pass is not an optimisation but
/// a correctness property: a separate placement pass is exactly how a bitfield's
/// size and its bit offset drift apart.
pub fn placeFields(allocator: std.mem.Allocator, info: *types.StructInfo) PlaceError!void {
    if (info.complete) return;
    var bits: u64 = 0;
    var align_: u64 = 1;
    var emitted: std.ArrayList(*Type) = .empty;
    var emitted_bytes: u64 = 0;
    const placed = allocator.alloc(types.Placed, info.fields.len) catch return error.OutOfMemory;
    // The emitted unit the cursor is currently filling, and its width in bits.
    var run_index: ?u32 = null;
    var run_unit_bits: u64 = 0;
    // Where the open packed run began, in bits, so its unit can be widened while
    // the fields' offsets inside it stay where they are.
    var run_bit_start: ?u64 = null;

    for (info.fields, 0..) |field, i| {
        const field_layout = aggregateLayoutGuess(field.ty) orelse return error.UnknownLayout;
        if (info.is_union) {
            placed[i] = .{ .emitted_index = 0, .storage_ty = field.ty };
            bits = @max(bits, field_layout.size * 8);
            align_ = @max(align_, field_layout.align_);
            continue;
        }

        if (!isBitfield(field.ty)) {
            bits = std.mem.alignForward(u64, bits, 8);
            const byte_offset = bits / 8;
            const start = if (info.is_packed) byte_offset else std.mem.alignForward(u64, byte_offset, field_layout.align_);
            if (start > emitted_bytes) {
                emitted.append(allocator, try paddingType(allocator, start - emitted_bytes)) catch return error.OutOfMemory;
                emitted_bytes = start;
            }
            run_index = null;
            run_unit_bits = 0;
            run_bit_start = null;
            placed[i] = .{ .emitted_index = @intCast(emitted.items.len), .storage_ty = field.ty };
            emitted.append(allocator, field.ty) catch return error.OutOfMemory;
            emitted_bytes = start + field_layout.size;
            bits = emitted_bytes * 8;
            if (!info.is_packed) align_ = @max(align_, field_layout.align_);
            continue;
        }

        const width: u64 = field.ty.int.bits;
        const unit = bitfieldUnitWidth(field.ty);
        if (info.is_packed) {
            // A packed run inserts nothing between fields, so its unit has to
            // cover the whole run: it may not straddle a field any more than an
            // aligned one may, but it also may not leave a gap. The run's unit is
            // therefore widened to the run's total width, which is 1, 2, 4 or 8
            // bytes because a bitfield is narrower than 64 bits.
            const run_start = run_bit_start orelse bits;
            const run_width = (bits - run_start) + width;
            const wide_unit = bitfieldUnitWidthForBits(run_width);
            align_ = 1;
            if (run_index == null or run_unit_bits != wide_unit * 8) {
                const start = run_start / 8;
                if (start > emitted_bytes) {
                    emitted.append(allocator, try paddingType(allocator, start - emitted_bytes)) catch return error.OutOfMemory;
                    emitted_bytes = start;
                }
                run_index = @intCast(emitted.items.len);
                run_unit_bits = wide_unit * 8;
                run_bit_start = run_start;
                emitted.append(allocator, try storageUnitType(allocator, wide_unit)) catch return error.OutOfMemory;
                emitted_bytes = @max(emitted_bytes, start + wide_unit);
            } else if ((bits + width + 7) / 8 > emitted_bytes) {
                // The run outgrew the unit that was opened for it. Re-laying the
                // run out from its start is what keeps the fields' bit offsets
                // unchanged as the unit grows, which is exactly the rule measured
                // for `{u3, u5, u12}` on the aligned path.
                const start = run_bit_start.? / 8;
                const reunit = bitfieldUnitWidthForBits(bits + width - run_bit_start.?);
                emitted.items[run_index.?] = try storageUnitType(allocator, reunit);
                run_unit_bits = reunit * 8;
                emitted_bytes = @max(emitted_bytes, start + reunit);
            }
            placed[i] = .{
                .emitted_index = run_index.?,
                .storage_ty = try storageUnitType(allocator, run_unit_bits / 8),
                .bit_offset = @intCast(bits - run_bit_start.?),
            };
            bits += width;
            continue;
        }
        // Rule 2 of the design: a field never straddles a boundary of its own unit
        // width, so when it would the cursor jumps to that boundary.
        const boundary = unit * 8;
        if ((bits % boundary) + width > boundary) bits = std.mem.alignForward(u64, bits, boundary);
        align_ = @max(align_, unit);
        // The unit is an emitted integer, so it begins where LLVM will put it: at
        // the start of the aligned block that holds the field's first byte. That
        // is the rule C uses, and it is why `c` in `{u3, u5, u12}` lands at bit 16
        // rather than 8 -- bits 8..19 do not fit the 2-byte block starting at byte
        // 0, so the field moves to the block starting at byte 2.
        const field_byte = bits / 8;
        const block_end = std.mem.alignForward(u64, field_byte + 1, unit);
        const field_end_byte = (bits + width + 7) / 8;
        const unit_start = if (field_end_byte <= block_end) block_end - unit else block_end;
        // Two emitted members may not overlap, so a unit that would begin inside
        // already-emitted storage is only usable while the field still fits there.
        // Otherwise the aggregate is rejected rather than given a layout the
        // emitted type cannot mirror.
        if (unit_start < emitted_bytes and field_end_byte > emitted_bytes) return error.UnrepresentableBitfield;
        std.debug.assert(bits >= unit_start * 8);
        const reuses_run = run_index != null and run_unit_bits == unit * 8 and
            (bits + width + 7) / 8 <= emitted_bytes;
        if (!reuses_run) {
            if (unit_start > emitted_bytes) {
                emitted.append(allocator, try paddingType(allocator, unit_start - emitted_bytes)) catch return error.OutOfMemory;
                emitted_bytes = unit_start;
            }
            run_index = @intCast(emitted.items.len);
            run_unit_bits = unit * 8;
            emitted.append(allocator, try storageUnitType(allocator, unit)) catch return error.OutOfMemory;
            emitted_bytes = @max(emitted_bytes, unit_start + unit);
        }
        placed[i] = .{
            .emitted_index = run_index.?,
            .storage_ty = try storageUnitType(allocator, unit),
            .bit_offset = @intCast(bits - unit_start * 8),
        };
        bits += width;
    }

    var size = (bits + 7) / 8;
    if (info.is_packed) {
        info.layout = .{ .size = size, .align_ = 1 };
    } else {
        size = std.mem.alignForward(u64, size, align_);
        info.layout = .{ .size = size, .align_ = align_ };
    }
    // The emitted members must reach exactly the size the cursor computed, or the
    // two disagree about how many bytes the aggregate has.
    if (emitted_bytes > size) return error.UnrepresentableBitfield;
    info.placed = placed;
    info.emitted = emitted.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// The integer type a storage unit of `bytes` is emitted as.
fn storageUnitType(allocator: std.mem.Allocator, bytes: u64) !*Type {
    const ty = try allocator.create(Type);
    ty.* = .{ .int = .{ .bits = @intCast(bytes * 8), .signed = false } };
    return ty;
}

/// `[len]u8`, used to make a gap an explicit member of the emitted type.
fn paddingType(allocator: std.mem.Allocator, len: u64) !*Type {
    const elem = try storageUnitType(allocator, 1);
    const ty = try allocator.create(Type);
    ty.* = .{ .array = .{ .elem = elem, .len = @intCast(len) } };
    return ty;
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

    /// The rendered name of a type the analyzer produced, using the same
    /// `typeName` the diagnostics use, so a test can assert a promoted type
    /// without duplicating the naming rules.
    fn typeName(self: *SemTest, ty: *Type) []const u8 {
        var sema = Sema.init(self.arena.allocator(), &self.reporter, &self.prims);
        return sema.typeName(ty);
    }

    /// The analyzed type declared under `name`. Looked up by name rather than by
    /// elimination over the declaration list: a table-driven test may declare a
    /// helper type of its own, and "the one that is not the helper" silently
    /// picks the wrong declaration the moment a case declares two.
    fn typeNamed(self: *SemTest, name: []const u8) ?*Type {
        const decls = self.program.?.decls;
        for (decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |sd| {
                    if (std.mem.eql(u8, sd.name, name)) return sd.ty;
                },
                else => {},
            }
        }
        return null;
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

/// Asserts the program fails with exactly `code` and nothing else: a duplicate
/// report of the same condition from an earlier phase is invisible to
/// `expectSemanticError`, which returns on the first match.
fn expectOnlyError(text: []const u8, code: []const u8) !void {
    var ctx: SemTest = undefined;
    try ctx.init(text);
    defer ctx.deinit();
    try ctx.run();
    if (!ctx.reporter.hasErrors()) return error.ExpectedDiagnostic;
    var seen: usize = 0;
    for (ctx.reporter.list.items) |diag| {
        if (!std.mem.eql(u8, diag.code, code)) {
            std.debug.print("unexpected {s}: {s}\n", .{ diag.code, diag.message });
            return error.UnexpectedDiagnostic;
        }
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen);
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

test "C ABI boundary classification follows Clang's leaf registers" {
    const shapes = [_]struct {
        decl: []const u8,
        expected: ?BoundaryClass,
    }{
        // The leaf width decides the register, even when a leaf is nested.
        .{ .decl = "struct S { a: i16, b: i64 }", .expected = .{ .pair = .{ .first = .i16, .second = .i64 } } },
        .{ .decl = "struct S { a: i64, b: i16 }", .expected = .{ .pair = .{ .first = .i64, .second = .i16 } } },
        .{ .decl = "struct S { a: i64, b: i64 }", .expected = .small_2 },
        .{ .decl = "struct S { a: i64, b: u64 }", .expected = .small_2 },
        // A pointer is an INTEGER eightbyte of the full width, never narrowed.
        .{ .decl = "struct S { a: *u8, b: i64 }", .expected = .{ .pair = .{ .first = .pointer, .second = .i64 } } },
        .{ .decl = "struct S { a: i8, b: *u8 }", .expected = .{ .pair = .{ .first = .i8, .second = .pointer } } },
        .{ .decl = "struct S { a: *u8, b: *u8 }", .expected = .{ .pair = .{ .first = .pointer, .second = .pointer } } },
        .{ .decl = "struct S { a: *u8, b: f64 }", .expected = .{ .pair = .{ .first = .pointer, .second = .f64 } } },
        .{ .decl = "struct S { a: f32, b: *u8 }", .expected = .{ .pair = .{ .first = .f32, .second = .pointer } } },
        // A pointer merged with other INTEGER leaves travels packed.
        .{ .decl = "struct S { a: i32, b: i32, c: *u8 }", .expected = .{ .pair = .{ .first = .i64, .second = .pointer } } },
        // SSE slots share the pair representation, including the SSEUP slot.
        .{ .decl = "struct S { a: f32, b: f32, c: i16 }", .expected = .{ .pair = .{ .first = .f32x2, .second = .i16 } } },
        .{ .decl = "struct S { a: f32, b: f32, c: *u8 }", .expected = .{ .pair = .{ .first = .f32x2, .second = .pointer } } },
        .{ .decl = "struct S { a: *u8, b: f32, c: f32 }", .expected = .{ .pair = .{ .first = .pointer, .second = .f32x2 } } },
        .{ .decl = "struct S { a: f32, b: f32, c: f32 }", .expected = .sse_f32x3 },
        .{ .decl = "struct S { a: f32, b: f32, c: f32, d: f32 }", .expected = .sse_f32x4 },
        .{ .decl = "struct S { a: f64, b: f64 }", .expected = .sse_f64x2 },
        .{ .decl = "struct S { a: f32, b: f64 }", .expected = .{ .pair = .{ .first = .f32, .second = .f64 } } },
        // A merged eightbyte is an INTEGER register even when a float is in
        // it, so `{ int; float }` and `{ float; int; bool }` pack to `i64`.
        .{ .decl = "struct S { a: i32, b: f32 }", .expected = .small_1 },
        .{ .decl = "struct S { a: f32, b: i32, c: bool }", .expected = .{ .pair = .{ .first = .i64, .second = .i8 } } },
        // An array member contributes one leaf per element, so it follows the
        // same rules as consecutive members: `{ [2]i8, f64 }` is a packed
        // INTEGER eightbyte followed by an SSE double.
        .{ .decl = "struct S { a: [2]i8, b: f64 }", .expected = .{ .pair = .{ .first = .i64, .second = .f64 } } },
        .{ .decl = "struct S { a: [2]i32 }", .expected = .small_1 },
        .{ .decl = "struct S { a: [3]i32 }", .expected = .{ .pair = .{ .first = .i64, .second = .i32 } } },
        .{ .decl = "struct S { a: [2]f32 }", .expected = .sse_f32x2 },
        // A lone `i128` fills both eightbytes, which is one 16-byte INTEGER:
        // Clang classifies `struct { __int128 a; }` exactly this way.
        .{ .decl = "struct S { a: i128 }", .expected = .small_2 },
        // Sixteen bytes of narrower members are two named registers instead,
        // because each eightbyte carries leaves of its own.
        .{ .decl = "struct S { a: [2]i64 }", .expected = .small_2 },
        // The covering leaf is found through nesting and through an array of
        // one element, so all three spellings classify the same way.
        .{ .decl = "struct I { v: i128 }\nstruct S { a: I }", .expected = .small_2 },
        .{ .decl = "struct S { a: [1]i128 }", .expected = .small_2 },
        .{ .decl = "struct S { a: u128 }", .expected = .small_2 },
    };

    for (shapes) |shape| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const lexer_mod = @import("lexer.zig");
        const parser_mod = @import("parser.zig");
        const src = try a.create(source.Source);
        const text = try std.fmt.allocPrint(a, "{s}\nfn main() i32 {{ return 0; }}\n", .{shape.decl});
        src.* = try source.Source.init(a, "abi.kyn", text);
        var reporter = diagnostics.Reporter.init(a, src);
        var prims = try types.Primitives.init(a);
        var lx = lexer_mod.Lexer.init(a, src, &reporter);
        const tokens = try lx.tokenize();
        var p = parser_mod.Parser.init(a, tokens, &reporter);
        const program = try p.parse();
        var sema = Sema.init(a, &reporter, &prims);
        try sema.analyze(program);
        try testing.expect(!reporter.hasErrors());

        var struct_ty: ?*Type = null;
        for (program.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |sd| {
                    if (sd.ty) |ty| struct_ty = ty;
                },
                else => {},
            }
        }
        const ty = struct_ty orelse return error.MissingStructType;
        const actual = aggregateBoundaryClassFor(ty, true);
        if (shape.expected) |expected| {
            try testing.expect(actual != null);
            try testing.expect(expected.eql(actual.?));
        } else {
            try testing.expect(actual == null);
        }
    }
}

test "semantic accepts an exported variadic function reading its arguments" {
    try expectClean(
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
        \\fn main() i32 { return 0; }
    );
}

test "semantic rejects a variadic function that is neither export nor extern" {
    // A Kyn-internal function is called only from Kyn, where the signature is
    // fixed and checked, so a variadic one could never receive its tail.
    try expectSemanticError(
        \\fn internal(count: i32, ...) i32 {
        \\    let value: i32 = va_arg();
        \\    return value;
        \\}
        \\fn main() i32 { return 0; }
    , "E0474");
}

test "semantic rejects va_arg outside a variadic function" {
    try expectOnlyError(
        \\fn plain() i32 {
        \\    let value: i32 = va_arg();
        \\    return value;
        \\}
        \\fn main() i32 { return 0; }
    , "E0480");
}

test "semantic requires a context type for va_arg" {
    // Guessing `i32` would misread a `double` from the same list, so a position
    // with no expected type is rejected rather than defaulted.
    try expectOnlyError(
        \\export fn f(count: i32, ...) i32 {
        \\    va_arg();
        \\    return count;
        \\}
        \\fn main() i32 { return 0; }
    , "E0478");
}

test "semantic rejects retrieval types the caller cannot have passed" {
    // An aggregate has no place in an argument list, so it cannot come out of
    // one either; the message names what was found rather than defaulting.
    try expectSemanticError(
        \\struct Pair { a: i32 }
        \\export fn f(count: i32, ...) i32 {
        \\    let pair: Pair = va_arg();
        \\    return count;
        \\}
        \\fn main() i32 { return 0; }
    , "E0478");
}

test "semantic rejects a retrieval narrower than the promoted width" {
    // C passes `i8` as `i32`; retrieving `i8` would read the right bytes with
    // the wrong width, so the promoted type is required and named.
    try expectOnlyError(
        \\export fn f(count: i32, ...) i32 {
        \\    let small: i8 = va_arg();
        \\    return 0;
        \\}
        \\fn main() i32 { return 0; }
    , "E0479");
}

test "semantic records the type a va_arg retrieves" {
    // `f32` is absent on purpose: it is promoted to `f64` by the caller, so a
    // retrieval of `f32` is rejected by the case below rather than recorded.
    const cases = [_]struct { annotation: []const u8, expected: []const u8 }{
        .{ .annotation = "i32", .expected = "i32" },
        .{ .annotation = "i64", .expected = "i64" },
        .{ .annotation = "u64", .expected = "u64" },
        .{ .annotation = "isize", .expected = "i64" },
        .{ .annotation = "f64", .expected = "f64" },
        .{ .annotation = "*u8", .expected = "*u8" },
        .{ .annotation = "fn(i32) i32", .expected = "fn(i32) i32" },
    };
    for (cases) |case| {
        var buf: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf,
            \\export fn f(count: i32, ...) i32 {{
            \\    let value: {s} = va_arg();
            \\    return count;
            \\}}
            \\fn main() i32 {{ return 0; }}
        , .{case.annotation});
        var ctx: SemTest = undefined;
        try ctx.init(text);
        defer ctx.deinit();
        try ctx.run();
        if (ctx.reporter.hasErrors()) {
            for (ctx.reporter.list.items) |diag| std.debug.print("  {s}: {s}\n", .{ diag.code, diag.message });
            return error.UnexpectedDiagnostic;
        }
        var found = false;
        for (ctx.program.?.decls) |decl| {
            switch (decl.kind) {
                .fn_decl => |fd| {
                    if (!std.mem.eql(u8, fd.name, "f")) continue;
                    // The retrieval reaches the back end as the recorded type,
                    // which is what the instruction names.
                    for (fd.body.?.stmts) |stmt| {
                        const vd = switch (stmt.kind) {
                            .var_decl => |v| v,
                            else => continue,
                        };
                        const init = vd.init orelse continue;
                        if (init.kind != .va_arg) continue;
                        found = true;
                        try testing.expectEqualStrings(case.expected, ctx.typeName(init.ty.?));
                    }
                },
                else => {},
            }
        }
        try testing.expect(found);
    }
}

test "semantic accepts a union and a packed struct" {
    try expectClean(
        \\union Value { integer: i64, real: f64 }
        \\packed struct Packet { kind: u8, length: u32 }
        \\fn main() i32 {
        \\    var v: Value = Value { real: 1.5 };
        \\    var p: Packet = Packet { kind: 1, length: 2 };
        \\    v.integer = 7;
        \\    return (v.integer + p.length as i64) as i32;
        \\}
    );
}

test "a union initializer must name exactly one member" {
    // Naming one member is what says which is live; naming two would claim
    // both, and naming none would leave the value uninitialized.
    try expectOnlyError(
        \\union Value { integer: i64, real: f64 }
        \\fn main() i32 {
        \\    var v: Value = Value { };
        \\    return 0;
        \\}
    , "E0485");
    try expectOnlyError(
        \\union Value { integer: i64, real: f64 }
        \\fn main() i32 {
        \\    var v: Value = Value { integer: 1, real: 2.0 };
        \\    return 0;
        \\}
    , "E0485");
}

test "a union reports itself as a union, not a struct" {
    try expectSemanticError(
        \\union Loop { inner: Loop }
        \\fn main() i32 { return 0; }
    , "E0403");
}

test "a bitfield run that the emitted type cannot mirror is rejected" {
    // `{u31, u33}`: 31 bits fill a 4-byte unit, and the next 33 bits would need an
    // 8-byte unit beginning at byte 3 -- inside the bytes the first unit already
    // owns. LLVM cannot express two overlapping members, so the aggregate is
    // rejected with a diagnostic instead of being given a layout the emitted type
    // would silently disagree with. C accepts this shape and makes the two runs
    // share one 8-byte unit; Kyn does not claim that rule, so it says so.
    var ctx: SemTest = undefined;
    try ctx.init("struct D { a: u31, b: u33 }\nfn main() i32 { return 0; }\n");
    defer ctx.deinit();
    try ctx.run();
    try testing.expect(ctx.reporter.hasErrors());
    var seen = false;
    for (ctx.reporter.list.items) |diag| {
        if (std.mem.eql(u8, diag.code, "E0489")) seen = true;
    }
    try testing.expect(seen);
}

test "bitfield runs are laid out as measured against clang" {
    const cases = [_]struct { decl: []const u8, name: []const u8, size: u64, alignment: u64 }{
        // Each expected pair is the clang answer for the same widths written with
        // the smallest unsigned/char type that holds each width, which is the C
        // spelling whose units are the widths themselves.
        .{ .decl = "struct Wire { k: u3, t: u5 }", .name = "Wire", .size = 1, .alignment = 1 },
        .{ .decl = "struct Halves { a: u20, b: u20 }", .name = "Halves", .size = 8, .alignment = 4 },
        .{ .decl = "struct Spill { a: u4, b: u6 }", .name = "Spill", .size = 2, .alignment = 1 },
        .{ .decl = "struct Wide { a: u31, b: u2 }", .name = "Wide", .size = 8, .alignment = 4 },
        .{ .decl = "struct Three { a: u3, b: u5, c: u12 }", .name = "Three", .size = 4, .alignment = 2 },
        .{ .decl = "struct Signed { a: i3, b: i5 }", .name = "Signed", .size = 1, .alignment = 1 },
        // A non-bitfield member does not open a fresh block: `b` resumes in the
        // same byte unit after `c`, so 8 + 8 + 5 bits round to 3 bytes. In C this
        // is the `unsigned char` form (measured 3/1); the `unsigned` form is 4/4
        // only because a 4-byte unit reaches a 4-byte alignment.
        .{ .decl = "struct Mix { a: u3, c: u8, b: u5 }", .name = "Mix", .size = 3, .alignment = 1 },
        // A `double` forces alignment 8, so the run restarts after it.
        .{ .decl = "struct Doubled { a: u3, d: f64, b: u5 }", .name = "Doubled", .size = 24, .alignment = 8 },
        // Packed: no boundary may be inserted, so a run may straddle its unit.
        .{ .decl = "packed struct Tight { a: u3, b: u5 }", .name = "Tight", .size = 1, .alignment = 1 },
        .{ .decl = "packed struct Tight2 { a: u4, b: u6 }", .name = "Tight2", .size = 2, .alignment = 1 },
    };
    for (cases) |case| {
        const source_text = try std.fmt.allocPrint(
            testing.allocator,
            "{s}\nfn main() i32 {{ return 0; }}\n",
            .{case.decl},
        );
        defer testing.allocator.free(source_text);

        var ctx: SemTest = undefined;
        try ctx.init(source_text);
        defer ctx.deinit();
        try ctx.run();
        if (ctx.reporter.hasErrors()) {
            for (ctx.reporter.list.items) |diag| std.debug.print("  {s}: {s}\n", .{ diag.code, diag.message });
            return error.UnexpectedDiagnostic;
        }
        const ty = ctx.typeNamed(case.name) orelse {
            std.debug.print("no type named {s}\n", .{case.name});
            return error.UnexpectedDiagnostic;
        };
        const layout = aggregateLayoutGuess(ty) orelse {
            std.debug.print("{s}: no layout\n", .{case.name});
            return error.UnexpectedDiagnostic;
        };
        if (layout.size != case.size or layout.align_ != case.alignment) {
            std.debug.print("{s}: expected {d}/{d}, got {d}/{d}\n", .{
                case.name, case.size, case.alignment, layout.size, layout.align_,
            });
            return error.UnexpectedDiagnostic;
        }
    }
}

test "union layout is the largest member and packed layout has no padding" {
    // The measured numbers from the design document: `union { u8, i32, f64 }` is
    // 8/8, and a packed `{ u8, i32 }` is 5 bytes with alignment 1 where the
    // unpacked form is 8/4.
    const cases = [_]struct { decl: []const u8, size: u64, alignment: u64 }{
        .{ .decl = "union F { x: f32, i: i32 }", .size = 4, .alignment = 4 },
        .{ .decl = "union S { c: u8 }", .size = 1, .alignment = 1 },
        .{ .decl = "union Big { d: [3]f64 }", .size = 24, .alignment = 8 },
        .{ .decl = "packed struct P { c: u8, i: i32 }", .size = 5, .alignment = 1 },
        .{ .decl = "packed struct P2 { i: i32, d: f64 }", .size = 12, .alignment = 1 },
        .{ .decl = "struct Natural { c: u8, i: i32 }", .size = 8, .alignment = 4 },
        .{ .decl = "struct Nested { c: u8, u: Pre }", .size = 16, .alignment = 8 },
        .{ .decl = "packed union PU { c: u8, d: f64 }", .size = 8, .alignment = 1 },
        .{ .decl = "union U { c: u8, i: i32, d: f64 }", .size = 8, .alignment = 8 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // `U` is declared in every program because one case nests it.
        const text = try std.fmt.allocPrint(a,
            \\union Pre {{ c: u8, i: i32, d: f64 }}
            \\{s}
            \\fn main() i32 {{ return 0; }}
        , .{case.decl});
        var ctx: SemTest = undefined;
        try ctx.init(text);
        defer ctx.deinit();
        try ctx.run();
        if (ctx.reporter.hasErrors()) {
            for (ctx.reporter.list.items) |diag| std.debug.print("  {s}: {s}\n", .{ diag.code, diag.message });
            return error.UnexpectedDiagnostic;
        }
        // The declaration under test is the one whose name is not `Pre`.
        var found: ?*Type = null;
        for (ctx.program.?.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |sd| if (!std.mem.eql(u8, sd.name, "Pre")) {
                    found = sd.ty;
                },
                else => {},
            }
        }
        const ty = found orelse return error.MissingStructType;
        const layout = aggregateLayoutGuess(ty) orelse return error.MissingLayout;
        try testing.expectEqual(case.size, layout.size);
        try testing.expectEqual(case.alignment, layout.align_);
    }
}

test "a packed aggregate crosses the C boundary by memory" {
    // Measured: clang passes a 5-byte packed struct with sret/byval rather than
    // in one register, so a packed aggregate is never a register class here.
    const cases = [_]struct { decl: []const u8, expected: BoundaryClass }{
        .{ .decl = "packed struct P { c: u8, i: i32 }", .expected = .memory },
        .{ .decl = "packed struct Small { c: u8 }", .expected = .memory },
        .{ .decl = "struct Natural { c: u8, i: i32 }", .expected = .small_1 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const text = try std.fmt.allocPrint(a, "{s}\nfn main() i32 {{ return 0; }}\n", .{case.decl});
        var ctx: SemTest = undefined;
        try ctx.init(text);
        defer ctx.deinit();
        try ctx.run();
        if (ctx.reporter.hasErrors()) return error.UnexpectedDiagnostic;
        const sd = ctx.program.?.decls[0].kind.struct_decl;
        const class = aggregateBoundaryClassFor(sd.ty.?, true) orelse return error.MissingClass;
        try testing.expect(case.expected.eql(class));
    }
}

test "a union classifies as the struct of its members" {
    // Measured against clang: `union { u8, i32, f64 }` travels in one i64, a
    // 1-byte union in an i8, and a 24-byte union by memory.
    const cases = [_]struct { decl: []const u8, expected: BoundaryClass }{
        .{ .decl = "union U { c: u8, i: i32, d: f64 }", .expected = .small_1 },
        .{ .decl = "union S { c: u8 }", .expected = .small_1 },
        .{ .decl = "union Big { d: [3]f64 }", .expected = .memory },
        .{ .decl = "union Two { a: i32, b: i32 }", .expected = .small_1 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const text = try std.fmt.allocPrint(a, "{s}\nfn main() i32 {{ return 0; }}\n", .{case.decl});
        var ctx: SemTest = undefined;
        try ctx.init(text);
        defer ctx.deinit();
        try ctx.run();
        if (ctx.reporter.hasErrors()) return error.UnexpectedDiagnostic;
        const sd = ctx.program.?.decls[0].kind.struct_decl;
        const class = aggregateBoundaryClassFor(sd.ty.?, true) orelse return error.MissingClass;
        try testing.expect(case.expected.eql(class));
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

test "semantic accepts a variadic extern call and promotes its arguments" {
    try expectClean(
        \\extern fn printf(format: *const u8, ...) i32;
        \\fn main() i32 {
        \\    let small: i8 = 7;
        \\    let flag: bool = true;
        \\    let ratio: f32 = 1.5;
        \\    return printf("%d %d %f\\n", small, flag, ratio);
        \\}
    );
}

test "semantic promotes narrow integers, bools and f32 in variadic calls" {
    // The promoted type is what the call passes, so the back end never has to
    // guess: `f32` must widen to `f64` or `%f` would read a garbage double, and
    // an `i8` must widen or the register stays half-filled. Reading the recorded
    // `arg_types` is how the promotion contract is checked without executing C.
    const cases = [_]struct { expr: []const u8, expected: []const u8 }{
        .{ .expr = "small", .expected = "i32" },
        .{ .expr = "flag", .expected = "i32" },
        .{ .expr = "ratio", .expected = "f64" },
        .{ .expr = "wide", .expected = "i64" },
        .{ .expr = "byte", .expected = "u32" },
        .{ .expr = "text", .expected = "*const u8" },
        .{ .expr = "1", .expected = "i32" },
        .{ .expr = "1.5", .expected = "f64" },
    };
    for (cases) |case| {
        var buf: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf,
            \\extern fn printf(format: *const u8, ...) i32;
            \\fn main() i32 {{
            \\    let small: i8 = 7;
            \\    let flag: bool = true;
            \\    let ratio: f32 = 1.5;
            \\    let wide: i64 = 9;
            \\    let byte: u8 = 3;
            \\    let text: *const u8 = "hi";
            \\    return printf("x", {s});
            \\}}
        , .{case.expr});
        var ctx: SemTest = undefined;
        try ctx.init(text);
        defer ctx.deinit();
        try ctx.run();
        try testing.expect(!ctx.reporter.hasErrors());
        const fn_decl = ctx.program.?.decls[1].kind.fn_decl;
        const ret = fn_decl.body.?.stmts[6].kind.return_stmt.value.?;
        const passed = ret.kind.call.arg_types;
        try testing.expectEqual(@as(usize, 2), passed.len);
        const name = ctx.typeName(passed[1]);
        try testing.expectEqualStrings(case.expected, name);
    }
}

test "semantic rejects aggregates, slices and null in variadic calls" {
    try expectSemanticError(
        \\extern fn printf(format: *const u8, ...) i32;
        \\struct Big { a: i32, b: i32 }
        \\fn main() i32 { return printf("%d", Big { a: 1, b: 2 }); }
    , "E0475");
    try expectSemanticError(
        \\extern fn printf(format: *const u8, ...) i32;
        \\fn main() i32 { return printf("%d", null); }
    , "E0475");
    // Calling with no arguments at all still violates the fixed parameters;
    // calling with only them is legal C and stays accepted.
    try expectSemanticError(
        \\extern fn printf(format: *const u8, ...) i32;
        \\fn main() i32 { return printf(); }
    , "E0446");
    try expectSemanticError(
        \\extern fn nope(...) i32;
        \\fn main() i32 { return 0; }
    , "E0474");
}

test "semantic accepts first-class function values and indirect calls" {
    try expectClean(
        \\fn double(v: i32) i32 { return v * 2; }
        \\fn apply(f: fn(i32) i32, v: i32) i32 { return f(v); }
        \\fn main() i32 {
        \\    let f: fn(i32) i32 = double;
        \\    let g = double;
        \\    if (f(2) != 4) { return 1; }
        \\    if (g(3) != 6) { return 2; }
        \\    let none: fn(i32) i32 = null;
        \\    if (none == null) { return apply(f, 5); }
        \\    return 0;
        \\}
    );
}

test "semantic distinguishes signatures in function type errors" {
    // The signature, not the word `fn`, has to appear: a mismatch between two
    // callbacks is otherwise unreadable.
    var ctx: SemTest = undefined;
    try ctx.init(
        \\fn double(v: i32) i32 { return v * 2; }
        \\fn main() i32 { let f: fn(i32, i32) i32 = double; return 0; }
    );
    defer ctx.deinit();
    try ctx.run();
    try testing.expect(ctx.reporter.hasErrors());
    var found = false;
    for (ctx.reporter.list.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "fn(i32) i32") != null and
            std.mem.indexOf(u8, diag.message, "fn(i32, i32) i32") != null)
        {
            found = true;
        }
    }
    try testing.expect(found);
}

test "semantic rejects calling a value that is not a function" {
    try expectSemanticError(
        \\fn main() i32 { let x: i32 = 1; return x(1); }
    , "E0445");
    try expectSemanticError(
        \\fn double(v: i32) i32 { return v * 2; }
        \\fn main() i32 { let f: fn(i32) i32 = double; return f(1, 2); }
    , "E0446");
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
    try expectClean(
        \\struct Inner { count: i32 }
        \\struct Nested { inner: Inner, amount: f64 }
        \\extern fn c_take(value: Nested) Nested;
        \\export fn kyn_identity(value: Nested) Nested { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct WideInt { amount: f64, count: i64 }
        \\struct WideUInt { amount: f64, count: u64 }
        \\extern fn c_take_wide(value: WideInt) WideInt;
        \\extern fn c_take_wide_u(value: WideUInt) WideUInt;
        \\export fn kyn_make_wide(amount: f64, count: i64) WideInt {
        \\    return WideInt { amount: amount, count: count };
        \\}
        \\export fn kyn_id_wide(value: WideInt) WideInt { return value; }
        \\export fn kyn_id_wide_u(value: WideUInt) WideUInt { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct Inner { count: i32 }
        \\struct Nested { inner: Inner, amount: f64 }
        \\export fn kyn_make() Nested { return Nested { inner: Inner { count: 1 }, amount: 2.0 }; }
        \\fn main() i32 { return 0; }
    );

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

    try expectClean(
        \\struct FloatDouble { amount: f32, ratio: f64 }
        \\extern fn c_take(value: FloatDouble) FloatDouble;
        \\export fn kyn_identity(value: FloatDouble) FloatDouble { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct DoubleFloat { ratio: f64, amount: f32 }
        \\extern fn c_take(value: DoubleFloat) DoubleFloat;
        \\export fn kyn_identity(value: DoubleFloat) DoubleFloat { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct FloatLong { amount: f32, count: i64 }
        \\struct LongFloat { count: i64, amount: f32 }
        \\struct DoubleLong { ratio: f64, count: i64 }
        \\struct LongDouble { count: i64, ratio: f64 }
        \\extern fn c_take_fl(value: FloatLong) FloatLong;
        \\extern fn c_take_lf(value: LongFloat) LongFloat;
        \\extern fn c_take_dl(value: DoubleLong) DoubleLong;
        \\extern fn c_take_ld(value: LongDouble) LongDouble;
        \\export fn kyn_id_fl(value: FloatLong) FloatLong { return value; }
        \\export fn kyn_id_lf(value: LongFloat) LongFloat { return value; }
        \\export fn kyn_id_dl(value: DoubleLong) DoubleLong { return value; }
        \\export fn kyn_id_ld(value: LongDouble) LongDouble { return value; }
        \\fn main() i32 { return 0; }
    );
}

test "C ABI small integer members accept exact layouts" {
    try expectClean(
        \\struct TinyI64 { count: i64 }
        \\struct TinyI32 { count: i32 }
        \\struct TinyU32 { count: u32 }
        \\struct TinyI16 { count: i16 }
        \\struct TinyU16 { count: u16 }
        \\struct TinyI8 { count: i8 }
        \\struct TinyU8 { count: u8 }
        \\extern fn c_take_i64(value: TinyI64) TinyI64;
        \\extern fn c_take_i32(value: TinyI32) TinyI32;
        \\extern fn c_take_u32(value: TinyU32) TinyU32;
        \\extern fn c_take_i16(value: TinyI16) TinyI16;
        \\extern fn c_take_u16(value: TinyU16) TinyU16;
        \\extern fn c_take_i8(value: TinyI8) TinyI8;
        \\extern fn c_take_u8(value: TinyU8) TinyU8;
        \\export fn kyn_id_i64(value: TinyI64) TinyI64 { return value; }
        \\export fn kyn_id_i32(value: TinyI32) TinyI32 { return value; }
        \\export fn kyn_id_u32(value: TinyU32) TinyU32 { return value; }
        \\export fn kyn_id_i16(value: TinyI16) TinyI16 { return value; }
        \\export fn kyn_id_u16(value: TinyU16) TinyU16 { return value; }
        \\export fn kyn_id_i8(value: TinyI8) TinyI8 { return value; }
        \\export fn kyn_id_u8(value: TinyU8) TinyU8 { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct TinyDouble { count: i8, amount: f64 }
        \\struct TinyUDouble { count: u8, amount: f64 }
        \\struct SmallDouble { count: i16, amount: f64 }
        \\struct SmallUDouble { count: u16, amount: f64 }
        \\struct DoubleTiny { amount: f64, count: i8 }
        \\struct DoubleSmall { amount: f64, count: i16 }
        \\struct BoolDouble { count: bool, amount: f64 }
        \\struct DoubleBool { amount: f64, count: bool }
        \\extern fn c_take_td(value: TinyDouble) TinyDouble;
        \\extern fn c_take_tu(value: TinyUDouble) TinyUDouble;
        \\extern fn c_take_sd(value: SmallDouble) SmallDouble;
        \\extern fn c_take_su(value: SmallUDouble) SmallUDouble;
        \\extern fn c_take_dt(value: DoubleTiny) DoubleTiny;
        \\extern fn c_take_ds(value: DoubleSmall) DoubleSmall;
        \\extern fn c_take_bd(value: BoolDouble) BoolDouble;
        \\extern fn c_take_db(value: DoubleBool) DoubleBool;
        \\export fn kyn_id_td(value: TinyDouble) TinyDouble { return value; }
        \\export fn kyn_id_tu(value: TinyUDouble) TinyUDouble { return value; }
        \\export fn kyn_id_sd(value: SmallDouble) SmallDouble { return value; }
        \\export fn kyn_id_su(value: SmallUDouble) SmallUDouble { return value; }
        \\export fn kyn_id_dt(value: DoubleTiny) DoubleTiny { return value; }
        \\export fn kyn_id_ds(value: DoubleSmall) DoubleSmall { return value; }
        \\export fn kyn_id_bd(value: BoolDouble) BoolDouble { return value; }
        \\export fn kyn_id_db(value: DoubleBool) DoubleBool { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct TinyFloatPair { count: i8, low: f32, mid: f32 }
        \\struct BoolFloatPair { count: bool, low: f32, mid: f32 }
        \\struct SmallFloatPair { count: i16, low: f32, mid: f32 }
        \\struct TinyFloatPair64 { count: i8, low: f32, ratio: f64 }
        \\extern fn c_take_tff(value: TinyFloatPair) TinyFloatPair;
        \\extern fn c_take_bfp(value: BoolFloatPair) BoolFloatPair;
        \\extern fn c_take_sfp(value: SmallFloatPair) SmallFloatPair;
        \\extern fn c_take_tfp(value: TinyFloatPair64) TinyFloatPair64;
        \\export fn kyn_id_tff(value: TinyFloatPair) TinyFloatPair { return value; }
        \\export fn kyn_id_bfp(value: BoolFloatPair) BoolFloatPair { return value; }
        \\export fn kyn_id_sfp(value: SmallFloatPair) SmallFloatPair { return value; }
        \\export fn kyn_id_tfp(value: TinyFloatPair64) TinyFloatPair64 { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct TinyLong { count: i8, amount: i64 }
        \\struct LongTiny { amount: i64, count: i8 }
        \\struct SmallLong { count: i16, amount: i64 }
        \\struct LongSmall { amount: i64, count: i16 }
        \\struct IntLong { count: i32, amount: i64 }
        \\struct LongInt { amount: i64, count: i32 }
        \\extern fn c_take_tl(value: TinyLong) TinyLong;
        \\extern fn c_take_lt(value: LongTiny) LongTiny;
        \\extern fn c_take_sl(value: SmallLong) SmallLong;
        \\extern fn c_take_ls(value: LongSmall) LongSmall;
        \\extern fn c_take_il(value: IntLong) IntLong;
        \\extern fn c_take_li(value: LongInt) LongInt;
        \\export fn kyn_id_tl(value: TinyLong) TinyLong { return value; }
        \\export fn kyn_id_lt(value: LongTiny) LongTiny { return value; }
        \\export fn kyn_id_sl(value: SmallLong) SmallLong { return value; }
        \\export fn kyn_id_ls(value: LongSmall) LongSmall { return value; }
        \\export fn kyn_id_il(value: IntLong) IntLong { return value; }
        \\export fn kyn_id_li(value: LongInt) LongInt { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct Narrow { value: i16 }
        \\struct Wide { value: i32 }
        \\struct NestedNarrow { narrow: Narrow, amount: i64 }
        \\struct NestedWide { wide: Wide, amount: i64 }
        \\struct ReversedNested { amount: i64, narrow: Narrow }
        \\struct DoubledNarrow { narrow: Narrow, count: i16 }
        \\extern fn c_take_nn(value: NestedNarrow) NestedNarrow;
        \\extern fn c_take_nw(value: NestedWide) NestedWide;
        \\extern fn c_take_rn(value: ReversedNested) ReversedNested;
        \\extern fn c_take_dn(value: DoubledNarrow) DoubledNarrow;
        \\export fn kyn_id_nn(value: NestedNarrow) NestedNarrow { return value; }
        \\export fn kyn_id_nw(value: NestedWide) NestedWide { return value; }
        \\export fn kyn_id_rn(value: ReversedNested) ReversedNested { return value; }
        \\export fn kyn_id_dn(value: DoubledNarrow) DoubledNarrow { return value; }
        \\fn main() i32 { return 0; }
    );

    // `{ [2]i8, f64 }` is one packed INTEGER eightbyte followed by an SSE
    // double: an array member follows the same leaf rules as consecutive
    // members, so this layout is supported rather than rejected.
    try expectClean(
        \\struct SmallArrayDouble { count: [2]i8, amount: f64 }
        \\extern fn c_take(value: SmallArrayDouble);
        \\export fn kyn_take(value: SmallArrayDouble) SmallArrayDouble { return value; }
        \\fn main() i32 { return 0; }
    );
}

test "C ABI enum members accept exact layouts" {
    try expectClean(
        \\enum E8 : u8 { a = 2 }
        \\enum E16 : u16 { b = 3 }
        \\enum E32 : u32 { c = 100 }
        \\enum E64 : u64 { d = 4000 }
        \\struct Enum8Double { tag: E8, amount: f64 }
        \\struct Double8Enum { amount: f64, tag: E8 }
        \\struct Enum16Double { tag: E16, amount: f64 }
        \\struct Double16Enum { amount: f64, tag: E16 }
        \\struct Enum32Double { tag: E32, amount: f64 }
        \\struct Double32Enum { amount: f64, tag: E32 }
        \\struct Enum64Double { tag: E64, amount: f64 }
        \\struct Double64Enum { amount: f64, tag: E64 }
        \\struct Enum64Float { tag: E64, low: f32, mid: f32 }
        \\struct FloatPairEnum32 { low: f32, mid: f32, high: E32 }
        \\extern fn c_take_e8(value: Enum8Double) Enum8Double;
        \\extern fn c_take_d8(value: Double8Enum) Double8Enum;
        \\extern fn c_take_e16(value: Enum16Double) Enum16Double;
        \\extern fn c_take_d16(value: Double16Enum) Double16Enum;
        \\extern fn c_take_e32(value: Enum32Double) Enum32Double;
        \\extern fn c_take_d32(value: Double32Enum) Double32Enum;
        \\extern fn c_take_e64(value: Enum64Double) Enum64Double;
        \\extern fn c_take_d64(value: Double64Enum) Double64Enum;
        \\extern fn c_take_elf(value: Enum64Float) Enum64Float;
        \\extern fn c_take_fpe(value: FloatPairEnum32) FloatPairEnum32;
        \\export fn kyn_id_e8(value: Enum8Double) Enum8Double { return value; }
        \\export fn kyn_id_e32(value: Enum32Double) Enum32Double { return value; }
        \\export fn kyn_id_elf(value: Enum64Float) Enum64Float { return value; }
        \\fn main() i32 { return 0; }
    );
}

test "C ABI multi-member eightbyte layouts accept exact runs" {
    try expectClean(
        \\struct IntPackedDouble { low: i32, mid: i32, high: f64 }
        \\struct CharPackedDouble { a: i8, b: i16, high: f64 }
        \\struct ShortPackedFloat { a: i16, b: i16, face: f32 }
        \\struct SparseShorts { a: i16, b: i16, c: i16, d: i16, ratio: f64 }
        \\struct ShortIntFloatPack { l: i16, m: i16, h: i16, f: f32 }
        \\struct LongPairFloat2 { low: i64, mid: i32, high: f64 }
        \\struct UIntPairDouble { a: u32, b: u32, high: f64 }
        \\struct UIntPackedFloat { a: u16, b: u16, c: f32 }
        \\struct PackedIntFloat { l: i32, m: i32, f: f32 }
        \\struct TwoEnumShort { tag: u8, mid: u16, face: f32 }
        \\extern fn c_take_ipd(value: IntPackedDouble) IntPackedDouble;
        \\extern fn c_take_cpd(value: CharPackedDouble) CharPackedDouble;
        \\extern fn c_take_spf(value: ShortPackedFloat) ShortPackedFloat;
        \\extern fn c_take_sp(value: SparseShorts) SparseShorts;
        \\extern fn c_take_sip(value: ShortIntFloatPack) ShortIntFloatPack;
        \\extern fn c_take_lpd(value: LongPairFloat2) LongPairFloat2;
        \\extern fn c_take_upd(value: UIntPairDouble) UIntPairDouble;
        \\extern fn c_take_upf(value: UIntPackedFloat) UIntPackedFloat;
        \\extern fn c_take_pif(value: PackedIntFloat) PackedIntFloat;
        \\extern fn c_take_tes(value: TwoEnumShort) TwoEnumShort;
        \\export fn kyn_id_ipd(value: IntPackedDouble) IntPackedDouble { return value; }
        \\export fn kyn_id_cpd(value: CharPackedDouble) CharPackedDouble { return value; }
        \\export fn kyn_id_spf(value: ShortPackedFloat) ShortPackedFloat { return value; }
        \\export fn kyn_id_sp(value: SparseShorts) SparseShorts { return value; }
        \\export fn kyn_id_sip(value: ShortIntFloatPack) ShortIntFloatPack { return value; }
        \\export fn kyn_id_lpd(value: LongPairFloat2) LongPairFloat2 { return value; }
        \\export fn kyn_id_upd(value: UIntPairDouble) UIntPairDouble { return value; }
        \\export fn kyn_id_upf(value: UIntPackedFloat) UIntPackedFloat { return value; }
        \\export fn kyn_id_pif(value: PackedIntFloat) PackedIntFloat { return value; }
        \\export fn kyn_id_tes(value: TwoEnumShort) TwoEnumShort { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct FloatPairInt { low: f32, mid: f32, high: i32 }
        \\struct FloatPairUInt { low: f32, mid: f32, high: u32 }
        \\struct FloatPairLong { low: f32, mid: f32, high: i64 }
        \\struct IntPairFloat { a: i32, b: f32, c: f32 }
        \\struct UIntPairFloat { a: u32, b: f32, c: f32 }
        \\struct LongPairFloat { a: i64, b: f32, c: f32 }
        \\struct FloatPairDouble { a: f32, b: f32, c: f64 }
        \\struct DoubleFloats { a: f64, b: f32, c: f32 }
        \\struct FloatIntFloat64 { a: f32, b: i32, c: f64 }
        \\struct IntFloatDouble { a: i32, b: f32, c: f64 }
        \\struct FloatLongFloat { a: f32, b: f32, c: i32, d: f32 }
        \\struct FloatIntPair64 { a: f64, b: i32, c: f32 }
        \\struct FloatIntFloat4 { a: f32, b: i32, c: f32, d: f32 }
        \\extern fn c_take_fpi(value: FloatPairInt) FloatPairInt;
        \\extern fn c_take_fpu(value: FloatPairUInt) FloatPairUInt;
        \\extern fn c_take_fpl(value: FloatPairLong) FloatPairLong;
        \\extern fn c_take_ipf(value: IntPairFloat) IntPairFloat;
        \\extern fn c_take_upf(value: UIntPairFloat) UIntPairFloat;
        \\extern fn c_take_lpf(value: LongPairFloat) LongPairFloat;
        \\extern fn c_take_fdp(value: FloatPairDouble) FloatPairDouble;
        \\extern fn c_take_dmf(value: DoubleFloats) DoubleFloats;
        \\extern fn c_take_fid(value: FloatIntFloat64) FloatIntFloat64;
        \\extern fn c_take_ifd(value: IntFloatDouble) IntFloatDouble;
        \\extern fn c_take_flf(value: FloatLongFloat) FloatLongFloat;
        \\extern fn c_take_fip64(value: FloatIntPair64) FloatIntPair64;
        \\extern fn c_take_fip4(value: FloatIntFloat4) FloatIntFloat4;
        \\export fn kyn_id_fpi(value: FloatPairInt) FloatPairInt { return value; }
        \\export fn kyn_id_fpl(value: FloatPairLong) FloatPairLong { return value; }
        \\export fn kyn_id_ipf(value: IntPairFloat) IntPairFloat { return value; }
        \\export fn kyn_id_lpf(value: LongPairFloat) LongPairFloat { return value; }
        \\export fn kyn_id_dpf(value: DoubleFloats) DoubleFloats { return value; }
        \\export fn kyn_id_fid(value: FloatIntFloat64) FloatIntFloat64 { return value; }
        \\export fn kyn_id_ifd(value: IntFloatDouble) IntFloatDouble { return value; }
        \\export fn kyn_id_flf(value: FloatLongFloat) FloatLongFloat { return value; }
        \\export fn kyn_id_fip64(value: FloatIntPair64) FloatIntPair64 { return value; }
        \\export fn kyn_id_fip4(value: FloatIntFloat4) FloatIntFloat4 { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct FloatIntFloat { x: f32, count: i32, y: f32 }
        \\export fn kyn_identity(value: FloatIntFloat) FloatIntFloat { return value; }
        \\extern fn c_take(value: FloatIntFloat) FloatIntFloat;
        \\fn main() i32 { return 0; }
    );

    // `{ [2]i8, f64 }` is one packed INTEGER eightbyte followed by an SSE
    // double: an array member follows the same leaf rules as consecutive
    // members, so this layout is supported rather than rejected.
    try expectClean(
        \\struct SmallArrayDouble { count: [2]i8, amount: f64 }
        \\extern fn c_take(value: SmallArrayDouble);
        \\export fn kyn_take(value: SmallArrayDouble) SmallArrayDouble { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct FloatLeaf { value: f32 }
        \\struct NestedFloat { inner: FloatLeaf, amount: i64 }
        \\extern fn c_take_nested(value: NestedFloat) NestedFloat;
        \\export fn kyn_identity_nested(value: NestedFloat) NestedFloat { return value; }
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

    // `{ [2]i8, f64 }` is one packed INTEGER eightbyte followed by an SSE
    // double: an array member follows the same leaf rules as consecutive
    // members, so this layout is supported rather than rejected.
    try expectClean(
        \\struct SmallArrayDouble { count: [2]i8, amount: f64 }
        \\extern fn c_take(value: SmallArrayDouble);
        \\export fn kyn_take(value: SmallArrayDouble) SmallArrayDouble { return value; }
        \\fn main() i32 { return 0; }
    );

    try expectClean(
        \\struct FloatIntFloat { x: f32, count: i32, y: f32 }
        \\extern fn c_take(value: FloatIntFloat);
        \\export fn kyn_identity(value: FloatIntFloat) FloatIntFloat { return value; }
        \\fn main() i32 { return 0; }
    );

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

    try expectClean(
        \\struct DoublePair { x: f64, y: f64 }
        \\struct NestedPair { pair: DoublePair }
        \\extern fn c_take(pair: NestedPair) NestedPair;
        \\export fn kyn_identity(pair: NestedPair) NestedPair { return pair; }
        \\fn main() i32 { return 0; }
    );

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

test "exported globals take the source name and a C-representable type" {
    try expectClean(
        \\struct Point { x: i32, y: i32 }
        \\export var counter: i32 = 41;
        \\export let threshold: i32 = 7;
        \\export const origin: Point = Point { x: 0, y: 0 };
        \\export const flags: u8 = 200;
        \\fn main() i32 { counter = counter + 1; return counter + threshold; }
    );

    // A bare array has no by-value C layout, so it cannot be an exported
    // object even though the same type is fine as a Kyn-only global.
    try expectClean(
        \\const table: [2]i32 = [1, 2];
        \\fn main() i32 { return table[0]; }
    );
    try expectSemanticError(
        \\export const table: [2]i32 = [1, 2];
        \\fn main() i32 { return 0; }
    , "E0476");
}

test "a u128 maximum literal is usable where the type is already u128" {
    try expectClean(
        \\fn main() i32 {
        \\    let top: u128 = 340282366920938463463374607431768211455;
        \\    if (top != 340282366920938463463374607431768211455) { return 1; }
        \\    if (top < 18446744073709551615) { return 2; }
        \\    return 0;
        \\}
    );

    // One past the maximum does not fit any type.
    try expectSemanticError(
        \\fn main() i32 {
        \\    let big: u64 = 18446744073709551616;
        \\    return 0;
        \\}
    , "E0426");
}

test "pointer and integer casts reach and leave a function value" {
    try expectClean(
        \\extern fn get_callback() *u8;
        \\fn double(x: i32) i32 { return x * 2; }
        \\fn main() i32 {
        \\    let handler: fn(i32) i32 = get_callback() as fn(i32) i32;
        \\    let erased: *u8 = double as *u8;
        \\    let address: usize = erased as usize;
        \\    let again: fn(i32) i32 = address as fn(i32) i32;
        \\    return handler(1) + again(1);
        \\}
    );

    // A signature is not a representation: two function types do not cast.
    try expectSemanticError(
        \\fn main() i32 {
        \\    let handler: fn(i32) i32 = 1 as fn(i32) i32;
        \\    let other: fn(i64) i64 = handler as fn(i64) i64;
        \\    return 0;
        \\}
    , "E0447");

    // Nor does an aggregate reinterpret as one address.
    try expectSemanticError(
        \\struct Pair { a: i32, b: i32 }
        \\fn main() i32 {
        \\    let pair: Pair = Pair { a: 1, b: 2 };
        \\    let handler: fn(i32) i32 = pair as fn(i32) i32;
        \\    return 0;
        \\}
    , "E0447");
}

test "the root entry point accepts only the signatures the C runtime calls" {
    // All four shapes the loader can satisfy.
    try expectClean(
        \\fn main() i32 { return 0; }
    );
    try expectClean(
        \\fn main(argc: i32) i32 { return argc; }
    );
    try expectClean(
        \\fn main(argc: i32, argv: **u8) i32 { return argc; }
    );
    try expectClean(
        \\fn main(argc: i32, argv: **const u8) i32 { return argc; }
    );

    // A return type the exit status cannot carry.
    try expectSemanticError(
        \\fn main() f64 { return 1.5; }
    , "E0477");
    // `argv` must be the string vector, not one string.
    try expectSemanticError(
        \\fn main(argc: i32, argv: *u8) i32 { return argc; }
    , "E0477");
    // `argc` is an `int`, not a wider integer.
    try expectSemanticError(
        \\fn main(argc: u64) i32 { return 0; }
    , "E0477");
    // C passes two arguments, never three.
    try expectSemanticError(
        \\fn main(argc: i32, argv: **u8, envp: **u8) i32 { return argc; }
    , "E0477");

    // A library may expose `main` with any shape; only the unmarked root
    // declaration is the entry point, and an exported one is just a function.
    try expectClean(
        \\export fn main(argc: i32, argv: *u8) i32 { return 0; }
    );
}

test "a struct initializer names every field exactly once" {
    // Declaration order does not matter.
    try expectClean(
        \\struct Point { x: i32, y: i32 }
        \\fn main() i32 {
        \\    let p: Point = Point { y: 2, x: 1 };
        \\    return p.x + p.y;
        \\}
    );

    // A repeated field is rejected instead of the last value winning.
    try expectSemanticError(
        \\struct Point { x: i32, y: i32 }
        \\fn main() i32 {
        \\    let p: Point = Point { x: 1, y: 2, x: 3 };
        \\    return p.x;
        \\}
    , "E0404");

    // The rule applies to every nested initializer, not only the outermost.
    try expectSemanticError(
        \\struct Inner { a: i32 }
        \\struct Outer { inner: Inner }
        \\fn main() i32 {
        \\    let o: Outer = Outer { inner: Inner { a: 1, a: 2 } };
        \\    return o.inner.a;
        \\}
    , "E0404");
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

test "a local needs a type, an initializer, or both" {
    // Both forms are complete: a declared type with no value (the slot is
    // uninitialized, and reading it is the analyzer's `E0501`), and an
    // initializer with no declared type (the literal materializes).
    try expectClean(
        \\fn main() i32 {
        \\    var slot: i32;
        \\    slot = 7;
        \\    let inferred: i64 = 5;
        \\    return slot + inferred as i32;
        \\}
    );

    // Neither is `E0420`, and it is the only diagnostic. The parser used to
    // report the same condition as `E0216` before the analyzer ever ran, which
    // both made `E0420` unreachable and gave one rule two codes; asserting the
    // absence of the other code is what keeps that from coming back.
    try expectOnlyError(
        \\fn main() i32 {
        \\    let empty;
        \\    return 0;
        \\}
    , "E0420");
    try expectOnlyError(
        \\fn main() i32 {
        \\    var empty;
        \\    return 0;
        \\}
    , "E0420");
}

test "a declaration is visible after itself and not before" {
    // The scope begins after the declaration, so a later declaration is
    // reachable and an earlier use of it is not.
    try expectClean(
        \\fn main() i32 {
        \\    let value: i32 = 4;
        \\    return value;
        \\}
    );
    try expectSemanticError(
        \\fn main() i32 {
        \\    return later;
        \\}
    , "E0427");
    try expectSemanticError(
        \\fn main() i32 {
        \\    let shadowed: i32 = 1;
        \\    let shadowed: i32 = 2;
        \\    return shadowed;
        \\}
    , "E0421");
}
