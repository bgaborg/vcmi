/*
 * XrDisplay.cpp, part of VCMI engine
 *
 * Authors: listed in file AUTHORS in main folder
 *
 * License: GNU General Public License v2.0 or later
 * Full text of license available in license.txt file, in main folder
 *
 */
#include "../../Global.h"
#include "XrDisplay.h"
#include "XrLoader.h"

#include "../../lib/logging/CLogger.h"

#include <SDL3/SDL.h>

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <jni.h>

#define XR_USE_GRAPHICS_API_OPENGL_ES
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#ifndef GL_FRAMEBUFFER_SRGB_EXT
#define GL_FRAMEBUFFER_SRGB_EXT 0x8DB9
#endif

namespace
{

/// Distance from the head to the game screen, in metres
constexpr float layerDistance = 2.0f;
/// Width of the game screen, in metres
constexpr float layerWidth = 2.4f;
/// Length of a controller ray that misses the game screen, in metres
constexpr float maxRayLength = 5.0f;

#define VCMI_XR_INSTANCE_FUNCTIONS(X) \
	X(xrDestroyInstance) \
	X(xrGetSystem) \
	X(xrGetOpenGLESGraphicsRequirementsKHR) \
	X(xrCreateSession) \
	X(xrDestroySession) \
	X(xrBeginSession) \
	X(xrEndSession) \
	X(xrRequestExitSession) \
	X(xrPollEvent) \
	X(xrCreateReferenceSpace) \
	X(xrDestroySpace) \
	X(xrEnumerateSwapchainFormats) \
	X(xrCreateSwapchain) \
	X(xrDestroySwapchain) \
	X(xrEnumerateSwapchainImages) \
	X(xrAcquireSwapchainImage) \
	X(xrWaitSwapchainImage) \
	X(xrReleaseSwapchainImage) \
	X(xrWaitFrame) \
	X(xrBeginFrame) \
	X(xrEndFrame) \
	X(xrStringToPath) \
	X(xrCreateActionSet) \
	X(xrDestroyActionSet) \
	X(xrCreateAction) \
	X(xrSuggestInteractionProfileBindings) \
	X(xrAttachSessionActionSets) \
	X(xrCreateActionSpace) \
	X(xrSyncActions) \
	X(xrGetActionStateBoolean) \
	X(xrLocateSpace) \
	X(xrEnumerateViewConfigurationViews) \
	X(xrLocateViews)

struct XrInstanceFunctions
{
#define VCMI_XR_DECLARE(name) PFN_##name name = nullptr;
	VCMI_XR_INSTANCE_FUNCTIONS(VCMI_XR_DECLARE)
#undef VCMI_XR_DECLARE

	/// Returns false if the runtime does not provide one of the functions
	bool load(PFN_xrGetInstanceProcAddr getInstanceProcAddr, XrInstance instance)
	{
		bool loaded = true;
#define VCMI_XR_LOAD(name) \
		name = XrLoader::getFunction<PFN_##name>(getInstanceProcAddr, instance, #name); \
		if(name == nullptr) \
		{ \
			logGlobal->warn("OpenXR: runtime does not provide %s", #name); \
			loaded = false; \
		}
		VCMI_XR_INSTANCE_FUNCTIONS(VCMI_XR_LOAD)
#undef VCMI_XR_LOAD
		return loaded;
	}
};

const char * sessionStateName(XrSessionState state)
{
	switch(state)
	{
		case XR_SESSION_STATE_IDLE: return "idle";
		case XR_SESSION_STATE_READY: return "ready";
		case XR_SESSION_STATE_SYNCHRONIZED: return "synchronized";
		case XR_SESSION_STATE_VISIBLE: return "visible";
		case XR_SESSION_STATE_FOCUSED: return "focused";
		case XR_SESSION_STATE_STOPPING: return "stopping";
		case XR_SESSION_STATE_LOSS_PENDING: return "loss pending";
		case XR_SESSION_STATE_EXITING: return "exiting";
		default: return "unknown";
	}
}

/// Logs a failed per-frame call; stops after a few messages so that a persistent failure does not flood the log
void warnFrameFailure(const char * call, XrResult result)
{
	static int remainingMessages = 20;
	if(remainingMessages <= 0)
		return;
	--remainingMessages;
	logGlobal->warn("OpenXR: %s failed, XrResult %d", call, static_cast<int>(result));
}

bool hasGlExtension(const std::string & name)
{
	const auto * extensions = reinterpret_cast<const char *>(glGetString(GL_EXTENSIONS));
	if(extensions == nullptr)
		return false;

	std::istringstream stream(extensions);
	std::string extension;
	while(stream >> extension)
		if(extension == name)
			return true;
	return false;
}

/// Returns 0 if the framebuffer is incomplete. Leaves the new framebuffer bound.
GLuint createFramebuffer(GLuint texture)
{
	GLuint framebuffer = 0;
	glGenFramebuffers(1, &framebuffer);
	glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);

	GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	if(status != GL_FRAMEBUFFER_COMPLETE)
	{
		logGlobal->warn("OpenXR: framebuffer for texture %d is incomplete, status 0x%x", texture, status);
		glDeleteFramebuffers(1, &framebuffer);
		return 0;
	}
	return framebuffer;
}

/// Whether the activity was started through an intent with the Horizon OS immersive category.
/// A session created from a panel activity would take the panel immersive.
bool launchedImmersive(JNIEnv * env, jobject activity)
{
	jclass activityClass = env->GetObjectClass(activity);
	jobject intent = env->CallObjectMethod(activity, env->GetMethodID(activityClass, "getIntent", "()Landroid/content/Intent;"));
	env->DeleteLocalRef(activityClass);
	if(intent == nullptr)
		return false;

	jclass intentClass = env->GetObjectClass(intent);
	jstring category = env->NewStringUTF("com.oculus.intent.category.VR");
	const bool result = env->CallBooleanMethod(intent, env->GetMethodID(intentClass, "hasCategory", "(Ljava/lang/String;)Z"), category);
	env->DeleteLocalRef(category);
	env->DeleteLocalRef(intentClass);
	env->DeleteLocalRef(intent);
	return result;
}

/// Column-major 4x4 matrix, as GLSL expects it
using Matrix = std::array<float, 16>;

Matrix multiply(const Matrix & a, const Matrix & b)
{
	Matrix result = {};
	for(int column = 0; column < 4; ++column)
		for(int row = 0; row < 4; ++row)
			for(int k = 0; k < 4; ++k)
				result[column * 4 + row] += a[k * 4 + row] * b[column * 4 + k];
	return result;
}

/// Transform from the local coordinates of `pose` to its space
Matrix poseMatrix(const XrPosef & pose)
{
	const auto [x, y, z, w] = pose.orientation;
	return {
		1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y), 0,
		2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x), 0,
		2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y), 0,
		pose.position.x, pose.position.y, pose.position.z, 1};
}

/// Inverse of poseMatrix: from the space of `pose` to its local coordinates
Matrix viewMatrix(const XrPosef & pose)
{
	const Matrix m = poseMatrix(pose);
	const XrVector3f & p = pose.position;
	return {
		m[0], m[4], m[8], 0,
		m[1], m[5], m[9], 0,
		m[2], m[6], m[10], 0,
		-(m[0] * p.x + m[1] * p.y + m[2] * p.z), -(m[4] * p.x + m[5] * p.y + m[6] * p.z), -(m[8] * p.x + m[9] * p.y + m[10] * p.z), 1};
}

