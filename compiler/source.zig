//! Source file management and offset/line/column conversion.
//!
//! A `Source` owns one source file's bytes and a lazily-built table
//! of line start offsets. All compiler stages address source text by byte
//! offset; only diagnostics and tooling convert those offsets to line/column.

const std = @import("std");

pub const Span = struct {
    start: u32,
    end: u32,
    source_id: u32 = 0,

    pub fn init(start: usize, end: usize) Span {
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }

    pub fn empty(at: usize) Span {
        const pos: u32 = @intCast(at);
        return .{ .start = pos, .end = pos };
    }

    pub fn join(a: Span, b: Span) Span {
        return .{ .start = @min(a.start, b.start), .end = @max(a.end, b.end), .source_id = a.source_id };
    }
};

pub const Location = struct {
    line: u32,
    column: u32,
};

pub const Source = struct {
    path: []const u8,
    text: []const u8,
    line_starts: []const u32,
    allocator: std.mem.Allocator,
    source_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !Source {
        return initWithId(allocator, path, text, 0);
    }

    pub fn initWithId(allocator: std.mem.Allocator, path: []const u8, text: []const u8, source_id: u32) !Source {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(allocator);

        try starts.append(allocator, 0);
        for (text, 0..) |byte, i| {
            if (byte == '\n' and i + 1 <= text.len) {
                try starts.append(allocator, @intCast(i + 1));
            }
        }

        return .{
            .path = path,
            .text = text,
            .line_starts = try starts.toOwnedSlice(allocator),
            .allocator = allocator,
            .source_id = source_id,
        };
    }

    pub fn span(self: *const Source, start: usize, end: usize) Span {
        return .{ .start = @intCast(start), .end = @intCast(end), .source_id = self.source_id };
    }

    pub fn deinit(self: *Source) void {
        self.allocator.free(self.line_starts);
    }

    /// Convert a byte offset into a 1-based line and column.
    pub fn location(self: *const Source, offset: u32) Location {
        const clamped = @min(offset, @as(u32, @intCast(self.text.len)));
        var lo: usize = 0;
        var hi: usize = if (self.line_starts.len == 0) 0 else self.line_starts.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (self.line_starts[mid] <= clamped) lo = mid else hi = mid - 1;
        }
        const column = clamped - self.line_starts[lo];
        return .{ .line = @intCast(lo + 1), .column = @intCast(column + 1) };
    }

    /// Return the full text of a 1-based line, without the trailing newline.
    pub fn lineText(self: *const Source, line: u32) []const u8 {
        if (line == 0 or line > self.line_starts.len) return "";
        const start: usize = self.line_starts[line - 1];
        const end: usize = if (line < self.line_starts.len)
            self.line_starts[line] - 1
        else
            self.text.len;
        var slice = self.text[start..end];
        if (slice.len > 0 and slice[slice.len - 1] == '\r') slice = slice[0 .. slice.len - 1];
        return slice;
    }
};

test "source line locations" {
    var src = try Source.init(std.testing.allocator, "x.kyn", "abc\ndef\nghi");
    defer src.deinit();

    try std.testing.expectEqual(@as(u32, 1), src.location(0).line);
    try std.testing.expectEqual(@as(u32, 3), src.location(2).column);
    try std.testing.expectEqual(@as(u32, 2), src.location(4).line);
    try std.testing.expectEqual(@as(u32, 3), src.location(9).line);
    try std.testing.expectEqualStrings("def", src.lineText(2));
}
