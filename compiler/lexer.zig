//! Lexer: turns UTF-8 source text into a stream of tokens.
//!
//! The lexer is allocation-light: tokens borrow slices of the source buffer.
//! Only the token list itself is allocated. Escape sequences are decoded later
//! by the parser so that the lexer never needs to copy text.

const std = @import("std");
const source = @import("source.zig");
const token = @import("token.zig");
const diagnostics = @import("diagnostics.zig");

pub const Span = source.Span;
pub const Token = token.Token;
pub const Kind = token.Kind;

pub const Lexer = struct {
    source: *const source.Source,
    text: []const u8,
    pos: usize = 0,
    reporter: ?*diagnostics.Reporter = null,
    allocator: std.mem.Allocator,
    tokens: std.ArrayList(Token) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        src: *const source.Source,
        reporter: ?*diagnostics.Reporter,
    ) Lexer {
        return .{
            .source = src,
            .text = src.text,
            .allocator = allocator,
            .reporter = reporter,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit(self.allocator);
    }

    /// Tokenize the whole source. A terminating `eof` token is always emitted.
    pub fn tokenize(self: *Lexer) ![]Token {
        while (true) {
            try self.skipTrivia();
            if (self.pos >= self.text.len) {
                try self.emit(.eof, self.pos, self.pos);
                break;
            }
            const start = self.pos;
            const byte = self.text[self.pos];

            if (isIdentStart(byte)) {
                try self.lexIdentifier(start);
                continue;
            }
            if (isDigit(byte)) {
                try self.lexNumber(start);
                continue;
            }
            switch (byte) {
                '"' => try self.lexString(start),
                '\'' => try self.lexChar(start),
                '(' => try self.single(.l_paren, start),
                ')' => try self.single(.r_paren, start),
                '{' => try self.single(.l_brace, start),
                '}' => try self.single(.r_brace, start),
                '[' => try self.single(.l_bracket, start),
                ']' => try self.single(.r_bracket, start),
                ',' => try self.single(.comma, start),
                ';' => try self.single(.semicolon, start),
                ':' => try self.single(.colon, start),
                '.' => try self.single(.dot, start),
                '@' => try self.single(.at, start),
                '~' => try self.single(.tilde, start),
                '+' => try self.lexPlus(start),
                '-' => try self.lexMinus(start),
                '*' => try self.twoOrOne(.star, .star_equal, start, '='),
                '/' => try self.twoOrOne(.slash, .slash_equal, start, '='),
                '%' => try self.twoOrOne(.percent, .percent_equal, start, '='),
                '^' => try self.twoOrOne(.caret, .caret_equal, start, '='),
                '!' => try self.twoOrOne(.bang, .bang_equal, start, '='),
                '=' => try self.twoOrOne(.equal, .equal_equal, start, '='),
                '&' => try self.lexAmp(start),
                '|' => try self.lexPipe(start),
                '<' => try self.lexLess(start),
                '>' => try self.lexGreater(start),
                else => {
                    self.pos += 1;
                    try self.reportError(Span.init(start, self.pos), "E0101", "invalid byte 0x{x:0>2} in source", .{byte});
                },
            }
        }
        return self.tokens.items;
    }

    fn emit(self: *Lexer, kind: Kind, start: usize, end: usize) !void {
        try self.tokens.append(self.allocator, .{
            .kind = kind,
            .span = Span.init(start, end),
            .lexeme = self.text[start..end],
        });
    }

    fn single(self: *Lexer, kind: Kind, start: usize) !void {
        self.pos += 1;
        try self.emit(kind, start, self.pos);
    }

    fn twoOrOne(self: *Lexer, one: Kind, two: Kind, start: usize, second: u8) !void {
        self.pos += 1;
        if (self.pos < self.text.len and self.text[self.pos] == second) {
            self.pos += 1;
            try self.emit(two, start, self.pos);
        } else {
            try self.emit(one, start, self.pos);
        }
    }

    fn lexPlus(self: *Lexer, start: usize) !void {
        self.pos += 1;
        if (self.pos < self.text.len and self.text[self.pos] == '=') {
            self.pos += 1;
            try self.emit(.plus_equal, start, self.pos);
        } else {
            try self.emit(.plus, start, self.pos);
        }
    }

    fn lexMinus(self: *Lexer, start: usize) !void {
        self.pos += 1;
        if (self.pos < self.text.len) {
            if (self.text[self.pos] == '>') {
                self.pos += 1;
                try self.emit(.arrow, start, self.pos);
                return;
            }
            if (self.text[self.pos] == '=') {
                self.pos += 1;
                try self.emit(.minus_equal, start, self.pos);
                return;
            }
        }
        try self.emit(.minus, start, self.pos);
    }

    fn lexAmp(self: *Lexer, start: usize) !void {
        self.pos += 1;
        if (self.pos < self.text.len) {
            if (self.text[self.pos] == '&') {
                self.pos += 1;
                try self.emit(.amp_amp, start, self.pos);
                return;
            }
            if (self.text[self.pos] == '=') {
                self.pos += 1;
                try self.emit(.amp_equal, start, self.pos);
                return;
            }
        }
        try self.emit(.amp, start, self.pos);
    }

    fn lexPipe(self: *Lexer, start: usize) !void {
        self.pos += 1;
        if (self.pos < self.text.len) {
            if (self.text[self.pos] == '|') {
                self.pos += 1;
                try self.emit(.pipe_pipe, start, self.pos);
                return;
            }
            if (self.text[self.pos] == '=') {
                self.pos += 1;
                try self.emit(.pipe_equal, start, self.pos);
                return;
            }
        }
        try self.emit(.pipe, start, self.pos);
    }

    fn lexLess(self: *Lexer, start: usize) !void {
        self.pos += 1;
        if (self.pos < self.text.len) {
            if (self.text[self.pos] == '<') {
                self.pos += 1;
                if (self.pos < self.text.len and self.text[self.pos] == '=') {
                    self.pos += 1;
                    try self.emit(.shl_equal, start, self.pos);
                } else {
                    try self.emit(.shl, start, self.pos);
                }
                return;
            }
            if (self.text[self.pos] == '=') {
                self.pos += 1;
                try self.emit(.less_equal, start, self.pos);
                return;
            }
        }
        try self.emit(.less, start, self.pos);
    }

    fn lexGreater(self: *Lexer, start: usize) !void {
        self.pos += 1;
        if (self.pos < self.text.len) {
            if (self.text[self.pos] == '>') {
                self.pos += 1;
                if (self.pos < self.text.len and self.text[self.pos] == '=') {
                    self.pos += 1;
                    try self.emit(.shr_equal, start, self.pos);
                } else {
                    try self.emit(.shr, start, self.pos);
                }
                return;
            }
            if (self.text[self.pos] == '=') {
                self.pos += 1;
                try self.emit(.greater_equal, start, self.pos);
                return;
            }
        }
        try self.emit(.greater, start, self.pos);
    }

    fn lexIdentifier(self: *Lexer, start: usize) !void {
        self.pos += 1;
        while (self.pos < self.text.len and isIdentContinue(self.text[self.pos])) : (self.pos += 1) {}
        const text = self.text[start..self.pos];
        const kind = token.keywordKind(text) orelse .identifier;
        try self.emit(kind, start, self.pos);
    }

    fn lexNumber(self: *Lexer, start: usize) !void {
        var is_float = false;
        const is_hex = self.pos + 1 < self.text.len and self.text[self.pos] == '0' and
            (self.text[self.pos + 1] == 'x' or self.text[self.pos + 1] == 'X' or
                self.text[self.pos + 1] == 'b' or self.text[self.pos + 1] == 'B' or
                self.text[self.pos + 1] == 'o' or self.text[self.pos + 1] == 'O');

        if (is_hex) {
            self.pos += 2;
            const digit_start = self.pos;
            while (self.pos < self.text.len and (isHexDigit(self.text[self.pos]) or self.text[self.pos] == '_')) : (self.pos += 1) {}
            if (self.pos == digit_start) {
                try self.reportError(Span.init(start, self.pos), "E0102", "expected digits after base prefix", .{});
                return;
            }
            try self.emit(.int_literal, start, self.pos);
            return;
        }

        while (self.pos < self.text.len and (isDigit(self.text[self.pos]) or self.text[self.pos] == '_')) : (self.pos += 1) {}

        if (self.pos < self.text.len and self.text[self.pos] == '.' and
            self.pos + 1 < self.text.len and isDigit(self.text[self.pos + 1]))
        {
            is_float = true;
            self.pos += 1;
            while (self.pos < self.text.len and (isDigit(self.text[self.pos]) or self.text[self.pos] == '_')) : (self.pos += 1) {}
        }

        if (self.pos < self.text.len and (self.text[self.pos] == 'e' or self.text[self.pos] == 'E')) {
            const exp_start = self.pos;
            self.pos += 1;
            if (self.pos < self.text.len and (self.text[self.pos] == '+' or self.text[self.pos] == '-')) self.pos += 1;
            const digits_start = self.pos;
            while (self.pos < self.text.len and (isDigit(self.text[self.pos]) or self.text[self.pos] == '_')) : (self.pos += 1) {}
            if (self.pos == digits_start) {
                try self.reportError(Span.init(exp_start, self.pos), "E0103", "expected exponent digits", .{});
                return;
            }
            is_float = true;
        }

        try self.emit(if (is_float) .float_literal else .int_literal, start, self.pos);
    }

    fn lexString(self: *Lexer, start: usize) !void {
        self.pos += 1;
        var terminated = false;
        while (self.pos < self.text.len) {
            const byte = self.text[self.pos];
            if (byte == '\\') {
                if (self.pos + 1 >= self.text.len) break;
                self.pos += 2;
                continue;
            }
            if (byte == '"') {
                self.pos += 1;
                terminated = true;
                break;
            }
            if (byte == '\n') break;
            self.pos += 1;
        }
        if (!terminated) {
            try self.reportError(Span.init(start, self.pos), "E0104", "unterminated string literal", .{});
            return;
        }
        try self.emit(.string_literal, start, self.pos);
    }

    fn lexChar(self: *Lexer, start: usize) !void {
        self.pos += 1;
        var terminated = false;
        while (self.pos < self.text.len) {
            const byte = self.text[self.pos];
            if (byte == '\\') {
                if (self.pos + 1 >= self.text.len) break;
                self.pos += 2;
                continue;
            }
            if (byte == '\'') {
                self.pos += 1;
                terminated = true;
                break;
            }
            if (byte == '\n') break;
            self.pos += 1;
        }
        if (!terminated) {
            try self.reportError(Span.init(start, self.pos), "E0105", "unterminated character literal", .{});
            return;
        }
        try self.emit(.char_literal, start, self.pos);
    }

    fn skipTrivia(self: *Lexer) !void {
        while (self.pos < self.text.len) {
            const byte = self.text[self.pos];
            if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
                self.pos += 1;
                continue;
            }
            if (byte == '/' and self.pos + 1 < self.text.len and self.text[self.pos + 1] == '/') {
                self.pos += 2;
                while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (byte == '/' and self.pos + 1 < self.text.len and self.text[self.pos + 1] == '*') {
                const start = self.pos;
                self.pos += 2;
                var depth: usize = 1;
                while (self.pos < self.text.len and depth > 0) {
                    if (self.pos + 1 < self.text.len and self.text[self.pos] == '/' and self.text[self.pos + 1] == '*') {
                        depth += 1;
                        self.pos += 2;
                    } else if (self.pos + 1 < self.text.len and self.text[self.pos] == '*' and self.text[self.pos + 1] == '/') {
                        depth -= 1;
                        self.pos += 2;
                    } else {
                        self.pos += 1;
                    }
                }
                if (depth != 0) {
                    try self.reportError(Span.init(start, self.pos), "E0106", "unterminated block comment", .{});
                    return;
                }
                continue;
            }
            break;
        }
    }

    fn reportError(self: *Lexer, span: Span, code: []const u8, comptime format: []const u8, args: anytype) !void {
        if (self.reporter) |rep| try rep.err(code, span, format, args);
    }
};

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isHexDigit(byte: u8) bool {
    return isDigit(byte) or (byte >= 'a' and byte <= 'f') or (byte >= 'A' and byte <= 'F');
}

