/*
 * XrRuntimeProbe.cpp, part of VCMI engine
 *
 * Authors: listed in file AUTHORS in main folder
 *
 * License: GNU General Public License v2.0 or later
 * Full text of license available in license.txt file, in main folder
 *
 */
#include "../../Global.h"
#include "XrRuntimeProbe.h"

#include "../../lib/logging/CLogger.h"

#include <dlfcn.h>
#include <jni.h>

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

namespace
{

/// Extensions that decide the phase 2 rendering path, see quest/PROJECT_PLAN.md
constexpr std::array reportedExtensions = {
	XR_KHR_ANDROID_CREATE_INSTANCE_EXTENSION_NAME,
	// names of graphics API extensions are defined only together with that API's headers
	"XR_KHR_opengl_es_enable",
	"XR_KHR_vulkan_enable2",
	XR_KHR_COMPOSITION_LAYER_CYLINDER_EXTENSION_NAME,
	XR_FB_PASSTHROUGH_EXTENSION_NAME,
	XR_FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME,
};

/// OpenXR struct with its type set and every other field zeroed
template<typename Struct>
Struct makeXrStruct(XrStructureType type)
{
	Struct result{};
	result.type = type;
	return result;
}

std::string versionToString(XrVersion version)
{
	return std::to_string(XR_VERSION_MAJOR(version)) + "." + std::to_string(XR_VERSION_MINOR(version)) + "." + std::to_string(XR_VERSION_PATCH(version));
}

class XrFunctions
{
	PFN_xrGetInstanceProcAddr getInstanceProcAddr;

public:
	explicit XrFunctions(PFN_xrGetInstanceProcAddr getInstanceProcAddr)
		: getInstanceProcAddr(getInstanceProcAddr)
	{
	}

	/// Returns nullptr if the runtime does not provide the function
	template<typename Function>
	Function get(XrInstance instance, const char * name) const
	{
		PFN_xrVoidFunction result = nullptr;
		if(XR_FAILED(getInstanceProcAddr(instance, name, &result)))
			return nullptr;
		return reinterpret_cast<Function>(result);
	}
};

}

