package eu.vcmi.vcmi;

import android.app.Activity;
import android.app.ActivityOptions;
import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.os.Bundle;
import android.util.Log;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.View;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;
import org.libsdl.app.QuestGamepad;
import org.libsdl.app.QuestPause;
import org.libsdl.app.SDLActivity;

import eu.vcmi.vcmi.util.FileUtil;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

import java.util.Collections;
import java.util.Set;

/**
 * Godot plugin `VcmiBridge`: runs the game activity on a private virtual display drawn into the XR layer surface,
 * and passes pointer events from the controllers to SDL.
 * Test commands: `adb shell am broadcast -a is.xyz.vcmi.quest.TEST --es cmd <command> --ef a <float> --ef b <float> --ef c <float>`,
 * emitted to the Godot scene as the signal `test_command` (see quest/xr/main.gd and quest/tools/quest.sh test)
 */
public class VcmiBridge extends GodotPlugin
{
    // android.util.Log: eu.vcmi.vcmi.util.Log prints to logcat in debug builds only, and the Quest checks run on release builds
    private static final String TAG = "VcmiBridge";
    private static final String EXTENSION_CONFIG = "vcmi_xr.gdextension";
    private static final int DISPLAY_DPI = 320;
    private static final String TEST_ACTION = "is.xyz.vcmi.quest.TEST";
    // held by adb shell and the system only, so other apps cannot send test commands
    private static final String TEST_SENDER_PERMISSION = "android.permission.DUMP";
    private static final SignalInfo TEST_COMMAND = new SignalInfo("test_command", String.class, Float.class, Float.class, Float.class);

    private VirtualDisplay display;
    private Activity game;
    private int buttons;
    private float pointerX;
    private float pointerY;
    private long hapticSettingTime = -1;
    private boolean hapticSetting = true;
    private boolean hostPaused;

    public VcmiBridge(final Godot godot)
    {
        super(godot);
    }

    @NonNull
    @Override
    public String getPluginName()
    {
        return "VcmiBridge";
    }

    /**
     * The extension that reads game data from the bridge in quest/bridge (quest/DATA_BRIDGE.md). Its configuration is an
     * APK asset copied to a file, because Godot reads it with plain file access and res:// is the exported pack; a
     * .gdextension in the Godot project would make the Linux editor that exports the pack fail to load it and abort.
     * The library is not at that path, so Godot loads it by file name from the APK's native libraries.
     */
    @NonNull
    @Override
    public Set<String> getPluginGDExtensionLibrariesPaths()
    {
        final File config = new File(getActivity().getFilesDir(), EXTENSION_CONFIG);
        try (InputStream in = getActivity().getAssets().open(EXTENSION_CONFIG); OutputStream out = new FileOutputStream(config))
        {
            FileUtil.copyStream(in, out);
        }
        catch (final IOException e)
        {
            Log.e(TAG, "no game data: cannot copy " + EXTENSION_CONFIG, e);
            return Collections.emptySet();
        }
        return Collections.singleton(config.getAbsolutePath());
    }

    @NonNull
    @Override
    public Set<SignalInfo> getPluginSignals()
    {
        return Collections.singleton(TEST_COMMAND);
    }

    @Override
    public View onMainCreate(@Nullable final Activity activity)
    {
        ContextCompat.registerReceiver(getActivity(), testReceiver, new IntentFilter(TEST_ACTION), TEST_SENDER_PERMISSION, null, ContextCompat.RECEIVER_EXPORTED);
        return null;
    }

    @UsedByGodot
    public void startGame(final Surface surface, final int width, final int height)
    {
        final Activity host = getActivity();
        host.runOnUiThread(() -> {
            defaultUpscalingNone();
            host.getApplication().registerActivityLifecycleCallbacks(gameLifecycle);
            final DisplayManager displays = host.getSystemService(DisplayManager.class);
            display = displays.createVirtualDisplay("VCMI", width, height, DISPLAY_DPI, surface, DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY);
            final int displayId = display.getDisplay().getDisplayId();
            Log.i(TAG, "game display " + displayId + ": " + width + "x" + height);

            final ActivityOptions options = ActivityOptions.makeBasic().setLaunchDisplayId(displayId);
            host.startActivity(new Intent(host, VcmiSDLActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), options.toBundle());
        });
    }

