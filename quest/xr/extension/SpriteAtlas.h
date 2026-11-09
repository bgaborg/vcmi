// SpriteAtlas.h, Meta Quest build: the map object sprites of the view in RGBA pages (quest/MILESTONE_3B.md, plan step 3).
// Workers decode the wanted animations through the bridge, bake and trim them and pack them into pages of RGBA8 with
// premultiplied alpha (so mipmaps blend edges right; the shader blends premultiplied), with an R8 owner mask page of
// the same layout; the main thread uploads at most one finished page per frame.
// Included by VcmiData.cpp (one translation unit, as the bridge's files).
// License: GNU General Public License v2.0 or later
#pragma once

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <numeric>
#include <thread>
#include <unordered_map>
#include <unordered_set>

#include <godot_cpp/classes/texture2d_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

/// one frame as the 2D map draws it: RGBA8 (shadow in alpha), the owner mask (empty when none), its place in the full frame
struct BakedFrame
{
	uint16_t group = 0, frame = 0;
	int16_t left = 0, top = 0;
	uint16_t fullWidth = 0, fullHeight = 0;
	uint16_t width = 0, height = 0;
	bool png = false;
	std::vector<uint8_t> rgba;
	std::vector<uint8_t> mask;
};

inline Ref<Image> loadPng(const uint8_t * bytes, uint32_t size)
{
	PackedByteArray buffer;
	buffer.resize(size);
	std::memcpy(buffer.ptrw(), bytes, size);
	Ref<Image> image;
	image.instantiate();
	if(image->load_png_from_buffer(buffer) != OK)
		return Ref<Image>();
	image->convert(Image::FORMAT_RGBA8);
	return image;
}

/// a .def palette as RGBA with the special entries the 2D map uses for map objects
/// (ScalableImageParameters::setShadowTransparency, clientsdl3/render/ScalableImage.cpp:205-222): 0 clear, 1 and 4
/// shadow at alpha 64 and 128, 2 and 3 the same when they hold H3's shadow colours. 5, the owner flag, keeps its
/// colour: objects without an owner draw it so (WITH_SHADOW or ONLY_BODY_IGNORE_OVERLAY, MapRenderer.cpp:425-427);
/// for owned ones the mask marks it for the owner colour
inline std::array<uint8_t, 1024> bakePalette(const uint8_t * rgb)
{
	std::array<uint8_t, 1024> out{};
	if(!rgb)
		return out;
	for(int i = 0; i < 256; i++)
	{
		std::memcpy(&out[i * 4], &rgb[i * 3], 3);
		out[i * 4 + 3] = 255;
	}
	const auto similar = [rgb](int i, int r, int g, int b)
	{
		return std::abs(rgb[i * 3] - r) < 8 && std::abs(rgb[i * 3 + 1] - g) < 8 && std::abs(rgb[i * 3 + 2] - b) < 8;
	};
	const auto shadow = [&out](int i, uint8_t alpha)
	{
		out[i * 4] = out[i * 4 + 1] = out[i * 4 + 2] = 0;
		out[i * 4 + 3] = alpha;
	};
	shadow(0, 0);
	shadow(1, 64);
	shadow(4, 128);
	if(similar(2, 255, 100, 255))
		shadow(2, 64);
	if(similar(3, 255, 50, 255))
		shadow(3, 128);
	return out;
}

