package eu.vcmi.vcmi;

import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotActivity;
import org.godotengine.godot.plugin.GodotPlugin;

import java.util.Collections;
import java.util.List;
import java.util.Set;

/**
 * Immersive entry point on Meta Quest: hosts the Godot XR scene (quest/xr), which shows the game activity on a virtual display
 */
public class VcmiXrActivity extends GodotActivity
{
    @Override
    public List<String> getCommandLine()
    {
        final List<String> args = super.getCommandLine();
        if (!args.contains("--main-pack"))
        {
            args.add("--xr_mode_openxr");
            args.add("--main-pack");
            args.add("res://vcmi-xr.pck");
        }
        return args;
    }

    @Override
    public Set<GodotPlugin> getHostPlugins(final Godot engine)
    {
        return Collections.singleton(new VcmiBridge(engine));
    }
}
