#include <stdint.h>
#include <stdbool.h>

enum Color8 { Red = 2, Blue = 3 };

struct EnumFloatPair { enum Color8 color; float low; float mid; };

extern struct EnumFloatPair kyn_transform(struct EnumFloatPair value);

struct EnumFloatPair c_transform(struct EnumFloatPair value) {
    value.low += 1.25f;
    value.mid += 2.5f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct EnumFloatPair result = kyn_transform((struct EnumFloatPair){ Red, 1.0f, 2.0f });
    return result.color == Red && result.low == 3.0f && result.mid == 5.0f ? 59 : 0;
}
