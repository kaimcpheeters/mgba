/* SPDX-License-Identifier: MPL-2.0 */
#include "gamedex-shell.h"
#include "main.h"
#include "feature/gamedex/capture.h"
#include <mgba/core/core.h>
#include <mgba/core/config.h>
#include <mgba/core/input.h>
#include <mgba/core/thread.h>
#include <SDL_ttf.h>
#include <json-c/json.h>
#include <algorithm>
#include <cmath>
#include <cctype>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
namespace {
constexpr int W = 1120, H = 800;
const SDL_Color INK{230, 239, 233, 255}, MUTED{144, 164, 156, 255}, GREEN{157, 213, 161, 255};
const SDL_Color PANEL{23, 36, 33, 255}, LINE{49, 68, 59, 255}, RED{255, 99, 88, 255};
const SDL_Rect REC{717, 30, 217, 58}, SETTINGS{950, 30, 146, 58}, PAUSE{660, 672, 132, 42};
const SDL_Rect LIBRARY{908, 738, 188, 36}, CLOSE{929, 140, 143, 40}, FOLDER{893, 208, 179, 40};
std::string field(json_object* o, const char* name, const std::string& fallback = "") {
	json_object* value = nullptr;
	if (!o || !json_object_object_get_ex(o, name, &value) || !json_object_is_type(value, json_type_string)) return fallback;
	return json_object_get_string(value);
}
double number(json_object* o, const char* name) {
	json_object* value = nullptr;
	return o && json_object_object_get_ex(o, name, &value) ? json_object_get_double(value) : 0;
}
std::string duration(double seconds) {
	unsigned n = std::isfinite(seconds) ? unsigned(std::clamp(seconds, 0.0, 3599999.0)) : 0;
	char text[32]; snprintf(text, sizeof(text), "%02u:%02u", n / 60, n % 60); return text;
}
std::string niceTitle(std::string title) {
	if (title.find("POKEMON EMER") != std::string::npos) return "Pokemon Emerald";
	return title.empty() ? "Game Boy Advance" : title;
}
std::string fileURL(const fs::path& p) {
	std::ostringstream out; out << "file://";
	for (unsigned char c : fs::absolute(p).string()) {
		if (isalnum(c) || c == '/' || c == '-' || c == '_' || c == '.' || c == '~') out << c;
		else out << '%' << std::uppercase << std::hex << std::setw(2) << std::setfill('0') << unsigned(c);
	}
	return out.str();
}
bool inside(const SDL_Rect& r, int x, int y) { return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h; }
}

struct GameDexShell {
	mSDLRenderer* view;
	mCoreThread* thread;
	SDL_Renderer* renderer;
	mGameDexCapture* capture = nullptr;
	fs::path library, current;
	bool settings = false, resumeAfterSettings = false, focused = true, resumeAfterFocus = false;
	bool failed = false, ttf = false;
	int scroll = 0, hoverX = -1, hoverY = -1;
	std::string title, message = "Your game is ready. Click the recording light whenever you are.", fontPath;
	std::map<int, TTF_Font*> fonts;
	struct Label { SDL_Texture* texture; int w, h; };
	std::map<std::string, Label> labels;
	struct Recording { fs::path dir; std::string title, date, state; double seconds = 0; bool complete = false; };
	std::vector<Recording> recordings;
	// Test mode only: inject real SDL events through the same UI handlers.
	fs::path testOutput;
	unsigned ticks = 0;
	Uint64 lastTick = 0;

