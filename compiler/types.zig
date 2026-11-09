//! Kyn's static type representation.
//!
//! Types are allocated in the compilation arena and compared structurally.
//! Primitive types are singletons created once per compilation.

const std = @import("std");

pub const IntInfo = struct {
    bits: u16,
    signed: bool,

    pub fn name(self: IntInfo) []const u8 {
        return if (self.signed)
            switch (self.bits) {
                8 => "i8",
                16 => "i16",
                32 => "i32",
                64 => "i64",
                128 => "i128",
                else => "iN",
            }
        else switch (self.bits) {
            8 => "u8",
            16 => "u16",
            32 => "u32",
            64 => "u64",
            128 => "u128",
            else => "uN",
        };
    }

    pub fn min(self: IntInfo) i128 {
        if (!self.signed) return 0;
        return -(@as(i128, 1) << @intCast(self.bits - 1));
    }

    pub fn max(self: IntInfo) i128 {
        if (!self.signed) return @intCast((@as(i128, 1) << @intCast(self.bits)) - 1);
        return (@as(i128, 1) << @intCast(self.bits - 1)) - 1;
    }
};

pub const PointerInfo = struct {
    elem: *Type,
    is_const: bool,
};

pub const ArrayInfo = struct {
    elem: *Type,
    len: usize,
};

pub const Field = struct {
    name: []const u8,
    ty: *Type,
    index: u32,
};

pub const SliceInfo = struct {
    elem: *Type,
    is_const: bool,
};

pub const StructInfo = struct {
    name: []const u8,
    owner_module_id: u32 = 0,
    is_public: bool = true,
    fields: []Field = &.{},
    /// Set once the declaration has been fully checked, to reject recursion by value.
    complete: bool = false,
    /// True while field types are being resolved.
    resolving: bool = false,
};

pub const Variant = struct {
    name: []const u8,
    value: i128,
};

pub const EnumInfo = struct {
    name: []const u8,
    owner_module_id: u32 = 0,
    is_public: bool = true,
    backing: *Type,
    variants: []Variant = &.{},
    complete: bool = false,
};

pub const FnInfo = struct {
    params: []*Type,
    ret: *Type,
};

