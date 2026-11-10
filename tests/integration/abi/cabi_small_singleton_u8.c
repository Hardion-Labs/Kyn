#include <stdint.h>

struct TinyU8 { uint8_t x; };

extern struct TinyU8 kyn_add(struct TinyU8 value);

uint8_t c_take(struct TinyU8 value) {
    return value.x;
}

int32_t c_verify_kyn(void) {
    struct TinyU8 r = kyn_add((struct TinyU8){ 20 });
    return r.x == 21 ? 37 : 0;
}
