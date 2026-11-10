#include <stdint.h>

struct DoubleFloatPair { double a; float b; float c; };

extern struct DoubleFloatPair kyn_transform(struct DoubleFloatPair value);

struct DoubleFloatPair c_transform(struct DoubleFloatPair value) {
    value.a += 0.5;
    value.b += 1.25f;
    value.c += 2.5f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct DoubleFloatPair result = kyn_transform((struct DoubleFloatPair){ 10.0, 1.0f, 2.0f });
    return result.a == 12.0 && result.b == 3.0f && result.c == 5.0f ? 53 : 0;
}
