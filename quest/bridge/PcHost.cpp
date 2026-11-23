/*
 * PcHost.cpp, Meta Quest build on the PC: the game as a library inside the Godot host (quest/EMULATORS.md), included
 * by Bridge.cpp on Windows. The host calls pcMain on a thread of its own; SDL's offscreen video driver with its
 * software renderer keeps the window's image in memory, which pcFrame has the game thread copy, and pcMouse / pcKey push SDL events, the
 * same path the Android plugin's MotionEvents and KeyEvents take. No change to the game's code.
 *
 * License: GNU General Public License v2.0 or later
 */

#include <SDL3/SDL.h>

// the client's entry point (clientapp/EntryPoint.cpp with ENABLE_DEBUG_CONSOLE, the default); it tells SDL itself that
// main ran, and changes to argv[0]'s folder
extern "C" int wmain(int argc, wchar_t * argv[]);

namespace
{

// the window size the host shows (main.gd SURFACE_SIZE): the offscreen driver's desktop is 1024x768, which the game's
// window settings cannot exceed, so the window is resized once it exists
std::atomic<int> wantedWidth{0};
std::atomic<int> wantedHeight{0};
// the last frame, copied on the game thread (the window surface changes on a resize), read by the host's thread
std::mutex frameMutex;
std::vector<uint8_t> frame;
uint32_t frameWidth = 0;
uint32_t frameHeight = 0;
std::atomic<bool> copyPending{false};
// the game window's id, read on the game thread: the host's thread must not walk SDL's window list
std::atomic<SDL_WindowID> windowId{0};
// the controllers as one SDL gamepad (QuestGamepad on Android), attached and used on the game thread only
SDL_Joystick * gamepad = nullptr;

// game thread, once SDL runs: the game opens it on SDL_EVENT_GAMEPAD_ADDED and uses its controller bindings
void attachGamepad()
{
	SDL_VirtualJoystickDesc desc;
	SDL_INIT_INTERFACE(&desc);
	desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
	desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
	desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
	desc.name = "Meta Quest Touch";
	gamepad = SDL_OpenJoystick(SDL_AttachVirtualJoystick(&desc));
	if(!gamepad)
		SDL_Log("VCMI PC host: no virtual gamepad: %s", SDL_GetError());
}

int pcMain(int argc, char ** argv, uint32_t width, uint32_t height)
{
	wantedWidth = width;
	wantedHeight = height;
	SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "offscreen");
	SDL_SetHint(SDL_HINT_RENDER_DRIVER, "software");
	// the UTF-8 arguments as UTF-16, Windows' wchar_t; kept until the process ends
	std::vector<wchar_t *> wide;
	for(int i = 0; i < argc; i++)
		wide.push_back(reinterpret_cast<wchar_t *>(SDL_iconv_string("UTF-16LE", "UTF-8", argv[i], SDL_strlen(argv[i]) + 1)));
	wide.push_back(nullptr);
	const int code = wmain(argc, wide.data());
	// the game quit from its own menu: end the host too, as the process ends with the game on Android. Running on would
	// let the bridge's lifecycle thread post to the destroyed engine (start(), shortcut there)
	std::quick_exit(code);
}

SDL_Window * gameWindow()
{
	int count = 0;
	SDL_Window ** windows = SDL_GetWindows(&count);
	SDL_Window * window = count > 0 ? windows[0] : nullptr;
	SDL_free(windows);
	return window;
}

// game thread, between two of its frames
void copyFrame()
{
	copyPending = false;
	[[maybe_unused]] static const bool attached = (attachGamepad(), true);
	SDL_Window * window = gameWindow();
	windowId = window ? SDL_GetWindowID(window) : 0;
	if(!window)
		return;
	int width = 0;
	int height = 0;
	SDL_GetWindowSize(window, &width, &height);
	if(wantedWidth > 0 && (width != wantedWidth || height != wantedHeight))
	{
		SDL_SetWindowSize(window, wantedWidth, wantedHeight); // the game follows its window (ScreenHandler::onScreenResize)
		return;
	}
	// the software renderer draws into this surface, the offscreen driver keeps it
	SDL_Surface * surface = SDL_GetWindowSurface(window);
	if(!surface)
		return;
	std::lock_guard lock(frameMutex);
	frame.resize(static_cast<size_t>(surface->w) * surface->h * 4);
	if(SDL_ConvertPixels(surface->w, surface->h, surface->format, surface->pixels, surface->pitch, SDL_PIXELFORMAT_RGBA32, frame.data(), surface->w * 4))
	{
		frameWidth = surface->w;
		frameHeight = surface->h;
	}
}

uint8_t pcFrame(uint8_t * out, uint32_t capacity, uint32_t * width, uint32_t * height)
{
	// the next copy, at most 30 a second; one pending for a second is posted again, as the lifecycle tick (start())
	static auto postedAt = std::chrono::steady_clock::time_point();
	const auto now = std::chrono::steady_clock::now();
	if(ENGINE && now - postedAt > std::chrono::milliseconds(33) && (!copyPending.exchange(true) || now - postedAt > std::chrono::seconds(1)))
	{
		ENGINE->dispatchMainThread(copyFrame);
		postedAt = now;
	}
	std::lock_guard lock(frameMutex);
	*width = frameWidth;
	*height = frameHeight;
	if(frameWidth == 0 || capacity < frame.size())
		return 0;
	std::memcpy(out, frame.data(), frame.size());
	return 1;
}