fn isIdentStart(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_';
}

fn isIdentContinue(byte: u8) bool {
    return isIdentStart(byte) or isDigit(byte);
}

pub fn kindOfSequence(text: []const u8) ?Kind {
    return token.keywordKind(text);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn lexAll(allocator: std.mem.Allocator, text: []const u8) !struct {
    src: source.Source,
    lexer: Lexer,
    reporter: diagnostics.Reporter,
    tokens: []Token,
} {
    var src = try source.Source.init(allocator, "test.kyn", text);
    errdefer src.deinit();
    var reporter = diagnostics.Reporter.init(allocator, &src);
    errdefer reporter.deinit();
    var lexer = Lexer.init(allocator, &src, &reporter);
    const tokens = try lexer.tokenize();
    return .{ .src = src, .lexer = lexer, .reporter = reporter, .tokens = tokens };
}

test "lex identifiers and keywords" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src = try source.Source.init(a, "test.kyn", "fn main() i32 { let x = 42; }");
    var rep = diagnostics.Reporter.init(a, &src);
    var lexer = Lexer.init(a, &src, &rep);
    const toks = try lexer.tokenize();

    try testing.expectEqual(Kind.kw_fn, toks[0].kind);
    try testing.expectEqualStrings("main", toks[1].lexeme);
    try testing.expectEqual(Kind.l_paren, toks[2].kind);
    try testing.expectEqual(Kind.r_paren, toks[3].kind);
    try testing.expectEqual(Kind.kw_i32, toks[4].kind);
    try testing.expectEqual(Kind.l_brace, toks[5].kind);
    try testing.expectEqual(Kind.kw_let, toks[6].kind);
    try testing.expectEqual(Kind.int_literal, toks[9].kind);
    try testing.expectEqual(Kind.eof, toks[toks.len - 1].kind);
}