void XrRuntimeProbe::logRuntime(void * javaVm, void * activity)
{
	// kept open for the lifetime of the process: the runtime may leave threads running in it
	void * loader = dlopen("libopenxr_loader.so", RTLD_NOW | RTLD_LOCAL);
	if(loader == nullptr)
	{
		logGlobal->warn("OpenXR: loader not available: %s", dlerror());
		return;
	}

	auto getInstanceProcAddr = reinterpret_cast<PFN_xrGetInstanceProcAddr>(dlsym(loader, "xrGetInstanceProcAddr"));
	if(getInstanceProcAddr == nullptr)
	{
		logGlobal->warn("OpenXR: xrGetInstanceProcAddr not found in the loader");
		return;
	}

	XrFunctions xr(getInstanceProcAddr);

	auto initializeLoader = xr.get<PFN_xrInitializeLoaderKHR>(XR_NULL_HANDLE, "xrInitializeLoaderKHR");
	if(initializeLoader == nullptr)
	{
		logGlobal->warn("OpenXR: xrInitializeLoaderKHR not available");
		return;
	}

	auto loaderInfo = makeXrStruct<XrLoaderInitInfoAndroidKHR>(XR_TYPE_LOADER_INIT_INFO_ANDROID_KHR);
	loaderInfo.applicationVM = javaVm;
	loaderInfo.applicationContext = activity;

	if(XrResult result = initializeLoader(reinterpret_cast<const XrLoaderInitInfoBaseHeaderKHR *>(&loaderInfo)); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: loader initialization failed, XrResult %d", static_cast<int>(result));
		return;
	}

	auto enumerateExtensions = xr.get<PFN_xrEnumerateInstanceExtensionProperties>(XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties");
	auto createInstance = xr.get<PFN_xrCreateInstance>(XR_NULL_HANDLE, "xrCreateInstance");
	if(enumerateExtensions == nullptr || createInstance == nullptr)
	{
		logGlobal->warn("OpenXR: loader does not provide instance creation functions");
		return;
	}

	uint32_t extensionCount = 0;
	if(XrResult result = enumerateExtensions(nullptr, 0, &extensionCount, nullptr); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: no runtime found, XrResult %d", static_cast<int>(result));
		return;
	}

	std::vector<XrExtensionProperties> extensions(extensionCount, makeXrStruct<XrExtensionProperties>(XR_TYPE_EXTENSION_PROPERTIES));
	if(XrResult result = enumerateExtensions(nullptr, extensionCount, &extensionCount, extensions.data()); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: extension enumeration failed, XrResult %d", static_cast<int>(result));
		return;
	}

	std::set<std::string> availableExtensions;
	for(const auto & extension : extensions)
		availableExtensions.insert(extension.extensionName);

	logGlobal->info("OpenXR: %d instance extensions", extensionCount);
	for(const char * name : reportedExtensions)
		logGlobal->info("OpenXR:   %s: %s", name, availableExtensions.count(name) ? "yes" : "no");

	if(!availableExtensions.count(XR_KHR_ANDROID_CREATE_INSTANCE_EXTENSION_NAME))
	{
		logGlobal->warn("OpenXR: runtime does not support %s", XR_KHR_ANDROID_CREATE_INSTANCE_EXTENSION_NAME);
		return;
	}

	const std::array enabledExtensions = {XR_KHR_ANDROID_CREATE_INSTANCE_EXTENSION_NAME};

	auto androidInfo = makeXrStruct<XrInstanceCreateInfoAndroidKHR>(XR_TYPE_INSTANCE_CREATE_INFO_ANDROID_KHR);
	androidInfo.applicationVM = javaVm;
	androidInfo.applicationActivity = activity;

	auto createInfo = makeXrStruct<XrInstanceCreateInfo>(XR_TYPE_INSTANCE_CREATE_INFO);
	createInfo.next = &androidInfo;
	std::strncpy(createInfo.applicationInfo.applicationName, "VCMI", XR_MAX_APPLICATION_NAME_SIZE - 1);
	std::strncpy(createInfo.applicationInfo.engineName, "VCMI", XR_MAX_ENGINE_NAME_SIZE - 1);
	createInfo.applicationInfo.apiVersion = XR_API_VERSION_1_0;
	createInfo.enabledExtensionCount = enabledExtensions.size();
	createInfo.enabledExtensionNames = enabledExtensions.data();

	XrInstance instance = XR_NULL_HANDLE;
	if(XrResult result = createInstance(&createInfo, &instance); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: instance creation failed, XrResult %d", static_cast<int>(result));
		return;
	}

	auto destroyInstance = xr.get<PFN_xrDestroyInstance>(instance, "xrDestroyInstance");
	auto getInstanceProperties = xr.get<PFN_xrGetInstanceProperties>(instance, "xrGetInstanceProperties");
	auto getSystem = xr.get<PFN_xrGetSystem>(instance, "xrGetSystem");
	auto getSystemProperties = xr.get<PFN_xrGetSystemProperties>(instance, "xrGetSystemProperties");

	if(destroyInstance == nullptr || getInstanceProperties == nullptr || getSystem == nullptr || getSystemProperties == nullptr)
	{
		logGlobal->warn("OpenXR: runtime does not provide core instance functions");
		if(destroyInstance)
			destroyInstance(instance);
		return;
	}

	auto instanceProperties = makeXrStruct<XrInstanceProperties>(XR_TYPE_INSTANCE_PROPERTIES);
	if(XR_SUCCEEDED(getInstanceProperties(instance, &instanceProperties)))
		logGlobal->info("OpenXR: runtime '%s' %s", instanceProperties.runtimeName, versionToString(instanceProperties.runtimeVersion));

	auto systemInfo = makeXrStruct<XrSystemGetInfo>(XR_TYPE_SYSTEM_GET_INFO);
	systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;

	XrSystemId systemId = XR_NULL_SYSTEM_ID;
	if(XrResult result = getSystem(instance, &systemInfo, &systemId); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: no head-mounted display system, XrResult %d", static_cast<int>(result));
	}
	else
	{
		auto systemProperties = makeXrStruct<XrSystemProperties>(XR_TYPE_SYSTEM_PROPERTIES);
		if(XR_SUCCEEDED(getSystemProperties(instance, systemId, &systemProperties)))
		{
			logGlobal->info("OpenXR: system '%s', vendor %d, max swapchain %dx%d, max layers %d, orientation tracking %d, position tracking %d",
				systemProperties.systemName,
				systemProperties.vendorId,
				systemProperties.graphicsProperties.maxSwapchainImageWidth,
				systemProperties.graphicsProperties.maxSwapchainImageHeight,
				systemProperties.graphicsProperties.maxLayerCount,
				systemProperties.trackingProperties.orientationTracking,
				systemProperties.trackingProperties.positionTracking);
		}
	}

	destroyInstance(instance);
}