void pcMouse(float x, float y, uint8_t button, uint8_t pressed)
{
	if(!windowId)
		return;
	SDL_Event event{};
	if(button == 0)
	{
		event.type = SDL_EVENT_MOUSE_MOTION;
		event.motion.windowID = windowId;
		event.motion.x = x;
		event.motion.y = y;
	}
	else
	{
		event.type = pressed ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP;
		event.button.windowID = windowId;
		event.button.button = button == 2 ? SDL_BUTTON_RIGHT : SDL_BUTTON_LEFT;
		event.button.down = pressed;
		event.button.clicks = 1;
		event.button.x = x;
		event.button.y = y;
	}
	SDL_PushEvent(&event);
}

// the Android key codes the host sends (KeyEvent.KEYCODE_*) as SDL key codes. shortcut: pushed key events do not change
// SDL's keyboard state, from which the game reads Ctrl, Shift and Alt; SDL's virtual keyboard would, when the PC needs
// modifiers. Text goes in through pcText
SDL_Keycode sdlKey(int32_t code)
{
	if(code >= 29 && code <= 54) // A..Z
		return SDLK_A + (code - 29);
	if(code >= 7 && code <= 16) // 0..9
		return SDLK_0 + (code - 7);
	if(code >= 131 && code <= 142) // F1..F12
		return SDLK_F1 + (code - 131);
	switch(code)
	{
		case 19:
			return SDLK_UP;
		case 20:
			return SDLK_DOWN;
		case 21:
			return SDLK_LEFT;
		case 22:
			return SDLK_RIGHT;
		case 57:
			return SDLK_LALT;
		case 59:
			return SDLK_LSHIFT;
		case 61:
			return SDLK_TAB;
		case 62:
			return SDLK_SPACE;
		case 66:
			return SDLK_RETURN;
		case 67:
			return SDLK_BACKSPACE;
		case 111:
			return SDLK_ESCAPE;
		case 113:
			return SDLK_LCTRL;
		default:
			return SDLK_UNKNOWN;
	}
}

void pcKey(int32_t androidKeycode, uint8_t pressed)
{
	const SDL_Keycode key = sdlKey(androidKeycode);
	if(!windowId || key == SDLK_UNKNOWN)
		return;
	SDL_Event event{};
	event.type = pressed ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
	event.key.windowID = windowId;
	event.key.key = key;
	event.key.scancode = SDL_GetScancodeFromKey(key, nullptr); // the game names its bindings by scan code
	event.key.down = pressed;
	SDL_PushEvent(&event);
}

void pcText(const char * utf8)
{
	if(!windowId || !utf8 || !*utf8)
		return;
	SDL_Event event{};
	event.type = SDL_EVENT_TEXT_INPUT;
	event.text.windowID = windowId;
	// shortcut: never freed (SDL copies the event, not its text), a few bytes per typed line; fine for tests
	event.text.text = SDL_strdup(utf8);
	SDL_PushEvent(&event);
}

// KeyEvent.KEYCODE_BUTTON_* as SDL gamepad buttons, those main.gd PAD_BUTTONS sends and the face buttons
SDL_GamepadButton padButton(int32_t code)
{
	switch(code)
	{
		case 96:
			return SDL_GAMEPAD_BUTTON_SOUTH; // A
		case 97:
			return SDL_GAMEPAD_BUTTON_EAST; // B
		case 99:
			return SDL_GAMEPAD_BUTTON_WEST; // X
		case 100:
			return SDL_GAMEPAD_BUTTON_NORTH; // Y
		case 102:
			return SDL_GAMEPAD_BUTTON_LEFT_SHOULDER;
		case 103:
			return SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER;
		case 106:
			return SDL_GAMEPAD_BUTTON_LEFT_STICK;
		case 107:
			return SDL_GAMEPAD_BUTTON_RIGHT_STICK;
		case 108:
			return SDL_GAMEPAD_BUTTON_START;
		default:
			return SDL_GAMEPAD_BUTTON_INVALID;
	}
}

void pcButton(int32_t androidKeycode, uint8_t pressed)
{
	const SDL_GamepadButton button = padButton(androidKeycode);
	if(ENGINE && button != SDL_GAMEPAD_BUTTON_INVALID)
		ENGINE->dispatchMainThread(
			[button, pressed]()
			{
				SDL_SetJoystickVirtualButton(gamepad, button, pressed);
			}
		);
}

void pcAxis(int32_t axis, float value)
{
	if(ENGINE && axis >= 0 && axis < SDL_GAMEPAD_AXIS_COUNT)
	{
		const auto position = static_cast<Sint16>(std::clamp(value, -1.0f, 1.0f) * SDL_JOYSTICK_AXIS_MAX);
		ENGINE->dispatchMainThread(
			[axis, position]()
			{
				SDL_SetJoystickVirtualAxis(gamepad, axis, position);
			}
		);
	}
}

}
