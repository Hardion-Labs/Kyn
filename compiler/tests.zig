//! Test aggregator: importing a module here makes its tests part of
//! `zig build test` while keeping one compilation unit per run.

const std = @import("std");

test {
    _ = @import("source.zig");
    _ = @import("diagnostics.zig");
    _ = @import("token.zig");
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
    _ = @import("target.zig");
    _ = @import("types.zig");
    _ = @import("sema.zig");
    _ = @import("analyzer.zig");
    _ = @import("ir.zig");
    _ = @import("backend/llvm.zig");
}
