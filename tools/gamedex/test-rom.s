/* Original synthetic GBA test program; no commercial ROM or BIOS. MPL-2.0. */
.syntax unified
.arm
.global _start
_start:
 mov r0, #0x04000000
 mov r1, #3
 orr r1, r1, #0x400
 strh r1, [r0]
 mov r2, #0x06000000
 mov r3, #31
 mov r4, #0x9600
fill:
 strh r3, [r2], #2
 subs r4, r4, #1
 bne fill
 /* Square wave through PSG channel 1, routed to both speakers. */
 mov r1, #0x80
 strh r1, [r0, #0x84]
 mov r1, #0x7700
 orr r1, r1, #0x77
 strh r1, [r0, #0x80]
 mov r1, #2
 strh r1, [r0, #0x82]
 mov r1, #0xf000
 orr r1, r1, #0x80
 strh r1, [r0, #0x62]
 mov r1, #0x8000
 orr r1, r1, #0x400
 strh r1, [r0, #0x64]
 /* Poll once per vertical blank, paint first pixel according to A. */
loop:
 ldrh r1, [r0, #6]
 cmp r1, #160
 bne loop
 add r5, r0, #0x100
 ldrh r1, [r5, #0x30]
 tst r1, #1
 moveq r3, #31
 movne r3, #0x7c00
 mov r2, #0x06000000
 strh r3, [r2]
wait:
 ldrh r1, [r0, #6]
 cmp r1, #160
 beq wait
 b loop
