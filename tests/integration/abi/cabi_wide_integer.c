#include <stdint.h>

/* A lone `__int128` member: Clang classifies this as a single 16-byte INTEGER
   and passes it as `i128`, which is what the Kyn side declares. */
struct WideInteger { __int128 value; };
struct WideInner { __int128 value; };
struct WideNested { struct WideInner inner; };
struct WideArray { __int128 values[1]; };

/* The wide value used by the nested checks, so both sides agree byte for byte. */
static __int128 wide_value(void) {
    return ((__int128)0x1122334455667788LL << 64)
         | (unsigned long long)0x99AABBCCDDEEFF00ULL;
}

extern struct WideInteger kyn_double(struct WideInteger value);

static int same(__int128 a, __int128 b) { return a == b; }

struct WideInteger c_roundtrip(struct WideInteger value) {
    /* Normalise through the members so a byte-order mistake cannot pass. */
    __int128 copy = value.value;
    struct WideInteger out;
    out.value = copy;
    return out;
}

struct WideInteger c_make(void) {
    struct WideInteger out;
    out.value = ((__int128)0x1122334455667788LL << 64)
              | (unsigned long long)0x99AABBCCDDEEFF00ULL;
    return out;
}

unsigned __int128 c_echo_unsigned(unsigned __int128 value) { return value; }

int64_t c_check_nested(struct WideNested value) {
    return value.inner.value == wide_value() ? 0 : 1;
}

int64_t c_check_array(struct WideArray value) {
    return value.values[0] == wide_value() ? 0 : 2;
}

int64_t c_check_kyn(void) {
    struct WideInteger in;
    in.value = 21;
    struct WideInteger out = kyn_double(in);
    if (!same(out.value, 42)) return 1;
    /* Both halves of a wide input must reach Kyn and come back doubled. */
    in.value = ((__int128)0x1122334455667788LL << 64)
             | (unsigned long long)0x99AABBCCDDEEFF00ULL;
    out = kyn_double(in);
    if (out.value != in.value * 2) return 2;
    return 0;
}