/// GL projection for an asymmetric OpenXR field of view
Matrix projectionMatrix(const XrFovf & fov, float nearZ, float farZ)
{
	const float left = std::tan(fov.angleLeft);
	const float right = std::tan(fov.angleRight);
	const float up = std::tan(fov.angleUp);
	const float down = std::tan(fov.angleDown);
	return {
		2 / (right - left), 0, 0, 0,
		0, 2 / (up - down), 0, 0,
		(right + left) / (right - left), (up + down) / (up - down), -(farZ + nearZ) / (farZ - nearZ), -1,
		0, 0, -2 * farZ * nearZ / (farZ - nearZ), 0};
}

/// Box of `size` centred on `centre`, in local coordinates
Matrix boxMatrix(const XrVector3f & centre, const XrVector3f & size)
{
	return {size.x, 0, 0, 0, 0, size.y, 0, 0, 0, 0, size.z, 0, centre.x, centre.y, centre.z, 1};
}

/// Unit cube as triangles, counter-clockwise from outside; each vertex is x, y, z and the brightness of its face
std::vector<float> unitCube()
{
	std::vector<float> vertices;
	for(int axis = 0; axis < 3; ++axis)
	{
		for(float side : {-0.5f, 0.5f})
		{
			const float brightness = axis == 1 ? (side > 0 ? 1.0f : 0.45f) : (axis == 0 ? 0.75f : 0.6f);
			std::array<std::array<float, 3>, 4> corners = {};
			const std::array<std::array<float, 2>, 4> faceCorners = {{{-0.5f, -0.5f}, {0.5f, -0.5f}, {0.5f, 0.5f}, {-0.5f, 0.5f}}};
			for(size_t i = 0; i < 4; ++i)
			{
				corners[i][axis] = side;
				corners[i][(axis + 1) % 3] = faceCorners[i][0];
				corners[i][(axis + 2) % 3] = faceCorners[i][1];
			}
			// the corner order above is counter-clockwise seen from the positive side of the axis
			const bool flip = side < 0;
			for(size_t index : flip ? std::array<size_t, 6>{0, 2, 1, 0, 3, 2} : std::array<size_t, 6>{0, 1, 2, 0, 2, 3})
			{
				vertices.insert(vertices.end(), corners[index].begin(), corners[index].end());
				vertices.push_back(brightness);
			}
		}
	}
	return vertices;
}

GLuint compileShader(GLenum type, const char * source)
{
	GLuint shader = glCreateShader(type);
	glShaderSource(shader, 1, &source, nullptr);
	glCompileShader(shader);
	GLint compiled = GL_FALSE;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
	if(compiled != GL_TRUE)
	{
		std::array<char, 512> message = {};
		glGetShaderInfoLog(shader, message.size(), nullptr, message.data());
		logGlobal->warn("OpenXR: shader compilation failed: %s", message.data());
		glDeleteShader(shader);
		return 0;
	}
	return shader;
}

class XrDisplayImpl
{
	XrInstanceFunctions xr;
	jobject activity = nullptr;
	XrInstance instance = XR_NULL_HANDLE;
	XrSystemId systemId = XR_NULL_SYSTEM_ID;
	XrSession session = XR_NULL_HANDLE;
	XrSpace space = XR_NULL_HANDLE;
	bool sessionRunning = false;

	int64_t swapchainFormat = 0;
	/// The swapchain is sRGB: the copy must store the sRGB values of the game frame without encoding them again
	bool disableSrgbEncoding = false;

	XrSwapchain swapchain = XR_NULL_HANDLE;
	int swapchainWidth = 0;
	int swapchainHeight = 0;
	std::vector<GLuint> swapchainFramebuffers;

	/// Render target the game frame is drawn into, then copied to the acquired swapchain image.
	/// SDL cannot draw into swapchain images directly: it redefines the storage of wrapped textures.
	SDL_Texture * frameTarget = nullptr;
	GLuint frameFramebuffer = 0;

	/// Controller input: the aim ray of the hand that pressed a button last moves the mouse, trigger and grip are its buttons
	XrActionSet actionSet = XR_NULL_HANDLE;
	XrAction aimAction = XR_NULL_HANDLE;
	XrAction leftClickAction = XR_NULL_HANDLE;
	XrAction rightClickAction = XR_NULL_HANDLE;
	std::array<XrPath, 2> handPaths = {};
	std::array<XrSpace, 2> aimSpaces = {};
	size_t activeHand = 1;
	SDL_MouseButtonFlags pressedButtons = 0;
	float pointerX = 0;
	float pointerY = 0;
	/// Aim poses of this frame; nullopt while a controller is not tracked
	std::array<std::optional<XrPosef>, 2> aimPoses;
	/// Length of the ray of the active hand: up to the layer, or the full length if it misses
	float rayLength = 0;

	/// Transparent projection layer over the game screen with the controllers and the ray, both eyes side by side
	XrSwapchain sceneSwapchain = XR_NULL_HANDLE;
	int eyeWidth = 0;
	int eyeHeight = 0;
	std::vector<GLuint> sceneFramebuffers;
	GLuint sceneProgram = 0;
	GLuint sceneVertexArray = 0;
	GLuint sceneVertexBuffer = 0;
	GLint mvpLocation = -1;
	GLint colorLocation = -1;
	GLsizei cubeVertexCount = 0;
	std::array<XrCompositionLayerProjectionView, 2> sceneViews = {};

	bool createInstance(PFN_xrGetInstanceProcAddr getInstanceProcAddr, JavaVM * javaVm);
	bool createSession();
	bool createInput();
	void updateInput(SDL_Renderer * renderer, XrTime time);
	bool pointerPosition(float & windowX, float & windowY, SDL_Renderer * renderer);
	void pushMouseButton(SDL_Renderer * renderer, Uint8 button, bool pressed);
	bool sceneFailed = false;

	bool createScene();
	void destroyScene();
	bool renderScene(SDL_Renderer * renderer, XrTime time, XrCompositionLayerProjection & layer);
	void drawSceneView(const XrView & view);
	bool selectSwapchainFormat();
	bool createSwapchain(SDL_Renderer * renderer, int width, int height);
	void destroySwapchain();
	void pollEvents();
	void onSessionStateChanged(XrSessionState state);
	void exitSession();
	bool renderLayer(SDL_Renderer * renderer, const std::function<void()> & drawFrame, XrCompositionLayerQuad & layer);
	void copyToSwapchainImage(uint32_t imageIndex);

public:
	XrDisplayImpl() = default;
	XrDisplayImpl(const XrDisplayImpl &) = delete;
	XrDisplayImpl & operator=(const XrDisplayImpl &) = delete;
	~XrDisplayImpl();

	bool start();
	bool presentFrame(SDL_Renderer * renderer, const std::function<void()> & drawFrame);
};

bool XrDisplayImpl::start()
{
	auto * env = static_cast<JNIEnv *>(SDL_GetAndroidJNIEnv());
	JavaVM * javaVm = nullptr;
	if(env == nullptr || env->GetJavaVM(&javaVm) != JNI_OK)
	{
		logGlobal->warn("OpenXR: Java VM not available");
		return false;
	}

	auto localActivity = static_cast<jobject>(SDL_GetAndroidActivity());
	if(localActivity == nullptr)
	{
		logGlobal->warn("OpenXR: activity not available");
		return false;
	}

	if(!launchedImmersive(env, localActivity))
	{
		logGlobal->info("OpenXR: activity was not launched as immersive, running as a panel");
		env->DeleteLocalRef(localActivity);
		return false;
	}
	// the instance keeps using the activity, a local reference would expire with this call
	activity = env->NewGlobalRef(localActivity);
	env->DeleteLocalRef(localActivity);

	PFN_xrGetInstanceProcAddr getInstanceProcAddr = XrLoader::open(javaVm, activity);
	if(getInstanceProcAddr == nullptr)
		return false;

	if(!createInstance(getInstanceProcAddr, javaVm) || !createSession() || !selectSwapchainFormat())
		return false;

	// the game still shows without controller input
	if(!createInput())
		logGlobal->warn("OpenXR: controller input not available");
	return true;
}

