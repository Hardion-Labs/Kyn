#include <stdint.h>

struct TinyLong { int8_t count; int64_t amount; };
struct LongTiny { int64_t amount; int8_t count; };
struct SmallLong { int16_t count; int64_t amount; };
struct LongSmall { int64_t amount; int16_t count; };
struct IntLong { int32_t count; int64_t amount; };
struct LongInt { int64_t amount; int32_t count; };

extern struct TinyLong kyn_take_tiny_long(struct TinyLong value);
extern struct LongTiny kyn_take_long_tiny(struct LongTiny value);
extern struct SmallLong kyn_take_small_long(struct SmallLong value);
extern struct LongSmall kyn_take_long_small(struct LongSmall value);
extern struct IntLong kyn_take_int_long(struct IntLong value);
extern struct LongInt kyn_take_long_int(struct LongInt value);

struct TinyLong c_take_tiny_long(struct TinyLong value) {
    value.count += 1;
    value.amount += 2;
    return value;
}

struct LongTiny c_take_long_tiny(struct LongTiny value) {
    value.amount += 2;
    value.count += 1;
    return value;
}

struct SmallLong c_take_small_long(struct SmallLong value) {
    value.count += 1;
    value.amount += 2;
    return value;
}

struct LongSmall c_take_long_small(struct LongSmall value) {
    value.amount += 2;
    value.count += 1;
    return value;
}

struct IntLong c_take_int_long(struct IntLong value) {
    value.count += 1;
    value.amount += 2;
    return value;
}

struct LongInt c_take_long_int(struct LongInt value) {
    value.amount += 2;
    value.count += 1;
    return value;
}

int32_t c_check_kyn(void) {
    struct TinyLong a = kyn_take_tiny_long((struct TinyLong){ 3, 10 });
    struct LongTiny b = kyn_take_long_tiny((struct LongTiny){ 20, 4 });
    struct SmallLong c = kyn_take_small_long((struct SmallLong){ 5, 30 });
    struct LongSmall d = kyn_take_long_small((struct LongSmall){ 40, 6 });
    struct IntLong e = kyn_take_int_long((struct IntLong){ 7, 50 });
    struct LongInt f = kyn_take_long_int((struct LongInt){ 60, 8 });
    int ok = a.count == 4 && a.amount == 12 &&
             b.amount == 22 && b.count == 5 &&
             c.count == 6 && c.amount == 32 &&
             d.amount == 42 && d.count == 7 &&
             e.count == 8 && e.amount == 52 &&
             f.amount == 62 && f.count == 9;
    return ok ? 0 : 1;
}
