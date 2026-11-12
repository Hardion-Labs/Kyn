#include <stdint.h>

int32_t kyn_double(int32_t);

static int32_t triple(int32_t x) { return x * 3; }

void *get_callback(void) { return (void *)triple; }

void *triple_ptr(void) { return (void *)triple; }

int32_t call_through(void *ptr, int32_t value) {
    int32_t (*op)(int32_t) = (int32_t (*)(int32_t))ptr;
    return op(value);
}

// C keeps no Kyn signature: it only sees an address it was handed.
int32_t check_kyn_callback(void *ptr) {
    int32_t (*op)(int32_t) = (int32_t (*)(int32_t))ptr;
    if (op(1) != 2) { return 10; }
    if (op(-3) != -6) { return 11; }
    return 42;
}
