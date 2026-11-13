#include <stdio.h>
#include <stdint.h>
/* Kyn: align(16) struct Al { c: u8 } */
struct Al { unsigned char c; } __attribute__((aligned(16)));
/* Kyn: align(16) struct Al8 { c: u8, i: i32 } */
struct Al8 { unsigned char c; int i; } __attribute__((aligned(16)));
/* Kyn: align(16) struct Same { v: i64 } */
struct Same { long v; } __attribute__((aligned(16)));
/* Kyn: align(16) struct Two { a: i64, b: u8 } */
struct Two { long a; unsigned char b; } __attribute__((aligned(16)));
/* Kyn: align(32) struct Big { c: u8 } -- by memory */
struct Big { unsigned char c; } __attribute__((aligned(32)));

/* Two directions: C receives what Kyn passed and returns what Kyn sent, so a
   mismatch in any register shows up as a wrong value rather than a missing one. */
struct Al c_echo_al(struct Al x) { return x; }
struct Al8 c_echo_al8(struct Al8 x) { return x; }
struct Same c_echo_same(struct Same x) { return x; }
struct Two c_echo_two(struct Two x) { return x; }
struct Big c_echo_big(struct Big x) { return x; }

int c_report(void) {
  printf("Al %zu Al8 %zu Same %zu Two %zu Big %zu\n",
      sizeof(struct Al), sizeof(struct Al8), sizeof(struct Same),
      sizeof(struct Two), sizeof(struct Big));
  return 0;
}
