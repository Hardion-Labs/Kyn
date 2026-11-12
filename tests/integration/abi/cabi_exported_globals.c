#include <stdint.h>

struct Limits { int32_t lo, hi; };

extern int32_t counter;
extern const int32_t threshold;
extern const struct Limits limits;
extern const uint8_t max_u8;

int32_t bump_counter(int32_t);

int32_t c_verify_exported_globals(void) {
    if (counter != 41) { return 1; }
    if (threshold != 7) { return 2; }
    if (limits.lo != 3 || limits.hi != 4) { return 3; }
    if (max_u8 != 200) { return 4; }

    // C writes the mutable global; Kyn reads the value C stored.
    counter = 100;
    if (bump_counter(5) != 105) { return 5; }
    if (counter != 105) { return 6; }

    // Reset so the Kyn side can check that a C write reached its storage.
    counter = 1;
    if (bump_counter(1) != 2) { return 7; }
    return 42;
}
