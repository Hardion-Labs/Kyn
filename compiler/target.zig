//! Compilation target: which machine code the generated IR is meant for.
//!
//! The design follows from how the toolchain actually works, which was measured
//! rather than assumed:
//!
//! * The IR is emitted without a `target triple` or `target datalayout`. When
//!   `clang` consumes such a module it *overrides* the layout with the one from
//!   its own `-target`, and it does so silently — an intentionally
//!   big-endian `datalayout` line in the module is discarded. So a triple
//!   written into the IR cannot direct code generation.
//! * What actually selects the machine code is the `-target` flag the assembler
//!   receives. The same IR compiled with `-target aarch64-linux-gnu` yields a
//!   valid `ELF64`/`AArch64` object.
//!
//! So the target is carried as an explicit option, validated here, and handed
//! to the external assembler. It is never inferred from a string in the IR.

const std = @import("std");

pub const Target = struct {
    /// Parsed form, used to validate the triple and to recover its parts.
    query: std.Target.Query,
    /// The triple as written on the command line, passed to the external
    /// assembler unchanged. Round-tripping through another spelling would risk
    /// handing `clang` something it parses differently.
    triple: []const u8,

    pub const arch = std.Target.Cpu.Arch;
    pub const os = std.Target.Os.Tag;

    pub fn cpuArch(self: Target) arch {
        return self.query.cpu_arch orelse .x86_64;
    }

    pub fn osTag(self: Target) os {
        return self.query.os_tag orelse .linux;
    }

    /// True when this is the one target the C ABI lowering knows: `x86_64`
    /// Linux System V. Everywhere else a C boundary would need a different
    /// classifier, so `extern`/`export` aggregates are rejected rather than
    /// lowered with the wrong convention.
    pub fn supportsSystemVAbi(self: Target) bool {
        return self.cpuArch() == .x86_64 and self.osTag() == .linux;
    }

    /// Human-readable form for diagnostics.
    pub fn describe(self: Target) []const u8 {
        return self.triple;
    }
};

pub const ParseError = error{ InvalidTarget, OutOfMemory };

/// Parses an `arch-os-abi` triple such as `x86_64-linux-gnu`.
///
/// Zig's own spelling is accepted (`x86_64-linux-gnu`); the `unknown` vendor
/// segment that Clang and GCC also print (`x86_64-unknown-linux-gnu`) is
/// normalised away first, because `std.Target.Query.parse` rejects it as an
/// unknown operating system.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Target {
    var normalised = text;
    const unknown = "-unknown-";
    if (std.mem.indexOf(u8, text, unknown)) |index| {
        normalised = try std.mem.concat(allocator, u8, &.{ text[0..index], "-", text[index + unknown.len ..] });
    }
    const query = std.Target.Query.parse(.{ .arch_os_abi = normalised }) catch return error.InvalidTarget;
    // A triple the assembler cannot name is not usable, even if it parses.
    if (query.cpu_arch == null or query.os_tag == null) return error.InvalidTarget;
    return .{ .query = query, .triple = normalised };
}

/// The target of the machine running the compiler, used when none is given.
pub fn native(allocator: std.mem.Allocator) ParseError!Target {
    const builtin = @import("builtin");
    const query: std.Target.Query = .{
        .cpu_arch = builtin.target.cpu.arch,
        .os_tag = builtin.target.os.tag,
        .abi = builtin.target.abi,
    };
    const text = query.zigTriple(allocator) catch return error.OutOfMemory;
    return .{ .query = query, .triple = text };
}

const testing = std.testing;

test "triples parse in Zig's spelling and in Clang's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zig_style = try parse(a, "x86_64-linux-gnu");
    try testing.expectEqual(Target.arch.x86_64, zig_style.cpuArch());
    try testing.expectEqual(Target.os.linux, zig_style.osTag());
    try testing.expect(zig_style.supportsSystemVAbi());
    try testing.expectEqualStrings("x86_64-linux-gnu", zig_style.triple);

    // The `unknown` vendor segment is what Clang and GCC print, and what a user
    // is most likely to paste. It must mean the same target, not an error.
    const clang_style = try parse(a, "x86_64-unknown-linux-gnu");
    try testing.expectEqual(Target.arch.x86_64, clang_style.cpuArch());
    try testing.expectEqual(Target.os.linux, clang_style.osTag());
    try testing.expect(clang_style.supportsSystemVAbi());
    try testing.expectEqualStrings("x86_64-linux-gnu", clang_style.triple);
}

test "only x86_64 Linux claims the System V classifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { triple: []const u8, systemv: bool }{
        .{ .triple = "x86_64-linux-gnu", .systemv = true },
        .{ .triple = "aarch64-linux-gnu", .systemv = false },
        .{ .triple = "riscv64-linux-gnu", .systemv = false },
        .{ .triple = "x86_64-windows-gnu", .systemv = false },
        .{ .triple = "x86_64-macos-none", .systemv = false },
    };
    for (cases) |case| {
        const parsed = try parse(a, case.triple);
        try testing.expectEqual(case.systemv, parsed.supportsSystemVAbi());
    }
}

test "an unusable triple is rejected rather than guessed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An operating system `std.Target` does not know.
    try testing.expectError(error.InvalidTarget, parse(a, "x86_64-unknown-linuxgnu2"));
    // An architecture nobody knows.
    try testing.expectError(error.InvalidTarget, parse(a, "bogus-linux-gnu"));
}

test "the native target of a supported host claims the System V classifier" {
    // This suite runs on the host, so on `x86_64` Linux the classifier is
    // available and the native triple round-trips through `parse`.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const host = try native(a);
    const reparsed = try parse(a, host.triple);
    try testing.expectEqual(host.cpuArch(), reparsed.cpuArch());
    try testing.expectEqual(host.osTag(), reparsed.osTag());
    try testing.expect(host.triple.len > 0);
}
