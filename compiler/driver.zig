//! Compiler driver: orchestrates the pipeline and the optional external
//! toolchain (clang) used for object generation and linking.

const std = @import("std");
const source = @import("source.zig");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const sema_mod = @import("sema.zig");
const analyzer_mod = @import("analyzer.zig");
const ir = @import("ir.zig");
const llvm = @import("backend/llvm.zig");

pub const Profile = enum {
    debug,
    safe,
    release,
    fast,

    pub fn parse(text: []const u8) ?Profile {
        if (std.mem.eql(u8, text, "debug")) return .debug;
        if (std.mem.eql(u8, text, "safe")) return .safe;
        if (std.mem.eql(u8, text, "release")) return .release;
        if (std.mem.eql(u8, text, "fast")) return .fast;
        return null;
    }

    pub fn optimizationFlags(self: Profile) []const []const u8 {
        return switch (self) {
            .debug => &.{ "-O0", "-g" },
            .safe => &.{"-O2"},
            .release => &.{"-O3"},
            .fast => &.{"-O3"},
        };
    }
};

pub const CompileResult = struct {
    ll: []const u8,
    had_warnings: bool,
};

/// Run the full frontend and lower to LLVM IR. The caller owns `arena`.
/// Returns null when diagnostics contain errors.
pub fn compile(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    src: *source.Source,
    reporter: *diagnostics.Reporter,
    program_out: *?*@import("ast.zig").Program,
) !?CompileResult {
    reporter.* = diagnostics.Reporter.init(arena, src);
    const program = try loadProgram(arena, io, path, src, reporter);
    program_out.* = program;
    if (reporter.hasErrors()) {
        renderDiagnostics(reporter);
        return null;
    }

    var prims = try types.Primitives.init(arena);
    var sema = sema_mod.Sema.init(arena, reporter, &prims);
    try sema.analyze(program);
    if (reporter.hasErrors()) {
        renderDiagnostics(reporter);
        return null;
    }

    var analyzer = analyzer_mod.Analyzer.init(arena, reporter);
    try analyzer.analyze(program);
    if (reporter.hasErrors()) {
        renderDiagnostics(reporter);
        return null;
    }

    const had_warnings = reporter.warning_count > 0;
    if (had_warnings) renderDiagnostics(reporter);

    var module = ir.Module.init(arena);
    var lowering = llvm.Lowering.init(arena, reporter, &module);
    try lowering.lower(program);
    if (reporter.hasErrors()) {
        renderDiagnostics(reporter);
        return null;
    }

    var output: std.Io.Writer.Allocating = .init(arena);
    var emitter = llvm.Emitter.init(arena, &module);
    try emitter.emit(&output.writer);
    const ll = try output.toOwnedSlice();
    return .{ .ll = ll, .had_warnings = had_warnings };
}

const ModuleVisit = enum { visiting, complete };

const ModuleRecord = struct {
    visit: ModuleVisit,
    source_id: u32,
};

const ModuleLoader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    reporter: *diagnostics.Reporter,
    root_source: *source.Source,
    visits: std.StringHashMap(ModuleRecord),
    declarations: std.ArrayList(*ast.Decl) = .empty,
    imports: std.ArrayList(ast.ImportDecl) = .empty,
    next_source_id: u32 = 1,

    fn load(self: *ModuleLoader, path: []const u8, display_path: []const u8, root: bool, import_span: source.Span) !u32 {
        if (self.visits.get(path)) |record| {
            if (record.visit == .visiting) try self.reporter.err("E0231", import_span, "cyclic import involving '{s}'", .{path});
            return record.source_id;
        }
        const module_id = if (root) 0 else self.next_source_id;
        if (!root) self.next_source_id += 1;
        try self.visits.put(path, .{ .visit = .visiting, .source_id = module_id });
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024 * 1024)) catch |err| {
            if (root) {
                std.debug.print("kyn: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
            } else {
                std.debug.print("kyn: cannot read imported source '{s}': {s}\n", .{ path, @errorName(err) });
            }
            try self.reporter.err("E0232", import_span, "cannot read source file '{s}'", .{path});
            return module_id;
        };
        const module_source: *source.Source = if (root) self.root_source else blk: {
            const created = try self.allocator.create(source.Source);
            created.* = try source.Source.initWithId(self.allocator, path, text, module_id);
            try self.reporter.addSource(created);
            break :blk created;
        };
        if (root) module_source.* = try source.Source.initWithId(self.allocator, display_path, text, module_id);

        var lex = lexer.Lexer.init(self.allocator, module_source, self.reporter);
        const tokens = try lex.tokenize();
        var parse = parser.Parser.init(self.allocator, tokens, self.reporter);
        const parsed = try parse.parse();
        if (self.reporter.hasErrors()) return module_id;

        const dir = std.fs.path.dirname(path) orelse ".";
        for (parsed.imports) |*imp| {
            const imported_path = try std.fs.path.resolve(self.allocator, &.{ dir, imp.path });
            imp.target_module_id = try self.load(imported_path, imported_path, false, imp.span);
            try self.imports.append(self.allocator, imp.*);
            if (self.reporter.hasErrors()) return module_id;
        }
        try self.declarations.appendSlice(self.allocator, parsed.decls);
        try self.visits.put(path, .{ .visit = .complete, .source_id = module_id });
        return module_id;
    }
};

