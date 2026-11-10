#include <stdint.h>

struct DoubleSmall { double ratio; int16_t count; };

extern struct DoubleSmall kyn_transform(struct DoubleSmall value);

struct DoubleSmall c_transform(struct DoubleSmall value) {
    value.ratio += 0.5;
    value.count += 2;
    return value;
}

int32_t c_verify_kyn(void) {
    struct DoubleSmall result = kyn_transform((struct DoubleSmall){ 10.0, 20 });
    return result.ratio == 12.0 && result.count == 23 ? 31 : 0;
}
