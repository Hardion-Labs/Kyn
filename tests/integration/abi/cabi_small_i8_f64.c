#include <stdint.h>

struct TinyDouble { int8_t count; double ratio; };

extern struct TinyDouble kyn_transform(struct TinyDouble value);

struct TinyDouble c_transform(struct TinyDouble value) {
    value.count += 2;
    value.ratio += 0.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct TinyDouble result = kyn_transform((struct TinyDouble){ 3, 10.0 });
    return result.count == 6 && result.ratio == 12.0 ? 23 : 0;
}
