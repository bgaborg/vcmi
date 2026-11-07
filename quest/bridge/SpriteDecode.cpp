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

namespace
{
// appends a frame's indices to the animation's pixel buffer; init gives the frame's real size (after the fix of the
// old SGTWMTA format in CDefFile::loadFrame) and the palette
class IndexLoader : public IImageLoader
{
public:
	IndexLoader(SpriteAnimation & out, SpriteFrame & frame) : anim(out), f(frame) {}

	void init(Point size, Point margins, Point fullSize, SDL_Color * pal) override
	{
		f.offset = static_cast<uint32_t>(anim.pixels.size());
		f.width = static_cast<uint16_t>(size.x);
		f.height = static_cast<uint16_t>(size.y);
		f.left = static_cast<int16_t>(margins.x);
		f.top = static_cast<int16_t>(margins.y);
		f.fullWidth = static_cast<uint16_t>(fullSize.x);
		f.fullHeight = static_cast<uint16_t>(fullSize.y);
		if(f.offset == 0)
		{
			// one palette per file; SDL_Color is {r, g, b, a} bytes in SDL2 and SDL3
			const auto * rgba = reinterpret_cast<const uint8_t *>(pal);
			for(int i = 0; i < 256; i++)
				std::memcpy(&anim.palette[i * 3], rgba + i * 4, 3);
		}
		anim.pixels.reserve(anim.pixels.size() + size_t(size.x) * size.y);
		rowStart = anim.pixels.size();
	}
	void load(size_t size, const ui8 * data) override { anim.pixels.insert(anim.pixels.end(), data, data + size); }
	void load(size_t size, ui8 color) override { anim.pixels.insert(anim.pixels.end(), size, color); }
	// a row's last run can be longer than what is left of the row; the SDL loader skips to the next row, as here
	void endLine() override
	{
		if(anim.pixels.size() != rowStart + f.width)
		{
			anim.overruns += anim.pixels.size() > rowStart + f.width;
			anim.pixels.resize(rowStart + f.width);
		}
		rowStart += f.width;
	}

private:
	SpriteAnimation & anim;
	SpriteFrame & f;
	size_t rowStart = 0;
};
}

SpriteAnimation decodeAnimation(const std::string & name)
{
	SpriteAnimation out;
	// as RenderHandler::getAnimationFile and getAnimationLayout (clientsdl3/render/RenderHandler.cpp) find them
	const auto path = AnimationPath::builtin(boost::starts_with(name, "SPRITES/") ? name : "SPRITES/" + name);
	out.json = CResourceHandler::get()->existsResource(path.toType<EResType::JSON>());
	out.def = CResourceHandler::get()->existsResource(path);
	if(!out.def)
		return out;

	const CDefFile def(path);
	// frames of the same name and size are the same pixels in the file (an idle group repeats frames): decode them once
	std::map<std::tuple<std::string, uint32_t, uint32_t, int32_t, int32_t>, SpriteFrame> known;
	for(const auto & [group, count] : def.getEntries())
		for(size_t frame = 0; frame < count; frame++)
		{
			const CDefFile::SSpriteDef info = def.getFrameInfo(frame, group);
			const auto key = std::make_tuple(def.getName(frame, group), info.width, info.height, info.leftMargin, info.topMargin);
			auto seen = std::get<0>(key).empty() ? known.end() : known.find(key);
			SpriteFrame f = seen != known.end() ? seen->second : SpriteFrame{};
			if(seen == known.end())
			{
				IndexLoader loader(out, f);
				def.loadFrame(frame, group, loader);
				// an unsupported frame format writes no pixels: keep the buffer in step with the sizes
				out.pixels.resize(f.offset + size_t(f.width) * f.height);
				known.emplace(key, f);
			}
			f.group = static_cast<uint16_t>(group);
			f.frame = static_cast<uint16_t>(frame);
			out.frames.push_back(f);
		}
	return out;
}
