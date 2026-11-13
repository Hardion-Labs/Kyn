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
    imports: []ImportDecl = &.{},
};

pub const ImportDecl = struct {
    span: Span,
    path: []const u8,
    alias: ?[]const u8 = null,
    target_module_id: u32 = 0,
};

pub const Decl = struct {
    span: Span,
    is_public: bool = true,
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
    /// True for `export var`/`export let`/`export const`: the variable is
    /// emitted under its source name so a C object can link against it.
    is_export: bool = false,
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
    /// True for an `extern fn name(fixed: T, ...) R;` declaration, whose extra
    /// arguments are supplied positionally at each call and default-promoted.
    /// Only a C boundary can be variadic, so the flag lives on the declaration
    /// rather than in the function type.
    is_variadic: bool = false,
    ret_expr: ?*TypeExpr,
    body: ?*Block,
    is_extern: bool,
    is_export: bool,
    ty: ?*Type = null,
    sym: ?*symbol.Symbol = null,
};

pub const StructField = struct {
    span: Span,
    /// Empty for an anonymous member, whose own fields are promoted into the
    /// enclosing aggregate's scope.
    name: []const u8,
    ty_expr: *TypeExpr,
    ty: ?*Type = null,
};

pub const StructDecl = struct {
    span: Span,
    name: []const u8,
    fields: []StructField,
    /// A `union`: every member starts at offset 0 and the size is the largest
    /// member's, so only one is live at a time. The program owns that choice;
    /// there is no tag.
    is_union: bool = false,
    /// A `packed struct`/`packed union`: no padding between members and an
    /// alignment of 1, which is what makes it cross the C ABI by memory.
    is_packed: bool = false,
    /// `align(N)`: the aggregate is at least `N`-aligned, and its size is rounded
    /// up to a multiple of it. Zero means absent. It never *lowers* an alignment,
    /// matching C's `aligned` attribute, and it wins over `packed` when the two
    /// disagree because the maximum of the two requirements is what both the
    /// measured layout and the emitted type use.
    explicit_align: u32 = 0,
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

    /// One parameter of a function type. A function *type* names no parameters,
    /// only their types, so this carries no name.
    pub const ParamType = struct {
        span: Span,
        ty_expr: *TypeExpr,
    };

    pub const Kind = union(enum) {
        name: []const u8,
        pointer: Pointer,
        array: Array,
        slice: Slice,
        /// `fn(i32, i32) i32` — the signature of a first-class function value.
        fn_type: FnType,
        /// An aggregate written inline where a type is expected, which is only an
        /// anonymous member: `struct { y: i32 }` inside another aggregate. Its
        /// declaration has an empty name and is not registered in any scope, so
        /// it can be reached only through the member it belongs to.
        inline_aggregate: *StructDecl,

        pub const FnType = struct {
            params: []ParamType,
            /// Null for a `void` return.
            ret: ?*TypeExpr,
        };

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
        slice: SliceAccess,
        struct_init: StructInit,
        array_lit: []*Expr,
        /// `va_arg()` — a builtin expression, not a call: there is no callee
        /// symbol, and its type is decided by the expected type.
        va_arg: VaArg,

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
            /// Filled by the analyzer when the callee is a variadic `extern`
            /// function, so the back end knows the tail arguments carry their
            /// promoted types rather than declared parameter types.
            is_variadic: bool = false,
            /// Per-argument type the call passes, taken from the declaration for
            /// a fixed parameter and from the C default promotions for a
            /// variadic one. Empty until the analyzer fills it. The back end
            /// converts each argument to this type, so the conversion is written
            /// once in the analyzer instead of being re-derived from the
            /// expression's own type on every emission path.
            arg_types: []*Type = &.{},
        };

        pub const Cast = struct {
            operand: *Expr,
            target: *TypeExpr,
        };

        /// `va_arg()` — retrieve the next argument a C caller passed to a
        /// variadic `export fn`. It carries no type of its own: the type comes
        /// from the expected type at the position where it is written, the same
        /// way an integer literal or a `null` takes its type from context.
        pub const VaArg = struct {
            /// Filled by the checker: the type the caller passed, which is what
            /// the retrieval instruction names.
            ty: ?*Type = null,
        };

        pub const Field = struct {
            base: *Expr,
            name: []const u8,
            /// Resolved struct field index, or enum variant value.
            field_index: u32 = 0,
            /// The chain of field indices to walk to reach the accessed field.
            /// One element for an ordinary field; more when the name was promoted
            /// out of one or more anonymous members. `field_index` is its last
            /// element, which is the field the access names.
            field_path: []const u32 = &.{},
            is_enum_variant: bool = false,
            variant_value: i128 = 0,
            through_pointer: bool = false,
            sym: ?*symbol.Symbol = null,
        };

        pub const Index = struct {
            base: *Expr,
            index: *Expr,
        };

        pub const SliceAccess = struct {
            base: *Expr,
            start: ?*Expr,
            end: ?*Expr,
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
            /// The chain of field indices the promoted name resolves through, so
            /// the emitter can build the nested value the anonymous member needs.
            field_path: []const u32 = &.{},
        };
    };
};

pub fn exprSpan(expr: *const Expr) Span {
    return expr.span;
}

pub fn stmtSpan(stmt: *const Stmt) Span {
    return stmt.span;
}
