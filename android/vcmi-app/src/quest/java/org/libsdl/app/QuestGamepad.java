package org.libsdl.app;

import android.util.Log;

/**
 * The Quest controllers as one SDL gamepad, so the game uses its own controller bindings (config/keyBindingsConfig.json, "joystickButtons").
 * Lives in SDL's package because SDL's Android joystick entry points are package-private.
 * Call on the UI thread, while the game activity exists.
 */
public final class QuestGamepad
{
    // no InputDevice id of a real device uses it
    private static final int DEVICE_ID = 0x51554553;
    // SDL gamepad buttons, as in SDLControllerManager.getButtonMask: A, B, X, Y, START, LEFTSTICK, RIGHTSTICK, LEFTSHOULDER, RIGHTSHOULDER
    private static final int BUTTON_MASK = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10);
    // leftx, lefty, rightx, righty
    private static final int AXIS_MASK = 0x000f;

    private static final String TAG = "QuestGamepad";

    private static boolean added;

    private QuestGamepad() {}

    /** `keycode` is a KeyEvent.KEYCODE_BUTTON_* value */
    public static void button(final int keycode, final boolean pressed)
    {
        add();
        final boolean handled = pressed ? SDLControllerManager.onNativePadDown(DEVICE_ID, keycode, 0) : SDLControllerManager.onNativePadUp(DEVICE_ID, keycode, 0);
        if (!handled)
            Log.w(TAG, "SDL did not take button " + keycode);
    }

    /** `axis` 0..3 is leftx, lefty, rightx, righty; `value` -1..1, positive y points down */
    public static void axis(final int axis, final float value)
    {
        add();
        SDLControllerManager.onNativeJoy(DEVICE_ID, axis, value);
    }

    /**
     * Registers the gamepad once; SDL has to be running in the game activity.
     * Call it before the first button: SDL turns buttons of a gamepad the game has not opened yet into keyboard keys.
     */
    public static void add()
    {
        if (added)
            return;
        added = true;
        SDLControllerManager.nativeAddJoystick(DEVICE_ID, "Meta Quest Touch", "Meta Quest Touch controllers through the XR host",
            0, 0, BUTTON_MASK, 4, AXIS_MASK, 0, false, false, false, false);
        Log.i(TAG, "added to SDL as device " + DEVICE_ID);
    }
}
