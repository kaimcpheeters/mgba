/* Deterministic integration driver; uses an original generated test ROM. MPL-2.0. */
#include "capture.h"
#include <mgba/core/core.h>
#include <mgba/core/config.h>
#include <mgba/gba/core.h>
#include <vector>
#include <cstring>
#include <cstdio>
#include <thread>
#include <chrono>
#ifndef _WIN32
#include <sys/resource.h>
#include <csignal>
#endif

int main(int argc, char** argv) {
	if (argc < 3) return 2;
	mCore* core = GBACoreCreate();
	if (!core || !core->init(core)) return 3;
	mCoreInitConfig(core, nullptr);
	mCoreOptions opts{};
	opts.useBios = false; opts.skipBios = true; opts.volume = 0x100; opts.audioBuffers = 1024;
	mCoreConfigLoadDefaults(&core->config, &opts);
	mCoreConfigSetIntValue(&core->config, "allowOpposingDirections", 0);
	mCoreLoadConfig(core);
	std::vector<mColor> pixels(256 * 160);
	core->setVideoBuffer(core, pixels.data(), 256); // Exercise a padded stride.
	if (!mCoreLoadFile(core, argv[1])) return 4;
	core->reset(core);
	mGameDexCapture* capture = mGameDexStart(core, argv[2]);
	if (!capture) { core->deinit(core); return 5; }
	#ifndef _WIN32
	bool diskFull = argc > 3 && !strcmp(argv[3], "disk-full");
	if (diskFull) {
		signal(SIGXFSZ, SIG_IGN);
		struct rlimit limit = {1024, 1024};
		if (setrlimit(RLIMIT_FSIZE, &limit)) return 7;
	}
#else
	bool diskFull = false;
#endif
	bool discontinuity = argc > 3 && (!strcmp(argv[3], "reset") || !strcmp(argv[3], "load"));
	unsigned count = argc > 3 && !strcmp(argv[3], "long") ? 600 : 180;
	for (unsigned i = 0; i < count && mGameDexHealthy(capture); ++i) {
		unsigned mask = i < 30 ? 1 : i < 60 ? 2 : i < 90 ? 0x30 : i < 120 ? 0x81 : 0;
		if (argc > 3 && !strcmp(argv[3], "all-keys")) mask = 1U << ((i / 10) % 10);
		core->setKeys(core, mask);
		// Real emulated KEYINPUT reads, including opposing-direction normalization.
		core->busRead16(core, 0x04000130);
		core->runFrame(core);
		if (i == 80 && argc > 3 && !strcmp(argv[3], "audio-rate")) core->busWrite16(core, 0x04000088, 0x4200);
		if (i == 70 && argc > 3 && !strcmp(argv[3], "pause")) std::this_thread::sleep_for(std::chrono::milliseconds(80));
		if (i == 80 && discontinuity) {
			if (!strcmp(argv[3], "reset")) core->reset(core);
			else {
				std::vector<uint8_t> state(core->stateSize(core));
				core->saveState(core, state.data()); core->loadState(core, state.data());
			}
		}
	}
	bool result = mGameDexStop(capture);
	core->unloadROM(core);
	mCoreConfigDeinit(&core->config);
	core->deinit(core);
	return result == !(discontinuity || diskFull) ? 0 : 6;
}
