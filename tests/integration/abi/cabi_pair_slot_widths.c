#include <stdint.h>
#include <stdbool.h>

struct FloatPairShort { float low; float high; int16_t extra; };
struct FloatPairByte { float low; float high; int8_t extra; };
struct FloatPairFlag { float low; float high; bool extra; };
struct ShortFloatPair { int16_t extra; float low; float high; };
struct PointerFloatPair { const char *pointer; float low; float high; };
struct FloatPairPointer { float low; float high; const char *pointer; };
struct IntFloatPair { int32_t count; float low; float high; };

extern struct FloatPairShort kyn_take_float_pair_short(struct FloatPairShort value);
extern struct FloatPairByte kyn_take_float_pair_byte(struct FloatPairByte value);
extern struct FloatPairFlag kyn_take_float_pair_flag(struct FloatPairFlag value);
extern struct IntFloatPair kyn_take_int_float_pair(struct IntFloatPair value);

// The `f32, f32` pair travels in one SSE register plus its SSEUP slot, so the
// trailing narrow member must round-trip at its own width without disturbing
// the float slots.
struct FloatPairShort c_take_float_pair_short(struct FloatPairShort value) {
    value.low += 1;
    value.high += 2;
    value.extra += 3;
    return value;
}

struct FloatPairByte c_take_float_pair_byte(struct FloatPairByte value) {
    value.low += 1;
    value.high += 1;
    value.extra += 1;
    return value;
}

struct FloatPairFlag c_take_float_pair_flag(struct FloatPairFlag value) {
    value.low += 1;
    value.high += 1;
    value.extra = !value.extra;
    return value;
}

struct ShortFloatPair c_take_short_float_pair(struct ShortFloatPair value) {
    value.extra += 1;
    value.low += 1;
    value.high += 1;
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

struct IntFloatPair c_take_int_float_pair(struct IntFloatPair value) {
    value.count *= 3;
    value.low += 1;
    value.high += 1;
    return value;
}

int32_t c_check_kyn(void) {
    struct FloatPairShort short_value =
        kyn_take_float_pair_short((struct FloatPairShort){ 1.5f, 2.5f, 7 });
    struct FloatPairByte byte_value =
        kyn_take_float_pair_byte((struct FloatPairByte){ 3.5f, 4.5f, 9 });
    struct FloatPairFlag flag_value =
        kyn_take_float_pair_flag((struct FloatPairFlag){ 5.5f, 6.5f, false });
    struct IntFloatPair int_value =
        kyn_take_int_float_pair((struct IntFloatPair){ 21, 13.5f, 14.5f });
    int ok = short_value.low == 2.5f && short_value.high == 4.5f && short_value.extra == 10 &&
             byte_value.low == 4.5f && byte_value.high == 5.5f && byte_value.extra == 10 &&
             flag_value.low == 6.5f && flag_value.high == 7.5f && flag_value.extra &&
             int_value.count == 42 && int_value.low == 14.5f && int_value.high == 15.5f;
    return ok ? 0 : 1;
}
