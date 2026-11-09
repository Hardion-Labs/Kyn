#include <stddef.h>
#include <stdint.h>

struct IntDouble { int32_t count; double amount; };

_Static_assert(offsetof(struct IntDouble, count) == 0, "count offset");
_Static_assert(offsetof(struct IntDouble, amount) == 8, "amount offset");
_Static_assert(sizeof(struct IntDouble) == 16, "struct size");

extern struct IntDouble kyn_transform(struct IntDouble value);

struct IntDouble c_transform(struct IntDouble value) {
    value.count += 2;
    value.amount += 0.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct IntDouble result = kyn_transform((struct IntDouble){ 20, 10.0 });
    return result.count == 23 && result.amount == 12.0 ? 35 : 0;
}
