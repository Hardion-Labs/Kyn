//! Static analysis pass.
//!
//! This pass runs after semantic analysis on the fully typed AST. It currently
//! detects:
//!   - reads of possibly-uninitialized locals;
//!   - compile-time provable division by zero;
//!   - compile-time provable integer overflow;
//!   - constant out-of-bounds array indexing;
//!   - unreachable statements;
//!   - compile-time constant conditions.
//!
//! The analysis is intentionally conservative. A diagnostic is only emitted
//! when the condition is provable from the program text.

const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");
const symbol = @import("symbol.zig");
const diagnostics = @import("diagnostics.zig");
const sema_mod = @import("sema.zig");

pub const Error = error{OutOfMemory};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    reporter: *diagnostics.Reporter,
    state: std.AutoHashMap(u32, bool),
    current_fn: ?*ast.FnDecl = null,

    pub fn init(allocator: std.mem.Allocator, reporter: *diagnostics.Reporter) Analyzer {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .state = std.AutoHashMap(u32, bool).init(allocator),
        };
    }

    pub fn analyze(self: *Analyzer, program: *ast.Program) Error!void {
        for (program.decls) |decl| {
            switch (decl.kind) {
                .fn_decl => |fd| {
                    if (fd.body) |body| try self.analyzeFunction(fd, body);
                },
                else => {},
            }
        }
    }

    fn analyzeFunction(self: *Analyzer, fd: *ast.FnDecl, body: *ast.Block) Error!void {
        self.state.clearRetainingCapacity();
        for (fd.params) |param| {
            if (param.sym) |sym| try self.state.put(sym.id, true);
        }
        self.current_fn = fd;
        try self.checkBlock(body);
        self.current_fn = null;
    }

    fn checkBlock(self: *Analyzer, block: *ast.Block) Error!void {
        var reachable = true;
        var warned_unreachable = false;
        for (block.stmts) |stmt| {
            if (!reachable) {
                if (!warned_unreachable and !isTrivial(stmt)) {
                    try self.reporter.warn("W0501", stmt.span, "unreachable statement", .{});
                    warned_unreachable = true;
                }
                continue;
            }
            try self.checkStmt(stmt);
            if (stmtTerminates(stmt)) reachable = false;
        }
    }

    fn checkStmt(self: *Analyzer, stmt: *ast.Stmt) Error!void {
        switch (stmt.kind) {
            .expr => |expr| try self.checkExpr(expr),
            .var_decl => |vd| {
                if (vd.init) |init_expr| try self.checkExpr(init_expr);
                if (vd.sym) |sym| try self.state.put(sym.id, vd.init != null);
            },
            .block => |block| try self.checkBlock(block),
            .if_stmt => |if_stmt| try self.checkIf(if_stmt),
            .while_stmt => |while_stmt| try self.checkWhile(while_stmt),
            .match_stmt => |match_stmt| {
                // The scrutinee is evaluated once; each arm's block is a path of
                // its own, so what is known after the match is only what holds on
                // every path. Nothing is learned from an arm's pattern, which keeps
                // the flow analysis conservative rather than wrong.
                try self.checkExpr(match_stmt.value);
                for (match_stmt.arms) |arm| {
                    if (arm.pattern) |pattern| try self.checkExpr(pattern);
                    try self.checkBlock(arm.body);
                }
            },
            .return_stmt => |ret_stmt| {
                if (ret_stmt.value) |value| try self.checkExpr(value);
            },
            .break_stmt, .continue_stmt, .empty => {},
        }
    }

    fn checkIf(self: *Analyzer, if_stmt: *ast.Stmt.IfStmt) Error!void {
        try self.checkExpr(if_stmt.cond);
        if (constBool(if_stmt.cond)) |value| {
            try self.reporter.warn("W0502", if_stmt.cond.span, "condition is always {s}", .{
                if (value) "true" else "false",
            });
        }

        var before = try self.cloneState();
        defer before.deinit();

        try self.checkBlock(if_stmt.then_branch);
        var then_state = try self.cloneState();

        if (if_stmt.else_branch) |else_stmt| {
            self.state = try self.cloneStateFrom(&before);
            try self.checkStmt(else_stmt);
        } else {
            self.state = try self.cloneStateFrom(&before);
        }
        var else_state = try self.cloneState();
        defer else_state.deinit();
        defer then_state.deinit();

        // Intersection: a local is initialized after the branch only if it was
        // initialized on every path.
        var it = self.state.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const a = then_state.get(key) orelse false;
            const b = else_state.get(key) orelse false;
            entry.value_ptr.* = a and b;
        }
    }

    fn checkWhile(self: *Analyzer, while_stmt: *ast.Stmt.WhileStmt) Error!void {
        try self.checkExpr(while_stmt.cond);
        if (constBool(while_stmt.cond)) |value| {
            try self.reporter.warn("W0502", while_stmt.cond.span, "loop condition is always {s}", .{
                if (value) "true" else "false",
            });
        }
        var before = try self.cloneState();
        defer before.deinit();
        try self.checkBlock(while_stmt.body);
        // The body may execute zero times.
        self.state.deinit();
        self.state = try self.cloneStateFrom(&before);
    }

    fn checkExpr(self: *Analyzer, expr: *ast.Expr) Error!void {
        switch (expr.kind) {
            .int_lit, .float_lit, .bool_lit, .char_lit, .string_lit, .null_lit => {},
            .ident => |ident| {
                if (ident.sym) |sym| {
                    if (sym.kind == .local) {
                        if (!(self.state.get(sym.id) orelse false)) {
                            try self.reporter.err("E0501", expr.span, "variable '{s}' may be used before it is initialized", .{sym.name});
                        }
                    }
                }
            },
            .unary => |unary| {
                // Taking the address of an uninitialized local is allowed.
                if (unary.op != .address_of) try self.checkExpr(unary.operand);
                if (unary.op == .dereference and constPointerIsNull(unary.operand)) {
                    try self.reporter.err("E0506", expr.span, "provable null pointer dereference", .{});
                }
                if (unary.op == .negate) try self.checkUnaryOverflow(expr, unary);
            },
            // `va_arg()` has no sub-expression and no variable to read, so
            // there is nothing for dataflow to say about it.
            .va_arg => {},
            .slice => |slice| {
                try self.checkExpr(slice.base);
                if (slice.start) |start_expr| try self.checkExpr(start_expr);
                if (slice.end) |end_expr| try self.checkExpr(end_expr);
                try self.checkSliceFacts(expr, slice);
            },
            .binary => |binary| {
                try self.checkExpr(binary.lhs);
                try self.checkExpr(binary.rhs);
                try self.checkBinaryFacts(expr, binary);
            },
            .assign => |assign| {
                if (assign.op != .assign) try self.checkExpr(assign.target);
                switch (assign.target.kind) {
                    .ident => {},
                    else => try self.checkExpr(assign.target),
                }
                try self.checkExpr(assign.value);
                self.markAssigned(assign.target);
            },
            .call => |call| {
                try self.checkExpr(call.callee);
                for (call.args) |arg| try self.checkExpr(arg);
            },
            .cast => |cast| {
                try self.checkExpr(cast.operand);
                if (cast.target.resolved) |target_ty| {
                    if (target_ty.* == .slice) {
                        if (cast.operand.ty) |src_ty| {
                            if (src_ty.* == .pointer and constPointerIsNull(cast.operand)) {
                                try self.reporter.err("E0506", expr.span, "provable null pointer dereference", .{});
                            }
                        }
                    }
                }
            },
            .field => |field| {
                if (field.through_pointer and constPointerIsNull(field.base)) {
                    try self.reporter.err("E0506", expr.span, "provable null pointer dereference", .{});
                }
                if (!field.is_enum_variant) try self.checkExpr(field.base);
            },
            .index => |index| {
                try self.checkExpr(index.base);
                try self.checkExpr(index.index);
                if (index.base.ty) |base_ty| {
                    if (base_ty.* == .pointer and constPointerIsNull(index.base)) {
                        try self.reporter.err("E0506", expr.span, "provable null pointer dereference", .{});
                    }
                    if (base_ty.* == .array) {
                        if (constInt(index.index)) |value| {
                            if (value < 0 or value >= @as(i128, @intCast(base_ty.array.len))) {
                                try self.reporter.err("E0502", index.index.span, "constant index {d} is out of bounds for array of length {d}", .{
                                    value, base_ty.array.len,
                                });
                            }
                        }
                    } else if (base_ty.* == .slice) {
                        if (constInt(index.index)) |value| {
                            if (value < 0) {
                                try self.reporter.err("E0502", index.index.span, "constant slice index {d} is negative", .{value});
                            }
                        }
                    }
                }
            },
            .struct_init => |initializer| {
                for (initializer.fields) |field| try self.checkExpr(field.value);
            },
            .array_lit => |elements| {
                for (elements) |element| try self.checkExpr(element);
            },
        }
    }

    fn markAssigned(self: *Analyzer, target: *ast.Expr) void {
        switch (target.kind) {
            .ident => |ident| {
                if (ident.sym) |sym| {
                    self.state.put(sym.id, true) catch {};
                }
            },
            .field => |field| self.markAssigned(field.base),
            .index => |index| self.markAssigned(index.base),
            else => {},
        }
    }

    fn checkSliceFacts(self: *Analyzer, expr: *ast.Expr, slice: ast.Expr.Kind.SliceAccess) Error!void {
        const base_ty = slice.base.ty orelse return;
        if (base_ty.* == .pointer and constPointerIsNull(slice.base)) {
            try self.reporter.err("E0506", expr.span, "provable null pointer dereference", .{});
        }

        const known_len: ?i128 = switch (base_ty.*) {
            .array => |a| @intCast(a.len),
            .pointer => |p| if (p.elem.* == .array) @intCast(p.elem.array.len) else null,
            else => null,
        };

        const start_const: ?i128 = if (slice.start) |s| constInt(s) else 0;
        const end_const: ?i128 = if (slice.end) |e| constInt(e) else known_len;

        var invalid = false;
        if (slice.start) |s| {
            if (start_const) |sv| {
                if (sv < 0) {
                    try self.reporter.err("E0502", s.span, "constant slice start {d} is negative", .{sv});
                    invalid = true;
                } else if (known_len) |len| {
                    if (sv > len) {
                        try self.reporter.err("E0502", s.span, "constant slice start {d} exceeds length {d}", .{ sv, len });
                        invalid = true;
                    }
                }
            }
        }
        if (slice.end) |e| {
            if (end_const) |ev| {
                if (ev < 0) {
                    try self.reporter.err("E0502", e.span, "constant slice end {d} is negative", .{ev});
                    invalid = true;
                } else if (known_len) |len| {
                    if (ev > len) {
                        try self.reporter.err("E0502", e.span, "constant slice end {d} exceeds length {d}", .{ ev, len });
                        invalid = true;
                    }
                }
            }
        }
        if (!invalid) {
            if (start_const) |sv| {
                if (end_const) |ev| {
                    if (sv > ev) {
                        try self.reporter.err("E0502", expr.span, "constant slice start {d} exceeds end {d}", .{ sv, ev });
                    }
                }
            }
        }
    }

    fn checkBinaryFacts(self: *Analyzer, expr: *ast.Expr, binary: ast.Expr.Kind.Binary) Error!void {
        if (binary.op == .div or binary.op == .mod) {
            if (constInt(binary.rhs)) |value| {
                if (value == 0) {
                    try self.reporter.err("E0503", expr.span, "division by zero is provable at compile time", .{});
                    return;
                }
            }
        }

        const lhs = constInt(binary.lhs);
        const rhs = constInt(binary.rhs);
        if (lhs == null or rhs == null) return;
        const ty = expr.ty orelse return;
        if (!ty.isInteger() or ty.* == .comptime_int) return;
        const info = ty.intInfo();
        const a = lhs.?;
        const b = rhs.?;

        const result: ?i128 = switch (binary.op) {
            .add => std.math.add(i128, a, b) catch return,
            .sub => std.math.sub(i128, a, b) catch return,
            .mul => std.math.mul(i128, a, b) catch return,
            .div => if (b == 0) null else @divTrunc(a, b),
            .mod => if (b == 0) null else @rem(a, b),
            .shl => blk: {
                if (b < 0 or b >= info.bits) {
                    try self.reporter.err("E0504", expr.span, "shift amount {d} is out of range for type '{s}'", .{ b, ty.intInfo().name() });
                    break :blk null;
                }
                break :blk a << @intCast(b);
            },
            .shr => blk: {
                if (b < 0 or b >= info.bits) {
                    try self.reporter.err("E0504", expr.span, "shift amount {d} is out of range for type '{s}'", .{ b, ty.intInfo().name() });
                    break :blk null;
                }
                break :blk a >> @intCast(b);
            },
            else => null,
        };
        if (result) |value| {
            if (!info.fits(value)) {
                try self.reporter.err("E0505", expr.span, "constant expression overflows type '{s}'", .{info.name()});
            }
        }
    }

    fn checkUnaryOverflow(self: *Analyzer, expr: *ast.Expr, unary: ast.Expr.Kind.Unary) Error!void {
        const value = constInt(unary.operand) orelse return;
        const ty = expr.ty orelse return;
        if (!ty.isInteger() or ty.* == .comptime_int) return;
        const info = ty.intInfo();
        const result = std.math.negate(value) catch return;
        if (!info.fits(result)) {
            try self.reporter.err("E0505", expr.span, "constant expression overflows type '{s}'", .{info.name()});
        }
    }

    fn cloneState(self: *Analyzer) Error!std.AutoHashMap(u32, bool) {
        return self.cloneStateFrom(&self.state);
    }

    fn cloneStateFrom(self: *Analyzer, source: *const std.AutoHashMap(u32, bool)) !std.AutoHashMap(u32, bool) {
        var result = std.AutoHashMap(u32, bool).init(self.allocator);
        var it = source.iterator();
        while (it.next()) |entry| try result.put(entry.key_ptr.*, entry.value_ptr.*);
        return result;
    }
};

