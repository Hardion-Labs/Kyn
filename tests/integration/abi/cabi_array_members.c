#include <stdint.h>

struct SmallArrayDouble { int8_t count[2]; double amount; };
struct TwoInts { int32_t v[2]; };
struct ThreeInts { int32_t v[3]; };
struct FourBytes { int8_t v[4]; };
struct ThreeShorts { int16_t v[3]; };
struct TwoFloats { float v[2]; };
struct TwoDoubles { double v[2]; };
struct TwoPointers { const char *v[2]; };
struct FourLongs { int64_t v[4]; };
/* Clang spells the second eightbyte `<2 x float>`; Kyn spells it `float`.
   Both put the value in the low lane of the same SSE register. */
struct TrailingFloatArray { int64_t head[1]; float tail[1]; };

extern struct SmallArrayDouble kyn_take_small_array_double(struct SmallArrayDouble value);
extern struct TwoInts kyn_take_two_ints(struct TwoInts value);
extern struct FourLongs kyn_take_four_longs(struct FourLongs value);
extern struct TwoPointers kyn_take_two_pointers(struct TwoPointers value);
extern struct TrailingFloatArray kyn_take_trailing_float_array(struct TrailingFloatArray value);

static const char BYTES[4] = { 1, 2, 3, 4 };

struct SmallArrayDouble c_take_small_array_double(struct SmallArrayDouble value) {
    value.count[0] += 1;
    value.count[1] += 2;
    value.amount += 1.0;
    return value;
}

struct TwoInts c_take_two_ints(struct TwoInts value) {
    value.v[0] += 1;
    value.v[1] += 2;
    return value;
}

struct ThreeInts c_take_three_ints(struct ThreeInts value) {
    value.v[0] += 1;
    value.v[1] += 2;
    value.v[2] += 3;
    return value;
}

struct FourBytes c_take_four_bytes(struct FourBytes value) {
    value.v[0] += 1;
    value.v[1] += 2;
    value.v[2] += 3;
    value.v[3] += 4;
    return value;
}

struct ThreeShorts c_take_three_shorts(struct ThreeShorts value) {
    value.v[0] += 1;
    value.v[1] += 2;
    value.v[2] += 3;
    return value;
}

struct TwoFloats c_take_two_floats(struct TwoFloats value) {
    value.v[0] += 1.0f;
    value.v[1] += 2.0f;
    return value;
}

struct TwoDoubles c_take_two_doubles(struct TwoDoubles value) {
    value.v[0] += 1.0;
    value.v[1] += 2.0;
    return value;
}

struct FourLongs c_take_four_longs(struct FourLongs value) {
    value.v[0] += 1;
    value.v[1] += 2;
    value.v[2] += 3;
    value.v[3] += 4;
    return value;
}

struct TwoPointers c_take_two_pointers(struct TwoPointers value) {
    return value;
}

// The reverse direction is checked here, against the value this side stored:
// an array member passed by value must arrive element for element, and a
// pointer element must keep its identity across the copy.
struct TrailingFloatArray c_take_trailing_float_array(struct TrailingFloatArray value) {
    value.head[0] += 1;
    value.tail[0] += 1.0f;
    return value;
}

int64_t c_lane_check(struct TrailingFloatArray value) {
    return value.head[0] + (int64_t)(value.tail[0] * 1.0f);
}

int32_t c_check_kyn(void) {
    struct SmallArrayDouble a = kyn_take_small_array_double((struct SmallArrayDouble){ { 1, 2 }, 3.0 });
    struct TwoInts b = kyn_take_two_ints((struct TwoInts){ { 10, 20 } });
    struct FourLongs c = kyn_take_four_longs((struct FourLongs){ { 1, 2, 3, 4 } });
    struct TwoPointers d = kyn_take_two_pointers((struct TwoPointers){ { BYTES, BYTES } });
    struct TrailingFloatArray e =
        kyn_take_trailing_float_array((struct TrailingFloatArray){ { 40 }, { 1.5f } });
    int ok = a.count[0] == 2 && a.count[1] == 4 && a.amount == 4.0 &&
             b.v[0] == 11 && b.v[1] == 22 &&
             c.v[0] == 2 && c.v[1] == 4 && c.v[2] == 6 && c.v[3] == 8 &&
             d.v[0] == BYTES && d.v[1] == BYTES &&
             e.head[0] == 41 && e.tail[0] == 2.5f;
    return ok ? 0 : 1;
}
