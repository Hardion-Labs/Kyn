#include <stdint.h>

struct TinyFloatPair { int8_t count; float low; float mid; };

extern struct TinyFloatPair kyn_transform(struct TinyFloatPair value);

struct TinyFloatPair c_transform(struct TinyFloatPair value) {
    value.count += 2;
    value.low += 1.25f;
    value.mid += 2.25f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct TinyFloatPair result = kyn_transform((struct TinyFloatPair){ 3, 1.0f, 2.0f });
    return result.count == 6 && result.low == 3.0f && result.mid == 5.0f ? 47 : 0;
}
