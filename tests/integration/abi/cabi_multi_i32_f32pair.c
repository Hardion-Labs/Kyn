#include <stdint.h>

struct IntFloatPair { int32_t a; float b; float c; };

extern struct IntFloatPair kyn_transform(struct IntFloatPair value);

struct IntFloatPair c_transform(struct IntFloatPair value) {
    value.a += 2;
    value.b += 1.25f;
    value.c += 1.25f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct IntFloatPair result = kyn_transform((struct IntFloatPair){ 20, 1.0f, 2.0f });
    return result.a == 23 && result.b == 3.0f && result.c == 6.0f ? 37 : 0;
}