/// the frames of a decoded animation, baked; frames whose data is out of range or no PNG are left out. Indexed frames
/// use `palette` when given (RGBA), else the map objects' (bakePalette). Any thread.
inline std::vector<BakedFrame> bakeFrames(const VcmiAnimationData & anim, const std::array<uint8_t, 1024> * tilePalette = nullptr)
{
	std::vector<BakedFrame> out;
	const auto palette = tilePalette ? *tilePalette : bakePalette(anim.palette);
	for(uint32_t i = 0; i < anim.frameCount; i++)
	{
		const VcmiFrame & f = anim.frames[i];
		if(f.offset + uint64_t(f.size) > anim.dataSize || f.overlayOffset + uint64_t(f.overlaySize) > anim.dataSize)
			continue;
		BakedFrame b;
		b.group = f.group;
		b.frame = f.frame;
		b.left = f.left;
		b.top = f.top;
		b.fullWidth = f.fullWidth;
		b.fullHeight = f.fullHeight;
		b.png = f.format == VCMI_FRAME_PNG;
		if(b.png)
		{
			const Ref<Image> image = loadPng(anim.data + f.offset, f.size);
			if(image.is_null())
				continue;
			b.width = image->get_width();
			b.height = image->get_height();
			const PackedByteArray px = image->get_data();
			b.rgba.assign(px.ptr(), px.ptr() + px.size());
			// the flag is where the overlay is opaque (its alpha), as the 2D map draws it in the owner colour
			if(f.overlaySize)
				if(const Ref<Image> overlay = loadPng(anim.data + f.overlayOffset, f.overlaySize);
				   overlay.is_valid() && overlay->get_size() == image->get_size())
				{
					const PackedByteArray ov = overlay->get_data();
					b.mask.resize(ov.size() / 4);
					for(size_t p = 0; p < b.mask.size(); p++)
						b.mask[p] = ov.ptr()[p * 4 + 3];
				}
		}
		else
		{
			if(f.width == 0 || f.height == 0 || f.size != uint32_t(f.width) * f.height)
				continue;
			b.width = f.width;
			b.height = f.height;
			b.rgba.resize(size_t(f.size) * 4);
			bool flagged = false;
			for(uint32_t p = 0; p < f.size; p++)
			{
				const uint8_t index = anim.data[f.offset + p];
				std::memcpy(&b.rgba[p * 4], &palette[index * 4], 4);
				flagged |= index == 5;
			}
			if(flagged)
			{
				b.mask.resize(f.size);
				for(uint32_t p = 0; p < f.size; p++)
					b.mask[p] = anim.data[f.offset + p] == 5 ? 255 : 0;
			}
		}
		out.push_back(std::move(b));
	}
	return out;
}

/// animation `name` decoded and baked: an object animation (VcmiObject.animation), or tile frames as the bridge's
/// tileAnimation describes them, "<file>#<o|k>[,<start>:<length>]...": the palette opaque (o) or with index 0 clear
/// (k), and one group per step of its rotating ranges, frame by frame of group 0, as AssetGenerator::
/// generatePaletteShiftedAnimation makes the 2D map's "_Shifted" animations. Any thread.
inline std::vector<BakedFrame> decodeBaked(const VcmiBridgeApi * api, const std::string & name)
{
	const size_t hash = name.find('#');
	VcmiAnimationData anim{};
	api->decodeAnimation(name.substr(0, hash).c_str(), &anim);
	if(hash == std::string::npos || hash + 1 >= name.size())
		return bakeFrames(anim);
	std::array<uint8_t, 1024> base{};
	for(int i = 0; anim.palette && i < 256; i++)
	{
		std::memcpy(&base[i * 4], &anim.palette[i * 3], 3);
		base[i * 4 + 3] = 255;
	}
	if(name[hash + 1] == 'k')
		base[0] = base[1] = base[2] = base[3] = 0;
	std::vector<std::pair<int, int>> ranges;
	int steps = 1;
	for(size_t at = name.find(',', hash); at != std::string::npos; at = name.find(',', at + 1))
	{
		int start = 0, length = 0;
		if(std::sscanf(name.c_str() + at + 1, "%d:%d", &start, &length) == 2 && start >= 0 && length > 0 && start + length <= 256)
		{
			ranges.emplace_back(start, length);
			steps = std::lcm(steps, length);
		}
	}
	// group 0 only, the source of the 2D map's tiles
	std::vector<VcmiFrame> source;
	bool png = false;
	for(uint32_t i = 0; i < anim.frameCount; i++)
		if(anim.frames[i].group == 0)
		{
			source.push_back(anim.frames[i]);
			png |= anim.frames[i].format == VCMI_FRAME_PNG;
		}
	// a mod's PNG frames have no palette to rotate; ranges of coprime lengths would bake hundreds of steps per frame
	if(png || steps > 64)
		steps = 1;
	VcmiAnimationData group0 = anim;
	group0.frames = source.data();
	group0.frameCount = uint32_t(source.size());
	std::vector<BakedFrame> out;
	for(int step = 0; step < steps; step++)
	{
		std::array<uint8_t, 1024> palette = base;
		for(const auto & [start, length] : ranges)
			for(int i = 0; i < length; i++)
				std::memcpy(&palette[(start + (i + step) % length) * 4], &base[(start + i) * 4], 4);
		for(BakedFrame & f : bakeFrames(group0, &palette))
		{
			f.group = uint16_t(step);
			out.push_back(std::move(f));
		}
	}
	return out;
}

