#include <stdint.h>

struct FloatDouble { float amount; double ratio; };

extern struct FloatDouble kyn_transform(struct FloatDouble value);

struct FloatDouble c_transform(struct FloatDouble value) {
    value.amount += 1.25f;
    value.ratio += 0.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct FloatDouble result = kyn_transform((struct FloatDouble){ 3.0f, 10.0 });
    return result.amount == 4.0f && result.ratio == 12.0 ? 33 : 0;
}
