"""Prints the UDID of an available iPhone simulator on the newest iOS 17+ runtime (CI helper)."""
import json
import subprocess
import sys


def version(text):
    return tuple(int(p) for p in text.split(".")[:2])


runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "available", "-j"]))["runtimes"]
runtimes = [r for r in runtimes if r.get("isAvailable") and "SimRuntime.iOS-" in r["identifier"] and version(r["version"]) >= (17, 0)]
if not runtimes:
    sys.exit("no iOS 17+ simulator runtime")
runtimes.sort(key=lambda r: version(r["version"]), reverse=True)
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
for rt in runtimes:
    phones = sorted((d for d in devices.get(rt["identifier"], []) if d.get("isAvailable") and d["name"].startswith("iPhone")),
                    key=lambda d: d["name"])
    if phones:
        print(phones[0]["udid"])
        sys.stderr.write(f"simulator: {phones[0]['name']} / iOS {rt['version']}\n")
        sys.exit(0)
# No device yet: create one from the newest runtime's first iPhone type.
rt = runtimes[0]
types = [t for t in rt.get("supportedDeviceTypes", []) if t.get("productFamily") == "iPhone"]
if not types:
    sys.exit("no iPhone device type")
udid = subprocess.check_output(["xcrun", "simctl", "create", "CI iPhone", types[-1]["identifier"], rt["identifier"]]).decode().strip()
sys.stderr.write(f"created simulator {types[-1]['name']} / iOS {rt['version']}\n")
print(udid)
