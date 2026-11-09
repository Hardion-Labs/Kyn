//! kyn-build: project orchestration for Kyn, C and Zig.
//!
//! The build file is intentionally small and declarative:
//!
//!   project "hello"
//!   target "hello" {
//!       kind: "exe"
//!       sources: ["src/main.kyn"]
//!       c_sources: ["src/helper.c"]
//!       zig_sources: ["zig/math.zig"]
//!       include_dirs: ["include"]
//!       libs: ["m"]
//!       profile: "safe"
//!   }
//!
//! Build incrementality is content based: a target is skipped only when the
//! SHA-256 of its configuration and every input file matches the stored stamp.

const std = @import("std");

const version = "0.1.0-alpha.1";

const Kind = enum {
    exe,
    staticlib,
    sharedlib,

    fn parse(text: []const u8) ?Kind {
        if (std.mem.eql(u8, text, "exe")) return .exe;
        if (std.mem.eql(u8, text, "staticlib")) return .staticlib;
        if (std.mem.eql(u8, text, "sharedlib")) return .sharedlib;
        return null;
    }
};

const Target = struct {
    name: []const u8,
    kind: Kind = .exe,
    kyn_sources: std.ArrayList([]const u8) = .empty,
    c_sources: std.ArrayList([]const u8) = .empty,
    zig_sources: std.ArrayList([]const u8) = .empty,
    include_dirs: std.ArrayList([]const u8) = .empty,
    libs: std.ArrayList([]const u8) = .empty,
    lib_dirs: std.ArrayList([]const u8) = .empty,
    cflags: std.ArrayList([]const u8) = .empty,
    profile: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

const Config = struct {
    project: []const u8 = "kyn-project",
    targets: std.ArrayList(*Target) = .empty,
};

const BuildError = error{
    InvalidConfig,
    MissingTarget,
    BuildFailed,
    OutOfMemory,
};

const Options = struct {
    file: []const u8 = "kyn.build",
    target: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    kync: ?[]const u8 = null,
    cc: []const u8 = "clang",
    zig: []const u8 = "zig",
    clean: bool = false,
    force: bool = false,
    verbose: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file.interface;

    const options = parseArgs(args) catch {
        try out.writeAll(usage_text);
        try out.flush();
        return 2;
    };
    if (options == null) {
        try out.writeAll(usage_text);
        try out.flush();
        return 0;
    }
    const opts = options.?;

    const cwd = try std.process.currentPathAlloc(io, arena);
    const config_dir = std.fs.path.dirname(opts.file) orelse ".";
    const project_dir = try std.fs.path.resolve(arena, &.{ cwd, config_dir });
    const config_path = try std.fs.path.resolve(arena, &.{ cwd, opts.file });

    if (opts.clean) {
        const build_dir = try std.fs.path.join(arena, &.{ project_dir, "build" });
        std.Io.Dir.cwd().deleteTree(io, build_dir) catch {};
    }

    const config_text = std.Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("kyn-build: cannot read '{s}': {s}\n", .{ opts.file, @errorName(err) });
        return 2;
    };

    var config = Config{};
    parseConfig(arena, config_text, opts.file, &config) catch {
        return 2;
    };

    const kync = resolveKync(arena, io, opts.kync) catch "kync";
    const build_root = try std.fs.path.join(arena, &.{ project_dir, "build" });
    try std.Io.Dir.cwd().createDirPath(io, build_root);

    var built: usize = 0;
    for (config.targets.items) |target| {
        if (opts.target) |wanted| {
            if (!std.mem.eql(u8, wanted, target.name)) continue;
        }
        const profile_text = opts.profile orelse target.profile orelse "safe";
        const profile = parseProfile(profile_text) orelse {
            std.debug.print("kyn-build: invalid profile '{s}'\n", .{profile_text});
            return 2;
        };

        const ok = buildTarget(
            arena,
            io,
            project_dir,
            build_root,
            kync,
            opts,
            target,
            profile,
            out,
        ) catch |err| {
            std.debug.print("kyn-build: target '{s}' failed: {s}\n", .{ target.name, @errorName(err) });
            return 3;
        };
        if (!ok) return 3;
        built += 1;
    }

    if (built == 0) {
        std.debug.print("kyn-build: no target matched\n", .{});
        return 2;
    }
    try out.flush();
    return 0;
}

