/* GameDex capture integration, MPL-2.0. */
#ifndef MGBA_GAMEDEX_CAPTURE_H
#define MGBA_GAMEDEX_CAPTURE_H
#include <mgba-util/common.h>
CXX_GUARD_START
struct mCore;
struct mGameDexCapture;
/* Call on the emulation thread or while interrupted; directory must not exist.
 * The caller owns the AV stream while recording. Stop before destroying core. */
struct mGameDexCapture* mGameDexStart(struct mCore*, const char* directory);
bool mGameDexHealthy(const struct mGameDexCapture*);
uint64_t mGameDexFrames(const struct mGameDexCapture*);
void mGameDexAbort(struct mGameDexCapture*, const char* reason);
bool mGameDexStop(struct mGameDexCapture*);
CXX_GUARD_END
#endif
