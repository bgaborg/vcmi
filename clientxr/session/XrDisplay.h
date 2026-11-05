/*
 * XrDisplay.h, part of VCMI engine
 *
 * Authors: listed in file AUTHORS in main folder
 *
 * License: GNU General Public License v2.0 or later
 * Full text of license available in license.txt file, in main folder
 *
 */
#pragma once

struct SDL_Renderer;

/// Shows the game frame on an OpenXR quad layer while the activity runs an immersive session.
/// Uses the EGL context of the SDL renderer; all functions run on the thread that owns it.
namespace XrDisplay
{

/// Creates the OpenXR instance and session on the current EGL context. Logs and stays inactive on failure.
void start();

/// Destroys the session and the instance. Must run before the EGL context is destroyed.
void stop();

/// Submits one XR frame; `drawFrame` draws the game frame into the current render target of `renderer`.
/// Returns false if no session is running, in which case the caller presents to the window.
bool presentFrame(SDL_Renderer * renderer, const std::function<void()> & drawFrame);

}
