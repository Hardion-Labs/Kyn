#include <stdint.h>

struct FloatPairLong { float low; float mid; int64_t high; };

extern struct FloatPairLong kyn_transform(struct FloatPairLong value);

struct FloatPairLong c_transform(struct FloatPairLong value) {
    value.low += 1.25f;
    value.mid += 2.5f;
    value.high += 4;
    return value;
}

int32_t c_verify_kyn(void) {
    struct FloatPairLong result = kyn_transform((struct FloatPairLong){ 3.0f, 4.0f, 20 });
    return result.low == 5.0f && result.mid == 7.0f && result.high == 24 ? 41 : 0;
}
