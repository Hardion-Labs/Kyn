#include <stdint.h>
union Big3 { int64_t a; double b; uint8_t c[8]; };
#pragma pack(push, 1)
struct Packed { uint8_t c; int32_t i; };
#pragma pack(pop)
struct Holder { uint8_t tag; union Big3 u; };

double kyn_round_u(union Big3 v);
int32_t kyn_unpack_p(struct Packed v);
double kyn_holder_read(struct Holder h);
union Big3 kyn_make_u(double x);

int64_t c_union_size(void) { return (int64_t)sizeof(union Big3); }
int64_t c_packed_size(void) { return (int64_t)sizeof(struct Packed); }

/* Kyn's own exported functions, called from C: a union argument and return, a
   packed struct by value, and a union nested inside a struct. */
int32_t c_verify_kyn(void) {
    int32_t score = 0;
    if (kyn_round_u((union Big3){ .b = 2.0 }) == 3.5) score += 32;
    if (kyn_unpack_p((struct Packed){ 4, 10 }) == 14) score += 64;
    if (kyn_holder_read((struct Holder){ 9, { .b = 1.25 } }) == 1.25) score += 128;
    union Big3 made = kyn_make_u(6.5);
    if (made.b == 6.5) score += 256;
    return score;
}

