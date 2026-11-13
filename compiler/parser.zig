//! Recursive-descent parser with precedence climbing.
//!
//! The parser reports diagnostics through `Reporter` and performs local
//! recovery: an invalid declaration or statement is skipped up to the next
//! synchronization point so that one error does not hide the rest of the file.

const std = @import("std");
const source = @import("source.zig");
const token = @import("token.zig");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

pub const Span = source.Span;
pub const Token = token.Token;
pub const Kind = token.Kind;

pub const Error = error{OutOfMemory};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    pos: usize = 0,
    reporter: *diagnostics.Reporter,

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token, reporter: *diagnostics.Reporter) Parser {
        return .{ .allocator = allocator, .tokens = tokens, .reporter = reporter };
    }

    pub fn parse(self: *Parser) !*ast.Program {
        var decls: std.ArrayList(*ast.Decl) = .empty;
        var imports: std.ArrayList(ast.ImportDecl) = .empty;
        while (!self.check(.eof)) {
            const before = self.pos;
            if (self.check(.kw_import)) {
                if (try self.parseImport()) |imp| try imports.append(self.allocator, imp);
            } else if (try self.parseDecl()) |decl| {
                try decls.append(self.allocator, decl);
            }
            if (self.pos == before) {
                _ = self.advance();
            }
        }
        const program = try self.allocator.create(ast.Program);
        program.* = .{ .decls = try decls.toOwnedSlice(self.allocator), .imports = try imports.toOwnedSlice(self.allocator) };
        return program;
    }

    fn parseImport(self: *Parser) !?ast.ImportDecl {
        const start = self.advance();
        if (!self.check(.string_literal)) {
            try self.reporter.err("E0230", self.peek().span, "expected a quoted path after 'import'", .{});
            self.synchronize(.semicolon);
            _ = self.match(.semicolon);
            return null;
        }
        const path_token = self.advance();
        const path = try self.decodeString(path_token);
        var alias: ?[]const u8 = null;
        if (self.match(.kw_as)) {
            if (!self.check(.identifier)) {
                try self.reporter.err("E0236", self.peek().span, "expected module alias after 'as'", .{});
                self.synchronize(.semicolon);
                _ = self.match(.semicolon);
                return null;
            }
            alias = self.advance().lexeme;
        }
        const end = self.peek().span;
        _ = try self.expect(.semicolon, "after import path");
        return .{ .span = source.Span.join(start.span, end), .path = path, .alias = alias };
    }

    // ------------------------------------------------------------------
    // Token helpers
    // ------------------------------------------------------------------

    fn peek(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn peekAt(self: *const Parser, offset: usize) Token {
        const index = @min(self.pos + offset, self.tokens.len - 1);
        return self.tokens[index];
    }

    fn advance(self: *Parser) Token {
        const tok = self.tokens[self.pos];
        if (self.pos + 1 < self.tokens.len) self.pos += 1;
        return tok;
    }

    fn check(self: *const Parser, kind: Kind) bool {
        return self.peek().kind == kind;
    }

    fn match(self: *Parser, kind: Kind) bool {
        if (!self.check(kind)) return false;
        _ = self.advance();
        return true;
    }

    fn expect(self: *Parser, kind: Kind, context: []const u8) !bool {
        if (self.match(kind)) return true;
        try self.reporter.err("E0201", self.peek().span, "expected {s} {s}, found {s}", .{
            token.describe(kind),
            context,
            token.describe(self.peek().kind),
        });
        return false;
    }

    fn errorExpr(self: *Parser, span: Span) !*ast.Expr {
        const expr = try self.allocator.create(ast.Expr);
        expr.* = .{ .span = span, .kind = .{ .int_lit = .{ .value = 0 } } };
        return expr;
    }

    fn errorStmt(self: *Parser, span: Span) !*ast.Stmt {
        const stmt = try self.allocator.create(ast.Stmt);
        stmt.* = .{ .span = span, .kind = .{ .empty = {} } };
        return stmt;
    }

    // ------------------------------------------------------------------
    // Declarations
    // ------------------------------------------------------------------

    fn parseDecl(self: *Parser) !?*ast.Decl {
        const tok = self.peek();
        switch (tok.kind) {
            .kw_private => {
                const start = self.advance().span;
                const decl = (try self.parseDecl()) orelse return null;
                decl.is_public = false;
                decl.span = Span.join(start, decl.span);
                return decl;
            },
            .kw_fn => return try self.parseFn(false, false),
            .kw_extern => {
                const start = self.advance().span;
                if (!self.check(.kw_fn)) {
                    try self.reporter.err("E0202", self.peek().span, "expected 'fn' after 'extern'", .{});
                    return null;
                }
                _ = start;
                return try self.parseFn(true, false);
            },
            .kw_export => {
                _ = self.advance();
                if (self.check(.kw_fn)) return try self.parseFn(false, true);
                // `export` also names a global variable's symbol, so a C object
                // links against the spelling the declaration used.
                if (self.check(.kw_const) or self.check(.kw_var) or self.check(.kw_let)) {
                    const decl = (try self.parseGlobalVar()) orelse return null;
                    switch (decl.kind) {
                        .var_decl => |vd| vd.is_export = true,
                        else => unreachable,
                    }
                    return decl;
                }
                try self.reporter.err("E0203", self.peek().span, "expected 'fn', 'const', 'var' or 'let' after 'export'", .{});
                return null;
            },
            .kw_struct => return try self.parseStruct(),
            .kw_enum => return try self.parseEnum(),
            .kw_const, .kw_var, .kw_let => return try self.parseGlobalVar(),
            else => {
                try self.reporter.err("E0204", tok.span, "expected a declaration, found {s}", .{token.describe(tok.kind)});
                self.synchronize(.semicolon);
                return null;
            },
        }
    }

    fn parseFn(self: *Parser, is_extern: bool, is_export: bool) !?*ast.Decl {
        const start = self.peek().span;
        _ = try self.expect(.kw_fn, "to begin function declaration");
        if (!self.check(.identifier)) {
            try self.reporter.err("E0205", self.peek().span, "expected function name, found {s}", .{token.describe(self.peek().kind)});
            return null;
        }
        const name_tok = self.advance();

        var params: std.ArrayList(ast.Param) = .empty;
        var is_variadic = false;
        if (try self.expect(.l_paren, "after function name")) {
            if (!self.check(.r_paren)) {
                while (true) {
                    // The parameter list ends at `...`, which is the variadic
                    // marker rather than a parameter: it carries no name, so it
                    // is consumed here and the loop stops.
                    if (self.check(.ellipsis)) {
                        is_variadic = true;
                        _ = self.advance();
                        break;
                    }
                    if (!self.check(.identifier)) {
                        try self.reporter.err("E0206", self.peek().span, "expected parameter name, found {s}", .{token.describe(self.peek().kind)});
                        break;
                    }
                    const param_name = self.advance();
                    if (!try self.expect(.colon, "after parameter name")) break;
                    const ty_expr = (try self.parseType()) orelse break;
                    try params.append(self.allocator, .{
                        .span = Span.join(param_name.span, ty_expr.span),
                        .name = param_name.lexeme,
                        .ty_expr = ty_expr,
                    });
                    if (!self.match(.comma)) break;
                }
            }
            _ = try self.expect(.r_paren, "after parameter list");
        }

        var ret_expr: ?*ast.TypeExpr = null;
        if (self.isTypeStart()) {
            ret_expr = try self.parseType();
        }

        var body: ?*ast.Block = null;
        if (!is_extern) {
            // A Kyn-defined function has a fixed signature: there is no calling
            // convention here that can receive an unspecified trailing list.
            if (is_variadic) {
                try self.reporter.err("E0474", name_tok.span, "variadic functions must be declared 'extern'; '{s}' has a body", .{name_tok.lexeme});
            }
            body = try self.parseBlock();
        } else {
            _ = try self.expect(.semicolon, "after extern function declaration");
        }

        const fn_decl = try self.allocator.create(ast.FnDecl);
        fn_decl.* = .{
            .span = Span.join(start, if (body) |b| b.span else self.peek().span),
            .name = name_tok.lexeme,
            .params = try params.toOwnedSlice(self.allocator),
            .is_variadic = is_variadic,
            .ret_expr = ret_expr,
            .body = body,
            .is_extern = is_extern,
            .is_export = is_export,
        };

        const decl = try self.allocator.create(ast.Decl);
        decl.* = .{
            .span = Span.join(start, if (body) |b| b.span else self.peek().span),
            .kind = .{ .fn_decl = fn_decl },
        };
        return decl;
    }

    fn parseStruct(self: *Parser) !?*ast.Decl {
        const start = self.peek().span;
        _ = try self.expect(.kw_struct, "to begin struct declaration");
        if (!self.check(.identifier)) {
            try self.reporter.err("E0207", self.peek().span, "expected struct name, found {s}", .{token.describe(self.peek().kind)});
            return null;
        }
        const name_tok = self.advance();

        var fields: std.ArrayList(ast.StructField) = .empty;
        if (try self.expect(.l_brace, "to begin struct body")) {
            while (!self.check(.r_brace) and !self.check(.eof)) {
                const before = self.pos;
                if (!self.check(.identifier)) {
                    try self.reporter.err("E0208", self.peek().span, "expected field name, found {s}", .{token.describe(self.peek().kind)});
                    self.synchronize(.comma);
                    _ = self.match(.comma);
                    if (self.pos == before) break;
                    continue;
                }
                const field_name = self.advance();
                if (!try self.expect(.colon, "after field name")) {
                    self.synchronize(.comma);
                    _ = self.match(.comma);
                    continue;
                }
                const ty_expr = (try self.parseType()) orelse {
                    self.synchronize(.comma);
                    _ = self.match(.comma);
                    continue;
                };
                try fields.append(self.allocator, .{
                    .span = Span.join(field_name.span, ty_expr.span),
                    .name = field_name.lexeme,
                    .ty_expr = ty_expr,
                });
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.r_brace, "to close struct body");
        }

        const struct_decl = try self.allocator.create(ast.StructDecl);
        struct_decl.* = .{ .span = Span.join(start, self.peek().span), .name = name_tok.lexeme, .fields = try fields.toOwnedSlice(self.allocator) };

        const decl = try self.allocator.create(ast.Decl);
        decl.* = .{ .span = Span.join(start, self.peek().span), .kind = .{ .struct_decl = struct_decl } };
        return decl;
    }

    fn parseEnum(self: *Parser) !?*ast.Decl {
        const start = self.peek().span;
        _ = try self.expect(.kw_enum, "to begin enum declaration");
        if (!self.check(.identifier)) {
            try self.reporter.err("E0209", self.peek().span, "expected enum name, found {s}", .{token.describe(self.peek().kind)});
            return null;
        }
        const name_tok = self.advance();

        var backing: ?*ast.TypeExpr = null;
        if (self.match(.colon)) {
            backing = try self.parseType();
        }

        var variants: std.ArrayList(ast.EnumVariantDecl) = .empty;
        if (try self.expect(.l_brace, "to begin enum body")) {
            while (!self.check(.r_brace) and !self.check(.eof)) {
                const before = self.pos;
                if (!self.check(.identifier)) {
                    try self.reporter.err("E0210", self.peek().span, "expected enum variant name, found {s}", .{token.describe(self.peek().kind)});
                    self.synchronize(.comma);
                    _ = self.match(.comma);
                    if (self.pos == before) break;
                    continue;
                }
                const variant_tok = self.advance();
                var value_expr: ?*ast.Expr = null;
                if (self.match(.equal)) value_expr = try self.parseExpr();
                try variants.append(self.allocator, .{
                    .span = variant_tok.span,
                    .name = variant_tok.lexeme,
                    .value_expr = value_expr,
                });
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.r_brace, "to close enum body");
        }

        const enum_decl = try self.allocator.create(ast.EnumDecl);
        enum_decl.* = .{
            .span = Span.join(start, self.peek().span),
            .name = name_tok.lexeme,
            .backing_expr = backing,
            .variants = try variants.toOwnedSlice(self.allocator),
        };

        const decl = try self.allocator.create(ast.Decl);
        decl.* = .{ .span = Span.join(start, self.peek().span), .kind = .{ .enum_decl = enum_decl } };
        return decl;
    }

    fn parseGlobalVar(self: *Parser) !?*ast.Decl {
        const start = self.peek();
        const mutable = start.kind != .kw_const and start.kind != .kw_let;
        _ = self.advance();

        if (!self.check(.identifier)) {
            try self.reporter.err("E0211", self.peek().span, "expected variable name, found {s}", .{token.describe(self.peek().kind)});
            return null;
        }
        const name_tok = self.advance();

        var ty_expr: ?*ast.TypeExpr = null;
        if (self.match(.colon)) ty_expr = try self.parseType();

        var init_expr: ?*ast.Expr = null;
        if (self.match(.equal)) init_expr = try self.parseExpr();

        _ = try self.expect(.semicolon, "after variable declaration");
        if (ty_expr == null and init_expr == null) {
            try self.reporter.err("E0212", name_tok.span, "variable '{s}' needs a type or an initializer", .{name_tok.lexeme});
        }

        const var_decl = try self.allocator.create(ast.VarDecl);
        var_decl.* = .{
            .span = Span.join(start.span, self.peek().span),
            .name = name_tok.lexeme,
            .mutable = mutable,
            .is_global = true,
            .ty_expr = ty_expr,
            .init = init_expr,
        };

        const decl = try self.allocator.create(ast.Decl);
        decl.* = .{ .span = Span.join(start.span, self.peek().span), .kind = .{ .var_decl = var_decl } };
        return decl;
    }

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    fn isTypeStart(self: *const Parser) bool {
        return switch (self.peek().kind) {
            .identifier, .star, .l_bracket, .kw_fn => true,
            else => self.peek().kind.isPrimitiveType(),
        };
    }

    fn parseType(self: *Parser) !?*ast.TypeExpr {
        const tok = self.peek();
        if (tok.kind == .kw_fn) {
            // `fn(i32, i32) i32` names a signature, so a function type is its
            // own type expression rather than a pointer to one: that is what
            // lets `let f: fn(i32) i32 = double;` read as a signature.
            _ = self.advance();
            var params: std.ArrayList(ast.TypeExpr.ParamType) = .empty;
            if (try self.expect(.l_paren, "after 'fn' in a function type")) {
                if (!self.check(.r_paren)) {
                    while (true) {
                        const param_ty = (try self.parseType()) orelse break;
                        try params.append(self.allocator, .{ .span = param_ty.span, .ty_expr = param_ty });
                        if (!self.match(.comma)) break;
                    }
                }
                _ = try self.expect(.r_paren, "after function type parameters");
            }
            // A missing return type means `void`, matching a function
            // declaration.
            var ret: ?*ast.TypeExpr = null;
            if (self.isTypeStart()) ret = try self.parseType();
            const expr = try self.allocator.create(ast.TypeExpr);
            const end = if (ret) |r| r.span else self.peek().span;
            expr.* = .{
                .span = Span.join(tok.span, end),
                .kind = .{ .fn_type = .{ .params = try params.toOwnedSlice(self.allocator), .ret = ret } },
            };
            return expr;
        }
        if (tok.kind == .star) {
            _ = self.advance();
            const is_const = self.match(.kw_const);
            const elem = (try self.parseType()) orelse return null;
            const expr = try self.allocator.create(ast.TypeExpr);
            expr.* = .{
                .span = Span.join(tok.span, elem.span),
                .kind = .{ .pointer = .{ .elem = elem, .is_const = is_const } },
            };
            return expr;
        }
        if (tok.kind == .l_bracket) {
            _ = self.advance();
            if (self.check(.r_bracket)) {
                _ = self.advance();
                const is_const = self.match(.kw_const);
                const elem = (try self.parseType()) orelse return null;
                const expr = try self.allocator.create(ast.TypeExpr);
                expr.* = .{
                    .span = Span.join(tok.span, elem.span),
                    .kind = .{ .slice = .{ .elem = elem, .is_const = is_const } },
                };
                return expr;
            }
            var len: ?*ast.Expr = null;
            if (!self.check(.r_bracket)) {
                len = try self.parseExpr();
            }
            _ = try self.expect(.r_bracket, "to close array length");
            const elem = (try self.parseType()) orelse return null;
            const expr = try self.allocator.create(ast.TypeExpr);
            expr.* = .{
                .span = Span.join(tok.span, elem.span),
                .kind = .{ .array = .{ .elem = elem, .len = len } },
            };
            return expr;
        }
        if (tok.kind == .identifier or tok.kind.isPrimitiveType()) {
            _ = self.advance();
            var name = tok.lexeme;
            var span = tok.span;
            if (tok.kind == .identifier and self.match(.dot)) {
                if (!self.check(.identifier)) {
                    try self.reporter.err("E0213", self.peek().span, "expected a type name after module qualifier", .{});
                    return null;
                }
                const member = self.advance();
                name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ tok.lexeme, member.lexeme });
                span = Span.join(span, member.span);
            }
            const expr = try self.allocator.create(ast.TypeExpr);
            expr.* = .{ .span = span, .kind = .{ .name = name } };
            return expr;
        }
        try self.reporter.err("E0213", tok.span, "expected a type, found {s}", .{token.describe(tok.kind)});
        return null;
    }

    // ------------------------------------------------------------------
    // Statements
    // ------------------------------------------------------------------

    fn parseBlock(self: *Parser) Error!*ast.Block {
        const start = self.peek().span;
        var stmts: std.ArrayList(*ast.Stmt) = .empty;
        if (try self.expect(.l_brace, "to begin block")) {
            while (!self.check(.r_brace) and !self.check(.eof)) {
                const before = self.pos;
                if (try self.parseStmt()) |stmt| try stmts.append(self.allocator, stmt);
                if (self.pos == before) {
                    _ = self.advance();
                }
            }
            _ = try self.expect(.r_brace, "to close block");
        }
        const block = try self.allocator.create(ast.Block);
        block.* = .{
            .span = Span.join(start, self.peek().span),
            .stmts = try stmts.toOwnedSlice(self.allocator),
        };
        return block;
    }

    fn parseStmt(self: *Parser) Error!?*ast.Stmt {
        const tok = self.peek();
        switch (tok.kind) {
            .l_brace => {
                const block = try self.parseBlock();
                const stmt = try self.allocator.create(ast.Stmt);
                stmt.* = .{ .span = block.span, .kind = .{ .block = block } };
                return stmt;
            },
            .kw_if => return try self.parseIf(),
            .kw_while => return try self.parseWhile(),
            .kw_return => return try self.parseReturn(),
            .kw_break => {
                const end = self.advance().span;
                _ = try self.expect(.semicolon, "after 'break'");
                const stmt = try self.allocator.create(ast.Stmt);
                stmt.* = .{ .span = end, .kind = .{ .break_stmt = {} } };
                return stmt;
            },
            .kw_continue => {
                const end = self.advance().span;
                _ = try self.expect(.semicolon, "after 'continue'");
                const stmt = try self.allocator.create(ast.Stmt);
                stmt.* = .{ .span = end, .kind = .{ .continue_stmt = {} } };
                return stmt;
            },
            .kw_let, .kw_var, .kw_const => return try self.parseLocalVar(),
            .semicolon => {
                const end = self.advance().span;
                const stmt = try self.allocator.create(ast.Stmt);
                stmt.* = .{ .span = end, .kind = .{ .empty = {} } };
                return stmt;
            },
            .kw_struct, .kw_enum, .kw_fn, .kw_extern, .kw_export, .kw_private => {
                try self.reporter.err("E0214", tok.span, "declarations are not allowed inside function bodies", .{});
                self.synchronize(.semicolon);
                return null;
            },
            else => {},
        }

        const expr = (try self.parseExpr()) orelse return null;
        _ = try self.expect(.semicolon, "after expression");
        const stmt = try self.allocator.create(ast.Stmt);
        stmt.* = .{ .span = expr.span, .kind = .{ .expr = expr } };
        return stmt;
    }

    fn parseLocalVar(self: *Parser) !?*ast.Stmt {
        const start = self.peek();
        const mutable = start.kind == .kw_var;
        _ = self.advance();

        if (!self.check(.identifier)) {
            try self.reporter.err("E0215", self.peek().span, "expected variable name, found {s}", .{token.describe(self.peek().kind)});
            self.synchronize(.semicolon);
            return null;
        }
        const name_tok = self.advance();

        var ty_expr: ?*ast.TypeExpr = null;
        if (self.match(.colon)) ty_expr = try self.parseType();

        var init_expr: ?*ast.Expr = null;
        if (self.match(.equal)) init_expr = try self.parseExpr();

        _ = try self.expect(.semicolon, "after variable declaration");
        // Whether a local has a type, an initializer or neither is a semantic
        // question, not a syntactic one: the parser accepts both forms and the
        // analyzer reports `E0420` for the empty one. Reporting it here as well
        // kept `E0420` unreachable and gave the same condition two codes.

        const var_decl = try self.allocator.create(ast.VarDecl);
        var_decl.* = .{
            .span = Span.join(start.span, self.peek().span),
            .name = name_tok.lexeme,
            .mutable = mutable,
            .is_global = false,
            .ty_expr = ty_expr,
            .init = init_expr,
        };

        const stmt = try self.allocator.create(ast.Stmt);
        stmt.* = .{ .span = Span.join(start.span, self.peek().span), .kind = .{ .var_decl = var_decl } };
        return stmt;
    }

    fn parseIf(self: *Parser) !?*ast.Stmt {
        const start = self.peek().span;
        _ = self.advance();
        _ = try self.expect(.l_paren, "after 'if'");
        const cond = (try self.parseExpr()) orelse try self.errorExpr(self.peek().span);
        _ = try self.expect(.r_paren, "after if condition");
        const then_branch = try self.parseBlock();

        var else_branch: ?*ast.Stmt = null;
        if (self.match(.kw_else)) {
            if (self.check(.kw_if)) {
                else_branch = try self.parseIf();
            } else if (self.check(.l_brace)) {
                const block = try self.parseBlock();
                const stmt = try self.allocator.create(ast.Stmt);
                stmt.* = .{ .span = block.span, .kind = .{ .block = block } };
                else_branch = stmt;
            } else {
                try self.reporter.err("E0217", self.peek().span, "expected 'if' or block after 'else'", .{});
            }
        }

        const payload = try self.allocator.create(ast.Stmt.IfStmt);
        payload.* = .{ .cond = cond, .then_branch = then_branch, .else_branch = else_branch };
        const stmt = try self.allocator.create(ast.Stmt);
        stmt.* = .{ .span = Span.join(start, self.peek().span), .kind = .{ .if_stmt = payload } };
        return stmt;
    }

    fn parseWhile(self: *Parser) !?*ast.Stmt {
        const start = self.peek().span;
        _ = self.advance();
        _ = try self.expect(.l_paren, "after 'while'");
        const cond = (try self.parseExpr()) orelse try self.errorExpr(self.peek().span);
        _ = try self.expect(.r_paren, "after while condition");
        const body = try self.parseBlock();

        const payload = try self.allocator.create(ast.Stmt.WhileStmt);
        payload.* = .{ .cond = cond, .body = body };
        const stmt = try self.allocator.create(ast.Stmt);
        stmt.* = .{ .span = Span.join(start, self.peek().span), .kind = .{ .while_stmt = payload } };
        return stmt;
    }

    fn parseReturn(self: *Parser) !?*ast.Stmt {
        const start = self.peek().span;
        _ = self.advance();
        var value: ?*ast.Expr = null;
        if (!self.check(.semicolon)) value = try self.parseExpr();
        _ = try self.expect(.semicolon, "after return statement");
        const payload = try self.allocator.create(ast.Stmt.ReturnStmt);
        payload.* = .{ .value = value };
        const stmt = try self.allocator.create(ast.Stmt);
        stmt.* = .{ .span = Span.join(start, self.peek().span), .kind = .{ .return_stmt = payload } };
        return stmt;
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    fn parseExpr(self: *Parser) Error!?*ast.Expr {
        return self.parseAssign();
    }

    fn parseAssign(self: *Parser) Error!?*ast.Expr {
        const lhs = (try self.parseLogicalOr()) orelse return null;
        const op: ast.AssignOp = switch (self.peek().kind) {
            .equal => .assign,
            .plus_equal => .add,
            .minus_equal => .sub,
            .star_equal => .mul,
            .slash_equal => .div,
            .percent_equal => .mod,
            .amp_equal => .bit_and,
            .pipe_equal => .bit_or,
            .caret_equal => .bit_xor,
            .shl_equal => .shl,
            .shr_equal => .shr,
            else => return lhs,
        };
        const op_tok = self.advance();
        const rhs = (try self.parseAssign()) orelse try self.errorExpr(op_tok.span);
        const node = try self.allocator.create(ast.Expr);
        node.* = .{
            .span = Span.join(lhs.span, rhs.span),
            .kind = .{ .assign = .{ .op = op, .target = lhs, .value = rhs } },
        };
        return node;
    }

    fn parseBinaryLevel(
        self: *Parser,
        comptime lower: fn (*Parser) Error!?*ast.Expr,
        ops: []const struct { Kind, ast.BinaryOp },
    ) Error!?*ast.Expr {
        var lhs = (try lower(self)) orelse return null;
        outer: while (true) {
            for (ops) |entry| {
                if (self.check(entry[0])) {
                    _ = self.advance();
                    const rhs = (try lower(self)) orelse return lhs;
                    const node = try self.allocator.create(ast.Expr);
                    node.* = .{
                        .span = Span.join(lhs.span, rhs.span),
                        .kind = .{ .binary = .{ .op = entry[1], .lhs = lhs, .rhs = rhs } },
                    };
                    lhs = node;
                    continue :outer;
                }
            }
            break;
        }
        return lhs;
    }

    fn parseLogicalOr(self: *Parser) Error!?*ast.Expr {
        return self.parseBinaryLevel(parseLogicalAnd, &.{.{ .pipe_pipe, .logical_or }});
    }

    fn parseLogicalAnd(self: *Parser) Error!?*ast.Expr {
        return self.parseBinaryLevel(parseBitOr, &.{.{ .amp_amp, .logical_and }});
    }

    fn parseBitOr(self: *Parser) Error!?*ast.Expr {
        return self.parseBinaryLevel(parseBitXor, &.{.{ .pipe, .bit_or }});
    }

    fn parseBitXor(self: *Parser) Error!?*ast.Expr {
        return self.parseBinaryLevel(parseBitAnd, &.{.{ .caret, .bit_xor }});
    }

    fn parseBitAnd(self: *Parser) Error!?*ast.Expr {
        return self.parseBinaryLevel(parseEquality, &.{.{ .amp, .bit_and }});
    }

    fn parseEquality(self: *Parser) Error!?*ast.Expr {
        return self.parseBinaryLevel(parseRelational, &.{
            .{ .equal_equal, .eq },
            .{ .bang_equal, .ne },
        });
    }

    fn parseRelational(self: *Parser) Error!?*ast.Expr {
        return self.parseBinaryLevel(parseShift, &.{
            .{ .less, .lt },
            .{ .less_equal, .le },
            .{ .greater, .gt },
            .{ .greater_equal, .ge },
        });
    }

    fn parseShift(self: *Parser) Error!?*ast.Expr {
        return self.parseBinaryLevel(parseAdditive, &.{
            .{ .shl, .shl },
            .{ .shr, .shr },
        });
    }

    fn parseAdditive(self: *Parser) Error!?*ast.Expr {
        return self.parseBinaryLevel(parseMultiplicative, &.{
            .{ .plus, .add },
            .{ .minus, .sub },
        });
    }

    fn parseMultiplicative(self: *Parser) Error!?*ast.Expr {
        return self.parseBinaryLevel(parseCast, &.{
            .{ .star, .mul },
            .{ .slash, .div },
            .{ .percent, .mod },
        });
    }

    fn parseCast(self: *Parser) Error!?*ast.Expr {
        var operand = (try self.parseUnary()) orelse return null;
        while (self.match(.kw_as)) {
            const target = (try self.parseType()) orelse return operand;
            const node = try self.allocator.create(ast.Expr);
            node.* = .{
                .span = Span.join(operand.span, target.span),
                .kind = .{ .cast = .{ .operand = operand, .target = target } },
            };
            operand = node;
        }
        return operand;
    }

    fn parseUnary(self: *Parser) Error!?*ast.Expr {
        const tok = self.peek();
        const op: ?ast.UnaryOp = switch (tok.kind) {
            .minus => .negate,
            .bang => .logical_not,
            .tilde => .bit_not,
            .amp => .address_of,
            .star => .dereference,
            else => null,
        };
        if (op) |unary_op| {
            _ = self.advance();
            const operand = (try self.parseUnary()) orelse try self.errorExpr(tok.span);
            const node = try self.allocator.create(ast.Expr);
            node.* = .{
                .span = Span.join(tok.span, operand.span),
                .kind = .{ .unary = .{ .op = unary_op, .operand = operand } },
            };
            return node;
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) Error!?*ast.Expr {
        var expr = (try self.parsePrimary()) orelse return null;
        while (true) {
            switch (self.peek().kind) {
                .l_paren => {
                    _ = self.advance();
                    var args: std.ArrayList(*ast.Expr) = .empty;
                    if (!self.check(.r_paren)) {
                        while (true) {
                            const arg = (try self.parseExpr()) orelse break;
                            try args.append(self.allocator, arg);
                            if (!self.match(.comma)) break;
                        }
                    }
                    _ = try self.expect(.r_paren, "after call arguments");
                    const node = try self.allocator.create(ast.Expr);
                    node.* = .{
                        .span = Span.join(expr.span, self.peek().span),
                        .kind = .{ .call = .{ .callee = expr, .args = try args.toOwnedSlice(self.allocator) } },
                    };
                    expr = node;
                },
                .l_bracket => {
                    _ = self.advance();
                    if (self.match(.dotdot)) {
                        var end: ?*ast.Expr = null;
                        if (!self.check(.r_bracket)) {
                            end = (try self.parseExpr()) orelse try self.errorExpr(self.peek().span);
                        }
                        _ = try self.expect(.r_bracket, "after slice range");
                        const node = try self.allocator.create(ast.Expr);
                        node.* = .{
                            .span = Span.join(expr.span, self.peek().span),
                            .kind = .{ .slice = .{ .base = expr, .start = null, .end = end } },
                        };
                        expr = node;
                        continue;
                    }
                    const first = (try self.parseExpr()) orelse try self.errorExpr(self.peek().span);
                    if (self.match(.dotdot)) {
                        var end: ?*ast.Expr = null;
                        if (!self.check(.r_bracket)) {
                            end = (try self.parseExpr()) orelse try self.errorExpr(self.peek().span);
                        }
                        _ = try self.expect(.r_bracket, "after slice range");
                        const node = try self.allocator.create(ast.Expr);
                        node.* = .{
                            .span = Span.join(expr.span, self.peek().span),
                            .kind = .{ .slice = .{ .base = expr, .start = first, .end = end } },
                        };
                        expr = node;
                        continue;
                    }
                    const index = first;
                    _ = try self.expect(.r_bracket, "after index expression");
                    const node = try self.allocator.create(ast.Expr);
                    node.* = .{
                        .span = Span.join(expr.span, self.peek().span),
                        .kind = .{ .index = .{ .base = expr, .index = index } },
                    };
                    expr = node;
                },
                .dot, .arrow => {
                    const arrow = self.advance().kind == .arrow;
                    if (!self.check(.identifier)) {
                        try self.reporter.err("E0218", self.peek().span, "expected field name, found {s}", .{token.describe(self.peek().kind)});
                        return expr;
                    }
                    const field_tok = self.advance();
                    const node = try self.allocator.create(ast.Expr);
                    node.* = .{
                        .span = Span.join(expr.span, field_tok.span),
                        .kind = .{ .field = .{
                            .base = expr,
                            .name = field_tok.lexeme,
                            .through_pointer = arrow,
                        } },
                    };
                    expr = node;
                },
                else => return expr,
            }
        }
    }

    fn parsePrimary(self: *Parser) Error!?*ast.Expr {
        const tok = self.peek();
        switch (tok.kind) {
            .int_literal => {
                _ = self.advance();
                const value = parseIntegerLiteral(tok.lexeme) catch {
                    try self.reporter.err("E0219", tok.span, "integer literal is malformed or too large", .{});
                    return try self.errorExpr(tok.span);
                };
                const node = try self.allocator.create(ast.Expr);
                node.* = .{ .span = tok.span, .kind = .{ .int_lit = .{ .value = value } } };
                return node;
            },
            .float_literal => {
                _ = self.advance();
                const cleaned = try self.cleanNumber(tok.lexeme);
                const value = std.fmt.parseFloat(f64, cleaned) catch {
                    try self.reporter.err("E0220", tok.span, "malformed float literal", .{});
                    return try self.errorExpr(tok.span);
                };
                const node = try self.allocator.create(ast.Expr);
                node.* = .{ .span = tok.span, .kind = .{ .float_lit = .{ .value = value } } };
                return node;
            },
            .string_literal => {
                _ = self.advance();
                const bytes = try self.decodeString(tok);
                const node = try self.allocator.create(ast.Expr);
                node.* = .{ .span = tok.span, .kind = .{ .string_lit = .{ .bytes = bytes } } };
                return node;
            },
            .char_literal => {
                _ = self.advance();
                const value = try self.decodeChar(tok);
                const node = try self.allocator.create(ast.Expr);
                node.* = .{ .span = tok.span, .kind = .{ .char_lit = value } };
                return node;
            },
            .kw_true, .kw_false => {
                _ = self.advance();
                const node = try self.allocator.create(ast.Expr);
                node.* = .{ .span = tok.span, .kind = .{ .bool_lit = tok.kind == .kw_true } };
                return node;
            },
            .kw_null => {
                _ = self.advance();
                const node = try self.allocator.create(ast.Expr);
                node.* = .{ .span = tok.span, .kind = .{ .null_lit = {} } };
                return node;
            },
            .identifier => {
                _ = self.advance();
                if (self.check(.l_brace)) {
                    const type_expr = try self.allocator.create(ast.TypeExpr);
                    type_expr.* = .{ .span = tok.span, .kind = .{ .name = tok.lexeme } };
                    return try self.parseStructInit(type_expr, tok.span);
                }
                if (self.check(.dot) and self.peekAt(1).kind == .identifier and
                    self.peekAt(2).kind == .l_brace)
                {
                    _ = self.advance();
                    const member = self.advance();
                    const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ tok.lexeme, member.lexeme });
                    const span = Span.join(tok.span, member.span);
                    const type_expr = try self.allocator.create(ast.TypeExpr);
                    type_expr.* = .{ .span = span, .kind = .{ .name = qualified } };
                    return try self.parseStructInit(type_expr, span);
                }
                const node = try self.allocator.create(ast.Expr);
                node.* = .{ .span = tok.span, .kind = .{ .ident = .{ .name = tok.lexeme } } };
                return node;
            },
            .l_paren => {
                _ = self.advance();
                const inner = (try self.parseExpr()) orelse try self.errorExpr(tok.span);
                _ = try self.expect(.r_paren, "after parenthesized expression");
                return inner;
            },
            .l_bracket => return try self.parseArrayLiteral(),
            else => {
                try self.reporter.err("E0221", tok.span, "expected an expression, found {s}", .{token.describe(tok.kind)});
                return null;
            },
        }
    }

    fn parseArrayLiteral(self: *Parser) Error!?*ast.Expr {
        const start = self.advance().span;
        var elements: std.ArrayList(*ast.Expr) = .empty;
        if (!self.check(.r_bracket)) {
            while (true) {
                const element = (try self.parseExpr()) orelse break;
                try elements.append(self.allocator, element);
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.r_bracket, "after array literal");
        const node = try self.allocator.create(ast.Expr);
        node.* = .{
            .span = Span.join(start, self.peek().span),
            .kind = .{ .array_lit = try elements.toOwnedSlice(self.allocator) },
        };
        return node;
    }

    fn parseStructInit(self: *Parser, type_expr: *ast.TypeExpr, start: Span) Error!*ast.Expr {
        var fields: std.ArrayList(ast.Expr.Kind.InitField) = .empty;
        if (try self.expect(.l_brace, "to begin struct initializer")) {
            while (!self.check(.r_brace) and !self.check(.eof)) {
                const before = self.pos;
                if (!self.check(.identifier)) {
                    try self.reporter.err("E0222", self.peek().span, "expected field name, found {s}", .{token.describe(self.peek().kind)});
                    self.synchronize(.comma);
                    _ = self.match(.comma);
                    if (self.pos == before) break;
                    continue;
                }
                const field_tok = self.advance();
                _ = try self.expect(.colon, "after field name in struct initializer");
                const value = (try self.parseExpr()) orelse try self.errorExpr(self.peek().span);
                try fields.append(self.allocator, .{
                    .span = Span.join(field_tok.span, value.span),
                    .name = field_tok.lexeme,
                    .value = value,
                });
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.r_brace, "to close struct initializer");
        }
        const node = try self.allocator.create(ast.Expr);
        node.* = .{
            .span = Span.join(start, self.peek().span),
            .kind = .{ .struct_init = .{ .type_expr = type_expr, .fields = try fields.toOwnedSlice(self.allocator) } },
        };
        return node;
    }

    // ------------------------------------------------------------------
    // Literal decoding
    // ------------------------------------------------------------------

    fn cleanNumber(self: *Parser, lexeme: []const u8) ![]const u8 {
        var buffer = try self.allocator.alloc(u8, lexeme.len);
        var n: usize = 0;
        for (lexeme) |byte| {
            if (byte == '_') continue;
            buffer[n] = byte;
            n += 1;
        }
        return buffer[0..n];
    }

    fn decodeString(self: *Parser, tok: Token) ![]const u8 {
        const raw = tok.lexeme;
        const inner = if (raw.len >= 2) raw[1 .. raw.len - 1] else "";
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < inner.len) {
            const byte = inner[i];
            if (byte != '\\') {
                try out.append(self.allocator, byte);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= inner.len) break;
            const esc = inner[i];
            i += 1;
            switch (esc) {
                'n' => try out.append(self.allocator, '\n'),
                'r' => try out.append(self.allocator, '\r'),
                't' => try out.append(self.allocator, '\t'),
                '0' => try out.append(self.allocator, 0),
                '\\' => try out.append(self.allocator, '\\'),
                '"' => try out.append(self.allocator, '"'),
                '\'' => try out.append(self.allocator, '\''),
                'x' => {
                    if (i + 2 > inner.len) {
                        try self.reporter.err("E0223", tok.span, "incomplete hex escape", .{});
                        break;
                    }
                    const value = std.fmt.parseInt(u8, inner[i .. i + 2], 16) catch {
                        try self.reporter.err("E0224", tok.span, "invalid hex escape", .{});
                        break;
                    };
                    try out.append(self.allocator, value);
                    i += 2;
                },
                else => {
                    try self.reporter.err("E0225", tok.span, "unknown escape sequence '\\{c}'", .{esc});
                    try out.append(self.allocator, esc);
                },
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn decodeChar(self: *Parser, tok: Token) !u32 {
        const raw = tok.lexeme;
        const inner = if (raw.len >= 2) raw[1 .. raw.len - 1] else "";
        if (inner.len == 0) {
            try self.reporter.err("E0226", tok.span, "empty character literal", .{});
            return 0;
        }
        if (inner[0] == '\\') {
            if (inner.len < 2) return 0;
            return switch (inner[1]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '0' => 0,
                '\\' => '\\',
                '\'' => '\'',
                '"' => '"',
                'x' => blk: {
                    if (inner.len < 4) {
                        try self.reporter.err("E0227", tok.span, "incomplete hex escape in character literal", .{});
                        break :blk 0;
                    }
                    break :blk std.fmt.parseInt(u8, inner[2..4], 16) catch 0;
                },
                else => blk: {
                    try self.reporter.err("E0228", tok.span, "unknown escape sequence in character literal", .{});
                    break :blk inner[1];
                },
            };
        }
        const view = std.unicode.Utf8View.init(inner) catch {
            try self.reporter.err("E0229", tok.span, "invalid UTF-8 in character literal", .{});
            return inner[0];
        };
        var it = view.iterator();
        return it.nextCodepoint() orelse 0;
    }

    // ------------------------------------------------------------------
    // Recovery
    // ------------------------------------------------------------------

    fn synchronize(self: *Parser, stop: Kind) void {
        while (!self.check(.eof)) {
            if (self.check(stop)) {
                _ = self.advance();
                return;
            }
            switch (self.peek().kind) {
                .kw_fn, .kw_struct, .kw_enum, .kw_extern, .kw_export => return,
                else => _ = self.advance(),
            }
        }
    }
};

pub fn parseIntegerLiteral(lexeme: []const u8) !u128 {
    var buffer: [256]u8 = undefined;
    if (lexeme.len > buffer.len) return error.Overflow;
    var n: usize = 0;
    var base: u8 = 10;
    var i: usize = 0;
    if (lexeme.len >= 2 and lexeme[0] == '0') {
        switch (lexeme[1]) {
            'x', 'X' => {
                base = 16;
                i = 2;
            },
            'b', 'B' => {
                base = 2;
                i = 2;
            },
            'o', 'O' => {
                base = 8;
                i = 2;
            },
            else => {},
        }
    }
    while (i < lexeme.len) : (i += 1) {
        if (lexeme[i] == '_') continue;
        buffer[n] = lexeme[i];
        n += 1;
    }
    if (n == 0) return error.InvalidCharacter;
    return std.fmt.parseInt(u128, buffer[0..n], base);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestContext = struct {
    arena: std.heap.ArenaAllocator,
    src: *source.Source,
    reporter: diagnostics.Reporter,

    fn init(self: *TestContext, text: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena.allocator();
        self.src = try a.create(source.Source);
        self.src.* = try source.Source.init(a, "test.kyn", text);
        self.reporter = diagnostics.Reporter.init(a, self.src);
    }

    fn deinit(self: *TestContext) void {
        self.arena.deinit();
    }
};

fn parseTest(text: []const u8, ctx: *TestContext) !*ast.Program {
    _ = text;
    const a = ctx.arena.allocator();
    const lexer = @import("lexer.zig");
    var lx = lexer.Lexer.init(a, ctx.src, &ctx.reporter);
    const tokens = try lx.tokenize();
    var parser = Parser.init(a, tokens, &ctx.reporter);
    return parser.parse();
}

test "parse function and variable declarations" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\const MAX: i32 = 10;
        \\fn add(a: i32, b: i32) i32 {
        \\    let x: i32 = a + b;
        \\    return x;
        \\}
    );
    defer ctx.deinit();

    const program = try parseTest(ctx.src.text, &ctx);
    try testing.expectEqual(@as(usize, 2), program.decls.len);
    try testing.expectEqual(std.meta.Tag(ast.Decl.Kind).var_decl, std.meta.activeTag(program.decls[0].kind));
    try testing.expectEqual(std.meta.Tag(ast.Decl.Kind).fn_decl, std.meta.activeTag(program.decls[1].kind));
    try testing.expect(!ctx.reporter.hasErrors());
}

test "precedence: 1 + 2 * 3 parses as 1 + (2 * 3)" {
    var ctx: TestContext = undefined;
    try ctx.init("fn main() i32 { return 1 + 2 * 3; }");
    defer ctx.deinit();

    const program = try parseTest(ctx.src.text, &ctx);
    try testing.expect(!ctx.reporter.hasErrors());
    const fn_decl = program.decls[0].kind.fn_decl;
    const ret = fn_decl.body.?.stmts[0].kind.return_stmt;
    const expr = ret.value.?;
    try testing.expectEqual(std.meta.Tag(ast.Expr.Kind).binary, std.meta.activeTag(expr.kind));
    try testing.expectEqual(ast.BinaryOp.add, expr.kind.binary.op);
    try testing.expectEqual(ast.BinaryOp.mul, expr.kind.binary.rhs.kind.binary.op);
}

test "parse control flow and calls" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\fn main() i32 {
        \\    var i: i32 = 0;
        \\    while (i < 10) {
        \\        if (i == 5) { break; } else { i = i + 1; }
        \\    }
        \\    return i;
        \\}
    );
    defer ctx.deinit();
    _ = try parseTest(ctx.src.text, &ctx);
    try testing.expect(!ctx.reporter.hasErrors());
}

