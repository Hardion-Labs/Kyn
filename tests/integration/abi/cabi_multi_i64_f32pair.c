#include <stdint.h>

struct LongFloatPair { int64_t a; float b; float c; };

extern struct LongFloatPair kyn_transform(struct LongFloatPair value);

struct LongFloatPair c_transform(struct LongFloatPair value) {
    value.a += 3;
    value.b += 1.25f;
    value.c += 2.25f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct LongFloatPair result = kyn_transform((struct LongFloatPair){ 20, 1.0f, 2.0f });
    return result.a == 25 && result.b == 3.0f && result.c == 5.0f ? 33 : 0;
}
