#include <stdint.h>

struct FloatPair { float low; float high; };

extern struct FloatPair kyn_scale_pair(struct FloatPair value);

struct FloatPair c_transform_pair(struct FloatPair value) {
    value.low *= 2.0f;
    value.high += 1.25f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct FloatPair result = kyn_scale_pair((struct FloatPair){ 3.0f, 5.0f });
    return result.low == 6.0f && result.high == 8.0f ? 51 : 0;
}