class SpriteAtlas
{
public:
	// small pages, many layers: an upload of a 2048² page with mipmaps took 7-11 ms of the main thread on the Quest
	// (MILESTONE_3B.md section 1c); 512² layers hold the same pixels and upload in pieces. 64 x 512² RGBA8 with
	// mipmaps and masks: about 112 MB on the GPU (the budget revised in PHASE4.md 4c)
	static constexpr int PAGE = 512;
	// 64: the tabletop view of the heaviest map (1.5 cm tiles) needed about 10 % more than 32 pages for its objects
	// (PHASE4.md 4b), and overflowed 48 once its terrain came in (4c: water and lava bake a frame per palette step)
	static constexpr int PAGES = 64;
	static constexpr int PAD = 4; // between sprites: they stay apart in mips 0-1 and mostly in 2; the LOD switch keeps
	// sprites from being drawn smaller than that (MILESTONE_3B.md section 5)
	static constexpr int WORKERS = 3; // the Quest 3 has 6 cores; the game thread takes one, Godot's main and render threads two

	/// where a frame is: page, rectangle, and its offset in the full frame (trimmed to its visible pixels)
	struct Placed
	{
		uint16_t group, frame;
		uint16_t page, x, y, width, height;
		int16_t left, top;
		uint16_t fullWidth, fullHeight;
		bool mask;
	};

	struct Stats
	{
		int64_t wanted = 0, loaded = 0, frames = 0, pixels = 0, refills = 0, overflowed = 0, evicted = 0;
		bool viewOverflowed = false; // the current view's animations do not all fit (VcmiData: markers then)
		int64_t decodeMicros = 0; // worker time of the bridge, baking, trimming and packing, summed
		int64_t mipmapMicros = 0; // worker time building the page images
		int64_t batchMillis = 0; // from the last want with new animations to all of them uploaded
		int64_t createMicros = 0; // main thread, once: the empty texture arrays
		int64_t uploadMicros = 0; // main thread, the last upload; maxUploadMicros the most of one frame
		int64_t maxUploadMicros = 0;
		int64_t pagesUsed = 0;
	};

	explicit SpriteAtlas(const VcmiBridgeApi * bridge) : api(bridge)
	{
		pages.resize(PAGES);
		for(Page & page : pages)
		{
			page.rgba.assign(size_t(PAGE) * PAGE * 4, 0);
			page.mask.assign(size_t(PAGE) * PAGE, 0);
		}
		for(int i = 0; i < WORKERS; i++)
			workers.emplace_back(
				[this]()
				{
					work();
				}
			);
	}

	~SpriteAtlas()
	{
		{
			std::lock_guard lock(mutex);
			stopping = true;
			queue.clear();
		}
		wake.notify_all();
		for(std::thread & worker : workers)
			worker.join();
	}

	/// main thread: the animations the view needs, by name. Loads those not in the pages; a full atlas makes room by
	/// clearing the page the view has not needed for longest (evict). Starts all pages again with only these when no
	/// page can go (the view needs more than the pages), or when the pages would hold mostly other animations.
	void want(const std::vector<std::string> & names)
	{
		std::lock_guard lock(mutex);
		stats.wanted = names.size();
		wantSerial++;
		wantedNow = std::unordered_set<std::string>(names.begin(), names.end());
		wantedOrder = names;
		for(Page & page : pages)
			if(std::any_of(
				   page.animations.begin(),
				   page.animations.end(),
				   [this](const std::string & a)
				   {
					   return wantedNow.count(a);
				   }
			   ))
				page.used = wantSerial;
		// what overflowed is tried again, before counting: evict may make room now that the view moved or shrank
		for(const std::string & name : overflowNames)
			failed.erase(name);
		overflowNames.clear();
		viewOverflowed = false;
		size_t missing = 0;
		for(const std::string & name : names)
			missing += !placed.count(name) && !failed.count(name);
		if(missing == 0)
			return;
		// shortcut: 64 animations stay cached when zooming in to a few; tune with the real views of phase 4
		if(placed.size() > 2 * names.size() && placed.size() > 64)
			refill();
		else
			freshBatch = false;
		queueWanted();
		batchStart = std::chrono::steady_clock::now();
		batchOpen = true;
		wake.notify_all();
	}

