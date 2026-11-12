#include <stdint.h>

int32_t kyn_add(int32_t, int32_t);
int32_t kyn_mul(int32_t, int32_t);

int32_t c_apply(int32_t (*op)(int32_t, int32_t), int32_t a, int32_t b) {
    return op(a, b);
}

int32_t c_apply_twice(int32_t (*op)(int32_t, int32_t), int32_t a, int32_t b) {
    return op(op(a, b), a);
}

// Kyn passes its own functions to C as pointers; C stores one and calls it
// later, which is the shape a callback has in practice.
static int32_t (*stored)(int32_t, int32_t);

int32_t c_verify_kyn_callbacks(void) {
    stored = kyn_add;
    if (stored(20, 22) != 42) { return 10; }
    stored = kyn_mul;
    if (stored(6, 7) != 42) { return 11; }
    return 42;
}
