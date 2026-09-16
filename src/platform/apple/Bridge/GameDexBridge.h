/* SPDX-License-Identifier: MPL-2.0 */
#ifndef GAMEDEX_APPLE_BRIDGE_H
#define GAMEDEX_APPLE_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
typedef struct GDCore GDCore;
typedef struct { uint64_t cycle; uint16_t buttons; } GDPoll;
GDCore* gd_create(const char* rom, const char* save);
void gd_destroy(GDCore*);
void gd_frame(GDCore*, uint32_t keys);
const uint8_t* gd_pixels(GDCore*);
const char* gd_title(GDCore*);
uint64_t gd_cycle(GDCore*);
uint16_t gd_sampled_keys(GDCore*);
size_t gd_audio(GDCore*, int16_t* output, size_t capacity);
unsigned gd_audio_rate(GDCore*);
const GDPoll* gd_polls(GDCore*, size_t* count);
int gd_poll_overflow(GDCore*);

#endif
