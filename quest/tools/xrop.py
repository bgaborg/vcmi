"""Drives the Godot host in Meta XR Simulator through Meta XR Operator (quest/EMULATORS.md), with real OpenXR input.

Usage, while quest/tools/xrsim.sh runs the host (xrsim-live.txt keeps it open):
    python quest/tools/xrop.py [step ...]
Steps run in order in one session of Meta's MCP proxy (meta-xr-operator-mcp-proxy.exe):
    <tool> '<json>'          any XR Operator tool, e.g. openxr_set_controller_input '{"hand":"left","component":"Menu","value":1}'
    aim:<yaw>,<pitch>        points the right controller from below the head, degrees (yaw + is left, pitch + is up)
    click                    pulls and releases the right trigger
    press:<hand>,<button>    presses and releases a button (A, B, X, Y, Menu, ThumbstickClick)
    sleep:<seconds>
    shot:<file.png>          the compositor's left eye image: the room and the game screen layer together
No steps: lists the tools. The proxy is found under %APPDATA%/metavr/tools/meta-xr-operator, or in $XROPERATOR_PROXY.
"""

import base64
import glob
import json
import math
import os
import subprocess
import sys
import time


def quaternion(yaw, pitch):
    """[x, y, z, w] of a yaw about Y then a pitch about X, in degrees"""
    y, p = math.radians(yaw) / 2, math.radians(pitch) / 2
    return [math.cos(y) * math.sin(p), math.sin(y) * math.cos(p), -math.sin(y) * math.sin(p), math.cos(y) * math.cos(p)]


class Operator:
    def __init__(self, proxy):
        self.process = subprocess.Popen([proxy], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
        self.id = 0
        self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "xrop", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.id += 1
        self.send({"jsonrpc": "2.0", "id": self.id, "method": method, "params": params})
        while True:
            line = self.process.stdout.readline()
            if not line:
                sys.exit("xrop: the proxy ended")
            reply = json.loads(line)
            if reply.get("id") == self.id:
                if "error" in reply:
                    sys.exit(f"xrop: {method}: {reply['error']}")
                return reply["result"]

    def call(self, tool, arguments):
        result = self.request("tools/call", {"name": tool, "arguments": arguments})
        if result.get("isError"):
            sys.exit(f"xrop: {tool}: {result['content']}")
        return result["content"]

    def text(self, tool, arguments):
        return "".join(c.get("text", "") for c in self.call(tool, arguments))


def run(operator, steps):
    i = 0
    while i < len(steps):
        step = steps[i]
        i += 1
        name, _, value = step.partition(":")
        if name == "sleep":
            time.sleep(float(value))
        elif name == "shot":
            images = [c for c in operator.call("openxr_capture_composited_image", {}) if c["type"] == "image"]
            if not images:
                sys.exit("xrop: no image")
            with open(value, "wb") as out:
                out.write(base64.b64decode(images[0]["data"]))
            print("xrop: shot", value)
        elif name == "aim":
            yaw, pitch = (float(v) for v in value.split(","))
            head = json.loads(operator.text("openxr_get_head_pose", {}))["pose"]["position"]
            for pose in ("aim", "grip"):
                operator.call("openxr_set_controller_pose", {"hand": "right", "pose_type": pose, "orientation": quaternion(yaw, pitch),
                                                             "position": [head[0] + 0.1, head[1] - 0.15, head[2] - 0.4]})
            time.sleep(0.3)
        elif name == "click" or name == "press":
            hand, button = value.split(",") if name == "press" else ("right", "Trigger")
            for pressed in (1, 0):
                operator.call("openxr_set_controller_input", {"hand": hand, "component": button, "value": pressed})
                time.sleep(0.15)
        else:
            if i >= len(steps):
                sys.exit(f"xrop: {step} needs its JSON arguments")
            print(step, operator.text(step, json.loads(steps[i]))[:300])
            i += 1


def main():
    proxy = os.environ.get("XROPERATOR_PROXY") or next(iter(sorted(glob.glob(os.path.join(
        os.environ.get("APPDATA", ""), "metavr", "tools", "meta-xr-operator", "*", "windows", "meta-xr-operator-mcp-proxy.exe")), reverse=True)), "")
    if not os.path.isfile(proxy):
        sys.exit("xrop: Meta XR Operator not installed: metavr tools install xroperator")
    operator = Operator(proxy)
    try:
        if len(sys.argv) < 2:
            for tool in operator.request("tools/list", {})["tools"]:
                print(tool["name"])
        else:
            run(operator, sys.argv[1:])
    finally:
        operator.process.terminate()


if __name__ == "__main__":
    # self-check of the pose maths: no turn is the identity, a 90 degree yaw turns about Y only
    assert quaternion(0, 0) == [0.0, 0.0, -0.0, 1.0]
    assert all(abs(a - b) < 1e-9 for a, b in zip(quaternion(90, 0), [0, math.sqrt(0.5), 0, math.sqrt(0.5)]))
    main()
