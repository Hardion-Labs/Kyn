#include <stdint.h>

struct SparseShorts { int16_t a, b, c, d; double ratio; };

extern struct SparseShorts kyn_transform(struct SparseShorts value);

struct SparseShorts c_transform(struct SparseShorts value) {
    value.a += 1;
    value.b += 2;
    value.c += 3;
    value.d += 4;
    value.ratio += 0.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct SparseShorts result = kyn_transform((struct SparseShorts){ 3, 4, 5, 6, 10.0 });
    return result.a == 4 && result.b == 5 && result.c == 6 && result.d == 7 && result.ratio == 12.0 ? 41 : 0;
}
