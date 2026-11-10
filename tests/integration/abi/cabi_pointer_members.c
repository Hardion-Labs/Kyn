#include <stdint.h>

struct PointerDouble { const char *pointer; double amount; };
struct DoublePointer { double amount; const char *pointer; };
struct FloatPointer { float amount; const char *pointer; };
struct PointerFloatPair { const char *pointer; float low; float high; };
struct FloatPairPointer { float low; float high; const char *pointer; };
struct PointerOnly { const char *pointer; };
struct NestedPointer { struct PointerOnly inner; double amount; };
struct NarrowPointer { int8_t tag; const char *pointer; };
struct ShortOnly { int16_t value; };
struct FloatOnly { float value; };
struct DoubleOnly { double value; };
struct ThreeShorts { int16_t a, b, c; };
struct ThreeBytes { int8_t a, b, c; };

extern struct PointerDouble kyn_take_pointer_double(struct PointerDouble value);
extern struct DoublePointer kyn_take_double_pointer(struct DoublePointer value);
extern struct NestedPointer kyn_take_nested_pointer(struct NestedPointer value);
extern struct NarrowPointer kyn_take_narrow_pointer(struct NarrowPointer value);
extern struct PointerOnly kyn_take_pointer_only(struct PointerOnly value);
extern struct ThreeShorts kyn_take_three_shorts(struct ThreeShorts value);
extern struct ThreeBytes kyn_take_three_bytes(struct ThreeBytes value);

static const char BYTES[4] = { 1, 2, 3, 4 };

struct PointerDouble c_take_pointer_double(struct PointerDouble value) {
    value.amount += 1;
    return value;
}

struct DoublePointer c_take_double_pointer(struct DoublePointer value) {
    value.amount += 2;
    return value;
}

struct FloatPointer c_take_float_pointer(struct FloatPointer value) {
    value.amount += 1;
    return value;
}

struct PointerFloatPair c_take_pointer_float_pair(struct PointerFloatPair value) {
    value.low += 1;
    value.high += 1;
    return value;
}

struct FloatPairPointer c_take_float_pair_pointer(struct FloatPairPointer value) {
    value.low += 1;
    value.high += 1;
    return value;
}

struct NestedPointer c_take_nested_pointer(struct NestedPointer value) {
    value.amount += 3;
    return value;
}

struct NarrowPointer c_take_narrow_pointer(struct NarrowPointer value) {
    value.tag += 1;
    return value;
}

struct PointerOnly c_take_pointer_only(struct PointerOnly value) { return value; }

struct ShortOnly c_take_short_only(struct ShortOnly value) {
    value.value += 1;
    return value;
}

struct FloatOnly c_take_float_only(struct FloatOnly value) {
    value.value += 1;
    return value;
}

struct DoubleOnly c_take_double_only(struct DoubleOnly value) {
    value.value += 1;
    return value;
}

struct ThreeShorts c_take_three_shorts(struct ThreeShorts value) {
    value.a += 1;
    value.b += 2;
    value.c += 3;
    return value;
}

struct ThreeBytes c_take_three_bytes(struct ThreeBytes value) {
    value.a += 1;
    value.b += 2;
    value.c += 3;
    return value;
}

// The pointer identity of every shape is checked here, against the value the
// caller stored: a by-value struct is copied into the callee, so a pointer
// member must come back pointing at the same object, not at a new one.
int32_t c_check_kyn(void) {
    struct PointerDouble a = kyn_take_pointer_double((struct PointerDouble){ BYTES, 10.0 });
    struct DoublePointer b = kyn_take_double_pointer((struct DoublePointer){ 20.0, BYTES });
    struct NestedPointer c = kyn_take_nested_pointer((struct NestedPointer){ { BYTES }, 30.0 });
    struct NarrowPointer d = kyn_take_narrow_pointer((struct NarrowPointer){ 6, BYTES });
    struct PointerOnly e = kyn_take_pointer_only((struct PointerOnly){ BYTES });
    struct ThreeShorts f = kyn_take_three_shorts((struct ThreeShorts){ 10, 20, 30 });
    struct ThreeBytes g = kyn_take_three_bytes((struct ThreeBytes){ 10, 5, 2 });
    int ok = a.pointer == BYTES && a.amount == 11.0 &&
             b.pointer == BYTES && b.amount == 22.0 &&
             c.inner.pointer == BYTES && c.amount == 33.0 &&
             d.pointer == BYTES && d.tag == 7 &&
             e.pointer == BYTES &&
             f.a == 11 && f.b == 22 && f.c == 33 &&
             g.a == 11 && g.b == 7 && g.c == 5;
    return ok ? 0 : 1;
}
