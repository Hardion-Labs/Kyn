#include <stdint.h>

struct LongDouble { int64_t count; double ratio; };

extern struct LongDouble kyn_transform(struct LongDouble value);

struct LongDouble c_transform(struct LongDouble value) {
    value.count += 2;
    value.ratio += 0.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct LongDouble result = kyn_transform((struct LongDouble){ 20, 10.0 });
    return result.count == 23 && result.ratio == 12.0 ? 47 : 0;
}