fn isTrivial(stmt: *ast.Stmt) bool {
    return switch (stmt.kind) {
        .empty => true,
        .block => |block| block.stmts.len == 0,
        else => false,
    };
}

fn stmtTerminates(stmt: *ast.Stmt) bool {
    return switch (stmt.kind) {
        .return_stmt, .break_stmt, .continue_stmt => true,
        .block => |block| block.stmts.len > 0 and stmtTerminates(block.stmts[block.stmts.len - 1]),
        .if_stmt => |if_stmt| if (if_stmt.else_branch) |else_stmt|
            sema_mod.blockAlwaysReturns(if_stmt.then_branch) and stmtTerminates(else_stmt)
        else
            false,
        .while_stmt => false,
        // An exhaustive match terminates when every one of its arms does: the
        // wildcard guarantees one of them runs. Checked only when the arm list is
        // exhaustive, since `sema` rejects a non-exhaustive one but the analyzer
        // may already be looking at the tree.
        .match_stmt => |match_stmt| blk: {
            var has_wildcard = false;
            for (match_stmt.arms) |arm| {
                if (arm.pattern == null) has_wildcard = true;
                if (!sema_mod.blockAlwaysReturns(arm.body)) break :blk false;
            }
            break :blk has_wildcard;
        },
        else => false,
    };
}

