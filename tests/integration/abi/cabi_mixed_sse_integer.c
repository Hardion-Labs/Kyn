#include <stdint.h>

struct DoubleInt { double amount; int32_t count; };

extern struct DoubleInt kyn_transform(struct DoubleInt value);

struct DoubleInt c_transform(struct DoubleInt value) {
    value.amount += 0.5;
    value.count += 2;
    return value;
}

int32_t c_verify_kyn(void) {
    struct DoubleInt result = kyn_transform((struct DoubleInt){ 10.0, 20 });
    return result.amount == 12.0 && result.count == 23 ? 35 : 0;
}
