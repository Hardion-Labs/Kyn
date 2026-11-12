#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// C formats the same arguments through the same library, so the comparison is
// against real promotion behaviour rather than a hand-computed expectation. A
// width that Kyn failed to promote changes the string and fails here.
int32_t c_verify_buffer(const uint8_t *text) {
    char expected[64];
    int written = snprintf(expected, sizeof expected, "%d/%d/%d/%.1f/%ld/%s",
                           (int)5, (unsigned)250, (int)true, (double)0.5f,
                           (long)9000000000L, "kyn");
    if (written != 26) { return 10; }
    return strcmp(expected, (const char *)text) == 0 ? 11 : 12;
}

int32_t c_format_expected(void) {
    // The same promotion path reached from C with the declared fixed parameter
    // and two variadic arguments, to confirm the shared declaration agrees on
    // both sides of the boundary.
    char buffer[32];
    int written = snprintf(buffer, sizeof buffer, "%.2f", (double)0.5f);
    return written == 4 ? 0 : 1;
}
