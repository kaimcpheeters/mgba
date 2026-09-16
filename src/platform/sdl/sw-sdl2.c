/* Copyright (c) 2013-2015 Jeffrey Pfau
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */
#include "main.h"
#ifdef BUILD_GAMEDEX_SHELL
#include "gamedex-shell.h"
#endif

#include <mgba/core/core.h>
#include <mgba/core/thread.h>
#include <mgba/core/version.h>

static bool mSDLSWInit(struct mSDLRenderer* renderer);
static void mSDLSWRunloop(struct mSDLRenderer* renderer, void* user);
static void mSDLSWDeinit(struct mSDLRenderer* renderer);

void mSDLSWCreate(struct mSDLRenderer* renderer) {
	renderer->init = mSDLSWInit;
	renderer->deinit = mSDLSWDeinit;
	renderer->runloop = mSDLSWRunloop;
}

bool mSDLSWInit(struct mSDLRenderer* renderer) {
	unsigned width, height;
	renderer->core->baseVideoSize(renderer->core, &width, &height);
#if SDL_VERSION_ATLEAST(3, 0, 0)
	renderer->window = SDL_CreateWindow(projectName, renderer->viewportWidth, renderer->viewportHeight, SDL_WINDOW_FULLSCREEN * renderer->player.fullscreen);
	renderer->sdlRenderer = SDL_CreateRenderer(renderer->window, NULL);
	SDL_SetRenderVSync(renderer->sdlRenderer, 1);
#else
	renderer->window = SDL_CreateWindow(projectName, SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, renderer->viewportWidth, renderer->viewportHeight, SDL_WINDOW_FULLSCREEN_DESKTOP * renderer->player.fullscreen);
	renderer->sdlRenderer = SDL_CreateRenderer(renderer->window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
#endif
	if (!renderer->window) return false;
	if (!renderer->sdlRenderer) {
#if SDL_VERSION_ATLEAST(3, 0, 0)
		renderer->sdlRenderer = SDL_CreateRenderer(renderer->window, "software");
#else
		renderer->sdlRenderer = SDL_CreateRenderer(renderer->window, -1, SDL_RENDERER_SOFTWARE);
#endif
	}
	if (!renderer->sdlRenderer) return false;
	SDL_GetWindowSize(renderer->window, &renderer->viewportWidth, &renderer->viewportHeight);
	renderer->player.window = renderer->window;
#ifdef COLOR_16_BIT
#ifdef COLOR_5_6_5
	renderer->sdlTex = SDL_CreateTexture(renderer->sdlRenderer, SDL_PIXELFORMAT_RGB565, SDL_TEXTUREACCESS_STREAMING, width, height);
#else
	renderer->sdlTex = SDL_CreateTexture(renderer->sdlRenderer, SDL_PIXELFORMAT_ABGR1555, SDL_TEXTUREACCESS_STREAMING, width, height);
#endif
#else
	renderer->sdlTex = SDL_CreateTexture(renderer->sdlRenderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STREAMING, width, height);
#endif

	if (!renderer->sdlTex) return false;
	int stride;
	if (!SDL_OK(SDL_LockTexture(renderer->sdlTex, 0, (void**) &renderer->outputBuffer, &stride))) return false;
	renderer->core->setVideoBuffer(renderer->core, renderer->outputBuffer, stride / BYTES_PER_PIXEL);

	return true;
}

void mSDLSWRunloop(struct mSDLRenderer* renderer, void* user) {
	struct mCoreThread* context = user;
	SDL_Event event;
#ifdef BUILD_GAMEDEX_SHELL
	struct GameDexShell* shell = NULL;
	bool useShell = false;
	mCoreConfigGetBoolValue(&renderer->core->config, "gamedexShell", &useShell);
	if (useShell) {
		shell = GameDexShellCreate(renderer, context);
		renderer->gameDexShell = shell;
		if (!shell) { mCoreThreadEnd(context); return; }
	}
#endif

	while (mCoreThreadIsActive(context)) {
		while (SDL_PollEvent(&event)) {
#ifdef BUILD_GAMEDEX_SHELL
			if (shell && GameDexShellEvent(shell, &event)) continue;
#endif
			mSDLHandleEvent(context, &renderer->player, &event);
		}

#ifdef BUILD_GAMEDEX_SHELL
		if (shell) GameDexShellTick(shell);
#endif
		if (mCoreSyncWaitFrameStart(&context->impl->sync)) {
			SDL_UnlockTexture(renderer->sdlTex);
#ifdef BUILD_GAMEDEX_SHELL
			if (shell) GameDexShellDraw(shell, renderer->sdlTex);
			else
#endif
			{
				SDL_RenderCopy(renderer->sdlRenderer, renderer->sdlTex, 0, 0);
				SDL_RenderPresent(renderer->sdlRenderer);
			}
			int stride;
			SDL_LockTexture(renderer->sdlTex, 0, (void**) &renderer->outputBuffer, &stride);
			renderer->core->setVideoBuffer(renderer->core, renderer->outputBuffer, stride / BYTES_PER_PIXEL);
		}
		mCoreSyncWaitFrameEnd(&context->impl->sync);
#ifdef BUILD_GAMEDEX_SHELL
		// Settings and recording controls must remain responsive while paused.
		if (shell && mCoreThreadIsPaused(context)) {
			GameDexShellDraw(shell, renderer->sdlTex);
			SDL_Delay(16);
		} else if (shell) SDL_Delay(1);
#endif
	}
}

void mSDLSWDeinit(struct mSDLRenderer* renderer) {
	/* outputBuffer belongs to the locked SDL texture, at every scale. */
	SDL_UnlockTexture(renderer->sdlTex);
	SDL_DestroyTexture(renderer->sdlTex);
	SDL_DestroyRenderer(renderer->sdlRenderer);
	renderer->outputBuffer = NULL;
}