test "parse struct, enum, pointer types and initializer" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\struct Point { x: i32, y: i32 }
        \\enum Color: u8 { Red, Green = 3, Blue }
        \\fn main() i32 {
        \\    var p: Point = Point { x: 1, y: 2 };
        \\    let q: *Point = &p;
        \\    let c: Color = Color.Blue;
        \\    return q->x;
        \\}
    );
    defer ctx.deinit();
    _ = try parseTest(ctx.src.text, &ctx);
    try testing.expect(!ctx.reporter.hasErrors());
}

test "parse extern function" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\extern fn puts(s: *const u8) i32;
        \\fn main() i32 { return 0; }
    );
    defer ctx.deinit();
    const program = try parseTest(ctx.src.text, &ctx);
    try testing.expect(!ctx.reporter.hasErrors());
    try testing.expect(program.decls[0].kind.fn_decl.is_extern);
}

test "parse variadic extern declaration" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\extern fn printf(format: *const u8, ...) i32;
        \\extern fn puts(s: *const u8) i32;
        \\fn main() i32 { return 0; }
    );
    defer ctx.deinit();
    const program = try parseTest(ctx.src.text, &ctx);
    try testing.expect(!ctx.reporter.hasErrors());
    const variadic = program.decls[0].kind.fn_decl;
    try testing.expect(variadic.is_variadic);
    // The marker is not a parameter: only the format string is declared, which
    // is what keeps the signature usable for the fixed-argument arity check.
    try testing.expectEqual(@as(usize, 1), variadic.params.len);
    try testing.expectEqualStrings("format", variadic.params[0].name);
    try testing.expect(!program.decls[1].kind.fn_decl.is_variadic);
    try testing.expect(!program.decls[2].kind.fn_decl.is_variadic);
}

