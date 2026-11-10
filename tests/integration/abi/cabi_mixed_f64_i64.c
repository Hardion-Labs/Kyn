#include <stdint.h>

struct DoubleLong { double ratio; int64_t count; };

extern struct DoubleLong kyn_transform(struct DoubleLong value);

struct DoubleLong c_transform(struct DoubleLong value) {
    value.ratio += 0.5;
    value.count += 2;
    return value;
}

int32_t c_verify_kyn(void) {
    struct DoubleLong result = kyn_transform((struct DoubleLong){ 10.0, 20 });
    return result.ratio == 12.0 && result.count == 23 ? 41 : 0;
}
