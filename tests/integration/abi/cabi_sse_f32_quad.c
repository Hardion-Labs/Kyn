#include <stdint.h>

struct FloatQuad { float a; float b; float c; float d; };

extern struct FloatQuad kyn_transform_quad(struct FloatQuad value);

struct FloatQuad c_transform_quad(struct FloatQuad value) {
    value.a *= 2.0f;
    value.b += 1.25f;
    value.c *= 2.0f;
    value.d += 1.0f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct FloatQuad result = kyn_transform_quad((struct FloatQuad){ 10.0f, 20.0f, 30.0f, 40.0f });
    return result.a == 11.0f && result.b == 22.0f && result.c == 33.0f && result.d == 44.0f ? 33 : 0;
}
