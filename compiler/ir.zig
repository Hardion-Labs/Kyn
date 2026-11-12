//! Kyn semantic IR.
//!
//! The IR is a typed, control-flow-graph representation lowered from the
//! checked AST. It is deliberately simple:
//!   - locals are stack slots (LLVM's optimizers promote them);
//!   - temporaries are SSA values;
//!   - blocks are explicit and every block is terminated by a branch, return
//!     or unreachable instruction.
//!
//! The backend consumes this IR without depending on AST details.

const std = @import("std");
const types = @import("types.zig");

pub const Type = types.Type;

/// Runtime checks promised by the selected compiler profile. Profiles currently
/// keep every implemented check enabled; policy is explicit so future changes
/// cannot silently alter language behavior during lowering.
pub const RuntimeCheckPolicy = struct {
    bounds: bool = true,
    integer_overflow: bool = true,
    division: bool = true,
    shifts: bool = true,
    null_dereference: bool = true,

    pub const all: RuntimeCheckPolicy = .{};
};

pub const Value = union(enum) {
    none,
    int: i128,
    float: f64,
    boolean: bool,
    null_ptr,
    local: u32,
    global: u32,
    string: u32,
    reg: u32,
    param: u32,
    /// The address of a function, either a declared one or an arbitrary symbol
    /// name. Function values are plain pointers at the ABI level, so this is
    /// the only new value kind a first-class function needs.
    func: []const u8,
};

pub const Linkage = enum {
    internal,
    external,
    declaration,
};

pub const Global = struct {
    name: []const u8,
    ty: *Type,
    init: Constant,
    mutable: bool,
};

pub const StringConst = struct {
    bytes: []const u8,
    index: u32,
};

pub const Param = struct {
    local: u32,
    ty: *Type,
    byval_type: ?*types.StructInfo = null,
};

pub const Local = struct {
    id: u32,
    name: []const u8,
    ty: *Type,
    padding: u16 = 0,
};

pub const UnOp = enum {
    negate,
    logical_not,
    bit_not,
};

pub const BinaryOp = enum {
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

pub const CmpOp = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
};

pub const CastKind = enum {
    trunc,
    zext,
    sext,
    fptrunc,
    fpext,
    sitofp,
    uitofp,
    fptosi,
    fptoui,
    ptrtoint,
    inttoptr,
    bitcast,
    int_to_bool,
    bool_to_int,
};

pub const Inst = union(enum) {
    checked_binary: struct {
        dst: u32,
        overflow: u32,
        op: BinaryOp,
        ty: *Type,
        lhs: Value,
        rhs: Value,
    },
    binary: struct {
        dst: u32,
        op: BinaryOp,
        ty: *Type,
        lhs: Value,
        rhs: Value,
    },
    unary: struct {
        dst: u32,
        op: UnOp,
        ty: *Type,
        operand: Value,
    },
    icmp: struct {
        dst: u32,
        op: CmpOp,
        ty: *Type,
        lhs: Value,
        rhs: Value,
    },
    fcmp: struct {
        dst: u32,
        op: CmpOp,
        ty: *Type,
        lhs: Value,
        rhs: Value,
    },
    cast: struct {
        dst: u32,
        kind: CastKind,
        from: *Type,
        to: *Type,
        value: Value,
    },
    byte_offset: struct {
        dst: u32,
        base: Value,
        offset: u64,
    },
    copy_bytes: struct {
        destination: Value,
        source: Value,
        length: u32,
    },
    call: struct {
        dst: ?u32,
        name: []const u8,
        /// Set for an indirect call: the callee is this value, not `name`. The
        /// target carries its own signature, so the emitted call spells out the
        /// return and parameter types instead of relying on a declaration.
        callee: ?Value = null,
        args: []Value,
        arg_types: []*Type,
        ret: *Type,
        sret: bool = false,
        sret_type: ?*types.StructInfo = null,
        byval_types: []const ?*types.StructInfo = &.{},
    },
    slice_field_ptr: struct {
        dst: u32,
        base: Value,
        field: u32,
    },
    field_ptr: struct {
        dst: u32,
        base: Value,
        struct_ty: *types.StructInfo,
        field: u32,
    },
    elem_ptr: struct {
        dst: u32,
        base: Value,
        container: *Type,
        index: Value,
        index_ty: *Type,
        is_array: bool,
    },
    load: struct {
        dst: u32,
        ptr: Value,
        ty: *Type,
    },
    store: struct {
        ptr: Value,
        value: Value,
        ty: *Type,
    },
    br: struct {
        target: u32,
    },
    cbr: struct {
        cond: Value,
        then_block: u32,
        else_block: u32,
    },
    ret: struct {
        value: ?Value,
    },
    trap_: void,
    unreachable_: void,
};

