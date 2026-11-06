package org.libsdl.app;

/**
 * Pauses the game while the XR host is paused (Meta menu, headset off).
 * The game activity stays resumed on its virtual display, so SDL's own onPause/onStop never pause it;
 * this runs the same pause: SDL blocks the game loop and stops audio until resume.
 * Lives in SDL's package because pauseNativeThread and resumeNativeThread are protected. Call on the UI thread.
 */
public final class QuestPause
{
    private QuestPause() {}

    public static void set(final SDLActivity game, final boolean paused)
    {
        if (paused)
            game.pauseNativeThread();
        else
            game.resumeNativeThread();
    }
}