	GameDexShell(mSDLRenderer* v, mCoreThread* t) : view(v), thread(t), renderer(v->sdlRenderer) {
		if (TTF_Init() < 0) throw std::runtime_error(TTF_GetError());
		ttf = true;
		const char* custom = getenv("GAMEDEX_FONT");
		const char* candidates[] = {custom, "/System/Library/Fonts/Supplemental/Arial.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "C:/Windows/Fonts/arial.ttf"};
		for (const char* path : candidates) if (path && fs::is_regular_file(path)) { fontPath = path; break; }
		if (fontPath.empty()) throw std::runtime_error("No UI font found. Set GAMEDEX_FONT to a TrueType font.");
		font(18);
		const char* configured = mCoreConfigGetValue(&v->core->config, "gamedexLibrary");
		const char* home = getenv("HOME");
		if (!home) home = getenv("USERPROFILE");
		if (!configured && !home) throw std::runtime_error("Set gamedexLibrary to a recordings folder");
		library = configured ? fs::path(configured) : fs::path(home) / "Documents" / "GameDex Recordings";
		fs::create_directories(library);
		mCoreThreadInterrupt(thread);
		mGameInfo info{}; v->core->getGameInfo(v->core, &info);
		for (char c : info.title) { if (!c) break; title += c >= 32 && c < 127 ? c : '?'; }
		mCoreThreadContinue(thread);
		title = niceTitle(title);
		SDL_SetWindowTitle(v->window, ("GameDex - " + title).c_str());
		SDL_SetWindowResizable(v->window, SDL_TRUE);
		SDL_SetWindowMinimumSize(v->window, 840, 600);
		SDL_SetWindowSize(v->window, W, H);
		SDL_RenderSetLogicalSize(renderer, W, H);
		SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
		const char* test = mCoreConfigGetValue(&v->core->config, "gamedexShellTest");
		if (test) { testOutput = test; fs::create_directories(testOutput); }
		fprintf(stderr, "GameDex shell ready; recording is OFF. Library: %s\n", library.string().c_str());
	}
	~GameDexShell() {
		for (auto& item : labels) SDL_DestroyTexture(item.second.texture);
		for (auto& item : fonts) TTF_CloseFont(item.second);
		if (ttf) TTF_Quit();
	}
	TTF_Font* font(int size) {
		auto it = fonts.find(size); if (it != fonts.end()) return it->second;
		TTF_Font* f = TTF_OpenFont(fontPath.c_str(), size);
		if (!f) throw std::runtime_error(TTF_GetError());
		fonts[size] = f; return f;
	}
	void rect(SDL_Rect r, SDL_Color color, int radius = 0) {
		SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
		if (!radius) { SDL_RenderFillRect(renderer, &r); return; }
		for (int y = 0; y < r.h; ++y) {
			int inset = 0;
			if (y < radius || y >= r.h - radius) {
				float dy = y < radius ? radius - y - .5f : y - (r.h - radius) + .5f;
				inset = radius - int(std::sqrt(float(radius * radius) - dy * dy));
			}
			SDL_RenderDrawLine(renderer, r.x + inset, r.y + y, r.x + r.w - inset - 1, r.y + y);
		}
	}
	void text(const std::string& s, int x, int y, int size = 18, SDL_Color color = INK, int maxWidth = 0) {
		if (s.empty()) return;
		std::string value = s;
		if (maxWidth) {
			int width; TTF_SizeUTF8(font(size), value.c_str(), &width, nullptr);
			while (width > maxWidth && value.size() > 4) {
				size_t end = value.size() - 1;
				while (end && (static_cast<unsigned char>(value[end]) & 0xC0) == 0x80) --end;
				value.resize(end);
				TTF_SizeUTF8(font(size), (value + "...").c_str(), &width, nullptr);
			}
			if (value != s) value += "...";
		}
		std::string key = std::to_string(size) + "/" + std::to_string(color.r) + "/" + std::to_string(color.g) + "/" + std::to_string(color.b) + "/" + value;
		auto found = labels.find(key);
		if (found == labels.end()) {
			if (labels.size() > 512) { for (auto& p : labels) SDL_DestroyTexture(p.second.texture); labels.clear(); }
			SDL_Surface* surface = TTF_RenderUTF8_Blended(font(size), value.c_str(), color);
			if (!surface) return;
			Label label{SDL_CreateTextureFromSurface(renderer, surface), surface->w, surface->h};
			SDL_FreeSurface(surface);
			found = labels.emplace(key, label).first;
		}
		SDL_Rect dst{x, y, found->second.w, found->second.h};
		if (found->second.texture) SDL_RenderCopy(renderer, found->second.texture, nullptr, &dst);
	}
	void button(SDL_Rect r, const std::string& label, bool enabled = true, bool primary = false) {
		bool hover = enabled && inside(r, hoverX, hoverY);
		rect(r, primary ? GREEN : hover ? SDL_Color{57, 77, 64, 255} : LINE, 9);
		int tw, th; TTF_SizeUTF8(font(16), label.c_str(), &tw, &th);
		text(label, r.x + (r.w - tw) / 2, r.y + (r.h - th) / 2, 16, !enabled ? MUTED : primary ? PANEL : INK);
	}
	void clearKeys() {
		mCoreThreadInterrupt(thread); thread->core->setKeys(thread->core, 0); mCoreThreadContinue(thread);
	}
	void browse(bool open) {
		if (settings == open) return;
		settings = open;
		if (open) {
			resumeAfterSettings = !mCoreThreadIsPaused(thread);
			mCoreThreadPause(thread); clearKeys(); scan();
		} else if (resumeAfterSettings && focused) mCoreThreadUnpause(thread);
	}
	void scan() {
		recordings.clear();
		try {
			for (const auto& entry : fs::directory_iterator(library)) {
				if (!entry.is_directory()) continue;
				fs::path metadata = entry.path() / "metadata.json";
				if (!fs::is_regular_file(metadata) || fs::file_size(metadata) > 4 * 1024 * 1024) continue;
				json_object* object = json_object_from_file(metadata.string().c_str());
				if (!object) continue;
				Recording r; r.dir = entry.path(); r.title = niceTitle(field(object, "game_name", entry.path().filename().string()));
				r.date = field(object, "start_time"); r.seconds = number(object, "duration_seconds");
				std::replace(r.date.begin(), r.date.end(), 'T', ' ');
				if (!r.date.empty() && r.date.back() == 'Z') r.date.replace(r.date.size() - 1, 1, " UTC");
				json_object* extension = nullptr; json_object* complete = nullptr;
				if (json_object_object_get_ex(object, "mgba_capture", &extension)) {
					r.complete = json_object_object_get_ex(extension, "complete", &complete) && json_object_get_boolean(complete);
				} else r.complete = number(object, "duration_seconds") > 0;
				r.complete = r.complete && fs::is_regular_file(r.dir / "video.mp4");
				r.state = capture && r.dir == current ? "Recording" : r.complete ? "Saved" : "Incomplete";
				json_object_put(object); recordings.push_back(r);
			}
			std::sort(recordings.begin(), recordings.end(), [](const Recording& a, const Recording& b) { return a.date > b.date; });
			scroll = std::clamp(scroll, 0, std::max(0, int(recordings.size()) - 5));
		} catch (const std::exception& e) { message = std::string("Could not read recordings: ") + e.what(); }
	}
	void toggle() {
		mCoreThreadInterrupt(thread);
		if (capture) {
			bool okay = mGameDexStop(capture); capture = nullptr;
			message = okay ? "Recording saved. Keep playing, or start another take." : "Recording could not be finalized. Open Settings to inspect its files.";
			failed = !okay;
		} else {
			try {
				time_t now = time(nullptr); struct tm local{};
#ifdef _WIN32
				localtime_s(&local, &now);
#else
				localtime_r(&now, &local);
#endif
				char name[64]; strftime(name, sizeof(name), "mgba-%Y%m%d-%H%M%S", &local);
				current = library / name;
				for (unsigned i = 1; fs::exists(current); ++i) current = library / (std::string(name) + "-" + std::to_string(i));
				capture = mGameDexStart(thread->core, current.string().c_str());
				failed = !capture;
				message = capture ? "Recording game video, audio and controls. Click the light to save." : "Could not start recording. Check the recordings folder and free disk space.";
			} catch (const std::exception& e) { failed = true; message = e.what(); }
		}
		mCoreThreadContinue(thread);
		if (settings) scan();
	}
	void open(const fs::path& path) {
		if (SDL_OpenURL(fileURL(path).c_str()) < 0) message = std::string("Could not open file: ") + SDL_GetError();
	}
	bool event(const SDL_Event& e) {
		if (e.type == SDL_QUIT) return false;
		if (e.type == SDL_WINDOWEVENT && e.window.event == SDL_WINDOWEVENT_FOCUS_LOST) {
			focused = false; resumeAfterFocus = !mCoreThreadIsPaused(thread);
			mCoreThreadPause(thread); clearKeys(); return false;
		}
		if (e.type == SDL_WINDOWEVENT && e.window.event == SDL_WINDOWEVENT_FOCUS_GAINED) {
			focused = true;
			if (resumeAfterFocus && !settings) mCoreThreadUnpause(thread);
			return false;
		}
		if (e.type == SDL_KEYDOWN && !e.key.repeat) {
			if (e.key.keysym.sym == SDLK_F10) { toggle(); return true; }
			if (e.key.keysym.sym == SDLK_F11 || e.key.keysym.sym == SDLK_ESCAPE) { browse(!settings); return true; }
		}
		if (e.type == SDL_MOUSEWHEEL && settings) { scroll = std::clamp(scroll - e.wheel.y, 0, std::max(0, int(recordings.size()) - 5)); return true; }
		if (e.type == SDL_MOUSEBUTTONDOWN && e.button.button == SDL_BUTTON_LEFT) {
			int x = e.button.x, y = e.button.y;
			if (inside(REC, x, y)) { toggle(); return true; }
			if (inside(SETTINGS, x, y)) { browse(!settings); return true; }
			if (!settings) {
				if (inside(LIBRARY, x, y)) browse(true);
				if (inside(PAUSE, x, y)) { mCoreThreadTogglePause(thread); clearKeys(); }
			} else {
				if (inside(CLOSE, x, y)) browse(false);
				if (inside(FOLDER, x, y)) open(library);
				for (int i = 0; i < 5 && i + scroll < int(recordings.size()); ++i) {
					auto& r = recordings[i + scroll]; int yy = 310 + i * 76;
					if (inside({854, yy + 12, 94, 36}, x, y) && r.complete) open(r.dir / "video.mp4");
					if (inside({960, yy + 12, 88, 36}, x, y)) open(r.dir);
				}
			}
			return true;
		}
		if ((settings || !focused) && (e.type == SDL_KEYDOWN || e.type == SDL_KEYUP || e.type == SDL_CONTROLLERBUTTONDOWN || e.type == SDL_CONTROLLERBUTTONUP || e.type == SDL_CONTROLLERAXISMOTION)) return true;
		return false;
	}
	void screenshot(const char* name) {
		int w, h; SDL_GetRendererOutputSize(renderer, &w, &h);
		SDL_Surface* image = SDL_CreateRGBSurfaceWithFormat(0, w, h, 32, SDL_PIXELFORMAT_RGBA32);
		if (image) {
			if (SDL_RenderReadPixels(renderer, nullptr, image->format->format, image->pixels, image->pitch) == 0) SDL_SaveBMP(image, (testOutput / name).string().c_str());
			SDL_FreeSurface(image);
		}
	}
	void tick() {
		if (capture && !mGameDexHealthy(capture)) toggle();
		if (SDL_GetTicks64() - lastTick < 16) return;
		lastTick = SDL_GetTicks64();
		++ticks;
		if (testOutput.empty()) return;
		SDL_Event e{};
		if (ticks == 45 || ticks == 150 || ticks == 175 || ticks == 260 || ticks == 345) {
			e.type = SDL_MOUSEBUTTONDOWN; e.button.button = SDL_BUTTON_LEFT; e.button.x = REC.x + 30; e.button.y = REC.y + 25; SDL_PushEvent(&e);
		}
		if (ticks == 30 || ticks == 100) {
			e.type = ticks == 30 ? SDL_KEYDOWN : SDL_KEYUP; e.key.keysym.sym = SDLK_x; SDL_PushEvent(&e);
		}
		if (ticks == 200 || ticks == 220) {
			e.type = SDL_WINDOWEVENT; e.window.event = ticks == 200 ? SDL_WINDOWEVENT_FOCUS_LOST : SDL_WINDOWEVENT_FOCUS_GAINED; SDL_PushEvent(&e);
		}
		if (ticks == 280 || ticks == 340) {
			e.type = SDL_KEYDOWN; e.key.keysym.sym = SDLK_F11; SDL_PushEvent(&e);
		}
		if (ticks == 355) { e.type = SDL_QUIT; SDL_PushEvent(&e); }
	}
	void draw(SDL_Texture* game) {
		int mx, my; SDL_GetMouseState(&mx, &my); float lx, ly;
		SDL_RenderWindowToLogical(renderer, mx, my, &lx, &ly); hoverX = lx; hoverY = ly;
		SDL_SetRenderDrawColor(renderer, 12, 22, 19, 255); SDL_RenderClear(renderer);
		text("GAMEDEX", 24, 29, 30, INK);
		text(title + "  /  Game Boy Advance", 26, 67, 16, MUTED);
		rect(REC, capture ? SDL_Color{68, 28, 26, 255} : SDL_Color{35, 47, 38, 255}, 12);
		SDL_Color lamp = capture ? RED : SDL_Color{104, 130, 110, 255};
		rect({735, 48, 22, 22}, {lamp.r, lamp.g, lamp.b, 50}, 11);
		rect({740, 53, 12, 12}, lamp, 6);
		text(capture ? "RECORDING" : "REC OFF", 764, 41, 17, capture ? RED : INK);
		text(capture ? duration(mGameDexFrames(capture) * double(thread->core->frameCycles(thread->core)) / thread->core->frequency(thread->core)) + "  /  Click to save" : "Click to record   F10", 764, 65, 12, MUTED);
		button(SETTINGS, settings ? "Back to game" : "Settings   F11");
		if (!settings) {
			rect({24, 116, 792, 604}, PANEL, 18);
			text("GAME SCREEN", 48, 137, 12, MUTED);
			text(mCoreThreadIsPaused(thread) ? "PAUSED" : "LIVE", 744, 137, 12, GREEN);
			rect({52, 172, 736, 488}, {4, 9, 6, 255}, 8);
			SDL_Rect destination{60, 176, 720, 480}; SDL_RenderCopy(renderer, game, nullptr, &destination);
			text("240 x 160  /  Original game pixels", 48, 684, 15, MUTED);
			button(PAUSE, mCoreThreadIsPaused(thread) ? "Resume" : "Pause");
			rect({836, 116, 260, 604}, PANEL, 18);
			text("Your controls", 858, 139, 23);
			text("Keyboard mappings", 858, 171, 14, MUTED);
			const char* names[] = {"A", "B", "Select", "Start", "Right", "Left", "Up", "Down", "R", "L"};
			const int order[] = {6, 7, 5, 4, 0, 1, 9, 8, 3, 2};
			const Uint8* down = SDL_GetKeyboardState(nullptr);
			for (int row = 0; row < 10; ++row) {
				int id = order[row], yy = 211 + row * 43;
				int key = mInputQueryBinding(&thread->core->inputMap, SDL_BINDING_KEY, id);
				std::string name = key < 0 ? "Unbound" : SDL_GetKeyName(key);
				if (name == "Return") name = "Enter";
				SDL_Scancode sc = SDL_GetScancodeFromKey(key);
				bool pressed = focused && !settings && sc != SDL_SCANCODE_UNKNOWN && down[sc];
				text(names[id], 858, yy + 7, 16, MUTED);
				rect({964, yy, 108, 33}, pressed ? GREEN : LINE, 7);
				text(name, 975, yy + 7, 15, pressed ? PANEL : INK, 89);
			}
			text("Keys light up as you play.", 858, 674, 13, MUTED);
			text("Controllers work, too.", 858, 694, 13, MUTED);
		} else drawSettings();
		text(message, 26, 745, 15, failed ? RED : MUTED, 856);
		if (!settings) button(LIBRARY, "View recordings");
		if (!testOutput.empty()) {
			if (ticks == 30) screenshot("standby.bmp");
			if (ticks == 110) screenshot("recording.bmp");
			if (ticks == 300) screenshot("settings.bmp");
		}
		SDL_RenderPresent(renderer);
	}
	void drawSettings() {
		rect({24, 116, 1072, 604}, PANEL, 18);
		text("Settings & recordings", 48, 139, 27);
		button(CLOSE, "Back to game", true, true);
		text("The game is paused while you browse.", 48, 177, 15, MUTED);
		rect({48, 203, 1024, 56}, {30, 47, 39, 255}, 10);
		text("SAVE LOCATION", 63, 211, 11, GREEN);
		text(library.string(), 63, 230, 14, INK, 805);
		button(FOLDER, "Open folder");
		text("Recordings", 48, 278, 18);
		text(std::to_string(recordings.size()) + " sessions  /  newest first", 804, 280, 14, MUTED);
		if (recordings.empty()) {
			text("Your first recording belongs here.", 80, 365, 26);
			text("Return to the game and click the REC OFF light to start a take.", 80, 408, 17, MUTED);
		}
		for (int i = 0; i < 5 && i + scroll < int(recordings.size()); ++i) {
			auto& r = recordings[i + scroll]; int yy = 310 + i * 76;
			rect({48, yy, 1024, 64}, {30, 43, 37, 255}, 9);
			text(r.title, 64, yy + 10, 18, INK, 410);
			text(r.date + "   /   " + duration(r.seconds), 64, yy + 37, 13, MUTED, 650);
			text(r.state, 732, yy + 24, 14, r.complete ? GREEN : MUTED);
			button({854, yy + 12, 94, 36}, "Video", r.complete);
			button({960, yy + 12, 88, 36}, "Files");
		}
		text("Video opens the picture track. Files includes game audio and input logs.", 48, 696, 12, MUTED);
		if (recordings.size() > 5) text("Scroll for more", 957, 696, 12, GREEN);
	}
};

extern "C" GameDexShell* GameDexShellCreate(mSDLRenderer* r, mCoreThread* t) {
	try { return new GameDexShell(r, t); }
	catch (const std::exception& e) { fprintf(stderr, "Cannot start GameDex shell: %s\n", e.what()); return nullptr; }
}
extern "C" bool GameDexShellEvent(GameDexShell* s, const SDL_Event* e) { return s->event(*e); }
extern "C" void GameDexShellTick(GameDexShell* s) { s->tick(); }
extern "C" void GameDexShellDraw(GameDexShell* s, SDL_Texture* t) { s->draw(t); }
extern "C" void GameDexShellDestroy(GameDexShell* s) {
	// Caller has joined the emulation thread before detaching the recorder.
	if (s->capture) {
		if (!mGameDexStop(s->capture)) fprintf(stderr, "GameDex: failed to finalize recording on exit\n");
		s->capture = nullptr;
	}
	delete s;
}
