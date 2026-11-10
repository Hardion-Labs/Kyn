#include <stdint.h>
#include <stdbool.h>

struct DoubleBool { double ratio; _Bool count; };

extern struct DoubleBool kyn_transform(struct DoubleBool value);

struct DoubleBool c_transform(struct DoubleBool value) {
    value.ratio += 0.5;
    value.count = (_Bool)!value.count;
    return value;
}

int32_t c_verify_kyn(void) {
    struct DoubleBool result = kyn_transform((struct DoubleBool){ 10.0, 0 });
    return result.ratio == 12.0 && result.count == 1 ? 53 : 0;
}