test "variadic function with a body is rejected" {
    var ctx: TestContext = undefined;
    try ctx.init("fn helper(value: i32, ...) i32 { return value; }");
    defer ctx.deinit();
    _ = try parseTest(ctx.src.text, &ctx);
    try testing.expect(ctx.reporter.hasErrors());
    try testing.expectEqualStrings("E0474", ctx.reporter.list.items[0].code);
}

test "parse a function type" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\fn main() i32 {
        \\    let f: fn(i32, i32) i32 = add;
        \\    let g: fn() = notify;
        \\    return f(1, 2);
        \\}
    );
    defer ctx.deinit();
    const program = try parseTest(ctx.src.text, &ctx);
    try testing.expect(!ctx.reporter.hasErrors());
    const body = program.decls[0].kind.fn_decl.body.?;
    const f_ty = body.stmts[0].kind.var_decl.ty_expr.?;
    const f_sig = f_ty.kind.fn_type;
    try testing.expectEqual(@as(usize, 2), f_sig.params.len);
    try testing.expect(f_sig.ret != null);
    // A missing return type means `void`, so it stays null in the tree.
    const g_sig = body.stmts[1].kind.var_decl.ty_expr.?.kind.fn_type;
    try testing.expectEqual(@as(usize, 0), g_sig.params.len);
    try testing.expect(g_sig.ret == null);
}

