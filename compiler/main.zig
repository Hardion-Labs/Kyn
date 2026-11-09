//! `kync` command line interface.

const std = @import("std");
const source = @import("source.zig");
const diagnostics = @import("diagnostics.zig");
const driver = @import("driver.zig");
const ast = @import("ast.zig");

const version = "0.1.0-alpha.2";

const Command = enum {
    check,
    emit_llvm,
    emit_obj,
    build,
    run,
};

const ParseResult = union(enum) {
    options: Options,
    help,
    version,
};

const usage_text =
    \\Kyn compiler
    \\
    \\Usage:
    \\  kync <command> [options] <file.kyn>
    \\
    \\Commands:
    \\  check       Parse and type-check only
    \\  emit-llvm   Emit textual LLVM IR
    \\  emit-obj    Emit a native object file
    \\  build       Build a native executable (default)
    \\  run         Build and execute a native executable
    \\
    \\Options:
    \\  -o <path>          Output path
    \\  --profile <name>   debug | safe | release | fast (default: safe)
    \\  --cc <path>        C compiler used for assembly/linking (default: clang)
    \\  --keep-ir          Keep the generated .ll file
    \\  --                 Pass the remaining arguments to the program (run)
    \\  -h, --help         Show this help
    \\  --version          Show compiler version
    \\
;

const Options = struct {
    command: Command = .build,
    file: ?[]const u8 = null,
    output: ?[]const u8 = null,
    profile: driver.Profile = .safe,
    cc: []const u8 = "clang",
    keep_ir: bool = false,
    program_args: []const []const u8 = &.{},
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    const parsed = parseArgs(arena, args) catch |err| {
        try out.print("kyn: {s}\n\n{s}", .{ @errorName(err), usage_text });
        try out.flush();
        return 2;
    } orelse {
        try out.writeAll(usage_text);
        try out.flush();
        return 0;
    };
    const opts: Options = switch (parsed) {
        .options => |value| value,
        .help => {
            try out.writeAll(usage_text);
            try out.flush();
            return 0;
        },
        .version => {
            try out.print("kync {s}\n", .{version});
            try out.flush();
            return 0;
        },
    };
    if (opts.file == null) {
        try out.writeAll(usage_text);
        try out.flush();
        return 2;
    }

    const path = opts.file.?;
    var src: source.Source = undefined;
    var reporter: diagnostics.Reporter = undefined;
    var program: ?*ast.Program = null;

    const result = driver.compile(arena, io, path, &src, &reporter, &program) catch |err| {
        try out.print("kyn: internal compiler error: {s}\n", .{@errorName(err)});
        try out.flush();
        return 70;
    };
    if (result == null) return 1;

    if (opts.command == .check) {
        try out.print("ok: {s}\n", .{path});
        try out.flush();
        return 0;
    }

    const stem = driver.defaultStem(arena, path) catch return 2;
    const exe_path = opts.output orelse stem;
    const ll_target = if (opts.command == .emit_llvm)
        (opts.output orelse try std.fmt.allocPrint(arena, "{s}.ll", .{stem}))
    else if (opts.output) |output|
        try std.fmt.allocPrint(arena, "{s}.ll", .{output})
    else
        try std.fmt.allocPrint(arena, "{s}.ll", .{stem});

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ll_target, .data = result.?.ll }) catch |err| {
        try out.print("kyn: cannot write '{s}': {s}\n", .{ ll_target, @errorName(err) });
        try out.flush();
        return 2;
    };

    if (opts.command == .emit_llvm) {
        try out.print("emitted {s}\n", .{ll_target});
        try out.flush();
        return 0;
    }

    var clang_args: std.ArrayList([]const u8) = .empty;
    try clang_args.append(arena, ll_target);
    switch (opts.command) {
        .emit_obj => {
            const obj_path = opts.output orelse try std.fmt.allocPrint(arena, "{s}.o", .{stem});
            try clang_args.appendSlice(arena, &.{ "-c", "-o", obj_path });
            try clang_args.appendSlice(arena, opts.profile.optimizationFlags());
            try clang_args.append(arena, "-fno-strict-aliasing");
            const tool = try driver.runTool(arena, io, opts.cc, clang_args.items);
            if (!opts.keep_ir) std.Io.Dir.cwd().deleteFile(io, ll_target) catch {};
            if (!tool.ok) return 3;
            try out.print("emitted {s}\n", .{obj_path});
            try out.flush();
            return 0;
        },
        .build, .run => {
            try clang_args.appendSlice(arena, &.{ "-o", exe_path });
            try clang_args.appendSlice(arena, opts.profile.optimizationFlags());
            try clang_args.append(arena, "-fno-strict-aliasing");
            const tool = try driver.runTool(arena, io, opts.cc, clang_args.items);
            if (!tool.ok) return 3;
            if (!opts.keep_ir) std.Io.Dir.cwd().deleteFile(io, ll_target) catch {};
            if (opts.command == .build) {
                try out.print("built {s}\n", .{exe_path});
                try out.flush();
                return 0;
            }
            const code = try driver.runProgram(arena, io, exe_path, opts.program_args);
            return code;
        },
        .check, .emit_llvm => unreachable,
    }
}

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) !?ParseResult {
    _ = arena;
    var options: Options = .{};
    var index: usize = 1;
    if (index >= args.len) return null;

    if (std.mem.eql(u8, args[index], "-h") or std.mem.eql(u8, args[index], "--help")) return .{ .help = {} };
    if (std.mem.eql(u8, args[index], "--version")) return .{ .version = {} };

    if (commandByName(args[index])) |command| {
        options.command = command;
        index += 1;
    }

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            options.program_args = args[index + 1 ..];
            break;
        }
        if (std.mem.eql(u8, arg, "-o")) {
            index += 1;
            if (index >= args.len) return error.MissingOutputPath;
            options.output = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--profile")) {
            index += 1;
            if (index >= args.len) return error.MissingProfile;
            options.profile = driver.Profile.parse(args[index]) orelse return error.InvalidProfile;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cc")) {
            index += 1;
            if (index >= args.len) return error.MissingCompiler;
            options.cc = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--keep-ir")) {
            options.keep_ir = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .{ .help = {} };
        if (std.mem.eql(u8, arg, "--version")) return .{ .version = {} };
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
        if (options.file != null) return error.MultipleInputFiles;
        options.file = arg;
    }
    return .{ .options = options };
}

fn commandByName(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, "check")) return .check;
    if (std.mem.eql(u8, name, "emit-llvm")) return .emit_llvm;
    if (std.mem.eql(u8, name, "emit-obj")) return .emit_obj;
    if (std.mem.eql(u8, name, "build")) return .build;
    if (std.mem.eql(u8, name, "run")) return .run;
    return null;
}