    /** The XR layer creates a new surface for each OpenXR session; the game display has to draw into the current one */
    @UsedByGodot
    public void setSurface(final Surface surface)
    {
        getActivity().runOnUiThread(() -> {
            if (display == null)
                return;
            display.setSurface(surface);
            Log.i(TAG, "game display on the surface of a new XR session");
        });
    }

    @UsedByGodot
    public void pointerMove(final float x, final float y)
    {
        runOnGame(() -> {
            // SDL runs once it takes pointer events, so the game opens the gamepad before its first button
            QuestGamepad.add();
            pointerX = x;
            pointerY = y;
            SDLActivity.onNativeMouse(buttons, buttons == 0 ? MotionEvent.ACTION_HOVER_MOVE : MotionEvent.ACTION_MOVE, x, y, false);
        });
    }

    /** `button` is a MotionEvent.BUTTON_* bit */
    @UsedByGodot
    public void pointerButton(final int button, final boolean pressed)
    {
        runOnGame(() -> {
            // SDL compares the button state with the previous one to find the changed button
            buttons = pressed ? buttons | button : buttons & ~button;
            SDLActivity.onNativeMouse(buttons, pressed ? MotionEvent.ACTION_DOWN : MotionEvent.ACTION_UP, pointerX, pointerY, false);
        });
    }

    /** `keycode` is a KeyEvent.KEYCODE_BUTTON_* value */
    @UsedByGodot
    public void gamepadButton(final int keycode, final boolean pressed)
    {
        runOnGame(() -> QuestGamepad.button(keycode, pressed));
    }

    /** `keycode` is a KeyEvent.KEYCODE_* value; the game maps keys to actions in config/keyBindingsConfig.json "keyboard" */
    @UsedByGodot
    public void key(final int keycode, final boolean pressed)
    {
        runOnGame(() -> {
            if (pressed)
                SDLActivity.onNativeKeyDown(keycode);
            else
                SDLActivity.onNativeKeyUp(keycode);
        });
    }

    /** `axis` 0..3 is leftx, lefty, rightx, righty; `value` -1..1, positive y points down */
    @UsedByGodot
    public void gamepadAxis(final int axis, final float value)
    {
        runOnGame(() -> QuestGamepad.axis(axis, value));
    }

    /**
     * The game's "Haptic feedback" option, `general.hapticFeedback` in its settings.json; on when the game has not saved it.
     * The game rewrites the file on each option change; it is parsed again only then.
     */
    @UsedByGodot
    public boolean hapticFeedbackEnabled()
    {
        final File settings = settingsFile();
        final long time = settings.lastModified(); // 0 when the file does not exist
        if (time == hapticSettingTime)
            return hapticSetting;
        hapticSettingTime = time;
        hapticSetting = true;
        if (time == 0)
            return hapticSetting;
        try
        {
            final JSONObject general = readSettings(settings).optJSONObject("general");
            hapticSetting = general == null || general.optBoolean("hapticFeedback", true);
        }
        catch (IOException | JSONException e)
        {
            Log.w(TAG, "cannot read the haptic feedback setting, using on: " + e);
        }
        return hapticSetting;
    }

