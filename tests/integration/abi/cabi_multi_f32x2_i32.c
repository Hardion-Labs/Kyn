#include <stdint.h>

struct FloatPairInt { float low; float mid; int32_t high; };

extern struct FloatPairInt kyn_transform(struct FloatPairInt value);

struct FloatPairInt c_transform(struct FloatPairInt value) {
    value.low += 1.25f;
    value.mid += 1.25f;
    value.high += 2;
    return value;
}

int32_t c_verify_kyn(void) {
    struct FloatPairInt result = kyn_transform((struct FloatPairInt){ 3.0f, 4.0f, 20 });
    return result.low == 4.0f && result.mid == 6.0f && result.high == 23 ? 39 : 0;
}
