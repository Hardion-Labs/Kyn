#include <stdio.h>
#include <stdint.h>
/* Kyn: struct Wire { kind: u3, tag: u5 }  -> 1 byte, align 1 */
struct Wire { unsigned char kind:3; unsigned char tag:5; };
/* Kyn: struct Sub { a: u3, b: u5, c: u12 } -> 4 bytes, align 2 */
struct Sub { unsigned char a:3; unsigned char b:5; unsigned short c:12; };
int c_probe(void) {
  struct Wire w; w.kind = 5; w.tag = 21;
  struct Sub s; s.a = 7; s.b = 31; s.c = 4095;
  unsigned char wb[1], sb[4];
  __builtin_memcpy(wb, &w, 1);
  __builtin_memcpy(sb, &s, sizeof s);
  printf("Wire size=%zu bytes=%02x\n", sizeof w, wb[0]);
  printf("Sub  size=%zu align=%zu bytes=%02x %02x %02x %02x\n",
         sizeof s, _Alignof(struct Sub), sb[0], sb[1], sb[2], sb[3]);
  return 0;
}
