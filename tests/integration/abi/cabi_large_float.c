#include <stdint.h>

struct LargeFloat { double amount; int64_t tag; int32_t count; };

extern struct LargeFloat kyn_make_large(double amount, int64_t tag, int32_t count);

struct LargeFloat c_transform_large(struct LargeFloat value) {
    value.amount += 0.5;
    value.tag += 4;
    value.count += 5;
    return value;
}

int32_t c_verify_large(void) {
    struct LargeFloat value = kyn_make_large(3.0, 6, 7);
    return value.amount == 4.0 && value.tag == 8 && value.count == 10 ? 20 : 0;
}
