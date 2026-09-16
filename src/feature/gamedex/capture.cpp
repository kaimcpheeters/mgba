/* Native emulator capture and GameDex 1.2.1 export. MPL-2.0. */
#include "capture.h"
#include <mgba/core/core.h>
#include <mgba/core/timing.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
}
#include <array>
#include <atomic>
#include <mgba/internal/gba/gba.h>
#include <deque>
#include <fstream>
#include <iomanip>
#include <locale>
#include <memory>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <ctime>
#include <sys/stat.h>
#ifdef _WIN32
#include <direct.h>
#endif

namespace {
constexpr unsigned FPS = 60, RATE = 44100;
// Canonical virtual keyboard, independent of the user's physical bindings.
const char* KEYS[10] = {"x", "z", "Key.backspace", "Key.enter", "Key.right", "Key.left", "Key.up", "Key.down", "s", "a"};
std::string quote(const std::string& s) {
	std::ostringstream o;
	o << '"';
	for (unsigned char c : s) {
		if (c == '"' || c == '\\') o << '\\' << c;
		else if (c < 32) o << "\\u" << std::hex << std::setw(4) << std::setfill('0') << unsigned(c);
		else o << c;
	}
	o << '"';
	return o.str();
}
std::string keys(unsigned mask) {
	std::string s = "[";
	for (unsigned i = 0; i < 10; ++i) if (mask & (1U << i)) {
		if (s.size() > 1) s += ',';
		s += quote(KEYS[i]);
	}
	return s + "]";
}
std::string now() {
	time_t t = time(nullptr);
	struct tm value;
#ifdef _WIN32
	gmtime_s(&value, &t);
#else
	gmtime_r(&t, &value);
#endif
	char buf[32];
	strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &value);
	return buf;
}
std::string uuid() {
	std::random_device r;
	std::array<unsigned char, 16> b;
	for (auto& v : b) v = static_cast<unsigned char>(r());
	b[6] = (b[6] & 15) | 0x40; b[8] = (b[8] & 63) | 0x80;
	std::ostringstream o;
	for (unsigned i = 0; i < b.size(); ++i) {
		if (i == 4 || i == 6 || i == 8 || i == 10) o << '-';
		o << std::hex << std::setw(2) << std::setfill('0') << unsigned(b[i]);
	}
	return o.str();
}
void check(int result, const char* operation) {
	if (result >= 0) return;
	char error[AV_ERROR_MAX_STRING_SIZE];
	av_strerror(result, error, sizeof(error));
	throw std::runtime_error(std::string(operation) + ": " + error);
}
void le(std::ostream& out, uint32_t value, unsigned bytes) {
	for (unsigned i = 0; i < bytes; ++i) out.put(static_cast<char>(value >> (i * 8)));
}
}

struct CaptureAV {
	mAVStream d{};
	mGameDexCapture* owner = nullptr;
};

struct mGameDexCapture {
	CaptureAV av;
	mCoreCallbacks callbacks{};
	mCore* core;
	std::string dir, id = uuid(), started = now(), game, error;
	std::ofstream actions, events, polls, mapping, audio;
	AVFormatContext* format = nullptr;
	AVCodecContext* encoder = nullptr;
	AVFrame* frame = nullptr;
	AVPacket* packet = nullptr;
	AVStream* stream = nullptr;
	SwsContext* scale = nullptr;
	SwrContext* resample = nullptr;
	unsigned width = 0, height = 0, inputRate = 0, observed = 0, held = 0, used = 0;
	uint64_t origin = 0, lastCycle = 0, frames = 0, keyEvents = 0, samples = 0;
	std::atomic<uint64_t> nativeFrames{0};
	std::atomic<bool> healthy{true};
	uint64_t imageCycle = 0;
	int64_t imageFrame = -1;
	uint64_t frequency;
	bool attached = false, header = false, waitingForFrame = true;
	struct Transition { uint64_t cycle; unsigned mask; };
	std::deque<Transition> pending;
	std::vector<uint8_t> rgb;

