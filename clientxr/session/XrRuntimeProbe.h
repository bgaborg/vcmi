/*
 * XrRuntimeProbe.h, part of VCMI engine
 *
 * Authors: listed in file AUTHORS in main folder
 *
 * License: GNU General Public License v2.0 or later
 * Full text of license available in license.txt file, in main folder
 *
 */
#pragma once

/// Creates a temporary OpenXR instance and logs the runtime, the head-mounted system and the
/// extensions that the XR client needs. Logs a warning and returns if any step fails.
namespace XrRuntimeProbe
{
/// javaVm is the JavaVM of the process, activity a JNI reference to the running activity
void logRuntime(void * javaVm, void * activity);
}