bool XrDisplayImpl::createInput()
{
	const auto toPath = [this](const char * name)
	{
		XrPath path = XR_NULL_PATH;
		if(XR_FAILED(xr.xrStringToPath(instance, name, &path)))
			logGlobal->warn("OpenXR: invalid path %s", name);
		return path;
	};
	handPaths = {toPath("/user/hand/left"), toPath("/user/hand/right")};

	auto setInfo = XrLoader::makeStruct<XrActionSetCreateInfo>(XR_TYPE_ACTION_SET_CREATE_INFO);
	std::strncpy(setInfo.actionSetName, "game", XR_MAX_ACTION_SET_NAME_SIZE - 1);
	std::strncpy(setInfo.localizedActionSetName, "Game", XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
	if(XrResult result = xr.xrCreateActionSet(instance, &setInfo, &actionSet); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: action set creation failed, XrResult %d", static_cast<int>(result));
		actionSet = XR_NULL_HANDLE;
		return false;
	}

	const auto createAction = [this](XrAction & action, XrActionType type, const char * name, const char * localizedName)
	{
		auto actionInfo = XrLoader::makeStruct<XrActionCreateInfo>(XR_TYPE_ACTION_CREATE_INFO);
		actionInfo.actionType = type;
		std::strncpy(actionInfo.actionName, name, XR_MAX_ACTION_NAME_SIZE - 1);
		std::strncpy(actionInfo.localizedActionName, localizedName, XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
		actionInfo.countSubactionPaths = handPaths.size();
		actionInfo.subactionPaths = handPaths.data();
		XrResult result = xr.xrCreateAction(actionSet, &actionInfo, &action);
		if(XR_FAILED(result))
			logGlobal->warn("OpenXR: action %s creation failed, XrResult %d", name, static_cast<int>(result));
		return XR_SUCCEEDED(result);
	};
	if(!createAction(aimAction, XR_ACTION_TYPE_POSE_INPUT, "aim", "Aim")
		|| !createAction(leftClickAction, XR_ACTION_TYPE_BOOLEAN_INPUT, "left_click", "Left click")
		|| !createAction(rightClickAction, XR_ACTION_TYPE_BOOLEAN_INPUT, "right_click", "Right click"))
		return false;

	// the runtime turns the analog trigger and grip values into presses with its own threshold
	std::vector<XrActionSuggestedBinding> bindings;
	for(const char * hand : {"left", "right"})
	{
		const std::string prefix = std::string("/user/hand/") + hand;
		bindings.push_back({aimAction, toPath((prefix + "/input/aim/pose").c_str())});
		bindings.push_back({leftClickAction, toPath((prefix + "/input/trigger/value").c_str())});
		bindings.push_back({rightClickAction, toPath((prefix + "/input/squeeze/value").c_str())});
	}
	auto suggestedBindings = XrLoader::makeStruct<XrInteractionProfileSuggestedBinding>(XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING);
	suggestedBindings.interactionProfile = toPath("/interaction_profiles/oculus/touch_controller");
	suggestedBindings.countSuggestedBindings = bindings.size();
	suggestedBindings.suggestedBindings = bindings.data();
	if(XrResult result = xr.xrSuggestInteractionProfileBindings(instance, &suggestedBindings); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: controller bindings rejected, XrResult %d", static_cast<int>(result));
		return false;
	}

	auto attachInfo = XrLoader::makeStruct<XrSessionActionSetsAttachInfo>(XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO);
	attachInfo.countActionSets = 1;
	attachInfo.actionSets = &actionSet;
	if(XrResult result = xr.xrAttachSessionActionSets(session, &attachInfo); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: action set attachment failed, XrResult %d", static_cast<int>(result));
		return false;
	}

	for(size_t hand = 0; hand < aimSpaces.size(); ++hand)
	{
		auto spaceInfo = XrLoader::makeStruct<XrActionSpaceCreateInfo>(XR_TYPE_ACTION_SPACE_CREATE_INFO);
		spaceInfo.action = aimAction;
		spaceInfo.subactionPath = handPaths[hand];
		spaceInfo.poseInActionSpace.orientation.w = 1.0f;
		if(XrResult result = xr.xrCreateActionSpace(session, &spaceInfo, &aimSpaces[hand]); XR_FAILED(result))
		{
			logGlobal->warn("OpenXR: aim space creation failed, XrResult %d", static_cast<int>(result));
			aimSpaces[hand] = XR_NULL_HANDLE;
			return false;
		}
	}
	return true;
}

void XrDisplayImpl::updateInput(SDL_Renderer * renderer, XrTime time)
{
	aimPoses = {};
	if(aimSpaces[1] == XR_NULL_HANDLE || swapchain == XR_NULL_HANDLE)
		return;

	XrActiveActionSet activeSet = {actionSet, XR_NULL_PATH};
	auto syncInfo = XrLoader::makeStruct<XrActionsSyncInfo>(XR_TYPE_ACTIONS_SYNC_INFO);
	syncInfo.countActiveActionSets = 1;
	syncInfo.activeActionSets = &activeSet;
	// XR_SESSION_NOT_FOCUSED while the system menu is open: input belongs to the system, held buttons are released
	if(xr.xrSyncActions(session, &syncInfo) != XR_SUCCESS)
	{
		pushMouseButton(renderer, SDL_BUTTON_LEFT, false);
		pushMouseButton(renderer, SDL_BUTTON_RIGHT, false);
		return;
	}

	std::array<std::array<bool, 2>, 2> buttons = {}; // [hand][left click, right click]
	for(size_t hand = 0; hand < handPaths.size(); ++hand)
	{
		for(size_t button = 0; button < 2; ++button)
		{
			auto getInfo = XrLoader::makeStruct<XrActionStateGetInfo>(XR_TYPE_ACTION_STATE_GET_INFO);
			getInfo.action = button == 0 ? leftClickAction : rightClickAction;
			getInfo.subactionPath = handPaths[hand];
			auto state = XrLoader::makeStruct<XrActionStateBoolean>(XR_TYPE_ACTION_STATE_BOOLEAN);
			xr.xrGetActionStateBoolean(session, &getInfo, &state);
			buttons[hand][button] = state.isActive && state.currentState;
			if(state.isActive && state.currentState && state.changedSinceLastSync && pressedButtons == 0)
				activeHand = hand;
		}
	}

	for(size_t hand = 0; hand < aimSpaces.size(); ++hand)
	{
		aimPoses[hand].reset();
		auto location = XrLoader::makeStruct<XrSpaceLocation>(XR_TYPE_SPACE_LOCATION);
		const XrSpaceLocationFlags required = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
		if(XR_SUCCEEDED(xr.xrLocateSpace(aimSpaces[hand], space, time, &location)) && (location.locationFlags & required) == required)
			aimPoses[hand] = location.pose;
	}

	float windowX = 0;
	float windowY = 0;
	if(pointerPosition(windowX, windowY, renderer) && (windowX != pointerX || windowY != pointerY))
	{
		SDL_Event event{};
		event.type = SDL_EVENT_MOUSE_MOTION;
		event.motion.windowID = SDL_GetWindowID(SDL_GetRenderWindow(renderer));
		event.motion.state = pressedButtons;
		event.motion.x = windowX;
		event.motion.y = windowY;
		event.motion.xrel = windowX - pointerX;
		event.motion.yrel = windowY - pointerY;
		SDL_PushEvent(&event);
		pointerX = windowX;
		pointerY = windowY;
	}

	pushMouseButton(renderer, SDL_BUTTON_LEFT, buttons[activeHand][0]);
	pushMouseButton(renderer, SDL_BUTTON_RIGHT, buttons[activeHand][1]);
}

bool XrDisplayImpl::pointerPosition(float & windowX, float & windowY, SDL_Renderer * renderer)
{
	rayLength = maxRayLength;
	if(!aimPoses[activeHand])
		return false;

	// the aim pose points along its -Z axis; the layer lies in the plane z = -layerDistance, centred on the Z axis
	const XrQuaternionf & q = aimPoses[activeHand]->orientation;
	const XrVector3f & origin = aimPoses[activeHand]->position;
	const XrVector3f direction = {-2 * (q.x * q.z + q.w * q.y), 2 * (q.w * q.x - q.y * q.z), -1 + 2 * (q.x * q.x + q.y * q.y)};
	if(direction.z > -0.001f)
		return false;
	const float distance = (-layerDistance - origin.z) / direction.z;
	if(distance < 0)
		return false;

	const float layerHeight = layerWidth * static_cast<float>(swapchainHeight) / static_cast<float>(swapchainWidth);
	const float u = (origin.x + distance * direction.x) / layerWidth + 0.5f;
	const float v = 0.5f - (origin.y + distance * direction.y) / layerHeight;
	if(u < 0 || u > 1 || v < 0 || v > 1)
		return false;

	rayLength = distance;

	// the events are converted back to render coordinates like the events of a real mouse
	return SDL_RenderCoordinatesToWindow(renderer, u * swapchainWidth, v * swapchainHeight, &windowX, &windowY);
}

void XrDisplayImpl::pushMouseButton(SDL_Renderer * renderer, Uint8 button, bool pressed)
{
	if(((pressedButtons & SDL_BUTTON_MASK(button)) != 0) == pressed)
		return;

	if(pressed)
		pressedButtons |= SDL_BUTTON_MASK(button);
	else
		pressedButtons &= ~SDL_BUTTON_MASK(button);

	SDL_Event event{};
	event.type = pressed ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP;
	event.button.windowID = SDL_GetWindowID(SDL_GetRenderWindow(renderer));
	event.button.button = button;
	event.button.down = pressed;
	event.button.clicks = 1;
	event.button.x = pointerX;
	event.button.y = pointerY;
	SDL_PushEvent(&event);
}

bool XrDisplayImpl::createInstance(PFN_xrGetInstanceProcAddr getInstanceProcAddr, JavaVM * javaVm)
{
	auto createInstanceFunction = XrLoader::getFunction<PFN_xrCreateInstance>(getInstanceProcAddr, XR_NULL_HANDLE, "xrCreateInstance");
	if(createInstanceFunction == nullptr)
	{
		logGlobal->warn("OpenXR: loader does not provide xrCreateInstance");
		return false;
	}

	const std::array extensions = {
		XR_KHR_ANDROID_CREATE_INSTANCE_EXTENSION_NAME,
		XR_KHR_OPENGL_ES_ENABLE_EXTENSION_NAME,
	};

	auto androidInfo = XrLoader::makeStruct<XrInstanceCreateInfoAndroidKHR>(XR_TYPE_INSTANCE_CREATE_INFO_ANDROID_KHR);
	androidInfo.applicationVM = javaVm;
	androidInfo.applicationActivity = activity;

	auto createInfo = XrLoader::makeStruct<XrInstanceCreateInfo>(XR_TYPE_INSTANCE_CREATE_INFO);
	createInfo.next = &androidInfo;
	std::strncpy(createInfo.applicationInfo.applicationName, "VCMI", XR_MAX_APPLICATION_NAME_SIZE - 1);
	std::strncpy(createInfo.applicationInfo.engineName, "VCMI", XR_MAX_ENGINE_NAME_SIZE - 1);
	createInfo.applicationInfo.apiVersion = XR_API_VERSION_1_0;
	createInfo.enabledExtensionCount = extensions.size();
	createInfo.enabledExtensionNames = extensions.data();

	if(XrResult result = createInstanceFunction(&createInfo, &instance); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: instance creation failed, XrResult %d", static_cast<int>(result));
		instance = XR_NULL_HANDLE;
		return false;
	}

	if(!xr.load(getInstanceProcAddr, instance))
		return false;

	auto systemInfo = XrLoader::makeStruct<XrSystemGetInfo>(XR_TYPE_SYSTEM_GET_INFO);
	systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
	if(XrResult result = xr.xrGetSystem(instance, &systemInfo, &systemId); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: no head-mounted display system, XrResult %d", static_cast<int>(result));
		return false;
	}
	return true;
}

bool XrDisplayImpl::createSession()
{
	auto requirements = XrLoader::makeStruct<XrGraphicsRequirementsOpenGLESKHR>(XR_TYPE_GRAPHICS_REQUIREMENTS_OPENGL_ES_KHR);
	if(XrResult result = xr.xrGetOpenGLESGraphicsRequirementsKHR(instance, systemId, &requirements); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: GLES requirements not available, XrResult %d", static_cast<int>(result));
		return false;
	}

	GLint majorVersion = 0;
	GLint minorVersion = 0;
	glGetIntegerv(GL_MAJOR_VERSION, &majorVersion);
	glGetIntegerv(GL_MINOR_VERSION, &minorVersion);
	const auto * versionString = reinterpret_cast<const char *>(glGetString(GL_VERSION));
	logGlobal->info("OpenXR: GLES context %d.%d (%s), runtime supports %s to %s",
		majorVersion,
		minorVersion,
		versionString ? versionString : "unknown",
		XrLoader::versionToString(requirements.minApiVersionSupported),
		XrLoader::versionToString(requirements.maxApiVersionSupported));

	if(XR_MAKE_VERSION(majorVersion, minorVersion, 0) < requirements.minApiVersionSupported)
	{
		logGlobal->warn("OpenXR: GLES context is older than the runtime requires");
		return false;
	}

	auto binding = XrLoader::makeStruct<XrGraphicsBindingOpenGLESAndroidKHR>(XR_TYPE_GRAPHICS_BINDING_OPENGL_ES_ANDROID_KHR);
	binding.display = eglGetCurrentDisplay();
	binding.config = static_cast<EGLConfig>(SDL_EGL_GetCurrentConfig());
	// shortcut: the session stays bound to this context; handle SDL_EVENT_RENDER_DEVICE_RESET if the context is ever lost on resume
	binding.context = eglGetCurrentContext();
	if(binding.display == EGL_NO_DISPLAY || binding.config == nullptr || binding.context == EGL_NO_CONTEXT)
	{
		logGlobal->warn("OpenXR: no current EGL context");
		return false;
	}

	auto sessionInfo = XrLoader::makeStruct<XrSessionCreateInfo>(XR_TYPE_SESSION_CREATE_INFO);
	sessionInfo.next = &binding;
	sessionInfo.systemId = systemId;
	if(XrResult result = xr.xrCreateSession(instance, &sessionInfo, &session); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: session creation failed, XrResult %d", static_cast<int>(result));
		session = XR_NULL_HANDLE;
		return false;
	}

	auto spaceInfo = XrLoader::makeStruct<XrReferenceSpaceCreateInfo>(XR_TYPE_REFERENCE_SPACE_CREATE_INFO);
	spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
	spaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
	if(XrResult result = xr.xrCreateReferenceSpace(session, &spaceInfo, &space); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: reference space creation failed, XrResult %d", static_cast<int>(result));
		space = XR_NULL_HANDLE;
		return false;
	}

	logGlobal->info("OpenXR: session created");
	return true;
}

bool XrDisplayImpl::selectSwapchainFormat()
{
	uint32_t formatCount = 0;
	if(XrResult result = xr.xrEnumerateSwapchainFormats(session, 0, &formatCount, nullptr); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: swapchain format enumeration failed, XrResult %d", static_cast<int>(result));
		return false;
	}
	std::vector<int64_t> formats(formatCount);
	xr.xrEnumerateSwapchainFormats(session, formatCount, &formatCount, formats.data());

	std::string formatList;
	for(int64_t format : formats)
		formatList += boost::str(boost::format(" 0x%x") % format);

	const bool srgbWriteControl = hasGlExtension("GL_EXT_sRGB_write_control");
	logGlobal->info("OpenXR: swapchain formats%s; GL_EXT_sRGB_write_control: %s", formatList, srgbWriteControl ? "yes" : "no");

	if(srgbWriteControl && vstd::contains(formats, GL_SRGB8_ALPHA8))
	{
		swapchainFormat = GL_SRGB8_ALPHA8;
		disableSrgbEncoding = true;
	}
	else if(vstd::contains(formats, GL_RGBA8))
	{
		swapchainFormat = GL_RGBA8;
	}
	else
	{
		logGlobal->warn("OpenXR: runtime supports neither GL_SRGB8_ALPHA8 nor GL_RGBA8 swapchains");
		return false;
	}

	logGlobal->info("OpenXR: swapchain format 0x%x", swapchainFormat);
	return true;
}

bool XrDisplayImpl::createSwapchain(SDL_Renderer * renderer, int width, int height)
{
	auto createInfo = XrLoader::makeStruct<XrSwapchainCreateInfo>(XR_TYPE_SWAPCHAIN_CREATE_INFO);
	// the compositor samples the image
	createInfo.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
	createInfo.format = swapchainFormat;
	createInfo.sampleCount = 1;
	createInfo.width = width;
	createInfo.height = height;
	createInfo.faceCount = 1;
	createInfo.arraySize = 1;
	createInfo.mipCount = 1;

	if(XrResult result = xr.xrCreateSwapchain(session, &createInfo, &swapchain); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: swapchain creation failed, XrResult %d", static_cast<int>(result));
		swapchain = XR_NULL_HANDLE;
		return false;
	}

	uint32_t imageCount = 0;
	xr.xrEnumerateSwapchainImages(swapchain, 0, &imageCount, nullptr);
	std::vector<XrSwapchainImageOpenGLESKHR> images(imageCount, XrLoader::makeStruct<XrSwapchainImageOpenGLESKHR>(XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR));
	if(XrResult result = xr.xrEnumerateSwapchainImages(swapchain, imageCount, &imageCount, reinterpret_cast<XrSwapchainImageBaseHeader *>(images.data())); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: swapchain image enumeration failed, XrResult %d", static_cast<int>(result));
		return false;
	}

	frameTarget = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_TARGET, width, height);
	if(frameTarget == nullptr)
	{
		logGlobal->warn("OpenXR: frame render target creation failed: %s", SDL_GetError());
		return false;
	}
	auto frameTexture = static_cast<GLuint>(SDL_GetNumberProperty(SDL_GetTextureProperties(frameTarget), SDL_PROP_TEXTURE_OPENGLES2_TEXTURE_NUMBER, 0));

	// raw GL calls follow, SDL must not have commands queued that it would issue in between
	SDL_FlushRenderer(renderer);
	GLint previousFramebuffer = 0;
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);

	frameFramebuffer = createFramebuffer(frameTexture);
	for(const auto & image : images)
		swapchainFramebuffers.push_back(createFramebuffer(image.image));

	glBindFramebuffer(GL_FRAMEBUFFER, previousFramebuffer);

	if(frameFramebuffer == 0 || vstd::contains(swapchainFramebuffers, 0u))
		return false;

	logGlobal->info("OpenXR: swapchain %dx%d with %d images", width, height, imageCount);
	return true;
}