test "lex numeric forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try source.Source.init(a, "test.kyn", "0 123 1_000 0xFF 0b1010 0o17 1.5 2e10 3.2e-4");
    var rep = diagnostics.Reporter.init(a, &src);
    var lexer = Lexer.init(a, &src, &rep);
    const toks = try lexer.tokenize();

    try testing.expectEqual(Kind.int_literal, toks[0].kind);
    try testing.expectEqual(Kind.int_literal, toks[1].kind);
    try testing.expectEqual(Kind.int_literal, toks[2].kind);
    try testing.expectEqual(Kind.int_literal, toks[3].kind);
    try testing.expectEqual(Kind.int_literal, toks[4].kind);
    try testing.expectEqual(Kind.int_literal, toks[5].kind);
    try testing.expectEqual(Kind.float_literal, toks[6].kind);
    try testing.expectEqual(Kind.float_literal, toks[7].kind);
    try testing.expectEqual(Kind.float_literal, toks[8].kind);
}

test "lex operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try source.Source.init(a, "test.kyn", "+ - * / % == != < <= > >= && || ! & | ^ ~ << >> += -= *= /= %= &= |= ^= <<= >>= ->");
    var rep = diagnostics.Reporter.init(a, &src);
    var lexer = Lexer.init(a, &src, &rep);
    const toks = try lexer.tokenize();

    const expected = [_]Kind{
        .plus,          .minus,       .star,        .slash,       .percent,
        .equal_equal,   .bang_equal,  .less,        .less_equal,  .greater,
        .greater_equal, .amp_amp,     .pipe_pipe,   .bang,        .amp,
        .pipe,          .caret,       .tilde,       .shl,         .shr,
        .plus_equal,    .minus_equal, .star_equal,  .slash_equal, .percent_equal,
        .amp_equal,     .pipe_equal,  .caret_equal, .shl_equal,   .shr_equal,
        .arrow,
    };
    try testing.expectEqual(expected.len + 1, toks.len);
    for (expected, 0..) |kind, i| try testing.expectEqual(kind, toks[i].kind);
}