test "parse errors are reported and recovered" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\fn main( i32 {
        \\    let x = ;
        \\}
        \\fn ok() i32 { return 0; }
    );
    defer ctx.deinit();
    _ = try parseTest(ctx.src.text, &ctx);
    try testing.expect(ctx.reporter.hasErrors());
}

test "parse string escapes" {
    var ctx: TestContext = undefined;
    try ctx.init("fn main() i32 { let s = \"a\\n\\x41\"; return 0; }");
    defer ctx.deinit();
    const program = try parseTest(ctx.src.text, &ctx);
    try testing.expect(!ctx.reporter.hasErrors());
    const stmt = program.decls[0].kind.fn_decl.body.?.stmts[0].kind.var_decl;
    const bytes = stmt.init.?.kind.string_lit.bytes;
    try testing.expectEqualStrings("a\nA", bytes);
}

test "parser terminates when a declaration appears inside a struct body" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\struct Point { x: i32, y: { } enum Color: u8 { Red }
        \\fn main() i32 { return 0; }
    );
    defer ctx.deinit();
    const program = try parseTest(ctx.src.text, &ctx);
    try testing.expect(ctx.reporter.hasErrors());
    try testing.expect(ctx.reporter.error_count <= 20);
    try testing.expectEqual(@as(usize, 3), program.decls.len);
    try testing.expectEqual(std.meta.Tag(ast.Decl.Kind).struct_decl, std.meta.activeTag(program.decls[0].kind));
    try testing.expectEqual(std.meta.Tag(ast.Decl.Kind).enum_decl, std.meta.activeTag(program.decls[1].kind));
}