void XrDisplayImpl::destroySwapchain()
{
	if(frameFramebuffer != 0)
		glDeleteFramebuffers(1, &frameFramebuffer);
	frameFramebuffer = 0;

	for(GLuint framebuffer : swapchainFramebuffers)
		if(framebuffer != 0)
			glDeleteFramebuffers(1, &framebuffer);
	swapchainFramebuffers.clear();

	if(frameTarget != nullptr)
		SDL_DestroyTexture(frameTarget);
	frameTarget = nullptr;

	if(swapchain != XR_NULL_HANDLE)
		xr.xrDestroySwapchain(swapchain);
	swapchain = XR_NULL_HANDLE;
}

void XrDisplayImpl::exitSession()
{
	if(!sessionRunning)
		return;

	if(XrResult result = xr.xrRequestExitSession(session); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: xrRequestExitSession failed, XrResult %d", static_cast<int>(result));
		return;
	}

	// the runtime reaches the stopping state only while frames are submitted; about 1.5 s at most
	for(int frame = 0; frame < 100 && sessionRunning; ++frame)
	{
		auto frameState = XrLoader::makeStruct<XrFrameState>(XR_TYPE_FRAME_STATE);
		auto waitInfo = XrLoader::makeStruct<XrFrameWaitInfo>(XR_TYPE_FRAME_WAIT_INFO);
		auto beginInfo = XrLoader::makeStruct<XrFrameBeginInfo>(XR_TYPE_FRAME_BEGIN_INFO);
		if(XR_FAILED(xr.xrWaitFrame(session, &waitInfo, &frameState)) || XR_FAILED(xr.xrBeginFrame(session, &beginInfo)))
			break;
		auto endInfo = XrLoader::makeStruct<XrFrameEndInfo>(XR_TYPE_FRAME_END_INFO);
		endInfo.displayTime = frameState.predictedDisplayTime;
		endInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
		xr.xrEndFrame(session, &endInfo);
		pollEvents();
	}
	if(sessionRunning)
		logGlobal->warn("OpenXR: session did not stop before shutdown");
}