fn buildTarget(
    arena: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    build_root: []const u8,
    kync: []const u8,
    opts: Options,
    target: *Target,
    profile: Profile,
    out: *std.Io.Writer,
) !bool {
    const target_dir = try std.fs.path.join(arena, &.{ build_root, target.name });
    try std.Io.Dir.cwd().createDirPath(io, target_dir);

    const output = try outputPath(arena, project_dir, target_dir, target);
    const stamp_path = try std.fs.path.join(arena, &.{ target_dir, ".kyn-stamp" });

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(target.name);
    hasher.update(@tagName(target.kind));
    hasher.update(@tagName(profile));
    for (target.kyn_sources.items) |source| {
        hasher.update(source);
        try hashFile(arena, io, &hasher, project_dir, source);
    }
    for (target.c_sources.items) |source| {
        hasher.update(source);
        try hashFile(arena, io, &hasher, project_dir, source);
    }
    for (target.zig_sources.items) |source| {
        hasher.update(source);
        try hashFile(arena, io, &hasher, project_dir, source);
    }
    for (target.cflags.items) |flag| hasher.update(flag);
    for (target.include_dirs.items) |dir| hasher.update(dir);
    for (target.libs.items) |lib| hasher.update(lib);
    for (target.lib_dirs.items) |dir| hasher.update(dir);
    hasher.update(kync);
    hasher.update(opts.cc);
    hasher.update(opts.zig);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const stamp = try std.fmt.allocPrint(arena, "{s}\n", .{digest_hex});

    const cached = !opts.force and fileExists(io, stamp_path) and fileExists(io, output);
    if (cached) {
        const previous = std.Io.Dir.cwd().readFileAlloc(io, stamp_path, arena, .limited(256)) catch "";
        if (std.mem.eql(u8, previous, stamp)) {
            try out.print("  {s}: up to date\n", .{target.name});
            return true;
        }
    }

    try out.print("  {s}: building ({s})\n", .{ target.name, @tagName(profile) });
    try out.flush();

    var objects: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;

    for (target.kyn_sources.items) |source| {
        const object = try std.fmt.allocPrint(arena, "{s}/kyn-{d}.o", .{ target_dir, index });
        index += 1;
        const source_abs = try std.fs.path.join(arena, &.{ project_dir, source });
        const argv = &.{
            kync,        "emit-obj",     source_abs, "-o",    object,
            "--profile", profile.name(), "--cc",     opts.cc,
        };
        if (!(try run(arena, io, project_dir, argv, opts.verbose))) return false;
        try objects.append(arena, object);
    }

    for (target.c_sources.items) |source| {
        const object = try std.fmt.allocPrint(arena, "{s}/c-{d}.o", .{ target_dir, index });
        index += 1;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ opts.cc, "-c", source, "-o", object });
        try argv.appendSlice(arena, profile.clangFlags());
        try argv.append(arena, "-fno-strict-aliasing");
        try argv.append(arena, "-fPIC");
        for (target.include_dirs.items) |dir| {
            try argv.append(arena, try std.fmt.allocPrint(arena, "-I{s}", .{dir}));
        }
        for (target.cflags.items) |flag| try argv.append(arena, flag);
        if (!(try run(arena, io, project_dir, argv.items, opts.verbose))) return false;
        try objects.append(arena, object);
    }

    for (target.zig_sources.items) |source| {
        const object = try std.fmt.allocPrint(arena, "{s}/zig-{d}.o", .{ target_dir, index });
        index += 1;
        const argv = &.{
            opts.zig,                                                   "build-obj", source,
            try std.fmt.allocPrint(arena, "-femit-bin={s}", .{object}), "-O",        profile.zigMode(),
            "-fPIC",
        };
        if (!(try run(arena, io, project_dir, argv, opts.verbose))) return false;
        try objects.append(arena, object);
    }

    if (objects.items.len == 0) {
        std.debug.print("kyn-build: target '{s}' has no sources\n", .{target.name});
        return false;
    }

    switch (target.kind) {
        .exe, .sharedlib => {
            var argv: std.ArrayList([]const u8) = .empty;
            if (target.zig_sources.items.len > 0) {
                try argv.append(arena, opts.zig);
                try argv.append(arena, "cc");
            } else {
                try argv.append(arena, opts.cc);
            }
            if (target.kind == .sharedlib) try argv.append(arena, "-shared");
            try argv.appendSlice(arena, objects.items);
            try argv.appendSlice(arena, &.{ "-o", output });
            try argv.append(arena, "-fno-strict-aliasing");
            for (target.lib_dirs.items) |dir| {
                try argv.append(arena, try std.fmt.allocPrint(arena, "-L{s}", .{dir}));
            }
            for (target.libs.items) |lib| {
                try argv.append(arena, try std.fmt.allocPrint(arena, "-l{s}", .{lib}));
            }
            if (!(try run(arena, io, project_dir, argv.items, opts.verbose))) return false;
        },
        .staticlib => {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(arena, "ar");
            try argv.append(arena, "rcs");
            try argv.append(arena, output);
            try argv.appendSlice(arena, objects.items);
            if (!(try run(arena, io, project_dir, argv.items, opts.verbose))) return false;
        },
    }

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stamp_path, .data = stamp }) catch |err| {
        std.debug.print("kyn-build: cannot write stamp: {s}\n", .{@errorName(err)});
        return false;
    };
    try out.print("  {s}: {s}\n", .{ target.name, output });
    return true;
}

