/*
 * XrLoader.cpp, part of VCMI engine
 *
 * Authors: listed in file AUTHORS in main folder
 *
 * License: GNU General Public License v2.0 or later
 * Full text of license available in license.txt file, in main folder
 *
 */
#include "../../Global.h"
#include "XrLoader.h"

#include "../../lib/logging/CLogger.h"

#include <dlfcn.h>
#include <jni.h>

#include <openxr/openxr_platform.h>

PFN_xrGetInstanceProcAddr XrLoader::open(void * javaVm, void * activity)
{
	// kept open for the lifetime of the process: the runtime may leave threads running in it
	void * loader = dlopen("libopenxr_loader.so", RTLD_NOW | RTLD_LOCAL);
	if(loader == nullptr)
	{
		logGlobal->warn("OpenXR: loader not available: %s", dlerror());
		return nullptr;
	}

	auto getInstanceProcAddr = reinterpret_cast<PFN_xrGetInstanceProcAddr>(dlsym(loader, "xrGetInstanceProcAddr"));
	if(getInstanceProcAddr == nullptr)
	{
		logGlobal->warn("OpenXR: xrGetInstanceProcAddr not found in the loader");
		return nullptr;
	}

	auto initializeLoader = getFunction<PFN_xrInitializeLoaderKHR>(getInstanceProcAddr, XR_NULL_HANDLE, "xrInitializeLoaderKHR");
	if(initializeLoader == nullptr)
	{
		logGlobal->warn("OpenXR: xrInitializeLoaderKHR not available");
		return nullptr;
	}

	auto loaderInfo = makeStruct<XrLoaderInitInfoAndroidKHR>(XR_TYPE_LOADER_INIT_INFO_ANDROID_KHR);
	loaderInfo.applicationVM = javaVm;
	loaderInfo.applicationContext = activity;

	if(XrResult result = initializeLoader(reinterpret_cast<const XrLoaderInitInfoBaseHeaderKHR *>(&loaderInfo)); XR_FAILED(result))
	{
		logGlobal->warn("OpenXR: loader initialization failed, XrResult %d", static_cast<int>(result));
		return nullptr;
	}

	return getInstanceProcAddr;
}

std::string XrLoader::versionToString(XrVersion version)
{
	return std::to_string(XR_VERSION_MAJOR(version)) + "." + std::to_string(XR_VERSION_MINOR(version)) + "." + std::to_string(XR_VERSION_PATCH(version));
}