XrDisplayImpl::~XrDisplayImpl()
{
	// destroying a running session skips the stopping state, the runtime then cleans up after the process instead
	exitSession();
	destroySwapchain();
	destroyScene();

	for(XrSpace aimSpace : aimSpaces)
		if(aimSpace != XR_NULL_HANDLE)
			xr.xrDestroySpace(aimSpace);
	// also destroys the actions
	if(actionSet != XR_NULL_HANDLE)
		xr.xrDestroyActionSet(actionSet);
	if(space != XR_NULL_HANDLE)
		xr.xrDestroySpace(space);
	if(session != XR_NULL_HANDLE)
		xr.xrDestroySession(session);
	if(instance != XR_NULL_HANDLE && xr.xrDestroyInstance != nullptr)
		xr.xrDestroyInstance(instance);

	if(activity != nullptr)
	{
		auto * env = static_cast<JNIEnv *>(SDL_GetAndroidJNIEnv());
		if(env != nullptr)
			env->DeleteGlobalRef(activity);
	}
}

void XrDisplayImpl::pollEvents()
{
	auto event = XrLoader::makeStruct<XrEventDataBuffer>(XR_TYPE_EVENT_DATA_BUFFER);
	while(xr.xrPollEvent(instance, &event) == XR_SUCCESS)
	{
		if(event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
			onSessionStateChanged(reinterpret_cast<const XrEventDataSessionStateChanged &>(event).state);
		else if(event.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING)
			logGlobal->warn("OpenXR: instance loss pending");

		event = XrLoader::makeStruct<XrEventDataBuffer>(XR_TYPE_EVENT_DATA_BUFFER);
	}
}

void XrDisplayImpl::onSessionStateChanged(XrSessionState state)
{
	logGlobal->info("OpenXR: session state %s", sessionStateName(state));

	switch(state)
	{
		case XR_SESSION_STATE_READY:
		{
			auto beginInfo = XrLoader::makeStruct<XrSessionBeginInfo>(XR_TYPE_SESSION_BEGIN_INFO);
			beginInfo.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
			if(XrResult result = xr.xrBeginSession(session, &beginInfo); XR_FAILED(result))
				logGlobal->warn("OpenXR: xrBeginSession failed, XrResult %d", static_cast<int>(result));
			else
				sessionRunning = true;
			break;
		}
		case XR_SESSION_STATE_STOPPING:
		{
			sessionRunning = false;
			if(XrResult result = xr.xrEndSession(session); XR_FAILED(result))
				logGlobal->warn("OpenXR: xrEndSession failed, XrResult %d", static_cast<int>(result));
			break;
		}
		case XR_SESSION_STATE_EXITING:
		case XR_SESSION_STATE_LOSS_PENDING:
		{
			// the runtime asks the application to quit, for example from the system menu
			sessionRunning = false;
			SDL_Event quitEvent{};
			quitEvent.type = SDL_EVENT_QUIT;
			SDL_PushEvent(&quitEvent);
			break;
		}
		default:
			break;
	}
}

bool XrDisplayImpl::presentFrame(SDL_Renderer * renderer, const std::function<void()> & drawFrame)
{
	// shortcut: frames the game skips submit nothing and poll no events, and its frame limiter runs on top of xrWaitFrame; move the XR loop out of presentScreenTexture if this judders
	pollEvents();
	if(!sessionRunning)
		return false;

	auto frameState = XrLoader::makeStruct<XrFrameState>(XR_TYPE_FRAME_STATE);
	auto waitInfo = XrLoader::makeStruct<XrFrameWaitInfo>(XR_TYPE_FRAME_WAIT_INFO);
	if(XrResult result = xr.xrWaitFrame(session, &waitInfo, &frameState); XR_FAILED(result))
	{
		warnFrameFailure("xrWaitFrame", result);
		return false;
	}

	auto beginInfo = XrLoader::makeStruct<XrFrameBeginInfo>(XR_TYPE_FRAME_BEGIN_INFO);
	if(XrResult result = xr.xrBeginFrame(session, &beginInfo); XR_FAILED(result))
	{
		// the next xrWaitFrame would block until a successful xrBeginFrame
		warnFrameFailure("xrBeginFrame", result);
		sessionRunning = false;
		return false;
	}

	auto layer = XrLoader::makeStruct<XrCompositionLayerQuad>(XR_TYPE_COMPOSITION_LAYER_QUAD);
	auto sceneLayer = XrLoader::makeStruct<XrCompositionLayerProjection>(XR_TYPE_COMPOSITION_LAYER_PROJECTION);
	// shortcut: input is read only on frames the game submits, up to 100 ms apart on idle screens; poll it every frame once the XR loop owns the frame pacing
	updateInput(renderer, frameState.predictedDisplayTime);

	// the scene layer goes over the game screen, so that controllers in front of it stay visible
	std::vector<const XrCompositionLayerBaseHeader *> layers;
	if(frameState.shouldRender && renderLayer(renderer, drawFrame, layer))
		layers.push_back(reinterpret_cast<const XrCompositionLayerBaseHeader *>(&layer));
	if(frameState.shouldRender && renderScene(renderer, frameState.predictedDisplayTime, sceneLayer))
		layers.push_back(reinterpret_cast<const XrCompositionLayerBaseHeader *>(&sceneLayer));

	auto endInfo = XrLoader::makeStruct<XrFrameEndInfo>(XR_TYPE_FRAME_END_INFO);
	endInfo.displayTime = frameState.predictedDisplayTime;
	endInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
	endInfo.layerCount = layers.size();
	endInfo.layers = layers.data();
	if(XrResult result = xr.xrEndFrame(session, &endInfo); XR_FAILED(result))
		warnFrameFailure("xrEndFrame", result);

	return true;
}

bool XrDisplayImpl::renderLayer(SDL_Renderer * renderer, const std::function<void()> & drawFrame, XrCompositionLayerQuad & layer)
{
	int width = 0;
	int height = 0;
	if(!SDL_GetRenderLogicalPresentation(renderer, &width, &height, nullptr) || width <= 0 || height <= 0)
		SDL_GetCurrentRenderOutputSize(renderer, &width, &height);

	if(width != swapchainWidth || height != swapchainHeight)
	{
		// a failed creation is not retried until the size changes again
		destroySwapchain();
		swapchainWidth = width;
		swapchainHeight = height;
		if(!createSwapchain(renderer, width, height))
			destroySwapchain();
	}

	if(swapchain == XR_NULL_HANDLE)
		return false;

	SDL_SetRenderTarget(renderer, frameTarget);
	drawFrame();
	SDL_SetRenderTarget(renderer, nullptr);
	SDL_FlushRenderer(renderer);

	uint32_t imageIndex = 0;
	auto acquireInfo = XrLoader::makeStruct<XrSwapchainImageAcquireInfo>(XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO);
	if(XrResult result = xr.xrAcquireSwapchainImage(swapchain, &acquireInfo, &imageIndex); XR_FAILED(result))
	{
		warnFrameFailure("xrAcquireSwapchainImage", result);
		return false;
	}

	auto waitInfo = XrLoader::makeStruct<XrSwapchainImageWaitInfo>(XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO);
	waitInfo.timeout = XR_INFINITE_DURATION;
	if(XrResult result = xr.xrWaitSwapchainImage(swapchain, &waitInfo); XR_FAILED(result))
	{
		// the image stays acquired; a new swapchain is created on the next frame
		warnFrameFailure("xrWaitSwapchainImage", result);
		destroySwapchain();
		swapchainWidth = 0;
		return false;
	}

	copyToSwapchainImage(imageIndex);

	auto releaseInfo = XrLoader::makeStruct<XrSwapchainImageReleaseInfo>(XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO);
	if(XrResult result = xr.xrReleaseSwapchainImage(swapchain, &releaseInfo); XR_FAILED(result))
	{
		warnFrameFailure("xrReleaseSwapchainImage", result);
		return false;
	}

	layer.space = space;
	layer.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
	layer.subImage.swapchain = swapchain;
	layer.subImage.imageRect.extent = {width, height};
	// shortcut: a flat quad in front of the head position at session start; the curved cylinder layer comes back once this shows
	layer.pose.orientation.w = 1.0f;
	layer.pose.position.z = -layerDistance;
	layer.size = {layerWidth, layerWidth * static_cast<float>(height) / static_cast<float>(width)};
	return true;
}

bool XrDisplayImpl::createScene()
{
	uint32_t viewCount = 0;
	std::array<XrViewConfigurationView, 2> configViews;
	configViews.fill(XrLoader::makeStruct<XrViewConfigurationView>(XR_TYPE_VIEW_CONFIGURATION_VIEW));
	if(XrResult result = xr.xrEnumerateViewConfigurationViews(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, configViews.size(), &viewCount, configViews.data());
		XR_FAILED(result) || viewCount != configViews.size())
	{
		logGlobal->warn("OpenXR: stereo views not available, XrResult %d", static_cast<int>(result));
		return false;
	}
	eyeWidth = configViews[0].recommendedImageRectWidth;
	eyeHeight = configViews[0].recommendedImageRectHeight;

	auto createInfo = XrLoader::makeStruct<XrSwapchainCreateInfo>(XR_TYPE_SWAPCHAIN_CREATE_INFO);
	createInfo.usageFlags = XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
	createInfo.format = swapchainFormat;
	createInfo.sampleCount = 1;
	createInfo.width = eyeWidth * 2;
	createInfo.height = eyeHeight;
	createInfo.faceCount = 1;
	createInfo.arraySize = 1;
	createInfo.mipCount = 1;
	if(XrResult result = xr.xrCreateSwapchain(session, &createInfo, &sceneSwapchain); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: scene swapchain creation failed, XrResult %d", static_cast<int>(result));
		sceneSwapchain = XR_NULL_HANDLE;
		return false;
	}

	uint32_t imageCount = 0;
	xr.xrEnumerateSwapchainImages(sceneSwapchain, 0, &imageCount, nullptr);
	std::vector<XrSwapchainImageOpenGLESKHR> images(imageCount, XrLoader::makeStruct<XrSwapchainImageOpenGLESKHR>(XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR));
	if(XrResult result = xr.xrEnumerateSwapchainImages(sceneSwapchain, imageCount, &imageCount, reinterpret_cast<XrSwapchainImageBaseHeader *>(images.data())); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: scene swapchain image enumeration failed, XrResult %d", static_cast<int>(result));
		return false;
	}

	const char * vertexSource =
		"#version 300 es\n"
		"layout(location = 0) in vec4 vertex;\n"
		"uniform mat4 mvp;\n"
		"out float brightness;\n"
		"void main() { brightness = vertex.w; gl_Position = mvp * vec4(vertex.xyz, 1.0); }\n";
	const char * fragmentSource =
		"#version 300 es\n"
		"precision mediump float;\n"
		"uniform vec4 color;\n"
		"in float brightness;\n"
		"out vec4 fragColor;\n"
		"void main() { fragColor = vec4(color.rgb * brightness, color.a); }\n";

	GLint previousFramebuffer = 0;
	GLint previousVertexArray = 0;
	GLint previousArrayBuffer = 0;
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);
	glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &previousVertexArray);
	glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &previousArrayBuffer);

	for(const auto & image : images)
		sceneFramebuffers.push_back(createFramebuffer(image.image));

	GLuint vertexShader = compileShader(GL_VERTEX_SHADER, vertexSource);
	GLuint fragmentShader = compileShader(GL_FRAGMENT_SHADER, fragmentSource);
	if(vertexShader != 0 && fragmentShader != 0)
	{
		sceneProgram = glCreateProgram();
		glAttachShader(sceneProgram, vertexShader);
		glAttachShader(sceneProgram, fragmentShader);
		glLinkProgram(sceneProgram);
		GLint linked = GL_FALSE;
		glGetProgramiv(sceneProgram, GL_LINK_STATUS, &linked);
		if(linked != GL_TRUE)
		{
			logGlobal->warn("OpenXR: scene shader linking failed");
			glDeleteProgram(sceneProgram);
			sceneProgram = 0;
		}
	}
	glDeleteShader(vertexShader);
	glDeleteShader(fragmentShader);
	if(sceneProgram != 0)
	{
		mvpLocation = glGetUniformLocation(sceneProgram, "mvp");
		colorLocation = glGetUniformLocation(sceneProgram, "color");
	}

	const std::vector<float> cube = unitCube();
	cubeVertexCount = cube.size() / 4;
	glGenVertexArrays(1, &sceneVertexArray);
	glBindVertexArray(sceneVertexArray);
	glGenBuffers(1, &sceneVertexBuffer);
	glBindBuffer(GL_ARRAY_BUFFER, sceneVertexBuffer);
	glBufferData(GL_ARRAY_BUFFER, cube.size() * sizeof(float), cube.data(), GL_STATIC_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 4 * sizeof(float), nullptr);

	glBindVertexArray(previousVertexArray);
	glBindBuffer(GL_ARRAY_BUFFER, previousArrayBuffer);
	glBindFramebuffer(GL_FRAMEBUFFER, previousFramebuffer);

	if(sceneProgram == 0 || vstd::contains(sceneFramebuffers, 0u))
		return false;

	logGlobal->info("OpenXR: scene swapchain %dx%d per eye", eyeWidth, eyeHeight);
	return true;
}

