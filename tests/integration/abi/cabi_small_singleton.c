#include <stdint.h>

struct TinyI32 { int32_t x; };

extern struct TinyI32 kyn_add(struct TinyI32 value);

int32_t c_take(struct TinyI32 value) {
    return value.x;
}

int32_t c_verify_kyn(void) {
    struct TinyI32 r = kyn_add((struct TinyI32){ 20 });
    return r.x == 21 ? 33 : 0;
}
