/* SPDX-License-Identifier: MPL-2.0 */
#ifndef GAMEDEX_SHELL_H
#define GAMEDEX_SHELL_H
#include <mgba-util/common.h>
#include <SDL.h>
CXX_GUARD_START
struct mSDLRenderer;
struct mCoreThread;
struct GameDexShell;
struct GameDexShell* GameDexShellCreate(struct mSDLRenderer*, struct mCoreThread*);
bool GameDexShellEvent(struct GameDexShell*, const SDL_Event*);
void GameDexShellTick(struct GameDexShell*);
void GameDexShellDraw(struct GameDexShell*, SDL_Texture*);
void GameDexShellDestroy(struct GameDexShell*);
CXX_GUARD_END
#endif
