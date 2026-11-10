#include <stdint.h>
#include <stdbool.h>

enum WideType { Big = 7, Huge = 9 };

struct EnumWide { enum WideType id; double ratio; };

extern struct EnumWide kyn_transform(struct EnumWide value);

struct EnumWide c_transform(struct EnumWide value) {
    value.ratio += 0.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct EnumWide result = kyn_transform((struct EnumWide){ Big, 10.0 });
    return result.id == Big && result.ratio == 12.0 ? 53 : 0;
}