pub const Block = struct {
    id: u32,
    insts: std.ArrayList(Inst) = .empty,
    terminated: bool = false,
};

pub const Function = struct {
    name: []const u8,
    params: []Param,
    ret: *Type,
    linkage: Linkage,
    /// True for a C declaration ending in `...`. Only a declaration can be
    /// variadic, so a definition never carries it.
    variadic: bool = false,
    sret: bool = false,
    sret_type: ?*types.StructInfo = null,
    byval_params: []bool = &.{},
    locals: std.ArrayList(Local) = .empty,
    blocks: std.ArrayList(*Block) = .empty,
    current: usize = 0,

    pub fn addLocal(self: *Function, allocator: std.mem.Allocator, id: u32, name: []const u8, ty: *Type, padding: u16) !void {
        for (self.locals.items) |local| {
            if (local.id == id) return;
        }
        try self.locals.append(allocator, .{ .id = id, .name = name, .ty = ty, .padding = padding });
    }

    pub fn block(self: *Function, id: u32) *Block {
        return self.blocks.items[id];
    }
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    functions: std.ArrayList(*Function) = .empty,
    globals: std.ArrayList(Global) = .empty,
    strings: std.ArrayList(StringConst) = .empty,
    structs: std.ArrayList(*types.StructInfo) = .empty,
    enums: std.ArrayList(*types.EnumInfo) = .empty,
    next_temp: u32 = 1,
    next_label: u32 = 1,
    ephemeral_id: u32 = 100_000,
    reg_types: std.AutoHashMap(u32, *Type),

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{
            .allocator = allocator,
            .reg_types = std.AutoHashMap(u32, *Type).init(allocator),
        };
    }

    pub fn temp(self: *Module) u32 {
        const id = self.next_temp;
        self.next_temp += 1;
        return id;
    }

    pub fn ephemeral(self: *Module) u32 {
        const id = self.ephemeral_id;
        self.ephemeral_id += 1;
        return id;
    }

    pub fn label(self: *Module) u32 {
        const id = self.next_label;
        self.next_label += 1;
        return id;
    }

    pub fn setRegType(self: *Module, id: u32, ty: *Type) !void {
        try self.reg_types.put(id, ty);
    }

    pub fn regType(self: *const Module, id: u32) ?*Type {
        return self.reg_types.get(id);
    }

    pub fn addString(self: *Module, bytes: []const u8) !u32 {
        for (self.strings.items) |string| {
            if (std.mem.eql(u8, string.bytes, bytes)) return string.index;
        }
        const index: u32 = @intCast(self.strings.items.len);
        try self.strings.append(self.allocator, .{ .bytes = bytes, .index = index });
        return index;
    }

    pub fn addStruct(self: *Module, info: *types.StructInfo) !void {
        for (self.structs.items) |existing| {
            if (existing == info) return;
        }
        try self.structs.append(self.allocator, info);
    }

    pub fn addEnum(self: *Module, info: *types.EnumInfo) !void {
        for (self.enums.items) |existing| {
            if (existing == info) return;
        }
        try self.enums.append(self.allocator, info);
    }
};

const testing = std.testing;

test "module interns constant strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var module = Module.init(arena.allocator());

    const first = try module.addString("hello");
    const repeated = try module.addString("hello");
    const second = try module.addString("world");

    try testing.expectEqual(first, repeated);
    try testing.expectEqual(first + 1, second);
    try testing.expectEqual(@as(usize, 2), module.strings.items.len);
}

test "module deduplicates struct and enum metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = Module.init(a);
    const prims = try types.Primitives.init(a);

    var struct_info: types.StructInfo = .{ .name = "Point", .fields = &.{}, .complete = true, .resolving = false };
    try module.addStruct(&struct_info);
    try module.addStruct(&struct_info);
    try testing.expectEqual(@as(usize, 1), module.structs.items.len);

    var enum_info: types.EnumInfo = .{
        .name = "Color",
        .backing = prims.u8,
        .variants = &.{},
        .complete = true,
    };
    try module.addEnum(&enum_info);
    try module.addEnum(&enum_info);
    try testing.expectEqual(@as(usize, 1), module.enums.items.len);
}

test "module assigns monotonically increasing temporaries and labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = Module.init(a);
    const prims = try types.Primitives.init(a);

    const reg = module.temp();
    try testing.expectEqual(@as(u32, 1), reg);
    try testing.expectEqual(@as(u32, 2), module.temp());

    try module.setRegType(reg, prims.i32);
    const stored = module.regType(reg).?;
    try testing.expect(stored == prims.i32);
    try testing.expect(module.regType(reg + 100) == null);

    try testing.expectEqual(@as(u32, 1), module.label());
    try testing.expectEqual(@as(u32, 2), module.label());
}

pub const Constant = union(enum) {
    scalar: Value,
    array: []Constant,
    struct_fields: []Constant,
};
