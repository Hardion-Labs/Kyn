//! Semantic symbols: locals, globals, functions, types and enum variants.

const std = @import("std");
const types = @import("types.zig");

pub const Kind = enum {
    local,
    global,
    function,
    struct_type,
    enum_type,
    enum_variant,
};

pub const Symbol = struct {
    id: u32,
    name: []const u8,
    kind: Kind,
    ty: *types.Type,
    /// Whether the binding can be assigned through its own name.
    mutable: bool = true,
    /// For enum variants: the integer value.
    variant_value: i128 = 0,
    /// For functions: whether the symbol is defined in Kyn.
    is_extern: bool = false,
    is_export: bool = false,
};
