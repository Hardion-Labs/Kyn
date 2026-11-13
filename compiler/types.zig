//! Kyn's static type representation.
//!
//! Types are allocated in the compilation arena and compared structurally.
//! Primitive types are singletons created once per compilation.

const std = @import("std");

pub const IntInfo = struct {
    bits: u16,
    signed: bool,

    /// A static name for the widths that have a keyword. `uN`/`iN` widths have
    /// no static spelling, so `nameAlloc` is the one to use when the name may
    /// reach a diagnostic; this stays for the callers that only want a label.
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

    /// The type's source spelling, for a diagnostic: `u8` for a keyword width and
    /// `u3`/`i7` for one that only exists through the width spelling.
    pub fn nameAlloc(self: IntInfo, allocator: std.mem.Allocator) []const u8 {
        if (self.bits == 8 or self.bits == 16 or self.bits == 32 or self.bits == 64 or self.bits == 128) {
            return self.name();
        }
        return std.fmt.allocPrint(allocator, "{c}{d}", .{ @as(u8, if (self.signed) 'i' else 'u'), self.bits }) catch self.name();
    }

    /// Smallest value of the type, as a signed 128-bit integer. Every type
    /// narrower than 128 bits fits, and an `i128` is exactly `i128`'s minimum,
    /// so this always has a representable answer.
    pub fn min(self: IntInfo) i128 {
        if (!self.signed) return 0;
        if (self.bits >= 128) return std.math.minInt(i128);
        return -(@as(i128, 1) << @intCast(self.bits - 1));
    }

    /// Largest value of the type, as an *unsigned* 128-bit integer: the width
    /// domain the literal checks compare against. A signed 128-bit maximum is
    /// not representable in `i128` arithmetic (`1 << 127` overflows), and a
    /// `u128` maximum is not representable at all, so widening the result type
    /// is what makes `i128`/`u128` bounds expressible rather than a special
    /// case per call site.
    pub fn max(self: IntInfo) u128 {
        if (self.bits >= 128) {
            return if (self.signed) std.math.maxInt(i128) else std.math.maxInt(u128);
        }
        const one: u128 = 1;
        if (!self.signed) return (one << @intCast(self.bits)) - 1;
        return (one << @intCast(self.bits - 1)) - 1;
    }

    /// True when `value` lies inside the type's range. The comparison runs in
    /// the unsigned domain past the lower bound so a `u128` maximum, which has
    /// no `i128` spelling, stays expressible.
    pub fn fits(self: IntInfo, value: i128) bool {
        if (value < 0) return value >= self.min();
        return self.fitsUnsigned(@intCast(value));
    }

    /// Whether a literal's magnitude, which can exceed `i128`'s maximum, lies
    /// inside the type's range. A value above `i128`'s maximum is only
    /// representable by an unsigned type, so it is compared in the unsigned
    /// domain rather than being rejected as unspeakable.
    pub fn fitsUnsigned(self: IntInfo, magnitude: u128) bool {
        return magnitude <= self.max();
    }

    /// Magnitude of the type's minimum, used to accept the most negative
    /// literal of a signed type (`-128` written as `128` with a unary minus).
    /// Computed by shifting rather than negating, because the minimum of the
    /// widest signed type has no positive counterpart in `i128`.
    pub fn minMagnitude(self: IntInfo) u128 {
        if (!self.signed) return 0;
        const one: u128 = 1;
        return one << @intCast(self.bits - 1);
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

/// Where a declared field lands in the emitted LLVM type. For an ordinary field
/// `emitted_index` is the field's own position and `bit_offset` is 0. For a
/// bitfield, several declarations share one emitted field — the storage unit —
/// so `emitted_index` names that shared unit and `bit_offset` is the field's
/// position inside it. This is deliberately *layout*, not a second type model:
/// the source still sees one field per declaration.
pub const AggregateLayoutValue = struct {
    size: u64 = 0,
    align_: u64 = 0,
};

pub const Placed = struct {
    /// Index of the field in the emitted LLVM struct.
    emitted_index: u32 = 0,
    /// The type of the emitted field: the storage unit for a bitfield, the
    /// field's own type otherwise.
    storage_ty: ?*Type = null,
    /// Bit position inside the storage unit. Zero for a non-bitfield.
    bit_offset: u32 = 0,
};

pub const SliceInfo = struct {
    elem: *Type,
    is_const: bool,
};

pub const StructInfo = struct {
    name: []const u8,
    /// A `union`: all members start at offset 0, the size is the largest
    /// member's and the alignment the largest member's, so the layout is the
    /// struct rule with "sum" replaced by "maximum".
    is_union: bool = false,
    /// A `packed struct`/`packed union`: members are not aligned and the
    /// aggregate's alignment is 1.
    is_packed: bool = false,
    /// `align(N)` on the declaration, or 0. It only ever *raises* the aggregate's
    /// alignment, and it wins over `packed` because the maximum of the two is what
    /// both the measured layout and the emitted type use. Recorded on the type so
    /// the emitter can annotate the definition and the allocas without repeating
    /// the computation.
    explicit_align: u32 = 0,
    /// Unique backend identifier; `name` remains the source-level spelling.
    llvm_name: []const u8 = "",
    owner_module_id: u32 = 0,
    is_public: bool = true,
    fields: []Field = &.{},
    /// Parallel to `fields`: where each one lands in the emitted type. Empty
    /// until the layout has run, which `resolveStruct` does once.
    placed: []Placed = &.{},
    /// `size`/`align_` as computed by the one layout walk. Stored on the type so
    /// that `aggregateLayoutGuess` can answer without re-walking (a re-walk would
    /// be a second implementation of the bit cursor) and so that a consumer
    /// cannot get a different answer from the one the emitter used.
    layout: AggregateLayoutValue = .{},
    /// The emitted LLVM struct's members, in order. A bitfield run collapses into
    /// one integer of its unit width, and any gap before a later unit becomes an
    /// explicit padding entry of that many bytes, so LLVM's own layout of the
    /// type reproduces the bit positions the source declares. A padding entry is
    /// an array of `u8` whose length is the gap.
    emitted: []*Type = &.{},
    /// Set once the declaration has been fully checked, to reject recursion by value.
    complete: bool = false,
    /// True while field types are being resolved.
    resolving: bool = false,
};

pub const Variant = struct {
    name: []const u8,
    value: i128,
    /// The type this variant carries, or null for a plain variant. A non-null
    /// payload makes the enum a tagged union whose value is a tag plus a union of
    /// every payload -- the representation measured against clang for
    /// `struct { T tag; union { ... } payload; }`.
    payload: ?*Type = null,
};

pub const EnumInfo = struct {
    name: []const u8,
    owner_module_id: u32 = 0,
    is_public: bool = true,
    backing: *Type,
    variants: []Variant = &.{},
    complete: bool = false,
    /// True when at least one variant carries a payload, which makes the value a
    /// tag plus a union rather than a bare integer. Recorded once at resolution
    /// so the layout rule is decided in one place and every consumer -- emitter,
    /// C ABI classifier, `==` rule -- reads the same flag.
    is_tagged: bool = false,
    /// The union of the payloads, laid out as the largest member's size and
    /// alignment. Null unless `is_tagged`; a tagged union with no payload at all
    /// still gets one, with no members and therefore size and alignment 0.
    payload_union: ?*StructInfo = null,
    /// The emitted value's type: a struct of exactly two members, tag then
    /// payload -- `{0}` the backing integer, `{1}` the payload union. Synthesised
    /// once at resolution so that every consumer (type spelling, GEP, the C ABI
    /// classifier, `sizeInBytes`, `aggregateLayoutGuess`) reuses the struct paths
    /// instead of each learning a second representation. Null unless `is_tagged`.
    value_ty: ?*Type = null,
};

pub const FnInfo = struct {
    params: []*Type,
    ret: *Type,
};

/// One slot of a two-register aggregate transport at the C ABI boundary.
/// `f32x2` is the SSE/SSEUP `<2 x float>` slot, which occupies an SSE
/// register and its continuation rather than a single scalar.
pub const AbiSlot = enum {
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    /// A pointer, which is never widened or narrowed by the classification.
    pointer,
    /// Two `float` values in one MMX-width SSE slot.
    f32x2,

    /// The slot's width in bits on `x86_64`.
    pub fn bits(self: AbiSlot) u16 {
        return switch (self) {
            .i8 => 8,
            .i16 => 16,
            .i32, .f32 => 32,
            .i64, .f64, .pointer, .f32x2 => 64,
        };
    }

    pub fn isFloat(self: AbiSlot) bool {
        return self == .f32 or self == .f64;
    }
};

/// The two registers a two-register aggregate travels in at the C ABI
/// boundary. The classification and the lowering share this value, so the
/// emitted transport type cannot drift from the boundary class.
pub const AbiPair = struct {
    first: AbiSlot,
    second: AbiSlot,
};

pub const Type = union(enum) {
    invalid,
    void,
    bool,
    char,
    int: IntInfo,
    float: u16,
    /// Backend-only transport types for System V aggregate coercions.
    abi_vec2_f32,
    abi_v2f32_f32,
    abi_v2f32_v2f32,
    abi_pair_f64,
    /// `{ <2 x float>, i32 }`, `{ <2 x float>, i64 }`, `{ i64, <2 x float> }`,
    /// `{ double, <2 x float> }` and `{ <2 x float>, double }`: the shapes
    /// where an SSE/SSEUP vector slot shares the aggregate with an INTEGER or
    /// scalar SSE register. They stay distinct from `abi_pair` because one
    /// slot is a vector, not a scalar.
    abi_v2f32_i32,
    abi_v2f32_i64,
    abi_i64_v2f32,
    abi_f64_v2f32,
    abi_v2f32_f64,
    /// Return transport of a two-register aggregate whose eightbytes travel
    /// as the two given scalar classes: `{ <2 x float>, i32 }` for a vector
    /// followed by a 32-bit integer, `{ ptr, double }` for a pointer followed
    /// by a double. One representation covers every register pair, including
    /// pairs that only occur in parameters and pointer-bearing eightbytes.
    abi_pair: AbiPair,
    pointer: PointerInfo,
    /// A first-class function value: a pointer to a function whose signature is
    /// `info`. It is a distinct type from `.pointer` on purpose — a function
    /// pointer cannot be dereferenced as data or used for pointer arithmetic —
    /// but it has the same C representation, one `ptr` at the boundary.
    fn_ptr: *FnInfo,
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
            // A tagged union's value is `{ tag, payload }`, so it crosses the
            // boundary as an aggregate and must be classified like one. A plain
            // enum is a bare integer and stays a scalar.
            .enum_type => |info| info.value_ty != null,
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
            .abi_vec2_f32 => b.* == .abi_vec2_f32,
            .abi_v2f32_f32 => b.* == .abi_v2f32_f32,
            .abi_v2f32_v2f32 => b.* == .abi_v2f32_v2f32,
            .abi_pair_f64 => b.* == .abi_pair_f64,
            .abi_v2f32_i32 => b.* == .abi_v2f32_i32,
            .abi_v2f32_i64 => b.* == .abi_v2f32_i64,
            .abi_i64_v2f32 => b.* == .abi_i64_v2f32,
            .abi_f64_v2f32 => b.* == .abi_f64_v2f32,
            .abi_v2f32_f64 => b.* == .abi_v2f32_f64,
            .abi_pair => |ap| switch (b.*) {
                .abi_pair => |bp| ap.first == bp.first and ap.second == bp.second,
                else => false,
            },
            .pointer => |ap| switch (b.*) {
                .pointer => |bp| ap.is_const == bp.is_const and eql(ap.elem, bp.elem),
                else => false,
            },
            .fn_ptr => |af| switch (b.*) {
                .fn_ptr => |bf| fnInfoEql(af, bf),
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
                .fn_type => |bf| fnInfoEql(af, bf),
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
            .abi_vec2_f32 => "<2 x f32 ABI value>",
            .abi_v2f32_f32 => "<f32x2, f32 ABI value>",
            .abi_v2f32_v2f32 => "<f32x2, f32x2 ABI value>",
            .abi_pair_f64 => "<f64, f64 ABI value>",
            .abi_v2f32_i32 => "<f32x2, i32 ABI value>",
            .abi_v2f32_i64 => "<f32x2, i64 ABI value>",
            .abi_i64_v2f32 => "<i64, f32x2 ABI value>",
            .abi_f64_v2f32 => "<f64, f32x2 ABI value>",
            .abi_v2f32_f64 => "<f32x2, f64 ABI value>",
            .abi_pair => |pair| std.fmt.bufPrint(buffer, "<{s}, {s} ABI value>", .{
                @tagName(pair.first),
                @tagName(pair.second),
            }) catch "<ABI pair>",
            .pointer => |p| std.fmt.bufPrint(buffer, "*{s}{s}", .{
                if (p.is_const) "const " else "",
                p.elem.displayName(buffer[@min(buffer.len, 8)..]),
            }) catch "*?",
            .array => |a| std.fmt.bufPrint(buffer, "[{d}]?", .{a.len}) catch "[?]",
            .slice => "slice",
            .struct_type => |s| s.name,
            .enum_type => |e| e.name,
            .fn_type => "fn",
            .fn_ptr => "fn",
            .comptime_int => "comptime_int",
            .comptime_float => "comptime_float",
            .null_type => "null",
        };
    }
};

/// Structural equality of two function signatures. Kept beside `Type.eql`
/// because both `fn_type` and `fn_ptr` need it, and a signature must compare
/// identically wherever it appears.
pub fn fnInfoEql(a: *const FnInfo, b: *const FnInfo) bool {
    if (a == b) return true;
    if (a.params.len != b.params.len) return false;
    if (!Type.eql(a.ret, b.ret)) return false;
    for (a.params, b.params) |ap, bp| {
        if (!Type.eql(ap, bp)) return false;
    }
    return true;
}

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

/// A first-class function value with the same signature as `fn_ty`.
pub fn makeFnPtr(allocator: std.mem.Allocator, fn_ty: *Type) !*Type {
    const ty = try allocator.create(Type);
    ty.* = .{ .fn_ptr = fn_ty.fn_type };
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
    allocator: std.mem.Allocator,
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

    /// Widths reachable only through the `uN`/`iN` spelling, interned so that
    /// `u8` written as a keyword and as `u8` are the same `*Type`: two pointers
    /// for one type would make equality depend on spelling, and `Type` has no
    /// other identity to fall back on.
    int_widths: [max_int_bits + 1]?*Type = @splat(null),
    int_widths_signed: [max_int_bits + 1]?*Type = @splat(null),

    /// Returns null for a width the language does not have: zero (no value at
    /// all) and anything above `max_int_bits` (the backend's widest instruction).
    /// The caller turns null into a diagnostic with the span in hand. Never
    /// reallocates an existing `*Type`, so a pointer handed out stays valid.
    pub fn intOfWidth(self: *Primitives, bits: u16, signed: bool) !?*Type {
        if (bits == 0 or bits > max_int_bits) return null;
        const known = self.knownWidth(bits, signed);
        if (known) |ty| return ty;
        const ty = try integer(self.allocator, bits, signed);
        if (signed) self.int_widths_signed[bits] = ty else self.int_widths[bits] = ty;
        return ty;
    }

    /// The named width, if the language already has a keyword for it.
    fn knownWidth(self: *Primitives, bits: u16, signed: bool) ?*Type {
        return switch (bits) {
            8 => if (signed) self.i8 else self.u8,
            16 => if (signed) self.i16 else self.u16,
            32 => if (signed) self.i32 else self.u32,
            64 => if (signed) self.i64 else self.u64,
            128 => if (signed) self.i128 else self.u128,
            else => null,
        };
    }

    pub fn init(allocator: std.mem.Allocator) !Primitives {
        return .{
            .allocator = allocator,
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

/// The largest integer width the backend can emit. LLVM itself takes any `iN`,
/// but the ABI, the arithmetic and the constant folding all assume at most 128,
/// and a wider type would silently reach instructions that only handle 128.
pub const max_int_bits: u16 = 128;

/// Parses the `uN`/`iN` spelling that is not a keyword. Returns null for anything
/// that is not exactly one of `u`/`i` followed by decimal digits, so a user type
/// named `uint` or `item` is left alone.
pub fn parseIntWidthName(name: []const u8) ?struct { bits: u16, signed: bool } {
    if (name.len < 2) return null;
    const signed = switch (name[0]) {
        'u' => false,
        'i' => true,
        else => return null,
    };
    var bits: u32 = 0;
    for (name[1..]) |c| {
        if (c < '0' or c > '9') return null;
        bits = bits * 10 + (c - '0');
        if (bits > std.math.maxInt(u16)) return null;
    }
    return .{ .bits = @intCast(bits), .signed = signed };
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
    try std.testing.expectEqual(@as(u128, 2147483647), p.i32.intInfo().max());
    try std.testing.expectEqual(@as(i128, -2147483648), p.i32.intInfo().min());
}

test "128-bit integer bounds stay representable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Primitives.init(a);

    // A signed 128-bit maximum is exactly `i128`'s, and its minimum is too, so
    // neither may overflow the `i128` arithmetic that computes the bounds.
    try std.testing.expectEqual(@as(u128, @intCast(std.math.maxInt(i128))), p.i128.intInfo().max());
    try std.testing.expectEqual(std.math.minInt(i128), p.i128.intInfo().min());
    // The magnitude of the signed minimum is one past the unsigned maximum of
    // the same width, which is why it needs its own accessor.
    try std.testing.expectEqual(@as(u128, 1) << 127, p.i128.intInfo().minMagnitude());

    // An unsigned 128-bit maximum is not representable in `i128` at all.
    try std.testing.expectEqual(std.math.maxInt(u128), p.u128.intInfo().max());
    try std.testing.expectEqual(@as(i128, 0), p.u128.intInfo().min());
    try std.testing.expectEqual(@as(u128, 0), p.u128.intInfo().minMagnitude());

    // A `u128` maximum is a valid literal but has no `i128` spelling, so it is
    // checked through the unsigned magnitude rather than through `fits`, whose
    // argument cannot hold it.
    try std.testing.expect(p.u128.intInfo().fitsUnsigned(std.math.maxInt(u128)));
    try std.testing.expect(!p.u64.intInfo().fitsUnsigned(std.math.maxInt(u128)));
    try std.testing.expect(!p.i128.intInfo().fitsUnsigned(@as(u128, 1) << 127));
}
