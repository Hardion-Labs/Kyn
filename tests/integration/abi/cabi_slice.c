#include <stddef.h>
#include <stdint.h>

typedef struct {
    int32_t *ptr;
    size_t len;
} KynMutSliceI32;

typedef struct {
    const int32_t *ptr;
    size_t len;
} KynConstSliceI32;

typedef struct {
    int32_t tag;
} SmallTag;

extern KynConstSliceI32 kyn_middle_slice(KynConstSliceI32 input);

int32_t c_sum_slice(KynConstSliceI32 xs, SmallTag tag) {
    int32_t acc = tag.tag;
    for (size_t i = 0; i < xs.len; ++i) {
        acc += xs.ptr[i];
    }
    return acc;
}

KynMutSliceI32 c_scale_and_tail(KynMutSliceI32 xs, int32_t factor) {
    for (size_t i = 0; i < xs.len; ++i) {
        xs.ptr[i] *= factor;
    }
    KynMutSliceI32 out = { xs.ptr + 1, xs.len - 1 };
    return out;
}

int32_t c_call_kyn_middle(const int32_t *ptr, size_t len) {
    KynConstSliceI32 in = { ptr, len };
    KynConstSliceI32 mid = kyn_middle_slice(in);
    int32_t acc = 0;
    for (size_t i = 0; i < mid.len; ++i) {
        acc += mid.ptr[i];
    }
    return acc;
}
