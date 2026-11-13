#include <stdio.h>
#include <stdint.h>
/* Kyn: align(16) struct A { c: u8 } */
struct A { char c; } __attribute__((aligned(16)));
/* Kyn: align(4) packed struct C { c: u8, i: i32 } */
struct C { char c; int i; } __attribute__((packed, aligned(4)));
int c_entry(void) {
  printf("A size=%zu align=%zu\n", sizeof(struct A), _Alignof(struct A));
  printf("C size=%zu align=%zu\n", sizeof(struct C), _Alignof(struct C));
  return 0;
}