const Profile = enum {
    debug,
    safe,
    release,
    fast,

    fn name(self: Profile) []const u8 {
        return @tagName(self);
    }

    fn clangFlags(self: Profile) []const []const u8 {
        return switch (self) {
            .debug => &.{ "-O0", "-g" },
            .safe => &.{"-O2"},
            .release => &.{"-O3"},
            .fast => &.{"-O3"},
        };
    }

    fn zigMode(self: Profile) []const u8 {
        return switch (self) {
            .debug => "Debug",
            .safe => "ReleaseSafe",
            .release, .fast => "ReleaseFast",
        };
    }
};

fn parseProfile(text: []const u8) ?Profile {
    if (std.mem.eql(u8, text, "debug")) return .debug;
    if (std.mem.eql(u8, text, "safe")) return .safe;
    if (std.mem.eql(u8, text, "release")) return .release;
    if (std.mem.eql(u8, text, "fast")) return .fast;
    return null;
}

fn outputPath(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    target_dir: []const u8,
    target: *Target,
) ![]const u8 {
    if (target.output) |output| {
        return std.fs.path.resolve(arena, &.{ project_dir, output });
    }
    return switch (target.kind) {
        .exe => std.fs.path.join(arena, &.{ target_dir, target.name }),
        .staticlib => std.fmt.allocPrint(arena, "{s}/lib{s}.a", .{ target_dir, target.name }),
        .sharedlib => std.fmt.allocPrint(arena, "{s}/lib{s}.so", .{ target_dir, target.name }),
    };
}

