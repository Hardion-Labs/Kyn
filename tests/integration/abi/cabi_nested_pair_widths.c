#include <stdint.h>

struct Narrow { int16_t value; };
struct Wide { int32_t value; };
struct NestedNarrow { struct Narrow narrow; int64_t amount; };
struct NestedWide { struct Wide wide; int64_t amount; };
struct ReversedNested { int64_t amount; struct Narrow narrow; };
struct DoubledNarrow { struct Narrow narrow; int16_t count; };

extern struct NestedNarrow kyn_take_nested_narrow(struct NestedNarrow value);
extern struct NestedWide kyn_take_nested_wide(struct NestedWide value);
extern struct ReversedNested kyn_take_reversed_nested(struct ReversedNested value);
extern struct DoubledNarrow kyn_take_doubled_narrow(struct DoubledNarrow value);

struct NestedNarrow c_take_nested_narrow(struct NestedNarrow value) {
    value.narrow.value += 1;
    value.amount += 2;
    return value;
}

struct NestedWide c_take_nested_wide(struct NestedWide value) {
    value.wide.value += 1;
    value.amount += 2;
    return value;
}

struct ReversedNested c_take_reversed_nested(struct ReversedNested value) {
    value.amount += 2;
    value.narrow.value += 1;
    return value;
}

struct DoubledNarrow c_take_doubled_narrow(struct DoubledNarrow value) {
    value.narrow.value += 1;
    value.count += 1;
    return value;
}

int32_t c_check_kyn(void) {
    struct NestedNarrow a = kyn_take_nested_narrow((struct NestedNarrow){ { 3 }, 10 });
    struct NestedWide b = kyn_take_nested_wide((struct NestedWide){ { 4 }, 20 });
    struct ReversedNested c = kyn_take_reversed_nested((struct ReversedNested){ 30, { 5 } });
    struct DoubledNarrow d = kyn_take_doubled_narrow((struct DoubledNarrow){ { 6 }, 7 });
    int ok = a.narrow.value == 4 && a.amount == 12 &&
             b.wide.value == 5 && b.amount == 22 &&
             c.amount == 32 && c.narrow.value == 6 &&
             d.narrow.value == 7 && d.count == 8;
    return ok ? 0 : 1;
}
