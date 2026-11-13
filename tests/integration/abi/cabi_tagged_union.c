#include <stdio.h>
/* The representation Kyn emits, written out the way clang lays it down. */
typedef struct { int tag; union { double circle; int rect; } payload; } Shape;

int c_tag_of(Shape s) { return s.tag == 0 ? 1 : (s.tag == 1 ? 2 : 3); }
double c_payload_of(Shape s) { return s.tag == 0 ? s.payload.circle : (double)s.payload.rect; }
Shape c_make_circle(double r) { Shape s; s.tag = 0; s.payload.circle = r; return s; }
Shape c_make_rect(int w) { Shape s; s.tag = 1; s.payload.rect = w; return s; }

/* The measured size and alignment, so a change to either fails here. */
int report(void) {
  printf("Shape %zu/%zu\n", sizeof(Shape), _Alignof(Shape));
  return 0;
}