void XrDisplayImpl::destroyScene()
{
	for(GLuint framebuffer : sceneFramebuffers)
		if(framebuffer != 0)
			glDeleteFramebuffers(1, &framebuffer);
	sceneFramebuffers.clear();
	if(sceneVertexBuffer != 0)
		glDeleteBuffers(1, &sceneVertexBuffer);
	if(sceneVertexArray != 0)
		glDeleteVertexArrays(1, &sceneVertexArray);
	if(sceneProgram != 0)
		glDeleteProgram(sceneProgram);
	sceneVertexBuffer = 0;
	sceneVertexArray = 0;
	sceneProgram = 0;

	if(sceneSwapchain != XR_NULL_HANDLE)
		xr.xrDestroySwapchain(sceneSwapchain);
	sceneSwapchain = XR_NULL_HANDLE;
}

bool XrDisplayImpl::renderScene(SDL_Renderer * renderer, XrTime time, XrCompositionLayerProjection & layer)
{
	if(!aimPoses[0] && !aimPoses[1])
		return false;

	// raw GL calls follow, SDL must not have commands queued that it would issue in between
	SDL_FlushRenderer(renderer);

	if(sceneSwapchain == XR_NULL_HANDLE)
	{
		if(sceneFailed)
			return false;
		if(!createScene())
		{
			// the game screen still works without controllers drawn
			sceneFailed = true;
			destroyScene();
			return false;
		}
	}

	auto locateInfo = XrLoader::makeStruct<XrViewLocateInfo>(XR_TYPE_VIEW_LOCATE_INFO);
	locateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
	locateInfo.displayTime = time;
	locateInfo.space = space;
	auto viewState = XrLoader::makeStruct<XrViewState>(XR_TYPE_VIEW_STATE);
	std::array<XrView, 2> views;
	views.fill(XrLoader::makeStruct<XrView>(XR_TYPE_VIEW));
	uint32_t viewCount = 0;
	const XrViewStateFlags required = XR_VIEW_STATE_ORIENTATION_VALID_BIT | XR_VIEW_STATE_POSITION_VALID_BIT;
	if(XR_FAILED(xr.xrLocateViews(session, &locateInfo, &viewState, views.size(), &viewCount, views.data())) || (viewState.viewStateFlags & required) != required)
		return false;

	uint32_t imageIndex = 0;
	auto acquireInfo = XrLoader::makeStruct<XrSwapchainImageAcquireInfo>(XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO);
	if(XrResult result = xr.xrAcquireSwapchainImage(sceneSwapchain, &acquireInfo, &imageIndex); XR_FAILED(result))
	{
		warnFrameFailure("xrAcquireSwapchainImage", result);
		return false;
	}
	auto waitInfo = XrLoader::makeStruct<XrSwapchainImageWaitInfo>(XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO);
	waitInfo.timeout = XR_INFINITE_DURATION;
	if(XrResult result = xr.xrWaitSwapchainImage(sceneSwapchain, &waitInfo); XR_FAILED(result))
	{
		// the image stays acquired; the scene is created again on the next frame
		warnFrameFailure("xrWaitSwapchainImage", result);
		destroyScene();
		return false;
	}

	// SDL caches GL state, so everything changed here is restored
	GLint previousFramebuffer = 0;
	GLint previousProgram = 0;
	GLint previousVertexArray = 0;
	std::array<GLint, 4> previousViewport = {};
	std::array<GLfloat, 4> previousClearColor = {};
	glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previousFramebuffer);
	glGetIntegerv(GL_CURRENT_PROGRAM, &previousProgram);
	glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &previousVertexArray);
	glGetIntegerv(GL_VIEWPORT, previousViewport.data());
	glGetFloatv(GL_COLOR_CLEAR_VALUE, previousClearColor.data());
	const GLboolean scissorEnabled = glIsEnabled(GL_SCISSOR_TEST);
	const GLboolean blendEnabled = glIsEnabled(GL_BLEND);
	const GLboolean cullEnabled = glIsEnabled(GL_CULL_FACE);

	glDisable(GL_SCISSOR_TEST);
	glDisable(GL_BLEND);
	glEnable(GL_CULL_FACE);
	if(disableSrgbEncoding)
		glDisable(GL_FRAMEBUFFER_SRGB_EXT);

	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, sceneFramebuffers.at(imageIndex));
	// transparent everywhere except the controllers and the ray
	glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glUseProgram(sceneProgram);
	glBindVertexArray(sceneVertexArray);
	for(size_t eye = 0; eye < views.size(); ++eye)
	{
		glViewport(eye * eyeWidth, 0, eyeWidth, eyeHeight);
		drawSceneView(views[eye]);
	}

	glBindVertexArray(previousVertexArray);
	glUseProgram(previousProgram);
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, previousFramebuffer);
	glViewport(previousViewport[0], previousViewport[1], previousViewport[2], previousViewport[3]);
	glClearColor(previousClearColor[0], previousClearColor[1], previousClearColor[2], previousClearColor[3]);
	if(disableSrgbEncoding)
		glEnable(GL_FRAMEBUFFER_SRGB_EXT);
	if(!cullEnabled)
		glDisable(GL_CULL_FACE);
	if(blendEnabled)
		glEnable(GL_BLEND);
	if(scissorEnabled)
		glEnable(GL_SCISSOR_TEST);

	auto releaseInfo = XrLoader::makeStruct<XrSwapchainImageReleaseInfo>(XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO);
	if(XrResult result = xr.xrReleaseSwapchainImage(sceneSwapchain, &releaseInfo); XR_FAILED(result))
	{
		warnFrameFailure("xrReleaseSwapchainImage", result);
		return false;
	}

	for(size_t eye = 0; eye < views.size(); ++eye)
	{
		sceneViews[eye] = XrLoader::makeStruct<XrCompositionLayerProjectionView>(XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW);
		sceneViews[eye].pose = views[eye].pose;
		sceneViews[eye].fov = views[eye].fov;
		sceneViews[eye].subImage.swapchain = sceneSwapchain;
		sceneViews[eye].subImage.imageRect.offset = {static_cast<int32_t>(eye) * eyeWidth, 0};
		sceneViews[eye].subImage.imageRect.extent = {eyeWidth, eyeHeight};
	}
	// premultiplied alpha: the cleared background is transparent black
	layer.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
	layer.space = space;
	layer.viewCount = sceneViews.size();
	layer.views = sceneViews.data();
	return true;
}

