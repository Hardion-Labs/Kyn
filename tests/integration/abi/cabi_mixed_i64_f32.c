#include <stdint.h>

struct LongFloat { int64_t count; float amount; };

extern struct LongFloat kyn_transform(struct LongFloat value);

struct LongFloat c_transform(struct LongFloat value) {
    value.count += 2;
    value.amount += 1.25f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct LongFloat result = kyn_transform((struct LongFloat){ 20, 10.0f });
    return result.count == 23 && result.amount == 11.0f ? 31 : 0;
}
