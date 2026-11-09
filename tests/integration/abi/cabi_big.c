struct Big { long a; long b; long c; };
extern struct Big kyn_make(long a, long b, long c);
long c_sum(struct Big p) { return p.a + p.b + p.c; }
long c_wrap(void) {
    struct Big big = kyn_make(40, 50, 60);
    return big.a + big.b + big.c;
}