test "parser terminates when a declaration appears inside an enum body" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\enum Color: u8 { Red, @@@ struct Point { x: i32 }
        \\fn main() i32 { return 0; }
    );
    defer ctx.deinit();
    const program = try parseTest(ctx.src.text, &ctx);
    try testing.expect(ctx.reporter.hasErrors());
    try testing.expect(ctx.reporter.error_count <= 20);
    try testing.expectEqual(@as(usize, 3), program.decls.len);
}

test "parser terminates when a declaration appears inside a struct initializer" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\struct Point { x: i32, y: i32 }
        \\fn main() i32 {
        \\    let p: Point = Point { x: 1, @@@ fn ok() i32 { return 0; } ;
        \\    return 0;
        \\}
    );
    defer ctx.deinit();
    const program = try parseTest(ctx.src.text, &ctx);
    try testing.expect(ctx.reporter.hasErrors());
    try testing.expect(ctx.reporter.error_count <= 30);
    try testing.expectEqual(@as(usize, 2), program.decls.len);
}

test "subtraction and division associate left-to-right" {
    var ctx: TestContext = undefined;
    try ctx.init("fn main() i32 { return 10 - 4 - 2; }");
    defer ctx.deinit();

    const program = try parseTest(ctx.src.text, &ctx);
    const ret = program.decls[0].kind.fn_decl.body.?.stmts[0].kind.return_stmt;
    const expr = ret.value.?;
    try testing.expectEqual(ast.BinaryOp.sub, expr.kind.binary.op);
    try testing.expectEqual(ast.BinaryOp.sub, expr.kind.binary.lhs.kind.binary.op);
    try testing.expectEqual(@as(u128, 10), expr.kind.binary.lhs.kind.binary.lhs.kind.int_lit.value);
}