pub const Type = union(enum) {
    invalid,
    void,
    bool,
    char,
    int: IntInfo,
    float: u16,
    pointer: PointerInfo,
    array: ArrayInfo,
    slice: SliceInfo,
    struct_type: *StructInfo,
    enum_type: *EnumInfo,
    fn_type: *FnInfo,
    /// Type of an integer literal before it is constrained by context.
    comptime_int,
    comptime_float,
    null_type,

    pub fn isInteger(self: *const Type) bool {
        return switch (self.*) {
            .int, .char, .comptime_int => true,
            else => false,
        };
    }

    pub fn isFloat(self: *const Type) bool {
        return self.* == .float or self.* == .comptime_float;
    }

    pub fn isNumeric(self: *const Type) bool {
        return self.isInteger() or self.isFloat();
    }

    pub fn isPointer(self: *const Type) bool {
        return self.* == .pointer;
    }

    pub fn isAggregate(self: *const Type) bool {
        return switch (self.*) {
            .struct_type, .array, .slice => true,
            else => false,
        };
    }

    pub fn intInfo(self: *const Type) IntInfo {
        return switch (self.*) {
            .int => |info| info,
            .char => .{ .bits = 32, .signed = false },
            else => .{ .bits = 0, .signed = false },
        };
    }

    pub fn eql(a: *const Type, b: *const Type) bool {
        if (a == b) return true;
        return switch (a.*) {
            .invalid => b.* == .invalid,
            .void => b.* == .void,
            .bool => b.* == .bool,
            .char => b.* == .char,
            .comptime_int => b.* == .comptime_int,
            .comptime_float => b.* == .comptime_float,
            .null_type => b.* == .null_type,
            .int => |ai| switch (b.*) {
                .int => |bi| ai.bits == bi.bits and ai.signed == bi.signed,
                else => false,
            },
            .float => |abits| switch (b.*) {
                .float => |bbits| abits == bbits,
                else => false,
            },
            .pointer => |ap| switch (b.*) {
                .pointer => |bp| ap.is_const == bp.is_const and eql(ap.elem, bp.elem),
                else => false,
            },
            .array => |aa| switch (b.*) {
                .array => |ba| aa.len == ba.len and eql(aa.elem, ba.elem),
                else => false,
            },
            .slice => |as| switch (b.*) {
                .slice => |bs| as.is_const == bs.is_const and eql(as.elem, bs.elem),
                else => false,
            },
            .struct_type => |as| switch (b.*) {
                .struct_type => |bs| as == bs,
                else => false,
            },
            .enum_type => |ae| switch (b.*) {
                .enum_type => |be| ae == be,
                else => false,
            },
            .fn_type => |af| switch (b.*) {
                .fn_type => |bf| blk: {
                    if (af.params.len != bf.params.len) break :blk false;
                    if (!eql(af.ret, bf.ret)) break :blk false;
                    for (af.params, bf.params) |ap, bp| {
                        if (!eql(ap, bp)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
        };
    }

    pub fn displayName(self: *const Type, buffer: []u8) []const u8 {
        return switch (self.*) {
            .invalid => "invalid",
            .void => "void",
            .bool => "bool",
            .char => "char",
            .int => |info| info.name(),
            .float => |bits| if (bits == 32) "f32" else "f64",
            .pointer => |p| std.fmt.bufPrint(buffer, "*{s}{s}", .{
                if (p.is_const) "const " else "",
                p.elem.displayName(buffer[@min(buffer.len, 8)..]),
            }) catch "*?",
            .array => |a| std.fmt.bufPrint(buffer, "[{d}]?", .{a.len}) catch "[?]",
            .slice => "slice",
            .struct_type => |s| s.name,
            .enum_type => |e| e.name,
            .fn_type => "fn",
            .comptime_int => "comptime_int",
            .comptime_float => "comptime_float",
            .null_type => "null",
        };
    }
};

/// Allocates and interns nothing: callers create types through these helpers.
pub fn makePointer(allocator: std.mem.Allocator, elem: *Type, is_const: bool) !*Type {
    const ty = try allocator.create(Type);
    ty.* = .{ .pointer = .{ .elem = elem, .is_const = is_const } };
    return ty;
}

pub fn makeArray(allocator: std.mem.Allocator, elem: *Type, len: usize) !*Type {
    const ty = try allocator.create(Type);
    ty.* = .{ .array = .{ .elem = elem, .len = len } };
    return ty;
}

pub fn makeSlice(allocator: std.mem.Allocator, elem: *Type, is_const: bool) !*Type {
    const ty = try allocator.create(Type);
    ty.* = .{ .slice = .{ .elem = elem, .is_const = is_const } };
    return ty;
}

pub fn makeFn(allocator: std.mem.Allocator, params: []*Type, ret: *Type) !*Type {
    const info = try allocator.create(FnInfo);
    info.* = .{ .params = params, .ret = ret };
    const ty = try allocator.create(Type);
    ty.* = .{ .fn_type = info };
    return ty;
}

pub const Primitives = struct {
    void: *Type,
    bool: *Type,
    char: *Type,
    i8: *Type,
    i16: *Type,
    i32: *Type,
    i64: *Type,
    i128: *Type,
    u8: *Type,
    u16: *Type,
    u32: *Type,
    u64: *Type,
    u128: *Type,
    f32: *Type,
    f64: *Type,
    usize: *Type,
    isize: *Type,
    comptime_int: *Type,
    comptime_float: *Type,
    null_type: *Type,
    invalid: *Type,

    pub fn init(allocator: std.mem.Allocator) !Primitives {
        return .{
            .void = try simple(allocator, .void),
            .bool = try simple(allocator, .bool),
            .char = try simple(allocator, .char),
            .i8 = try integer(allocator, 8, true),
            .i16 = try integer(allocator, 16, true),
            .i32 = try integer(allocator, 32, true),
            .i64 = try integer(allocator, 64, true),
            .i128 = try integer(allocator, 128, true),
            .u8 = try integer(allocator, 8, false),
            .u16 = try integer(allocator, 16, false),
            .u32 = try integer(allocator, 32, false),
            .u64 = try integer(allocator, 64, false),
            .u128 = try integer(allocator, 128, false),
            .f32 = try float(allocator, 32),
            .f64 = try float(allocator, 64),
            .usize = try integer(allocator, 64, false),
            .isize = try integer(allocator, 64, true),
            .comptime_int = try simple(allocator, .comptime_int),
            .comptime_float = try simple(allocator, .comptime_float),
            .null_type = try simple(allocator, .null_type),
            .invalid = try simple(allocator, .invalid),
        };
    }
};

fn simple(allocator: std.mem.Allocator, value: Type) !*Type {
    const ty = try allocator.create(Type);
    ty.* = value;
    return ty;
}

fn integer(allocator: std.mem.Allocator, bits: u16, signed: bool) !*Type {
    const ty = try allocator.create(Type);
    ty.* = .{ .int = .{ .bits = bits, .signed = signed } };
    return ty;
}

fn float(allocator: std.mem.Allocator, bits: u16) !*Type {
    const ty = try allocator.create(Type);
    ty.* = .{ .float = bits };
    return ty;
}

test "primitive type identity and equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Primitives.init(a);
    try std.testing.expect(Type.eql(p.i32, p.i32));
    try std.testing.expect(!Type.eql(p.i32, p.u32));
    try std.testing.expect(p.i32.intInfo().signed);
    try std.testing.expectEqual(@as(i128, 2147483647), p.i32.intInfo().max());
    try std.testing.expectEqual(@as(i128, -2147483648), p.i32.intInfo().min());
}
