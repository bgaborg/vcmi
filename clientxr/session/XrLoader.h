/*
 * XrLoader.h, part of VCMI engine
 *
 * Authors: listed in file AUTHORS in main folder
 *
 * License: GNU General Public License v2.0 or later
 * Full text of license available in license.txt file, in main folder
 *
 */
#pragma once

#include <openxr/openxr.h>

namespace XrLoader
{

/// Opens libopenxr_loader.so and initializes it for the given Java VM and activity.
/// Returns nullptr and logs a warning if the loader is not available.
PFN_xrGetInstanceProcAddr open(void * javaVm, void * activity);

/// Formats an OpenXR version as major.minor.patch
std::string versionToString(XrVersion version);

/// OpenXR struct with its type set and every other field zeroed
template<typename Struct>
Struct makeStruct(XrStructureType type)
{
	Struct result{};
	result.type = type;
	return result;
}

/// Looks up an OpenXR function; returns nullptr if the runtime does not provide it
template<typename Function>
Function getFunction(PFN_xrGetInstanceProcAddr getInstanceProcAddr, XrInstance instance, const char * name)
{
	PFN_xrVoidFunction result = nullptr;
	if(XR_FAILED(getInstanceProcAddr(instance, name, &result)))
		return nullptr;
	return reinterpret_cast<Function>(result);
}

}
