#include <stdint.h>

struct Packed { int32_t low; int32_t mid; double high; };

extern struct Packed kyn_transform(struct Packed value);

struct Packed c_transform(struct Packed value) {
    value.low *= 2;
    value.mid += 2;
    value.high += 0.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct Packed result = kyn_transform((struct Packed){ 3, 4, 10.0 });
    return result.low == 6 && result.mid == 8 && result.high == 12.0 ? 47 : 0;
}