fn loadProgram(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    root_source: *source.Source,
    reporter: *diagnostics.Reporter,
) !*ast.Program {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    const absolute_path = try std.fs.path.resolve(allocator, &.{ cwd, path });
    root_source.* = try source.Source.initWithId(allocator, path, "", 0);
    var loader: ModuleLoader = .{
        .allocator = allocator,
        .io = io,
        .reporter = reporter,
        .root_source = root_source,
        .visits = std.StringHashMap(ModuleRecord).init(allocator),
    };
    _ = try loader.load(absolute_path, path, true, .{ .start = 0, .end = 0 });
    const program = try allocator.create(ast.Program);
    program.* = .{
        .decls = try loader.declarations.toOwnedSlice(allocator),
        .imports = try loader.imports.toOwnedSlice(allocator),
    };
    return program;
}

pub fn renderDiagnostics(reporter: *const diagnostics.Reporter) void {
    const rendered = reporter.renderAlloc() catch {
        std.debug.print("kyn: failed to render diagnostics\n", .{});
        return;
    };
    std.debug.print("{s}", .{rendered});
}

pub fn defaultStem(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const basename = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, basename, ".kyn")) {
        return try allocator.dupe(u8, basename[0 .. basename.len - 4]);
    }
    return try allocator.dupe(u8, basename);
}

pub const ToolResult = struct {
    ok: bool,
    exit_code: u8,
};

/// Run clang (or another C compiler) with the given arguments.
pub fn runTool(
    arena: std.mem.Allocator,
    io: std.Io,
    compiler: []const u8,
    args: []const []const u8,
) !ToolResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, compiler);
    try argv.appendSlice(arena, args);

    const result = std.process.run(arena, io, .{ .argv = argv.items }) catch |err| {
        std.debug.print("kyn: failed to execute '{s}': {s}\n", .{ compiler, @errorName(err) });
        return .{ .ok = false, .exit_code = 127 };
    };

    if (result.stderr.len > 0 and !isSuccessful(result.term)) {
        std.debug.print("{s}", .{result.stderr});
    }
    if (!isSuccessful(result.term)) {
        return .{ .ok = false, .exit_code = termCode(result.term) };
    }
    return .{ .ok = true, .exit_code = 0 };
}

pub fn runProgram(
    arena: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    program_args: []const []const u8,
) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    const run_path = if (std.mem.indexOfScalar(u8, executable, '/') == null)
        try std.fmt.allocPrint(arena, "./{s}", .{executable})
    else
        executable;
    try argv.append(arena, run_path);
    try argv.appendSlice(arena, program_args);
    const result = std.process.run(arena, io, .{ .argv = argv.items }) catch |err| {
        std.debug.print("kyn: failed to execute '{s}': {s}\n", .{ executable, @errorName(err) });
        return 127;
    };
    if (result.stdout.len > 0) {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
        const out = &stdout.interface;
        try out.writeAll(result.stdout);
        try out.flush();
    }
    if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
    return termCode(result.term);
}

pub fn isSuccessful(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @truncate(128 + @backingInt(signal)),
        .stopped => |signal| @truncate(128 + @backingInt(signal)),
        .unknown => 1,
    };
}
