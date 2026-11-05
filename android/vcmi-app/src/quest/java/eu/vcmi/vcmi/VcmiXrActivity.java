package eu.vcmi.vcmi;

/**
 * The game as an immersive OpenXR activity on Horizon OS. A separate class instead of an activity-alias:
 * an alias inherits the panel attributes of VcmiSDLActivity (layout, resizeable), and Horizon then runs it in a panel window.
 */
public class VcmiXrActivity extends VcmiSDLActivity
{
}