fn hashFile(
    arena: std.mem.Allocator,
    io: std.Io,
    hasher: *std.crypto.hash.sha2.Sha256,
    base: []const u8,
    relative: []const u8,
) !void {
    const path = try std.fs.path.resolve(arena, &.{ base, relative });
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("kyn-build: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        return error.FileNotFound;
    };
    hasher.update(data);
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    verbose: bool,
) !bool {
    if (verbose) {
        std.debug.print("  $", .{});
        for (argv) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print("\n", .{});
    }
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    }) catch |err| {
        std.debug.print("kyn-build: cannot execute '{s}': {s}\n", .{ argv[0], @errorName(err) });
        return false;
    };
    if (result.stdout.len > 0 and verbose) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn resolveKync(arena: std.mem.Allocator, io: std.Io, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |path| return path;
    const exe = std.process.executablePathAlloc(io, arena) catch return "kync";
    const dir = std.fs.path.dirname(exe) orelse return "kync";
    const candidate = try std.fs.path.join(arena, &.{ dir, "kync" });
    if (fileExists(io, candidate)) return candidate;
    return "kync";
}

// ---------------------------------------------------------------------------
// Build file parser
// ---------------------------------------------------------------------------

fn parseConfig(arena: std.mem.Allocator, text: []const u8, path: []const u8, config: *Config) BuildError!void {
    var current: ?*Target = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = trimComment(raw_line);
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "project")) {
            const rest = std.mem.trim(u8, line["project".len..], " \t");
            config.project = unquote(rest) orelse {
                configError(path, line_number, "expected a quoted project name", .{});
                return error.InvalidConfig;
            };
            continue;
        }

        if (std.mem.startsWith(u8, line, "target")) {
            if (current != null) {
                configError(path, line_number, "nested target blocks are not allowed", .{});
                return error.InvalidConfig;
            }
            const rest = std.mem.trim(u8, line["target".len..], " \t");
            const brace = std.mem.indexOfScalar(u8, rest, '{') orelse {
                configError(path, line_number, "expected {{ after target name", .{});
                return error.InvalidConfig;
            };
            const name_text = std.mem.trim(u8, rest[0..brace], " \t");
            const name = unquote(name_text) orelse {
                configError(path, line_number, "expected a quoted target name", .{});
                return error.InvalidConfig;
            };
            const target = try arena.create(Target);
            target.* = .{ .name = name };
            try config.targets.append(arena, target);
            current = target;
            continue;
        }

        if (std.mem.eql(u8, line, "}")) {
            if (current == null) {
                configError(path, line_number, "unexpected }}.", .{});
                return error.InvalidConfig;
            }
            current = null;
            continue;
        }

        const target = current orelse {
            configError(path, line_number, "expected 'project' or 'target'", .{});
            return error.InvalidConfig;
        };

        const separator = std.mem.indexOfAny(u8, line, ":=") orelse {
            configError(path, line_number, "expected 'key: value'", .{});
            return error.InvalidConfig;
        };
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");

        if (std.mem.eql(u8, key, "kind")) {
            const text_value = unquote(value) orelse value;
            target.kind = Kind.parse(text_value) orelse {
                configError(path, line_number, "unknown target kind '{s}'", .{text_value});
                return error.InvalidConfig;
            };
        } else if (std.mem.eql(u8, key, "sources")) {
            target.kyn_sources = try parseList(arena, value, path, line_number);
        } else if (std.mem.eql(u8, key, "c_sources")) {
            target.c_sources = try parseList(arena, value, path, line_number);
        } else if (std.mem.eql(u8, key, "zig_sources")) {
            target.zig_sources = try parseList(arena, value, path, line_number);
        } else if (std.mem.eql(u8, key, "include_dirs")) {
            target.include_dirs = try parseList(arena, value, path, line_number);
        } else if (std.mem.eql(u8, key, "libs")) {
            target.libs = try parseList(arena, value, path, line_number);
        } else if (std.mem.eql(u8, key, "lib_dirs")) {
            target.lib_dirs = try parseList(arena, value, path, line_number);
        } else if (std.mem.eql(u8, key, "cflags")) {
            target.cflags = try parseList(arena, value, path, line_number);
        } else if (std.mem.eql(u8, key, "profile")) {
            target.profile = unquote(value) orelse value;
        } else if (std.mem.eql(u8, key, "output")) {
            target.output = unquote(value) orelse value;
        } else {
            configError(path, line_number, "unknown key '{s}'", .{key});
            return error.InvalidConfig;
        }
    }

    if (current != null) {
        configError(path, line_number, "unterminated target block", .{});
        return error.InvalidConfig;
    }
    if (config.targets.items.len == 0) {
        configError(path, 0, "no targets defined", .{});
        return error.InvalidConfig;
    }
}

