#include <stdint.h>

extern unsigned __int128 wide_max;
extern unsigned __int128 wide_small;
unsigned __int128 kyn_get_max(void);

int32_t c_check_wide(void) {
    if (wide_max != ~(unsigned __int128)0) { return 10; }
    if (wide_small != (unsigned __int128)UINT64_MAX) { return 11; }
    if (kyn_get_max() != wide_max) { return 12; }
    return 42;
}
