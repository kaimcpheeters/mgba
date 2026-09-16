/* SPDX-License-Identifier: MPL-2.0 */
#include "GameDexBridge.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char** argv) {
 assert(argc == 3);
 GDCore* core = gd_create(argv[1], NULL); assert(core);
 for (int i = 0; i < 10; ++i) gd_frame(core, 0);
 unsigned char expected[240 * 160 * 4];
 assert(gd_save_state(core, argv[2]));
 gd_frame(core, 0); /* Matches the neutral redraw after loading. */
 memcpy(expected, gd_pixels(core), sizeof(expected));
 gd_frame(core, 1);
 for (int i = 0; i < 10; ++i) gd_frame(core, 0);
 unsigned char future[240 * 160 * 4];
 memcpy(future, gd_pixels(core), sizeof(future));
 assert(gd_load_state(core, argv[2]));
 assert(!memcmp(expected, gd_pixels(core), sizeof(expected)));
 gd_frame(core, 1);
 for (int i = 0; i < 10; ++i) gd_frame(core, 0);
 assert(!memcmp(future, gd_pixels(core), sizeof(future)));
 gd_destroy(core);
 core = gd_create(argv[1], NULL); assert(core);
 assert(gd_load_state(core, argv[2]));
 assert(!memcmp(expected, gd_pixels(core), sizeof(expected)));
 assert(!gd_load_state(core, "/nonexistent/gamedex-test.state"));
 gd_destroy(core);
 puts("PASS: state restores pixels and deterministic continuation, survives core restart, and rejects a missing file");
}