test "lex comments and strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try source.Source.init(a, "test.kyn",
        \\// line comment
        \\/* block /* nested */ comment */
        \\let s = "hello\nworld";
        \\let c = '\n';
    );
    var rep = diagnostics.Reporter.init(a, &src);
    var lexer = Lexer.init(a, &src, &rep);
    const toks = try lexer.tokenize();

    try testing.expectEqual(Kind.kw_let, toks[0].kind);
    try testing.expectEqual(Kind.identifier, toks[1].kind);
    try testing.expectEqual(Kind.equal, toks[2].kind);
    try testing.expectEqual(Kind.string_literal, toks[3].kind);
    try testing.expectEqual(Kind.semicolon, toks[4].kind);
    try testing.expectEqual(Kind.char_literal, toks[8].kind);
}

test "lexer reports unterminated string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try source.Source.init(a, "test.kyn", "let s = \"oops");
    var rep = diagnostics.Reporter.init(a, &src);
    var lexer = Lexer.init(a, &src, &rep);
    _ = try lexer.tokenize();
    try testing.expect(rep.hasErrors());
    try testing.expectEqualStrings("E0104", rep.list.items[0].code);
}

test "lexer reports invalid byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try source.Source.init(a, "test.kyn", "let x = #;");
    var rep = diagnostics.Reporter.init(a, &src);
    var lexer = Lexer.init(a, &src, &rep);
    _ = try lexer.tokenize();
    try testing.expect(rep.hasErrors());
    try testing.expectEqualStrings("E0101", rep.list.items[0].code);
}