test "bitwise operators respect precedence" {
    var ctx: TestContext = undefined;
    try ctx.init("fn main() i32 { return 1 | 2 ^ 3 & 4; }");
    defer ctx.deinit();

    const program = try parseTest(ctx.src.text, &ctx);
    const ret = program.decls[0].kind.fn_decl.body.?.stmts[0].kind.return_stmt;
    const expr = ret.value.?;
    try testing.expectEqual(ast.BinaryOp.bit_or, expr.kind.binary.op);
    try testing.expectEqual(ast.BinaryOp.bit_xor, expr.kind.binary.rhs.kind.binary.op);
    try testing.expectEqual(ast.BinaryOp.bit_and, expr.kind.binary.rhs.kind.binary.rhs.kind.binary.op);
}

test "shift has lower precedence than addition" {
    var ctx: TestContext = undefined;
    try ctx.init("fn main() i32 { return 1 << 2 + 3; }");
    defer ctx.deinit();

    const program = try parseTest(ctx.src.text, &ctx);
    const ret = program.decls[0].kind.fn_decl.body.?.stmts[0].kind.return_stmt;
    const expr = ret.value.?;
    try testing.expectEqual(ast.BinaryOp.shl, expr.kind.binary.op);
    try testing.expectEqual(ast.BinaryOp.add, expr.kind.binary.rhs.kind.binary.op);
}

