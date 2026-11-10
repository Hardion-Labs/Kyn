#include <stdint.h>
#include <stdbool.h>

struct BoolDouble { _Bool count; double ratio; };

extern struct BoolDouble kyn_transform(struct BoolDouble value);

struct BoolDouble c_transform(struct BoolDouble value) {
    value.count = (_Bool)!value.count;
    value.ratio += 0.5;
    return value;
}

int32_t c_verify_kyn(void) {
    struct BoolDouble result = kyn_transform((struct BoolDouble){ 0, 10.0 });
    return result.count == 1 && result.ratio == 12.0 ? 47 : 0;
}
