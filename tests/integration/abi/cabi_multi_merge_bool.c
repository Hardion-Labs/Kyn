#include <stdint.h>
#include <stdbool.h>

struct BoolFloatPair { _Bool count; float low; float mid; };

extern struct BoolFloatPair kyn_transform(struct BoolFloatPair value);

struct BoolFloatPair c_transform(struct BoolFloatPair value) {
    value.count = (_Bool)!value.count;
    value.low += 1.25f;
    value.mid += 1.25f;
    return value;
}

int32_t c_verify_kyn(void) {
    struct BoolFloatPair result = kyn_transform((struct BoolFloatPair){ 0, 1.0f, 2.0f });
    return result.count == 1 && result.low == 3.0f && result.mid == 5.0f ? 47 : 0;
}
