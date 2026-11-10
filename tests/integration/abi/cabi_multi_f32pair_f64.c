#include <stdint.h>

struct FloatPairDouble { float a; float b; double c; };

extern struct FloatPairDouble kyn_transform(struct FloatPairDouble value);

struct FloatPairDouble c_transform(struct FloatPairDouble value) {
    value.a += 1.25f;
    value.b += 2.5f;
    value.c += 0.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct FloatPairDouble result = kyn_transform((struct FloatPairDouble){ 3.0f, 4.0f, 10.0 });
    return result.a == 5.0f && result.b == 7.0f && result.c == 14.0 ? 47 : 0;
}