	/// main thread, once per frame: creates the textures on the first call, then uploads one finished page.
	/// true when it uploaded
	bool upload()
	{
		const auto from = std::chrono::steady_clock::now();
		Ref<Image> image;
		Ref<Image> mask;
		int layer = -1;
		{
			// never wait: a worker may be copying a page; the next frame then
			std::unique_lock lock(mutex, std::try_to_lock);
			if(!lock)
				return false;
			for(int i = 0; i < PAGES && layer < 0; i++)
				if(pages[i].ready.is_valid())
				{
					layer = i;
					image = pages[i].ready;
					mask = pages[i].readyMask;
					pages[i].ready.unref();
					pages[i].readyMask.unref();
				}
		}
		if(body.is_null())
		{
			// all layers at once, empty: Texture2DArray takes its size and format from them
			TypedArray<Image> bodies;
			TypedArray<Image> masks;
			for(int i = 0; i < PAGES; i++)
			{
				Ref<Image> b = Image::create_empty(PAGE, PAGE, true, Image::FORMAT_RGBA8);
				Ref<Image> m = Image::create_empty(PAGE, PAGE, true, Image::FORMAT_R8);
				bodies.push_back(b);
				masks.push_back(m);
			}
			body.instantiate();
			body->create_from_images(bodies);
			flags.instantiate();
			flags->create_from_images(masks);
			stats.createMicros = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
		}
		if(layer >= 0)
		{
			wake.notify_all(); // a page packed into again while its image waited can be built now
			body->update_layer(image, layer);
			flags->update_layer(mask, layer);
		}
		const int64_t spent = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
		std::unique_lock lock(mutex, std::try_to_lock);
		if(!lock)
			return layer >= 0;
		if(layer >= 0)
		{
			stats.uploadMicros = spent;
			stats.maxUploadMicros = std::max(stats.maxUploadMicros, spent);
		}
		bool pending = !queue.empty() || busy > 0;
		for(const Page & page : pages)
			pending |= page.dirty || page.ready.is_valid();
		if(batchOpen && !pending)
		{
			batchOpen = false;
			stats.batchMillis = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - batchStart).count();
		}
		return layer >= 0;
	}

	Ref<Texture2DArray> bodyTexture() const
	{
		return body;
	}
	Ref<Texture2DArray> maskTexture() const
	{
		return flags;
	}

	/// the frames of an animation in the pages; empty when not (yet) loaded. The pixels are on the GPU only once
	/// busyNow() is false: a renderer waits for that (a refill reuses the pages)
	std::vector<Placed> frames(const std::string & name) const
	{
		std::lock_guard lock(mutex);
		auto it = placed.find(name);
		return it == placed.end() ? std::vector<Placed>() : it->second;
	}

	/// true while animations wait or pages wait for their upload
	bool busyNow() const
	{
		std::lock_guard lock(mutex);
		bool pending = !queue.empty() || busy > 0 || batchOpen;
		return pending;
	}

	Stats statsNow() const
	{
		std::lock_guard lock(mutex);
		Stats s = stats;
		s.viewOverflowed = viewOverflowed;
		s.loaded = placed.size();
		s.pagesUsed = 0;
		for(const Page & page : pages)
			s.pagesUsed += page.shelfY + page.shelfHeight > 0;
		return s;
	}

	/// page `layer` as the workers last built it, with the mask in red, for a look; null when empty. Main thread.
	Ref<Image> debugPage(int layer) const
	{
		std::lock_guard lock(mutex);
		if(layer < 0 || layer >= PAGES)
			return Ref<Image>();
		PackedByteArray px;
		px.resize(int64_t(PAGE) * PAGE * 4);
		uint8_t * out = px.ptrw();
		const Page & page = pages[layer];
		if(page.stale || page.shelfY + page.shelfHeight == 0)
			return Ref<Image>();
		for(size_t p = 0; p < size_t(PAGE) * PAGE; p++)
		{
			const uint8_t * in = &page.rgba[p * 4];
			const int a = in[3];
			// premultiplied, over grey, the mask in red
			for(int c = 0; c < 3; c++)
				out[p * 4 + c] = uint8_t(std::min(255, in[c] + 128 * (255 - a) / 255));
			if(page.mask[p])
				out[p * 4] = 255, out[p * 4 + 1] = out[p * 4 + 2] = 0;
			out[p * 4 + 3] = 255;
		}
		return Image::create_from_data(PAGE, PAGE, false, Image::FORMAT_RGBA8, px);
	}