void XrDisplayImpl::drawSceneView(const XrView & view)
{
	const Matrix viewProjection = multiply(projectionMatrix(view.fov, 0.05f, 100.0f), viewMatrix(view.pose));
	const auto drawBox = [this](const Matrix & mvp, float red, float green, float blue)
	{
		glUniformMatrix4fv(mvpLocation, 1, GL_FALSE, mvp.data());
		glUniform4f(colorLocation, red, green, blue, 1.0f);
		glDrawArrays(GL_TRIANGLES, 0, cubeVertexCount);
	};

	for(size_t hand = 0; hand < aimPoses.size(); ++hand)
	{
		if(!aimPoses[hand])
			continue;
		// shortcut: boxes stand in for the controllers and the ray, without a depth buffer; load the controller models with XR_FB_render_model for a real look
		const Matrix handMatrix = multiply(viewProjection, poseMatrix(*aimPoses[hand]));
		// the aim pose sits at the front of the controller and points along -Z
		drawBox(multiply(handMatrix, boxMatrix({0.0f, -0.015f, 0.06f}, {0.04f, 0.035f, 0.12f})), 0.85f, 0.85f, 0.88f);
		if(hand == activeHand)
			drawBox(multiply(handMatrix, boxMatrix({0.0f, 0.0f, -rayLength / 2}, {0.003f, 0.003f, rayLength})), 0.35f, 0.75f, 1.0f);
	}
}

