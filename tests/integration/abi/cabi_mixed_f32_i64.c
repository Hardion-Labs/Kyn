#include <stdint.h>

struct FloatLong { float amount; int64_t count; };

extern struct FloatLong kyn_transform(struct FloatLong value);

struct FloatLong c_transform(struct FloatLong value) {
    value.amount += 1.25f;
    value.count += 2;
    return value;
}

int32_t c_verify_kyn(void) {
    struct FloatLong result = kyn_transform((struct FloatLong){ 3.0f, 20 });
    return result.amount == 4.0f && result.count == 23 ? 37 : 0;
}
