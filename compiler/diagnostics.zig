//! Structured compiler diagnostics.
//!
//! Every stage reports problems through `Reporter`. Diagnostics carry a stable
//! code (e.g. `E0201`), a severity and a source span so that editors and CI can
//! consume them. Rendering is deliberately separated from production.

const std = @import("std");
const source = @import("source.zig");

pub const Span = source.Span;

pub const Severity = enum {
    note,
    warning,
    err,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .note => "note",
            .warning => "warning",
            .err => "error",
        };
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    code: []const u8,
    span: Span,
    message: []const u8,
};

pub const Reporter = struct {
    allocator: std.mem.Allocator,
    source: *const source.Source,
    list: std.ArrayList(Diagnostic) = .empty,
    error_count: usize = 0,
    warning_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, src: *const source.Source) Reporter {
        return .{ .allocator = allocator, .source = src };
    }

    pub fn deinit(self: *Reporter) void {
        for (self.list.items) |diag| self.allocator.free(diag.message);
        self.list.deinit(self.allocator);
    }

    pub fn add(
        self: *Reporter,
        severity: Severity,
        code: []const u8,
        span: Span,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, format, args);
        try self.list.append(self.allocator, .{
            .severity = severity,
            .code = code,
            .span = span,
            .message = message,
        });
        switch (severity) {
            .err => self.error_count += 1,
            .warning => self.warning_count += 1,
            .note => {},
        }
    }

    pub fn err(self: *Reporter, code: []const u8, span: Span, comptime format: []const u8, args: anytype) !void {
        try self.add(.err, code, span, format, args);
    }

    pub fn warn(self: *Reporter, code: []const u8, span: Span, comptime format: []const u8, args: anytype) !void {
        try self.add(.warning, code, span, format, args);
    }

    pub fn note(self: *Reporter, code: []const u8, span: Span, comptime format: []const u8, args: anytype) !void {
        try self.add(.note, code, span, format, args);
    }

    pub fn hasErrors(self: *const Reporter) bool {
        return self.error_count > 0;
    }

    /// Render every diagnostic into a newly allocated buffer.
    pub fn renderAlloc(self: *const Reporter) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        for (self.list.items) |diag| try self.renderOne(&out.writer, diag);
        return out.toOwnedSlice();
    }

    pub fn renderOne(self: *const Reporter, writer: *std.Io.Writer, diag: Diagnostic) !void {
        const loc = self.source.location(diag.span.start);
        try writer.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
            self.source.path,
            loc.line,
            loc.column,
            diag.severity.label(),
            diag.code,
            diag.message,
        });

        const text = self.source.lineText(loc.line);
        if (text.len == 0) return;
        try writer.print("    {s}\n", .{text});
        try writer.writeAll("    ");
        const caret_col = @min(loc.column - 1, @as(u32, @intCast(text.len)));
        var i: u32 = 0;
        while (i < caret_col) : (i += 1) {
            try writer.writeByte(if (i < text.len and text[i] == '\t') '\t' else ' ');
        }
        const width: u32 = if (diag.span.end > diag.span.start) @min(diag.span.end - diag.span.start, 40) else 1;
        i = 0;
        while (i < width) : (i += 1) try writer.writeByte('^');
        try writer.writeByte('\n');
    }
};

test "diagnostic rendering" {
    var src = try source.Source.init(std.testing.allocator, "test.kyn", "fn main() {\n  bad\n}\n");
    defer src.deinit();
    var rep = Reporter.init(std.testing.allocator, &src);
    defer rep.deinit();
    try rep.err("E0001", .{ .start = 14, .end = 17 }, "unknown symbol '{s}'", .{"bad"});
    try std.testing.expect(rep.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), rep.error_count);

    const rendered = try rep.renderAlloc();
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "test.kyn:2:3: error[E0001]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "^^^") != null);
}
