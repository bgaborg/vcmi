/*
 * SpriteDecode.cpp, Meta Quest build: see SpriteDecode.h.
 *
 * License: GNU General Public License v2.0 or later
 */
#include "../../Global.h"

#include "SpriteDecode.h"

#include "../../client/render/CDefFile.h"
#include "../../client/render/IImageLoader.h"
#include "../../lib/Point.h"
#include "../../lib/filesystem/Filesystem.h"
#include "../../lib/json/JsonNode.h"

namespace
{
// appends a frame's indices to the animation's data; init gives the frame's real size (after the fix of the old
// SGTWMTA format in CDefFile::loadFrame) and the palette
class IndexLoader : public IImageLoader
{
public:
	IndexLoader(SpriteAnimation & out, SpriteFrame & frame, bool & paletteCopied) : anim(out), f(frame), palette(paletteCopied) {}

	void init(Point size, Point margins, Point fullSize, SDL_Color * pal) override
	{
		f.format = VCMI_FRAME_INDEXED;
		f.offset = static_cast<uint32_t>(anim.data.size());
		f.width = static_cast<uint16_t>(size.x);
		f.height = static_cast<uint16_t>(size.y);
		f.size = uint32_t(f.width) * f.height;
		f.left = static_cast<int16_t>(margins.x);
		f.top = static_cast<int16_t>(margins.y);
		f.fullWidth = static_cast<uint16_t>(fullSize.x);
		f.fullHeight = static_cast<uint16_t>(fullSize.y);
		if(!palette)
		{
			// one palette per file; SDL_Color is {r, g, b, a} bytes in SDL2 and SDL3
			const auto * rgba = reinterpret_cast<const uint8_t *>(pal);
			for(int i = 0; i < 256; i++)
				std::memcpy(&anim.palette[i * 3], rgba + i * 4, 3);
			palette = true;
		}
		anim.data.reserve(anim.data.size() + f.size);
		rowStart = anim.data.size();
	}
	void load(size_t size, const ui8 * data) override
	{
		anim.data.insert(anim.data.end(), data, data + size);
	}
	void load(size_t size, ui8 color) override
	{
		anim.data.insert(anim.data.end(), size, color);
	}
	// a row's last run can be longer than what is left of the row; the SDL loader skips to the next row, as here
	void endLine() override
	{
		if(anim.data.size() != rowStart + f.width)
		{
			anim.overruns += anim.data.size() > rowStart + f.width;
			anim.data.resize(rowStart + f.width);
		}
		rowStart += f.width;
	}

private:
	SpriteAnimation & anim;
	SpriteFrame & f;
	bool & palette;
	size_t rowStart = 0;
};

// as RenderHandler::loadImageFromFileUncached and loadScaledImage at scale 1 (clientsdl3/render/RenderHandler.cpp:324-340,
// 464-490): SPRITES/, then DATA/, then the path itself
std::optional<ImagePath> findImage(const std::string & name)
{
	for(const char * prefix : {"SPRITES/", "DATA/", ""})
	{
		const auto path = ImagePath::builtin(prefix + name);
		if(CResourceHandler::get()->existsResource(path))
			return path;
	}
	return std::nullopt;
}

// appends a file's bytes and returns where they are
std::pair<uint32_t, uint32_t> appendFile(SpriteAnimation & anim, const ImagePath & path)
{
	auto [bytes, size] = CResourceHandler::get()->load(path)->readAll();
	const auto offset = static_cast<uint32_t>(anim.data.size());
	anim.data.insert(anim.data.end(), bytes.get(), bytes.get() + size);
	return {offset, static_cast<uint32_t>(size)};
}

// the image files a mod's JSON layout puts in place of frames, by group and frame, as RenderHandler::initFromJson
// (RenderHandler.cpp:156-202) reads `basepath`, `sequences` and `images` with `file`, the layouts of all mods in order.
// A `sequences` group replaces the whole group, .def frames included (initFromJson clears it): those groups are in
// `replaced`. A layout that is no valid JSON throws, as it does in the game.
// shortcut: `defFile` entries (a frame of another .def) and margins/width/height are not read; no installed mod uses
// them (2 088 layouts in hd-remastered and HotA, 2026-11-07), add them when one does
struct Layout
{
	std::map<std::pair<size_t, size_t>, std::string> files;
	std::set<size_t> replaced;
};

Layout readLayout(const AnimationPath & path)
{
	Layout layout;
	auto & files = layout.files;
	const auto jsonPath = path.toType<EResType::JSON>();
	for(const auto * loader : CResourceHandler::get()->getResourcesWithName(jsonPath))
	{
		auto [text, size] = loader->load(jsonPath)->readAll();
		const JsonNode config(reinterpret_cast<const std::byte *>(text.get()), size, jsonPath.getOriginalName());
		const std::string basepath = config["basepath"].String();
		for(const JsonNode & group : config["sequences"].Vector())
		{
			const size_t id = group["group"].Integer();
			std::erase_if(
				files,
				[id](const auto & entry)
				{
					return entry.first.first == id;
				}
			);
			layout.replaced.insert(id);
			size_t frame = 0;
			for(const JsonNode & file : group["frames"].Vector())
				files[{id, frame++}] = basepath + file.String();
		}
		for(const JsonNode & image : config["images"].Vector())
			if(!image["file"].isNull())
				files[{size_t(image["group"].Integer()), size_t(image["frame"].Integer())}] = basepath + image["file"].String();
	}
	return layout;
}

// PNG width and height from the IHDR chunk; 0 when the bytes are no PNG
std::pair<uint16_t, uint16_t> pngSize(const uint8_t * png, uint32_t size)
{
	static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
	if(size < 24 || std::memcmp(png, signature, 8) != 0)
		return {0, 0};
	const auto be32 = [png](int at)
	{
		return (uint32_t(png[at]) << 24) | (uint32_t(png[at + 1]) << 16) | (uint32_t(png[at + 2]) << 8) | png[at + 3];
	};
	return {static_cast<uint16_t>(std::min<uint32_t>(be32(16), UINT16_MAX)), static_cast<uint16_t>(std::min<uint32_t>(be32(20), UINT16_MAX))};
}
}

