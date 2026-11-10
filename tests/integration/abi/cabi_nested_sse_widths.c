#include <stdint.h>

struct Inner { int32_t count; };
struct Nested { struct Inner inner; double amount; };
struct DoublePair { double x; double y; };
struct NestedPair { struct DoublePair pair; };
struct FloatLeaf { float value; };
struct NestedFloat { struct FloatLeaf inner; int64_t amount; };

extern struct Nested kyn_take_nested(struct Nested value);
extern struct NestedPair kyn_take_nested_pair(struct NestedPair value);
extern struct NestedFloat kyn_take_nested_float(struct NestedFloat value);

struct Nested c_take_nested(struct Nested value) {
    value.inner.count += 1;
    value.amount += 2;
    return value;
}

struct NestedPair c_take_nested_pair(struct NestedPair value) {
    value.pair.x += 1;
    value.pair.y += 2;
    return value;
}

struct NestedFloat c_take_nested_float(struct NestedFloat value) {
    value.inner.value += 1;
    value.amount += 2;
    return value;
}

int32_t c_check_kyn(void) {
    struct Nested a = kyn_take_nested((struct Nested){ { 3 }, 10.0 });
    struct NestedPair b = kyn_take_nested_pair((struct NestedPair){ { 4.0, 5.0 } });
    struct NestedFloat c = kyn_take_nested_float((struct NestedFloat){ { 6.0f }, 20 });
    int ok = a.inner.count == 4 && a.amount == 12.0 &&
             b.pair.x == 5.0 && b.pair.y == 7.0 &&
             c.inner.value == 7.0f && c.amount == 22;
    return ok ? 0 : 1;
}
