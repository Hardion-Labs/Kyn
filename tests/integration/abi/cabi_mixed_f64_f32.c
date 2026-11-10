#include <stdint.h>

struct DoubleFloat { double ratio; float amount; };

extern struct DoubleFloat kyn_transform(struct DoubleFloat value);

struct DoubleFloat c_transform(struct DoubleFloat value) {
    value.ratio += 0.5;
    value.amount += 1.25f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct DoubleFloat result = kyn_transform((struct DoubleFloat){ 10.0, 20.0f });
    return result.ratio == 11.0 && result.amount == 22.0f ? 31 : 0;
}