test "lexer handles nested block comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try source.Source.init(a, "test.kyn",
        \\/* outer /* nested /* deep */ inner */ tail */
        \\fn main() i32 { return 0; }
    );
    var rep = diagnostics.Reporter.init(a, &src);
    var lexer = Lexer.init(a, &src, &rep);
    const toks = try lexer.tokenize();

    try testing.expectEqual(Kind.kw_fn, toks[0].kind);
    try testing.expect(!rep.hasErrors());
}

test "lexer reports unterminated block comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try source.Source.init(a, "test.kyn", "/* never closed");
    var rep = diagnostics.Reporter.init(a, &src);
    var lexer = Lexer.init(a, &src, &rep);
    _ = try lexer.tokenize();
    try testing.expect(rep.hasErrors());
    try testing.expectEqualStrings("E0106", rep.list.items[0].code);
}

test "lexer reports exponent without digits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try source.Source.init(a, "test.kyn", "1e+");
    var rep = diagnostics.Reporter.init(a, &src);
    var lexer = Lexer.init(a, &src, &rep);
    _ = try lexer.tokenize();
    try testing.expect(rep.hasErrors());
    try testing.expectEqualStrings("E0103", rep.list.items[0].code);
}

test "lexer reports base prefix without digits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = try source.Source.init(a, "test.kyn", "0x");
    var rep = diagnostics.Reporter.init(a, &src);
    var lexer = Lexer.init(a, &src, &rep);
    _ = try lexer.tokenize();
    try testing.expect(rep.hasErrors());
    try testing.expectEqualStrings("E0102", rep.list.items[0].code);
}