	explicit mGameDexCapture(mCore* c, const char* d) : core(c), dir(d), frequency(c->frequency(c)) { av.owner = this; }
	~mGameDexCapture() {
		if (attached) { core->setAVStream(core, nullptr); core->removeCoreCallbacks(core, &callbacks); }
		if (format && format->pb) avio_closep(&format->pb);
		avformat_free_context(format);
		avcodec_free_context(&encoder);
		av_frame_free(&frame);
		av_packet_free(&packet);
		sws_freeContext(scale);
		swr_free(&resample);
	}
	void fail(const char* message) {
		if (!error.empty()) return;
		error = message;
		healthy.store(false);
		fprintf(stderr, "GameDex capture failed: %s\n", message);
	}
	template<typename F> void guard(F f) {
		if (!error.empty()) return;
		try { f(); } catch (const std::exception& e) { fail(e.what()); }
	}
	uint64_t clock() {
		uint64_t value = mTimingGlobalTime(core->timing);
		if (value < origin || value - origin < lastCycle) throw std::runtime_error("Emulation timeline changed; start a new session");
		lastCycle = value - origin;
		return lastCycle;
	}
	void openFile(std::ofstream& f, const char* name) {
		f.exceptions(std::ios::failbit | std::ios::badbit);
		f.imbue(std::locale::classic());
		f.open(dir + "/" + name, std::ios::binary);
		f << std::setprecision(15);
	}
	void metadata(bool complete) {
		std::ofstream f;
		openFile(f, "metadata.json.tmp");
		f << "{\n\"session_id\":" << quote(id) << ",\"game_name\":" << quote(game)
		  << ",\"start_time\":" << quote(started) << ",\"end_time\":" << (complete ? quote(now()) : "null")
		  << ",\"duration_seconds\":" << double(frames) / FPS << ",\"upload_status\":\"" << (complete ? "pending" : "failed") << "\",\n"
		  << "\"video\":{\"width\":" << width << ",\"height\":" << height
		  << ",\"fps\":60,\"codec\":\"h264\",\"encoder\":\"libx264\",\"crf\":18,\"total_frames\":" << frames << "},\n"
		  << "\"audio\":{\"enabled\":true,\"saved\":" << (complete ? "true" : "false") << ",\"sample_rate\":44100,\"channels\":2,\"format\":\"wav\"},\n"
		  << "\"stats\":{\"total_key_events\":" << keyEvents << ",\"total_mouse_events\":0,\"total_controller_events\":0,\"unique_keys_used\":" << keys(used)
		  << ",\"controllers_used\":[],\"dropped_frames\":0},\n"
#ifdef __APPLE__
		  << "\"system\":{\"os\":\"macos\",\"rust_version\":\"not applicable (mGBA C/C++)\"},\n"
#elif defined(_WIN32)
		  << "\"system\":{\"os\":\"windows\",\"rust_version\":\"not applicable (mGBA C/C++)\"},\n"
#else
		  << "\"system\":{\"os\":\"linux\",\"rust_version\":\"not applicable (mGBA C/C++)\"},\n"
#endif
		  << "\"mgba_capture\":{\"version\":1,\"complete\":" << (complete ? "true" : "false")
		  << ",\"clock_hz\":" << frequency << ",\"native_frame_cycles\":" << core->frameCycles(core)
		  << ",\"origin_cycle\":" << origin << ",\"native_frames\":" << nativeFrames << ",\"emulated_cycles\":" << lastCycle
		  << ",\"input_semantics\":\"sampled GBA buttons mapped to virtual keys\",\"button_keys\":[";
		for (unsigned i = 0; i < 10; ++i) f << (i ? "," : "") << quote(KEYS[i]);
		f << "],\"error\":" << (error.empty() ? "null" : quote(error)) << "}}\n";
		f.close();
		if (rename((dir + "/metadata.json.tmp").c_str(), (dir + "/metadata.json").c_str())) throw std::runtime_error("Cannot publish metadata");
	}
	void wavHeader(uint32_t bytes) {
		audio.seekp(0);
		audio.write("RIFF", 4); le(audio, bytes + 36, 4); audio.write("WAVEfmt ", 8);
		le(audio, 16, 4); le(audio, 1, 2); le(audio, 2, 2); le(audio, RATE, 4);
		le(audio, RATE * 4, 4); le(audio, 4, 2); le(audio, 16, 2);
		audio.write("data", 4); le(audio, bytes, 4);
	}
	void writeSamples(const int16_t* buffer, int count) {
		if ((samples + count) * 4 > UINT32_MAX - 36) throw std::runtime_error("WAV 4 GiB limit reached; start a new session");
		for (int i = 0; i < count * 2; ++i) le(audio, static_cast<uint16_t>(buffer[i]), 2);
		samples += count;
	}
	void flushAudio() {
		if (!resample) return;
		int16_t buffer[4096];
		uint8_t* out[] = {reinterpret_cast<uint8_t*>(buffer)};
		for (;;) {
			int n = swr_convert(resample, out, 2048, nullptr, 0);
			check(n, "Flush audio");
			if (!n) break;
			writeSamples(buffer, n);
		}
	}
	void rate(unsigned value) {
		if (value == inputRate) return;
		flushAudio(); swr_free(&resample);
		AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
		check(swr_alloc_set_opts2(&resample, &stereo, AV_SAMPLE_FMT_S16, RATE, &stereo, AV_SAMPLE_FMT_S16, value, 0, nullptr), "Audio resampler");
		check(swr_init(resample), "Initialize audio resampler");
		inputRate = value;
	}
	void sound(int16_t left, int16_t right) {
		if (waitingForFrame) return;
		int16_t inBuffer[] = {left, right}, outBuffer[64];
		const uint8_t* in[] = {reinterpret_cast<uint8_t*>(inBuffer)};
		uint8_t* out[] = {reinterpret_cast<uint8_t*>(outBuffer)};
		int n = swr_convert(resample, out, 32, in, 1);
		check(n, "Resample audio"); writeSamples(outBuffer, n);
	}
	void receive() {
		for (;;) {
			int result = avcodec_receive_packet(encoder, packet);
			if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return;
			check(result, "Encode video");
			av_packet_rescale_ts(packet, encoder->time_base, stream->time_base);
			packet->stream_index = stream->index;
			packet->duration = av_rescale_q(1, encoder->time_base, stream->time_base);
			result = av_interleaved_write_frame(format, packet);
			av_packet_unref(packet);
			check(result, "Write video");
		}
	}
	void emitUntil(uint64_t cycle) {
		while (frames * frequency < cycle * FPS) {
			while (!pending.empty() && pending.front().cycle * FPS <= frames * frequency) {
				held = pending.front().mask; pending.pop_front();
			}
			check(av_frame_make_writable(frame), "Video buffer");
			const uint8_t* src[] = {rgb.data()}; int strides[] = {int(width * 3)};
			if (sws_scale(scale, src, strides, 0, height, frame->data, frame->linesize) != int(height)) throw std::runtime_error("Video color conversion failed");
			frame->pts = frames;
			check(avcodec_send_frame(encoder, frame), "Submit video"); receive();
			actions << "{\"frame_id\":" << frames << ",\"timestamp_ms\":" << double(frames) * 1000 / FPS
			        << ",\"inputs\":{\"keys\":" << keys(held) << ",\"mouse\":{\"x\":0,\"y\":0,\"buttons\":{\"left\":false,\"right\":false,\"middle\":false}}}}\n";
			mapping << "{\"frame_id\":" << frames << ",\"native_frame\":" << imageFrame << ",\"source_cycle\":" << imageCycle << "}\n";
			++frames;
		}
	}
	void copyPixels(const mColor* pixels, size_t stride) {
		for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) {
			mColor c = pixels[y * stride + x];
			size_t i = (y * width + x) * 3;
#ifndef COLOR_16_BIT
			rgb[i] = c & 255; rgb[i + 1] = (c >> 8) & 255; rgb[i + 2] = (c >> 16) & 255;
#elif defined(COLOR_5_6_5)
			rgb[i] = (c & 31) * 255 / 31; rgb[i + 1] = ((c >> 5) & 63) * 255 / 63; rgb[i + 2] = ((c >> 11) & 31) * 255 / 31;
#else
			rgb[i] = (c & 31) * 255 / 31; rgb[i + 1] = ((c >> 5) & 31) * 255 / 31; rgb[i + 2] = ((c >> 10) & 31) * 255 / 31;
#endif
		}
	}
	void video(const mColor* pixels, size_t stride) {
		if (waitingForFrame) {
			// Arm at the next completed frame: never export a half-rendered start image.
			origin = mTimingGlobalTime(core->timing);
			lastCycle = 0;
			copyPixels(pixels, stride);
			imageFrame = nativeFrames++; imageCycle = 0;
			// Seed held state from the last KEYINPUT result, without inventing an input poll.
			held = observed = (static_cast<GBA*>(core->board)->memory.io[0x130 / 2] ^ 0x3FF) & 0x3FF;
			used = held;
			for (unsigned i = 0; i < 10; ++i) if (held & (1U << i)) {
				events << "{\"timestamp_ms\":0,\"type\":\"key_press\",\"data\":{\"key\":" << quote(KEYS[i]) << "}}\n";
				++keyEvents;
			}
			waitingForFrame = false;
			return;
		}
		uint64_t cycle = clock();
		emitUntil(cycle); // Sample-and-hold the last completed frame; no future pixels.
		copyPixels(pixels, stride);
		imageFrame = nativeFrames++; imageCycle = cycle;
	}
	void input(uint16_t mask) {
		if (waitingForFrame) return;
		uint64_t cycle = clock();
		polls << "{\"cycle\":" << cycle << ",\"native_frame\":" << nativeFrames << ",\"buttons\":" << mask << "}\n";
		if (mask == observed) return;
		for (unsigned i = 0; i < 10; ++i) if ((mask ^ observed) & (1U << i)) {
			events << "{\"timestamp_ms\":" << double(cycle) * 1000 / frequency << ",\"type\":\"key_" << ((mask & (1U << i)) ? "press" : "release")
			       << "\",\"data\":{\"key\":" << quote(KEYS[i]) << "}}\n";
			++keyEvents;
		}
		used |= mask; observed = mask; pending.push_back({cycle, mask});
	}
	void start() {
		if (core->platform(core) != mPLATFORM_GBA) throw std::runtime_error("GameDex capture currently supports GBA only");
		if (core->opts.frameskip) throw std::runtime_error("Disable frameskip for capture");
#ifdef _WIN32
		if (_mkdir(dir.c_str()))
#else
		if (mkdir(dir.c_str(), 0700))
#endif
			throw std::runtime_error("Capture directory must be new, with an existing parent");
		core->currentVideoSize(core, &width, &height);
		if (width != 240 || height != 160) throw std::runtime_error("Capture requires native 240x160 GBA rendering");
		mGameInfo info{}; core->getGameInfo(core, &info);
		for (unsigned i = 0; i < sizeof(info.title) && info.title[i]; ++i) {
			unsigned char c = info.title[i];
			game += c >= 32 && c < 127 ? char(c) : '?';
		}
		origin = mTimingGlobalTime(core->timing);
		openFile(actions, "actions.jsonl"); openFile(events, "events.jsonl");
		openFile(polls, "mgba-inputs.jsonl"); openFile(mapping, "mgba-frames.jsonl");
		openFile(audio, "audio.wav"); wavHeader(0);
		metadata(false);
		check(avformat_alloc_output_context2(&format, nullptr, "mp4", nullptr), "Create MP4");
		const AVCodec* codec = avcodec_find_encoder_by_name("libx264");
		if (!codec) throw std::runtime_error("FFmpeg must include libx264");
		encoder = avcodec_alloc_context3(codec); frame = av_frame_alloc(); packet = av_packet_alloc();
		stream = avformat_new_stream(format, nullptr);
		if (!encoder || !frame || !packet || !stream) throw std::bad_alloc();
		encoder->width = width; encoder->height = height;
		encoder->pix_fmt = AV_PIX_FMT_YUV420P; encoder->time_base = {1, FPS}; encoder->framerate = {FPS, 1};
		encoder->gop_size = FPS; encoder->max_b_frames = 0;
		if (format->oformat->flags & AVFMT_GLOBALHEADER) encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
		check(av_opt_set(encoder->priv_data, "preset", "veryfast", 0), "Encoder preset");
		check(av_opt_set(encoder->priv_data, "crf", "18", 0), "Encoder quality");
		check(avcodec_open2(encoder, codec, nullptr), "Open H.264 encoder");
		check(avcodec_parameters_from_context(stream->codecpar, encoder), "Video parameters");
		stream->time_base = encoder->time_base;
		check(avio_open(&format->pb, (dir + "/video.mp4").c_str(), AVIO_FLAG_WRITE), "Open video.mp4");
		check(avformat_write_header(format, nullptr), "Write MP4 header"); header = true;
		frame->format = encoder->pix_fmt; frame->width = width; frame->height = height;
		check(av_frame_get_buffer(frame, 32), "Allocate video frame");
		scale = sws_getContext(width, height, AV_PIX_FMT_RGB24, width, height, encoder->pix_fmt, SWS_POINT, nullptr, nullptr, nullptr);
		if (!scale) throw std::runtime_error("Cannot allocate color converter");
		rgb.resize(width * height * 3, 0);
		av.d.postVideoFrame = [](mAVStream* a, const mColor* p, size_t s) { auto* c = reinterpret_cast<CaptureAV*>(a)->owner; c->guard([&] { c->video(p, s); }); };
		av.d.postAudioFrame = [](mAVStream* a, int16_t l, int16_t r) { auto* c = reinterpret_cast<CaptureAV*>(a)->owner; c->guard([&] { c->sound(l, r); }); };
		av.d.audioRateChanged = [](mAVStream* a, unsigned r) { auto* c = reinterpret_cast<CaptureAV*>(a)->owner; c->guard([&] { c->rate(r); }); };
		av.d.videoDimensionsChanged = [](mAVStream* a, unsigned w, unsigned h) { auto* c = reinterpret_cast<CaptureAV*>(a)->owner; if (w != c->width || h != c->height) c->fail("Video dimensions changed"); };
		callbacks.context = this;
		callbacks.coreCrashed = [](void* p) { static_cast<mGameDexCapture*>(p)->fail("Emulator core crashed"); };
		callbacks.keysSampled = [](void* p, uint16_t keys) { auto* c = static_cast<mGameDexCapture*>(p); c->guard([&] { c->input(keys); }); };
		callbacks.captureDiscontinuity = [](void* p) { static_cast<mGameDexCapture*>(p)->fail("Reset or state load during capture; start a new session"); };
		core->addCoreCallbacks(core, &callbacks); attached = true;
		core->setAVStream(core, &av.d);
		if (!error.empty()) throw std::runtime_error(error);
	}
	bool finish() {
		core->setAVStream(core, nullptr); core->removeCoreCallbacks(core, &callbacks); attached = false;
		guard([&] {
			if (waitingForFrame) throw std::runtime_error("Recording stopped before the first completed frame");
			emitUntil(clock()); flushAudio();
		});
		try {
			if (header) {
				check(avcodec_send_frame(encoder, nullptr), "Flush encoder"); receive();
				check(av_write_trailer(format), "Finish MP4");
				check(avio_closep(&format->pb), "Close video");
			}
			// Complete the final CFR frame's duration with silence (less than one frame).
			uint64_t expected = frames * (RATE / FPS);
			int16_t silence[2] = {0, 0};
			while (samples < expected) writeSamples(silence, 1);
			wavHeader(samples * 4); audio.close();
			actions.close(); events.close(); polls.close(); mapping.close();
		} catch (const std::exception& e) { fail(e.what()); }
		if (!frames) fail("No frames captured");
		try { metadata(error.empty()); } catch (const std::exception& e) { fail(e.what()); }
		return error.empty();
	}
};

extern "C" mGameDexCapture* mGameDexStart(mCore* core, const char* directory) {
	try {
		auto c = std::make_unique<mGameDexCapture>(core, directory);
		c->start();
		return c.release();
	} catch (const std::exception& e) { fprintf(stderr, "Cannot start GameDex capture: %s\n", e.what()); return nullptr; }
}
extern "C" bool mGameDexHealthy(const mGameDexCapture* c) { return c && c->healthy.load(); }
extern "C" uint64_t mGameDexFrames(const mGameDexCapture* c) { return c ? c->nativeFrames.load() : 0; }
extern "C" void mGameDexAbort(mGameDexCapture* c, const char* reason) { if (c) c->fail(reason); }
extern "C" bool mGameDexStop(mGameDexCapture* c) {
	if (!c) return false;
	bool result = c->finish(); delete c; return result;
}
