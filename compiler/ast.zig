//! Abstract syntax tree for Kyn.
//!
//! Expressions and statements are tagged structs: `span` and the resolved
//! `ty` live on the outer node, keeping semantic annotations simple and
//! uniform across all node kinds.

const source = @import("source.zig");
const types = @import("types.zig");
const symbol = @import("symbol.zig");

pub const Span = source.Span;
pub const Type = types.Type;

pub const Program = struct {
    decls: []*Decl,
};

pub const Decl = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        var_decl: *VarDecl,
        fn_decl: *FnDecl,
        struct_decl: *StructDecl,
        enum_decl: *EnumDecl,
    };
};

pub const VarDecl = struct {
    span: Span,
    name: []const u8,
    mutable: bool,
    is_global: bool,
    ty_expr: ?*TypeExpr,
    init: ?*Expr,
    ty: ?*Type = null,
    sym: ?*symbol.Symbol = null,
};

pub const Param = struct {
    span: Span,
    name: []const u8,
    ty_expr: *TypeExpr,
    ty: ?*Type = null,
    sym: ?*symbol.Symbol = null,
};

pub const FnDecl = struct {
    span: Span,
    name: []const u8,
    params: []Param,
    ret_expr: ?*TypeExpr,
    body: ?*Block,
    is_extern: bool,
    is_export: bool,
    ty: ?*Type = null,
    sym: ?*symbol.Symbol = null,
};

pub const StructField = struct {
    span: Span,
    name: []const u8,
    ty_expr: *TypeExpr,
    ty: ?*Type = null,
};

pub const StructDecl = struct {
    span: Span,
    name: []const u8,
    fields: []StructField,
    ty: ?*Type = null,
    sym: ?*symbol.Symbol = null,
};

pub const EnumVariantDecl = struct {
    span: Span,
    name: []const u8,
    value_expr: ?*Expr,
    value: i128 = 0,
};

pub const EnumDecl = struct {
    span: Span,
    name: []const u8,
    backing_expr: ?*TypeExpr,
    variants: []EnumVariantDecl,
    ty: ?*Type = null,
    sym: ?*symbol.Symbol = null,
};

pub const TypeExpr = struct {
    span: Span,
    resolved: ?*Type = null,
    kind: Kind,

    pub const Kind = union(enum) {
        name: []const u8,
        pointer: Pointer,
        array: Array,
        slice: Slice,

        pub const Pointer = struct {
            elem: *TypeExpr,
            is_const: bool,
        };

        pub const Array = struct {
            elem: *TypeExpr,
            /// Null for an inferred-length array; currently only used in types.
            len: ?*Expr,
        };

        pub const Slice = struct {
            elem: *TypeExpr,
            is_const: bool,
        };
    };
};

pub const Block = struct {
    span: Span,
    stmts: []*Stmt,
};

pub const Stmt = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        expr: *Expr,
        var_decl: *VarDecl,
        block: *Block,
        if_stmt: *IfStmt,
        while_stmt: *WhileStmt,
        return_stmt: *ReturnStmt,
        break_stmt: void,
        continue_stmt: void,
        empty: void,
    };

    pub const IfStmt = struct {
        cond: *Expr,
        then_branch: *Block,
        else_branch: ?*Stmt,
    };

    pub const WhileStmt = struct {
        cond: *Expr,
        body: *Block,
    };

    pub const ReturnStmt = struct {
        value: ?*Expr,
    };
};

pub const UnaryOp = enum {
    negate,
    logical_not,
    bit_not,
    address_of,
    dereference,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    shl,
    shr,
    bit_and,
    bit_or,
    bit_xor,
    logical_and,
    logical_or,
};

pub const AssignOp = enum {
    assign,
    add,
    sub,
    mul,
    div,
    mod,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
};

pub const Expr = struct {
    span: Span,
    ty: ?*Type = null,
    kind: Kind,

    pub const Kind = union(enum) {
        int_lit: IntLit,
        float_lit: FloatLit,
        bool_lit: bool,
        char_lit: u32,
        string_lit: StringLit,
        null_lit: void,
        ident: Ident,
        unary: Unary,
        binary: Binary,
        assign: Assign,
        call: Call,
        cast: Cast,
        field: Field,
        index: Index,
        struct_init: StructInit,
        array_lit: []*Expr,

        pub const IntLit = struct {
            value: u128,
        };

        pub const FloatLit = struct {
            value: f64,
        };

        pub const StringLit = struct {
            bytes: []const u8,
        };

        pub const Ident = struct {
            name: []const u8,
            sym: ?*symbol.Symbol = null,
        };

        pub const Unary = struct {
            op: UnaryOp,
            operand: *Expr,
        };

        pub const Binary = struct {
            op: BinaryOp,
            lhs: *Expr,
            rhs: *Expr,
        };

        pub const Assign = struct {
            op: AssignOp,
            target: *Expr,
            value: *Expr,
        };

        pub const Call = struct {
            callee: *Expr,
            args: []*Expr,
        };

        pub const Cast = struct {
            operand: *Expr,
            target: *TypeExpr,
        };

        pub const Field = struct {
            base: *Expr,
            name: []const u8,
            /// Resolved struct field index, or enum variant value.
            field_index: u32 = 0,
            is_enum_variant: bool = false,
            variant_value: i128 = 0,
            through_pointer: bool = false,
        };

        pub const Index = struct {
            base: *Expr,
            index: *Expr,
        };

        pub const StructInit = struct {
            type_expr: *TypeExpr,
            fields: []InitField,
        };

        pub const InitField = struct {
            span: Span,
            name: []const u8,
            value: *Expr,
            index: u32 = 0,
        };
    };
};

pub fn exprSpan(expr: *const Expr) Span {
    return expr.span;
}

pub fn stmtSpan(stmt: *const Stmt) Span {
    return stmt.span;
}