test "as binds to the nearest multiplicative operand" {
    var ctx: TestContext = undefined;
    try ctx.init("fn main() i32 { return a * b as i64; }");
    defer ctx.deinit();

    const program = try parseTest(ctx.src.text, &ctx);
    const ret = program.decls[0].kind.fn_decl.body.?.stmts[0].kind.return_stmt;
    const expr = ret.value.?;
    try testing.expectEqual(ast.BinaryOp.mul, expr.kind.binary.op);
    try testing.expectEqual(std.meta.Tag(ast.Expr.Kind).cast, std.meta.activeTag(expr.kind.binary.rhs.kind));
}

test "assignment is right-associative" {
    var ctx: TestContext = undefined;
    try ctx.init("fn main() i32 { a = b = c; return a; }");
    defer ctx.deinit();

    const program = try parseTest(ctx.src.text, &ctx);
    const stmt = program.decls[0].kind.fn_decl.body.?.stmts[0].kind.expr;
    try testing.expectEqual(std.meta.Tag(ast.Expr.Kind).assign, std.meta.activeTag(stmt.kind));
    try testing.expectEqual(std.meta.Tag(ast.Expr.Kind).assign, std.meta.activeTag(stmt.kind.assign.value.kind));
}

test "parse open-ended and bounded slice expressions" {
    var ctx: TestContext = undefined;
    try ctx.init(
        \\fn main() i32 {
        \\    let a = arr[..];
        \\    let b = arr[1..];
        \\    let c = arr[..3];
        \\    let d = arr[1..3];
        \\    return 0;
        \\}
    );
    defer ctx.deinit();

    const program = try parseTest(ctx.src.text, &ctx);
    try testing.expect(!ctx.reporter.hasErrors());
    const stmts = program.decls[0].kind.fn_decl.body.?.stmts;

    const full = stmts[0].kind.var_decl.init.?.kind.slice;
    try testing.expect(full.start == null);
    try testing.expect(full.end == null);

    const from = stmts[1].kind.var_decl.init.?.kind.slice;
    try testing.expect(from.start != null);
    try testing.expect(from.end == null);

    const up_to = stmts[2].kind.var_decl.init.?.kind.slice;
    try testing.expect(up_to.start == null);
    try testing.expect(up_to.end != null);

    const bounded = stmts[3].kind.var_decl.init.?.kind.slice;
    try testing.expect(bounded.start != null);
    try testing.expect(bounded.end != null);
}
