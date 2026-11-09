#include <stdint.h>

struct FloatBox { float value; };
struct DoubleBox { double value; };

extern struct FloatBox kyn_transform_float(struct FloatBox value);
extern struct DoubleBox kyn_transform_double(struct DoubleBox value);

struct FloatBox c_transform_float(struct FloatBox value) {
    value.value += 1.0f;
    return value;
}

struct DoubleBox c_transform_double(struct DoubleBox value) {
    value.value += 1.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct FloatBox single = kyn_transform_float((struct FloatBox){ 4.0f });
    struct DoubleBox dbl = kyn_transform_double((struct DoubleBox){ 5.0 });
    return single.value == 6.0f && dbl.value == 8.0 ? 41 : 0;
}
