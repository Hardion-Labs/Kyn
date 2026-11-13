#include <stdint.h>
#pragma pack(push, 1)
struct P { uint8_t c; int32_t i; };
#pragma pack(pop)
int32_t c_read_byte(const uint8_t *p) { return (int32_t)*p; }
void c_write(uint8_t *p) { p[1] = 0x99; }