private:
	// lock held: all pages start again empty, for the animations of the last want() only. A frame that does not fit
	// in such a fresh batch means the view needs more than the pages (viewOverflowed)
	void refill()
	{
		generation++;
		placed.clear();
		failed.clear();
		overflowNames.clear();
		queue.clear();
		for(Page & page : pages)
		{
			page.stale = true; // cleared by the next pack, on a worker: 63 MB is too much for the main thread
			page.shelfY = page.shelfHeight = page.x = 0;
			page.dirty = false;
			page.ready.unref();
			page.readyMask.unref();
			page.animations.clear();
		}
		freshBatch = true;
		stats.refills++;
	}

	// lock held: the wanted animations that are not loaded, failed or queued go into the queue
	void queueWanted()
	{
		for(const std::string & name : wantedOrder)
			if(!placed.count(name) && !failed.count(name) && std::find(queue.begin(), queue.end(), name) == queue.end())
				queue.push_back(name);
	}

	struct Page
	{
		std::vector<uint8_t> rgba;
		std::vector<uint8_t> mask;
		int x = 0, shelfY = 0, shelfHeight = 0; // the open shelf
		bool dirty = false; // packed into since its last image
		bool stale = false; // holds a refilled generation's pixels
		std::unordered_set<std::string> animations; // with frames on this page
		uint64_t used = 0; // the last want() whose view needed one of them (evict)
		Ref<Image> ready, readyMask; // built, waiting for the upload
	};

	void work()
	{
		for(;;)
		{
			std::string name;
			uint64_t gen;
			{
				std::unique_lock lock(mutex);
				wake.wait(
					lock,
					[this]()
					{
						return stopping || !queue.empty() || (busy == 0 && anyDirty());
					}
				);
				if(stopping)
					return;
				if(queue.empty())
				{
					buildPages(lock);
					continue;
				}
				name = queue.front();
				queue.pop_front();
				gen = generation;
				busy++;
			}
			const auto from = std::chrono::steady_clock::now();
			std::vector<BakedFrame> baked = decodeBaked(api, name);
			VcmiBridgeStats game{};
			api->stats(&game);
			for(BakedFrame & f : baked)
			{
				trim(f);
				premultiply(f);
			}
			std::unique_lock lock(mutex);
			busy--;
			if(gen == generation && !stopping && game.inGame)
			{
				if(baked.empty())
					failed.insert(name);
				else
					pack(name, baked);
				stats.decodeMicros += std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
			}
			lock.unlock();
			wake.notify_all();
		}
	}

	bool anyDirty() const
	{
		int waiting = 0;
		for(const Page & page : pages)
			waiting += page.ready.is_valid();
		if(waiting >= 2) // the upload takes one per frame: more built images would only hold memory (1.75 MB each)
			return false;
		for(const Page & page : pages)
			if(page.dirty && page.ready.is_null())
				return true;
		return false;
	}

	// the visible box (alpha or mask): most frames have empty borders (MILESTONE_3B.md section 1a: 50 M -> 35 M pixels)
	static void trim(BakedFrame & f)
	{
		int x0 = f.width, y0 = f.height, x1 = -1, y1 = -1;
		for(int y = 0; y < f.height; y++)
			for(int x = 0; x < f.width; x++)
			{
				const size_t p = size_t(y) * f.width + x;
				if(f.rgba[p * 4 + 3] || (!f.mask.empty() && f.mask[p]))
				{
					x0 = std::min(x0, x);
					x1 = std::max(x1, x);
					y0 = std::min(y0, y);
					y1 = std::max(y1, y);
				}
			}
		if(x1 < 0)
		{
			f.width = f.height = 0;
			return;
		}
		if(x0 == 0 && y0 == 0 && x1 == f.width - 1 && y1 == f.height - 1)
			return;
		const int w = x1 - x0 + 1, h = y1 - y0 + 1;
		std::vector<uint8_t> rgba(size_t(w) * h * 4);
		std::vector<uint8_t> mask(f.mask.empty() ? 0 : size_t(w) * h);
		for(int y = 0; y < h; y++)
		{
			std::memcpy(&rgba[size_t(y) * w * 4], &f.rgba[(size_t(y0 + y) * f.width + x0) * 4], size_t(w) * 4);
			if(!mask.empty())
				std::memcpy(&mask[size_t(y) * w], &f.mask[size_t(y0 + y) * f.width + x0], w);
		}
		f.rgba = std::move(rgba);
		f.mask = std::move(mask);
		f.left = int16_t(f.left + x0);
		f.top = int16_t(f.top + y0);
		f.width = uint16_t(w);
		f.height = uint16_t(h);
	}

	// sRGB byte -> linear, and linear (0..4095) -> sRGB byte
	static const std::pair<std::array<float, 256>, std::array<uint8_t, 4096>> & srgbTables()
	{
		static const auto tables = []()
		{
			std::pair<std::array<float, 256>, std::array<uint8_t, 4096>> t;
			for(int i = 0; i < 256; i++)
			{
				const float c = i / 255.0f;
				t.first[i] = c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f);
			}
			for(int i = 0; i < 4096; i++)
			{
				const float l = i / 4095.0f;
				const float c = l <= 0.0031308f ? l * 12.92f : 1.055f * std::pow(l, 1.0f / 2.4f) - 0.055f;
				t.second[i] = uint8_t(std::lround(std::clamp(c, 0.0f, 1.0f) * 255.0f));
			}
			return t;
		}();
		return tables;
	}

	// colour times alpha in linear light, stored sRGB-encoded: the GPU's sRGB decode (source_color) then gives the
	// premultiplied linear colour with no maths in the shader
	static void premultiply(BakedFrame & f)
	{
		const auto & t = srgbTables();
		for(size_t p = 0; p < f.rgba.size(); p += 4)
		{
			const float a = f.rgba[p + 3] / 255.0f;
			for(int c = 0; c < 3; c++)
				f.rgba[p + c] = t.second[size_t(t.first[f.rgba[p + c]] * a * 4095.0f + 0.5f)];
		}
	}

	// a page with its mipmaps, each level the 2x2 average of the one above in linear light (Image::generate_mipmaps
	// averages the encoded bytes, which darkens the premultiplied edges)
	static PackedByteArray withLinearMipmaps(const PackedByteArray & base)
	{
		const auto & t = srgbTables();
		PackedByteArray out = base;
		std::vector<uint8_t> level(base.ptr(), base.ptr() + base.size());
		for(int size = PAGE; size > 1; size /= 2)
		{
			const int half = size / 2;
			std::vector<uint8_t> next(size_t(half) * half * 4);
			for(int y = 0; y < half; y++)
				for(int x = 0; x < half; x++)
					for(int c = 0; c < 4; c++)
					{
						const uint8_t * p = &level[(size_t(2 * y) * size + 2 * x) * 4 + c];
						const size_t row = size_t(size) * 4;
						uint8_t & o = next[(size_t(y) * half + x) * 4 + c];
						if(c == 3)
							o = uint8_t((p[0] + p[4] + p[row] + p[row + 4] + 2) / 4);
						else
							o = t.second[size_t((t.first[p[0]] + t.first[p[4]] + t.first[p[row]] + t.first[p[row + 4]]) * 0.25f * 4095.0f + 0.5f)];
					}
			const int64_t at = out.size();
			out.resize(at + int64_t(next.size()));
			std::memcpy(out.ptrw() + at, next.data(), next.size());
			level = std::move(next);
		}
		return out;
	}

	// under the mutex: shelf packing in page order, frames in decode order (an animation's frames have one size mostly)
	void pack(const std::string & name, const std::vector<BakedFrame> & baked)
	{
		std::vector<Placed> out;
		for(const BakedFrame & f : baked)
		{
			Placed p{f.group, f.frame, 0, 0, 0, f.width, f.height, f.left, f.top, f.fullWidth, f.fullHeight, !f.mask.empty()};
			if(f.width && f.height)
			{
				if(f.width > PAGE || f.height > PAGE)
				{
					failed.insert(name); // stays a marker; no refill could place it
					return;
				}
				int page = 0;
				for(; page < PAGES; page++)
				{
					if(pages[page].stale)
					{
						std::fill(pages[page].rgba.begin(), pages[page].rgba.end(), 0);
						std::fill(pages[page].mask.begin(), pages[page].mask.end(), 0);
						pages[page].stale = false;
					}
					if(fit(pages[page], std::min(f.width + PAD, PAGE), std::min(f.height + PAD, PAGE)))
						break;
				}
				if(page == PAGES)
				{
					page = evict(name);
					if(page >= 0 && !fit(pages[page], std::min(f.width + PAD, PAGE), std::min(f.height + PAD, PAGE)))
						page = PAGES;
					if(page < 0)
						page = PAGES;
				}
				if(page == PAGES && !freshBatch)
				{
					// the pages are fragmented (each holds something the view needs): start again with this view only
					refill();
					queueWanted();
					return;
				}
				if(page == PAGES)
				{
					// stays a marker until the view moves, so a view needing more than the pages does not refill forever
					viewOverflowed = true;
					stats.overflowed++;
					failed.insert(name);
					overflowNames.insert(name);
					return;
				}
				Page & target = pages[page];
				target.animations.insert(name);
				target.used = wantSerial;
				p.page = uint16_t(page);
				p.x = uint16_t(target.x);
				p.y = uint16_t(target.shelfY);
				for(int row = 0; row < f.height; row++)
				{
					std::memcpy(&target.rgba[(size_t(p.y + row) * PAGE + p.x) * 4], &f.rgba[size_t(row) * f.width * 4], size_t(f.width) * 4);
					if(!f.mask.empty())
						std::memcpy(&target.mask[size_t(p.y + row) * PAGE + p.x], &f.mask[size_t(row) * f.width], f.width);
				}
				extrude(target, p, f);
				target.x += f.width + PAD;
				target.dirty = true;
				stats.pixels += int64_t(f.width) * f.height;
			}
			out.push_back(p);
		}
		stats.frames += out.size();
		placed[name] = std::move(out);
	}

	// a frame opaque to its border (terrain, full fog) gets its edge pixels copied PAD / 2 outward, where the page has
	// room: tiles lie side by side, and the clear padding would show between them in the smaller mipmaps. Its
	// neighbours take at most the other half of the padding
	static void extrude(Page & page, const Placed & p, const BakedFrame & f)
	{
		const auto alpha = [&f](int x, int y)
		{
			return f.rgba[(size_t(y) * f.width + x) * 4 + 3];
		};
		for(int x = 0; x < f.width; x++)
			if(alpha(x, 0) < 255 || alpha(x, f.height - 1) < 255)
				return;
		for(int y = 0; y < f.height; y++)
			if(alpha(0, y) < 255 || alpha(f.width - 1, y) < 255)
				return;
		constexpr int E = PAD / 2;
		const auto at = [&page](int x, int y)
		{
			return &page.rgba[(size_t(y) * PAGE + x) * 4];
		};
		const int x0 = std::max(int(p.x) - E, 0), x1 = std::min(int(p.x) + f.width + E, PAGE);
		const int y0 = std::max(int(p.y) - E, 0), y1 = std::min(int(p.y) + f.height + E, PAGE);
		for(int y = y0; y < y1; y++)
			for(int x = x0; x < x1; x++)
				if(x < p.x || y < p.y || x >= p.x + f.width || y >= p.y + f.height)
					std::memcpy(at(x, y), at(std::clamp(x, int(p.x), p.x + f.width - 1), std::clamp(y, int(p.y), p.y + f.height - 1)), 4);
	}

	// a page the current view does not need, the one unneeded for longest, cleared for new frames; its animations are
	// dropped (their frames elsewhere stay as unused space). Their sprites lie outside the view and its margin (the
	// view asks for 2 tiles more on every side), so nothing visible points at the page while it is refilled. -1: none
	int evict(const std::string & packing)
	{
		int best = -1;
		for(int i = 0; i < PAGES; i++)
			if(pages[i].used < wantSerial && !pages[i].animations.count(packing) && (best < 0 || pages[i].used < pages[best].used))
				best = i;
		if(best < 0)
			return -1;
		Page & page = pages[best];
		for(const std::string & name : page.animations)
		{
			placed.erase(name);
			for(Page & other : pages)
				if(&other != &page)
					other.animations.erase(name);
		}
		page.animations.clear();
		std::fill(page.rgba.begin(), page.rgba.end(), 0);
		std::fill(page.mask.begin(), page.mask.end(), 0);
		page.stale = false;
		page.x = page.shelfY = page.shelfHeight = 0;
		page.ready.unref();
		page.readyMask.unref();
		page.dirty = true;
		stats.evicted++;
		return best;
	}

	// in the open shelf, else in a new one below it; the page changes only when the frame goes in, so trying the
	// pages in order wastes no shelf
	static bool fit(Page & page, int w, int h)
	{
		if(w > PAGE || h > PAGE)
			return false;
		if(page.x + w <= PAGE && page.shelfY + std::max(page.shelfHeight, h) <= PAGE)
		{
			page.shelfHeight = std::max(page.shelfHeight, h);
			return true;
		}
		const int y = page.shelfY + page.shelfHeight;
		if(y + h > PAGE)
			return false;
		page.shelfY = y;
		page.x = 0;
		page.shelfHeight = h;
		return true;
	}

	// a worker with the queue empty: copies the dirty pages out under the lock and builds their images with mipmaps
	// outside it, so the main thread only uploads
	void buildPages(std::unique_lock<std::mutex> & lock)
	{
		for(int i = 0; i < PAGES; i++)
		{
			if(!pages[i].dirty || pages[i].ready.is_valid())
				continue;
			pages[i].dirty = false;
			const uint64_t gen = generation;
			PackedByteArray rgba;
			PackedByteArray mask;
			rgba.resize(pages[i].rgba.size());
			mask.resize(pages[i].mask.size());
			std::memcpy(rgba.ptrw(), pages[i].rgba.data(), pages[i].rgba.size());
			std::memcpy(mask.ptrw(), pages[i].mask.data(), pages[i].mask.size());
			busy++;
			lock.unlock();
			const auto from = std::chrono::steady_clock::now();
			Ref<Image> image = Image::create_from_data(PAGE, PAGE, true, Image::FORMAT_RGBA8, withLinearMipmaps(rgba));
			Ref<Image> flag = Image::create_from_data(PAGE, PAGE, false, Image::FORMAT_R8, mask);
			flag->generate_mipmaps();
			const int64_t spent = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - from).count();
			lock.lock();
			busy--;
			stats.mipmapMicros += spent;
			if(gen == generation && !stopping)
			{
				pages[i].ready = image;
				pages[i].readyMask = flag;
			}
			return; // one page per build keeps the copies to one page (about 50 MB at the peak)
		}
	}

	const VcmiBridgeApi * api;
	mutable std::mutex mutex;
	std::condition_variable wake;
	std::vector<std::thread> workers;
	bool stopping = false;
	std::deque<std::string> queue;
	int busy = 0; // workers decoding or building outside the lock
	uint64_t generation = 0; // raised by a refill: work of an older generation is dropped
	uint64_t wantSerial = 0; // raised by each want()
	std::unordered_set<std::string> wantedNow; // the names of the last want()
	std::vector<std::string> wantedOrder; // the same in the caller's order: the first ones are loaded and placed first
	std::vector<Page> pages;
	std::unordered_map<std::string, std::vector<Placed>> placed;
	std::unordered_set<std::string> failed; // missing or JSON-only without files: markers stay
	bool viewOverflowed = false; // the last want() needs more than the pages hold, even after evicting
	bool freshBatch = true; // the pages were refilled for the current view (an overflow then is real)
	std::unordered_set<std::string> overflowNames; // failed for want of room: tried again by the next want()
	bool batchOpen = false;
	std::chrono::steady_clock::time_point batchStart;
	Stats stats;
	Ref<Texture2DArray> body;
	Ref<Texture2DArray> flags;
};