    /**
     * The game's upscaling filter `video.upscalingFilter` defaults to none on Quest, unless the player chose one: "auto"
     * picks xBRZ, whose sprite caches got the game killed by the low-memory killer on the largest maps (quest/DATA_BRIDGE.md, Memory).
     * Written before the game starts, which reads the file once at start. "auto" is the schema default, which the game does
     * not save: a player who wants xBRZ picks a concrete filter such as xbrz2.
     */
    private void defaultUpscalingNone()
    {
        final File settings = settingsFile();
        try
        {
            final JSONObject root = settings.exists() ? readSettings(settings) : new JSONObject();
            JSONObject video = root.optJSONObject("video");
            if (video == null)
                root.put("video", video = new JSONObject());
            if (video.has("upscalingFilter"))
                return;
            video.put("upscalingFilter", "none");
            // via a temporary file, so a failed write cannot leave the player's settings half written
            final File temp = new File(settings.getPath() + ".tmp");
            if (!settings.getParentFile().isDirectory() && !settings.getParentFile().mkdirs())
                throw new IOException("cannot create " + settings.getParent());
            try (OutputStream out = new FileOutputStream(temp))
            {
                out.write(root.toString(4).getBytes(StandardCharsets.UTF_8));
            }
            if (!temp.renameTo(settings))
                throw new IOException("cannot replace " + settings);
            Log.i(TAG, "upscaling filter set to none");
        }
        catch (IOException | JSONException e)
        {
            Log.w(TAG, "upscaling filter left as it is: " + e);
        }
    }

    private File settingsFile()
    {
        return new File(Storage.getVcmiDataDir(getActivity()), "config/settings.json");
    }

    private static JSONObject readSettings(final File settings) throws IOException, JSONException
    {
        try (InputStream in = new FileInputStream(settings); ByteArrayOutputStream out = new ByteArrayOutputStream())
        {
            FileUtil.copyStream(in, out);
            return new JSONObject(out.toString("UTF-8"));
        }
    }

    @Override
    public void onMainPause()
    {
        setGamePaused(true);
    }

    @Override
    public void onMainResume()
    {
        setGamePaused(false);
    }

    private void setGamePaused(final boolean paused)
    {
        hostPaused = paused;
        runOnGame(() -> {
            QuestPause.set((SDLActivity) game, paused);
            Log.i(TAG, paused ? "game paused" : "game resumed");
        });
    }

    @Override
    public void onMainDestroy()
    {
        getActivity().getApplication().unregisterActivityLifecycleCallbacks(gameLifecycle);
        getActivity().unregisterReceiver(testReceiver);
        if (game != null)
            game.finish();
        if (display != null)
            display.release();
    }

    /** Events reach SDL only while its activity exists; SDL reads them on the UI thread */
    private void runOnGame(final Runnable action)
    {
        getActivity().runOnUiThread(() -> {
            if (game != null)
                action.run();
        });
    }

    private final BroadcastReceiver testReceiver = new BroadcastReceiver()
    {
        @Override
        public void onReceive(final Context context, final Intent intent)
        {
            final String command = intent.getStringExtra("cmd");
            emitSignal(TEST_COMMAND, command == null ? "" : command, intent.getFloatExtra("a", 0), intent.getFloatExtra("b", 0), intent.getFloatExtra("c", 0));
        }
    };

    private final Application.ActivityLifecycleCallbacks gameLifecycle = new Application.ActivityLifecycleCallbacks()
    {
        @Override
        public void onActivityCreated(@NonNull final Activity activity, final Bundle state)
        {
            if (activity instanceof VcmiSDLActivity)
                game = activity;
        }

        /** SDL's onStart resumes the game, also on wake while the host is still paused (Meta menu, Guardian): pause it again */
        @Override
        public void onActivityPostStarted(@NonNull final Activity activity)
        {
            if (activity == game && hostPaused)
                setGamePaused(true);
        }

        @Override
        public void onActivityDestroyed(@NonNull final Activity activity)
        {
            if (activity != game)
                return;
            // the game quit: leave immersive mode with it (VcmiSDLActivity.onDestroy also ends the process)
            game = null;
            getActivity().finish();
        }

        @Override public void onActivityStarted(@NonNull final Activity activity) {}
        @Override public void onActivityResumed(@NonNull final Activity activity) {}
        @Override public void onActivityPaused(@NonNull final Activity activity) {}
        @Override public void onActivityStopped(@NonNull final Activity activity) {}
        @Override public void onActivitySaveInstanceState(@NonNull final Activity activity, @NonNull final Bundle state) {}
    };
}
