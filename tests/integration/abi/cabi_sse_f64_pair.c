#include <stdint.h>

struct DoublePair { double low; double high; };

extern struct DoublePair kyn_transform_pair(struct DoublePair value);

struct DoublePair c_transform_pair(struct DoublePair value) {
    value.low += 0.5;
    value.high += 1.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct DoublePair result = kyn_transform_pair((struct DoublePair){ 10.0, 20.0 });
    return result.low == 11.0 && result.high == 22.0 ? 33 : 0;
}