fn parseList(
    arena: std.mem.Allocator,
    value: []const u8,
    path: []const u8,
    line: usize,
) BuildError!std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    const trimmed = std.mem.trim(u8, value, " \t");
    if (!std.mem.startsWith(u8, trimmed, "[") or !std.mem.endsWith(u8, trimmed, "]")) {
        configError(path, line, "expected an array of quoted strings", .{});
        return error.InvalidConfig;
    }
    const inner = trimmed[1 .. trimmed.len - 1];
    var index: usize = 0;
    while (index < inner.len) {
        while (index < inner.len and (inner[index] == ' ' or inner[index] == '\t' or inner[index] == ',')) index += 1;
        if (index >= inner.len) break;
        if (inner[index] != '"') {
            configError(path, line, "expected a quoted string in array", .{});
            return error.InvalidConfig;
        }
        index += 1;
        const start = index;
        while (index < inner.len and inner[index] != '"') index += 1;
        if (index >= inner.len) {
            configError(path, line, "unterminated string in array", .{});
            return error.InvalidConfig;
        }
        try result.append(arena, try arena.dupe(u8, inner[start..index]));
        index += 1;
    }
    return result;
}

fn unquote(text: []const u8) ?[]const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    return null;
}

fn trimComment(line: []const u8) []const u8 {
    var in_string = false;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (line[index] == '"') in_string = !in_string;
        if (!in_string and line[index] == '/' and index + 1 < line.len and line[index + 1] == '/') {
            return std.mem.trim(u8, line[0..index], " \t\r");
        }
    }
    return std.mem.trim(u8, line, " \t\r");
}

fn configError(path: []const u8, line: usize, comptime format: []const u8, args: anytype) void {
    std.debug.print("kyn-build: {s}:{d}: error: ", .{ path, line });
    std.debug.print(format, args);
    std.debug.print("\n", .{});
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const usage_text =
    \\kyn-build — build Kyn, C and Zig projects
    \\
    \\Usage:
    \\  kyn-build [options]
    \\
    \\Options:
    \\  --file <path>      Build file (default: kyn.build)
    \\  --target <name>    Build only one target
    \\  --profile <name>   debug | safe | release | fast
    \\  --kync <path>      Kyn compiler to use
    \\  --cc <path>        C compiler (default: clang)
    \\  --zig <path>       Zig compiler (default: zig)
    \\  --clean            Remove the build directory first
    \\  --force            Rebuild even when the stamp matches
    \\  --verbose          Print each tool invocation
    \\  -h, --help         Show this help
    \\  --version          Show version
    \\
;

fn parseArgs(args: []const []const u8) !?Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return null;
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("kyn-build {s}\n", .{version});
            return null;
        }
        if (std.mem.eql(u8, arg, "--file")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.file = args[index];
        } else if (std.mem.eql(u8, arg, "--target")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.target = args[index];
        } else if (std.mem.eql(u8, arg, "--profile")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.profile = args[index];
        } else if (std.mem.eql(u8, arg, "--kync")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.kync = args[index];
        } else if (std.mem.eql(u8, arg, "--cc")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.cc = args[index];
        } else if (std.mem.eql(u8, arg, "--zig")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.zig = args[index];
        } else if (std.mem.eql(u8, arg, "--clean")) {
            options.clean = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}
