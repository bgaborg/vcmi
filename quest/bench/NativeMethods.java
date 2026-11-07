// NativeMethods.java, Meta Quest build: the entry point of the object benchmark (ObjectBench.cpp), run with
// app_process by quest/tools/object-bench.sh. It stands in for the game's eu.vcmi.vcmi.NativeMethods, which VCMI's
// library asks for its data folders (VCMIDirsAndroid::init).
// License: GNU General Public License v2.0 or later
package eu.vcmi.vcmi;

public class NativeMethods
{
	public static String dataRoot()
	{
		return System.getenv("VCMI_DATA_ROOT");
	}

	public static String internalDataRoot()
	{
		return System.getenv("VCMI_INTERNAL_ROOT");
	}

	static native int bench(String save, int repeats);

	/// arguments: the benchmark library, the saved game, the runs per measurement
	public static void main(String[] args)
	{
		System.load(args[0]);
		System.out.flush();
		System.exit(bench(args[1], Integer.parseInt(args[2])));
	}
}
