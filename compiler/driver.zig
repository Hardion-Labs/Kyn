//! Compiler driver: orchestrates the pipeline and the optional external
//! toolchain (clang) used for object generation and linking.

const std = @import("std");
const source = @import("source.zig");
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
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("kyn: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        return null;
    };

    src.* = try source.Source.init(arena, path, text);
    reporter.* = diagnostics.Reporter.init(arena, src);

    var lex = lexer.Lexer.init(arena, src, reporter);
    const tokens = try lex.tokenize();
    if (reporter.hasErrors()) {
        renderDiagnostics(reporter);
        return null;
    }

    var parse = parser.Parser.init(arena, tokens, reporter);
    const program = try parse.parse();
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
