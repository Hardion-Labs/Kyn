#include <stdint.h>

// A NaN is nonzero, so C's own `(_Bool)` conversion of one is true; Kyn has to
// agree, which is why the narrowing compares unordered-or-not-equal. The values
// come from C so no fold can produce them.
double c_nan(void) { return 0.0 / 0.0; }
double c_inf(void) { return 1.0 / 0.0; }
double c_zero(void) { return 0.0; }
double c_neg_zero(void) { return -0.0; }
double c_half(void) { return 0.5; }
float c_narrow_half(void) { return 0.5f; }
double c_from_flag(int8_t flag) { return flag ? 1.0 : 0.0; }
