// The C side of the callee-variadic fixture: every call here appends arguments
// with the C default promotions, which is exactly what the exported retrieval
// types assume. Doubles are exact in the values used, so the comparison is an
// equality rather than a tolerance.
#include <stdint.h>

int32_t kyn_var_sum(int32_t count, ...);
int64_t kyn_var_sum_wide(int32_t count, ...);
double kyn_var_sum_float(int32_t count, ...);
double kyn_var_mixed(int32_t count, ...);
int32_t kyn_var_callback(int32_t count, ...);
int32_t kyn_var_scale(int32_t value);

// The three-argument sum, the empty list, the wide integers and the float list.
// The register save area is what holds them, so a wrong `va_start`/`va_arg`
// pairing shows up as a wrong number rather than as a crash.
int32_t c_var_sum(int32_t which) {
    switch (which) {
    case 0:
        return kyn_var_sum(3, 10, 20, 12) == 42 ? 1 : 0;
    case 1:
        return kyn_var_sum(0) == 0 ? 2 : 0;
    case 2:
        return kyn_var_sum_wide(3, 1000000000000LL, 2LL, 3LL) == 1000000000005LL ? 4 : 0;
    case 3:
        return kyn_var_sum_float(3, 1.5, 2.25, 3.25) == 7.0 ? 8 : 0;
    default:
        return 0;
    }
}

// The mixed case crosses the two independent save areas, and the negatives check
// that a signed retrieval keeps its sign.
int32_t c_var_mixed(int32_t which) {
    (void)which;
    if (kyn_var_mixed(2, 42, 0.5) != 42.5) return 0;
    if (kyn_var_sum(3, -10, 20, -12) != -2) return 0;
    return 16;
}

// A retrieved function value must be callable: if it came back as anything but a
// pointer, this either traps or returns the wrong number.
int32_t c_var_callback(int32_t which) {
    (void)which;
    return kyn_var_callback(2, 7, kyn_var_scale) == 21 ? 32 : 0;
}
