#include <stdint.h>
#include <stdbool.h>

enum Color8 { Red = 2, Blue = 3 };

struct EnumDouble { enum Color8 color; double ratio; };

extern struct EnumDouble kyn_transform(struct EnumDouble value);

struct EnumDouble c_transform(struct EnumDouble value) {
    value.ratio += 0.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct EnumDouble result = kyn_transform((struct EnumDouble){ Red, 10.0 });
    return result.color == Red && result.ratio == 12.0 ? 47 : 0;
}
