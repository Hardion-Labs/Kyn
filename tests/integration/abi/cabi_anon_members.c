#include <stdio.h>
/* Kyn: struct P { x: i32, struct { y: i32, z: i8 } } */
struct P { int x; struct { int y; char z; }; };
struct Q { char c; struct { short s; }; int i; };
struct Q echo_q(struct Q v) { return v; }
struct P echo_p(struct P v) { return v; }
int report(void) {
  printf("P %zu/%zu Q %zu/%zu\n", sizeof(struct P), _Alignof(struct P),
         sizeof(struct Q), _Alignof(struct Q));
  return 0;
}