void XrDisplayImpl::copyToSwapchainImage(uint32_t imageIndex)
{
	// SDL caches GL state, so everything changed here is restored
	GLint previousReadFramebuffer = 0;
	GLint previousDrawFramebuffer = 0;
	glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previousReadFramebuffer);
	glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previousDrawFramebuffer);
	const GLboolean scissorEnabled = glIsEnabled(GL_SCISSOR_TEST);

	if(scissorEnabled)
		glDisable(GL_SCISSOR_TEST);
	if(disableSrgbEncoding)
		glDisable(GL_FRAMEBUFFER_SRGB_EXT);

	glBindFramebuffer(GL_READ_FRAMEBUFFER, frameFramebuffer);
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, swapchainFramebuffers.at(imageIndex));
	// SDL render targets hold the top row first, OpenXR GL images the bottom row
	glBlitFramebuffer(0, 0, swapchainWidth, swapchainHeight, 0, swapchainHeight, swapchainWidth, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);

	// layers of the game frame are composed without blending and can leave alpha 0; the runtime must see an opaque image
	GLfloat previousClearColor[4] = {};
	glGetFloatv(GL_COLOR_CLEAR_VALUE, previousClearColor);
	glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_TRUE);
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
	glClearColor(previousClearColor[0], previousClearColor[1], previousClearColor[2], previousClearColor[3]);

	if(disableSrgbEncoding)
		glEnable(GL_FRAMEBUFFER_SRGB_EXT);
	if(scissorEnabled)
		glEnable(GL_SCISSOR_TEST);
	glBindFramebuffer(GL_READ_FRAMEBUFFER, previousReadFramebuffer);
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, previousDrawFramebuffer);
}

std::unique_ptr<XrDisplayImpl> display;

}

void XrDisplay::start()
{
	auto newDisplay = std::make_unique<XrDisplayImpl>();
	if(newDisplay->start())
		display = std::move(newDisplay);
}

void XrDisplay::stop()
{
	display.reset();
}

bool XrDisplay::presentFrame(SDL_Renderer * renderer, const std::function<void()> & drawFrame)
{
	return display && display->presentFrame(renderer, drawFrame);
}
