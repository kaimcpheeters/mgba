/* SPDX-License-Identifier: MPL-2.0 */
#include "GameDexBridge.h"
#include <mgba/core/core.h>
#include <mgba/core/log.h>
#include <mgba/core/timing.h>
#include <mgba/gba/core.h>
#include <mgba-util/audio-buffer.h>
#include <mgba-util/vfs.h>
#include <stdlib.h>
#include <string.h>
struct GDCore {
 struct mCore* core;
 struct mCoreCallbacks callbacks;
 mColor pixels[240 * 160];
 GDPoll polls[65536];
 size_t count;
 int overflow;
 uint16_t sampled;
 char title[32];
};
static void sampled(void* context, uint16_t keys) {
 GDCore* g = context; g->sampled = keys;
 if (g->count < 65536) g->polls[g->count++] = (GDPoll){mTimingGlobalTime(g->core->timing), keys};
 else g->overflow = 1;
}
static void logMessage(struct mLogger* logger, int category, enum mLogLevel level, const char* format, va_list args) {
 (void)logger; (void)category;
 if (level & (mLOG_FATAL | mLOG_ERROR)) { vfprintf(stderr, format, args); fputc('\n', stderr); }
}
static struct mLogger logger = {.log = logMessage};
GDCore* gd_create(const char* rom, const char* save) {
 mLogSetDefaultLogger(&logger);
 GDCore* g = calloc(1, sizeof(*g)); if (!g) return NULL;
 g->core = GBACoreCreate();
 if (!g->core || !g->core->init(g->core)) { free(g); return NULL; }
 struct mCore* c = g->core;
 mCoreInitConfig(c, NULL);
 struct mCoreOptions opts = {0};
 opts.useBios = false; opts.skipBios = true; opts.volume = 0x100; opts.audioBuffers = 4096;
 mCoreConfigLoadDefaults(&c->config, &opts);
 mCoreConfigSetIntValue(&c->config, "allowOpposingDirections", 0);
 mCoreLoadConfig(c);
 c->setVideoBuffer(c, g->pixels, 240);
 c->setAudioBufferSize(c, 4096);
 if (!mCoreLoadFile(c, rom)) { mCoreConfigDeinit(&c->config); c->deinit(c); free(g); return NULL; }
 if (save) {
  struct VFile* vf = VFileOpen(save, O_RDWR | O_CREAT);
  if (vf && !c->loadSave(c, vf)) vf->close(vf);
 }
 g->callbacks.context = g; g->callbacks.keysSampled = sampled;
 c->addCoreCallbacks(c, &g->callbacks);
 struct mGameInfo info = {0}; c->getGameInfo(c, &info);
 memcpy(g->title, info.title, sizeof(info.title));
 c->reset(c);
 return g;
}
void gd_destroy(GDCore* g) {
 if (!g) return;
 g->core->unloadROM(g->core); mCoreConfigDeinit(&g->core->config); g->core->deinit(g->core); free(g);
}
void gd_frame(GDCore* g, uint32_t keys) { g->count = 0; g->core->setKeys(g->core, keys); g->core->runFrame(g->core); }
const uint8_t* gd_pixels(GDCore* g) { return (const uint8_t*)g->pixels; }
const char* gd_title(GDCore* g) { return g->title; }
uint64_t gd_cycle(GDCore* g) { return mTimingGlobalTime(g->core->timing); }
uint16_t gd_sampled_keys(GDCore* g) { return g->sampled; }
size_t gd_audio(GDCore* g, int16_t* output, size_t capacity) { return mAudioBufferRead(g->core->getAudioBuffer(g->core), output, capacity); }
unsigned gd_audio_rate(GDCore* g) { return g->core->audioSampleRate(g->core); }
const GDPoll* gd_polls(GDCore* g, size_t* count) { *count = g->count; return g->polls; }
int gd_poll_overflow(GDCore* g) { return g->overflow; }