SpriteAnimation decodeAnimation(const std::string & name)
{
	SpriteAnimation out;
	// as RenderHandler::getAnimationFile and getAnimationLayout (clientsdl3/render/RenderHandler.cpp) find them
	const auto path = AnimationPath::builtin(boost::starts_with(name, "SPRITES/") ? name : "SPRITES/" + name);
	out.def = CResourceHandler::get()->existsResource(path);
	const auto layout = readLayout(path);
	out.json = !layout.files.empty() || !layout.replaced.empty();

	// in group and frame order: the .def frames, replaced or added to by the layout's files
	std::map<std::pair<size_t, size_t>, SpriteFrame> frames;
	if(out.def)
	{
		const CDefFile def(path);
		bool paletteCopied = false;
		// frames of the same name and size are the same pixels in the file (an idle group repeats frames): decode once
		std::map<std::tuple<std::string, uint32_t, uint32_t, int32_t, int32_t>, SpriteFrame> known;
		for(const auto & [group, count] : def.getEntries())
			for(size_t frame = 0; frame < count; frame++)
			{
				if(layout.files.count({group, frame}) || layout.replaced.count(group))
					continue;
				const CDefFile::SSpriteDef info = def.getFrameInfo(frame, group);
				const auto key = std::make_tuple(def.getName(frame, group), info.width, info.height, info.leftMargin, info.topMargin);
				auto seen = std::get<0>(key).empty() ? known.end() : known.find(key);
				SpriteFrame f = seen != known.end() ? seen->second : SpriteFrame{};
				if(seen == known.end())
				{
					IndexLoader loader(out, f, paletteCopied);
					def.loadFrame(frame, group, loader);
					// an unsupported frame format writes no pixels: keep the data in step with the sizes
					out.data.resize(f.offset + f.size);
					known.emplace(key, f);
				}
				frames[{group, frame}] = f;
			}
	}
	for(const auto & [where, file] : layout.files)
	{
		const auto body = findImage(file);
		if(!body)
			continue;
		SpriteFrame f{};
		f.format = VCMI_FRAME_PNG;
		std::tie(f.offset, f.size) = appendFile(out, *body);
		std::tie(f.width, f.height) = pngSize(out.data.data() + f.offset, f.size);
		f.fullWidth = f.width;
		f.fullHeight = f.height;
		// the owner flag mask, named as loadScaledImage does (RenderHandler.cpp:464-472): the name without extension
		if(const auto mask = findImage(ImagePath::builtin(file).getName() + "-OVERLAY"))
			std::tie(f.overlayOffset, f.overlaySize) = appendFile(out, *mask);
		frames[where] = f;
	}
	for(auto & [where, f] : frames)
	{
		f.group = static_cast<uint16_t>(where.first);
		f.frame = static_cast<uint16_t>(where.second);
		out.frames.push_back(f);
	}
	return out;
}
