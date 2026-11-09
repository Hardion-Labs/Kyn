#include <stdint.h>

struct FloatInt { float amount; int32_t count; };
struct IntFloat { int32_t count; float amount; };

extern struct FloatInt kyn_make_fi(float amount, int32_t count);
extern struct IntFloat kyn_make_if(int32_t count, float amount);

struct FloatInt c_transform_fi(struct FloatInt value) {
    value.amount += 1.0f;
    value.count += 2;
    return value;
}

struct IntFloat c_transform_if(struct IntFloat value) {
    value.count += 3;
    value.amount += 1.5f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct FloatInt fi = kyn_make_fi(3.0f, 5);
    struct IntFloat int_float = kyn_make_if(6, 3.0f);
    return fi.amount == 5.0f && fi.count == 9 &&
                   int_float.count == 10 && int_float.amount == 5.0f
               ? 34
               : 0;
}
