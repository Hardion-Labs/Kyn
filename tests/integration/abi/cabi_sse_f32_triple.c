#include <stdint.h>

struct FloatTriple { float low; float middle; float high; };

extern struct FloatTriple kyn_scale_triple(struct FloatTriple value);

struct FloatTriple c_transform_triple(struct FloatTriple value) {
    value.low *= 2.0f;
    value.middle += 1.25f;
    value.high *= 2.0f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct FloatTriple result = kyn_scale_triple((struct FloatTriple){ 3.0f, 5.0f, 7.0f });
    return result.low == 6.0f && result.middle == 8.0f && result.high == 11.0f ? 51 : 0;
}
