struct Pair { long a; long b; };
extern struct Pair kyn_make(long a, long b);
long c_sum(struct Pair p) { return p.a + p.b; }
long c_wrap(void) {
    struct Pair pair = kyn_make(40, 50);
    return pair.a + pair.b;
}