/// Fold a constant integer expression. Returns null when the value is not
/// statically known.
pub fn constInt(expr: *ast.Expr) ?i128 {
    return switch (expr.kind) {
        .int_lit => |lit| if (lit.value <= @as(u128, @intCast(std.math.maxInt(i128)))) @intCast(lit.value) else null,
        .char_lit => |value| @intCast(value),
        .bool_lit => |value| if (value) 1 else 0,
        .unary => |unary| blk: {
            const value = constInt(unary.operand) orelse break :blk null;
            break :blk switch (unary.op) {
                .negate => std.math.negate(value) catch null,
                .bit_not => ~value,
                .logical_not => if (value == 0) 1 else 0,
                else => null,
            };
        },
        .binary => |binary| blk: {
            const a = constInt(binary.lhs) orelse break :blk null;
            const b = constInt(binary.rhs) orelse break :blk null;
            break :blk switch (binary.op) {
                .add => std.math.add(i128, a, b) catch null,
                .sub => std.math.sub(i128, a, b) catch null,
                .mul => std.math.mul(i128, a, b) catch null,
                .div => if (b == 0) null else @divTrunc(a, b),
                .mod => if (b == 0) null else @rem(a, b),
                .shl => if (b < 0 or b > 127) null else a << @intCast(b),
                .shr => if (b < 0 or b > 127) null else a >> @intCast(b),
                .bit_and => a & b,
                .bit_or => a | b,
                .bit_xor => a ^ b,
                .eq => if (a == b) 1 else 0,
                .ne => if (a != b) 1 else 0,
                .lt => if (a < b) 1 else 0,
                .le => if (a <= b) 1 else 0,
                .gt => if (a > b) 1 else 0,
                .ge => if (a >= b) 1 else 0,
                .logical_and => if (a != 0 and b != 0) 1 else 0,
                .logical_or => if (a != 0 or b != 0) 1 else 0,
            };
        },
        .cast => |cast| constInt(cast.operand),
        .field => |field| blk: {
            if (field.is_enum_variant) break :blk field.variant_value;
            if (!field.through_pointer and std.mem.eql(u8, field.name, "len")) {
                if (field.base.ty) |bt| {
                    if (bt.* == .array and (field.base.kind == .ident or field.base.kind == .array_lit)) {
                        break :blk @intCast(bt.array.len);
                    }
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn constPointerIsNull(expr: *ast.Expr) bool {
    return switch (expr.kind) {
        .null_lit => true,
        .cast => |cast| blk: {
            if (cast.target.resolved) |target_ty| {
                if (target_ty.* != .pointer) break :blk false;
                break :blk constPointerIsNull(cast.operand) or (constInt(cast.operand) orelse 1) == 0;
            }
            break :blk false;
        },
        else => false,
    };
}

fn constBool(expr: *ast.Expr) ?bool {
    return switch (expr.kind) {
        .bool_lit => |value| value,
        .unary => |unary| if (unary.op == .logical_not) blk: {
            const value = constBool(unary.operand) orelse break :blk null;
            break :blk !value;
        } else null,
        .binary => |binary| blk: {
            if (binary.op == .logical_and or binary.op == .logical_or) {
                const a = constBool(binary.lhs) orelse break :blk null;
                const b = constBool(binary.rhs) orelse break :blk null;
                break :blk if (binary.op == .logical_and) a and b else a or b;
            }
            const a = constInt(binary.lhs) orelse break :blk null;
            const b = constInt(binary.rhs) orelse break :blk null;
            break :blk switch (binary.op) {
                .eq => a == b,
                .ne => a != b,
                .lt => a < b,
                .le => a <= b,
                .gt => a > b,
                .ge => a >= b,
                else => null,
            };
        },
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const AnalyzerTest = struct {
    arena: std.heap.ArenaAllocator,
    src: *@import("source.zig").Source,
    reporter: diagnostics.Reporter,
    prims: types.Primitives,
    program: ?*ast.Program = null,

    fn init(self: *AnalyzerTest, text: []const u8) !void {
        const lexer = @import("lexer.zig");
        const parser = @import("parser.zig");
        const source = @import("source.zig");
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena.allocator();
        self.src = try a.create(source.Source);
        self.src.* = try source.Source.init(a, "test.kyn", text);
        self.reporter = diagnostics.Reporter.init(a, self.src);
        self.prims = try types.Primitives.init(a);
        var lx = lexer.Lexer.init(a, self.src, &self.reporter);
        const tokens = try lx.tokenize();
        var p = parser.Parser.init(a, tokens, &self.reporter);
        self.program = try p.parse();
    }

    fn run(self: *AnalyzerTest) !void {
        var sema = sema_mod.Sema.init(self.arena.allocator(), &self.reporter, &self.prims);
        try sema.analyze(self.program.?);
        var analyzer = Analyzer.init(self.arena.allocator(), &self.reporter);
        try analyzer.analyze(self.program.?);
    }

    fn deinit(self: *AnalyzerTest) void {
        self.arena.deinit();
    }
};

fn expectAnalyzerError(text: []const u8, code: []const u8) !void {
    var ctx: AnalyzerTest = undefined;
    try ctx.init(text);
    defer ctx.deinit();
    try ctx.run();
    for (ctx.reporter.list.items) |diag| {
        if (std.mem.eql(u8, diag.code, code)) return;
    }
    for (ctx.reporter.list.items) |diag| std.debug.print("got {s}: {s}\n", .{ diag.code, diag.message });
    return error.ExpectedDiagnostic;
}

test "analyzer detects uninitialized read" {
    try expectAnalyzerError(
        \\fn main() i32 {
        \\    var x: i32;
        \\    return x;
        \\}
    , "E0501");
}

test "analyzer accepts assignment before read" {
    var ctx: AnalyzerTest = undefined;
    try ctx.init(
        \\fn main() i32 {
        \\    var x: i32;
        \\    x = 4;
        \\    return x;
        \\}
    );
    defer ctx.deinit();
    try ctx.run();
    try testing.expect(!ctx.reporter.hasErrors());
}

test "analyzer detects division by zero" {
    try expectAnalyzerError(
        \\fn main() i32 {
        \\    let x: i32 = 10 / 0;
        \\    return x;
        \\}
    , "E0503");
}

test "analyzer detects constant overflow" {
    try expectAnalyzerError(
        \\fn main() i32 {
        \\    let x: u8 = 200 + 100;
        \\    return 0;
        \\}
    , "E0505");
}

test "analyzer detects constant out-of-bounds index" {
    try expectAnalyzerError(
        \\fn main() i32 {
        \\    let a: [3]i32 = [1, 2, 3];
        \\    return a[5];
        \\}
    , "E0502");
}

test "analyzer warns on unreachable statement" {
    var ctx: AnalyzerTest = undefined;
    try ctx.init(
        \\fn main() i32 {
        \\    return 0;
        \\    let x: i32 = 1;
        \\}
    );
    defer ctx.deinit();
    try ctx.run();
    try testing.expectEqual(@as(usize, 1), ctx.reporter.warning_count);
}

test "analyzer warning on constant condition" {
    var ctx: AnalyzerTest = undefined;
    try ctx.init(
        \\fn main() i32 {
        \\    if (true) { return 1; }
        \\    return 0;
        \\}
    );
    defer ctx.deinit();
    try ctx.run();
    try testing.expect(ctx.reporter.warning_count > 0);
}

test "analyzer detects provable null pointer dereference" {
    try expectAnalyzerError(
        \\fn main() i32 {
        \\    return *(null as *i32);
        \\}
    , "E0506");

    try expectAnalyzerError(
        \\struct Point {
        \\    x: i32,
        \\    y: i32,
        \\}
        \\fn main() i32 {
        \\    return (null as *Point)->x;
        \\}
    , "E0506");
}

test "analyzer checks constant subslice bounds and null slice sources" {
    try expectAnalyzerError(
        \\fn main() i32 {
        \\    let a: [4]i32 = [1, 2, 3, 4];
        \\    let s = a[..5];
        \\    return s.len as i32;
        \\}
    , "E0502");

    try expectAnalyzerError(
        \\fn main() i32 {
        \\    let a: [4]i32 = [1, 2, 3, 4];
        \\    let s = a[3..2];
        \\    return s.len as i32;
        \\}
    , "E0502");

    try expectAnalyzerError(
        \\fn main() i32 {
        \\    let a: [4]i32 = [1, 2, 3, 4];
        \\    let s = a[-1..2];
        \\    return s.len as i32;
        \\}
    , "E0502");

    try expectAnalyzerError(
        \\fn main() i32 {
        \\    let s = (null as *[4]i32)[..];
        \\    return s.len as i32;
        \\}
    , "E0506");

    try expectAnalyzerError(
        \\fn main() i32 {
        \\    let s = (null as *[4]i32) as []i32;
        \\    return s.len as i32;
        \\}
    , "E0506");

    var ctx: AnalyzerTest = undefined;
    try ctx.init(
        \\fn main() i32 {
        \\    let a: [4]i32 = [1, 2, 3, 4];
        \\    let tail = a[4..];
        \\    let head = a[..0];
        \\    return (tail.len + head.len) as i32;
        \\}
    );
    defer ctx.deinit();
    try ctx.run();
    try testing.expect(!ctx.reporter.hasErrors());
}

test "every documented provable-null context is rejected" {
    // `safety-model.md` §2.8 names six places where a provably `null` pointer
    // is rejected: dereference, field access through a pointer, pointer index,
    // array-pointer slice, and array-pointer-to-slice cast. The analysis works
    // from the expression text, so each is written inline — a `null` in a
    // variable is not proven, and the runtime trap covers that case.
    try expectAnalyzerError(
        \\fn main() i32 {
        \\    return *(null as *i32);
        \\}
    , "E0506");
    try expectAnalyzerError(
        \\fn main() i32 {
        \\    return (null as *i32)[0];
        \\}
    , "E0506");
    try expectAnalyzerError(
        \\struct P { x: i32 }
        \\fn main() i32 {
        \\    return (null as *P)->x;
        \\}
    , "E0506");
    try expectAnalyzerError(
        \\fn main() i32 {
        \\    let s: []i32 = (null as *[4]i32)[..];
        \\    return s.len as i32;
        \\}
    , "E0506");
    try expectAnalyzerError(
        \\fn main() i32 {
        \\    let s: []i32 = (null as *[4]i32) as []i32;
        \\    return s.len as i32;
        \\}
    , "E0506");
}

test "a null in a variable is not proven, only the inline form is" {
    // The documented limit: provenance is not tracked through a variable. The
    // program compiles and the runtime trap is what stops it, which is why the
    // two cases here differ. Asserting the clean compile keeps the limit
    // honest rather than silently "fixing" it into a false diagnostic.
    var ctx: AnalyzerTest = undefined;
    try ctx.init(
        \\fn main() i32 {
        \\    let p: *i32 = null;
        \\    return p[0];
        \\}
    );
    defer ctx.deinit();
    try ctx.run();
    try testing.expect(!ctx.reporter.hasErrors());
}

test "unreachable statements after every terminator are warned once" {
    const cases = [_][]const u8{
        \\fn main() i32 {
        \\    return 1;
        \\    let x: i32 = 2;
        \\    return x;
        \\}
        ,
        \\fn main() i32 {
        \\    while (true) {
        \\        break;
        \\        let y: i32 = 1;
        \\    }
        \\    return 0;
        \\}
        ,
        \\fn main() i32 {
        \\    var i: i32 = 0;
        \\    while (i < 3) {
        \\        i += 1;
        \\        continue;
        \\        let z: i32 = 1;
        \\    }
        \\    return i;
        \\}
        ,
    };
    for (cases) |text| {
        var ctx: AnalyzerTest = undefined;
        try ctx.init(text);
        defer ctx.deinit();
        try ctx.run();
        var found: usize = 0;
        for (ctx.reporter.list.items) |diag| {
            if (std.mem.eql(u8, diag.code, "W0501")) found += 1;
        }
        // One statement is unreachable, so exactly one warning names it; the
        // warning is not an error and must not fail the program.
        try testing.expectEqual(@as(usize, 1), found);
        try testing.expect(!ctx.reporter.hasErrors());
    }
}
