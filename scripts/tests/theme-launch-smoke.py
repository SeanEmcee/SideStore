"""Launch the real theme manager in UIKit, on an iOS simulator, rather than only compiling it."""
import json
import pathlib
import plistlib
import subprocess
import tempfile
import time


def run(*args, timeout=120):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.CalledProcessError as error:
        print(error.output)
        raise
    except subprocess.TimeoutExpired as error:
        print(f"Timed out while running {args}")
        if error.output:
            print(error.output.decode(errors="replace") if isinstance(error.output, bytes) else error.output)
        raise


runtime = next(r for r in json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
               if r["isAvailable"] and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS"))
device_type = next(d for d in json.loads(run("xcrun", "simctl", "list", "devicetypes", "-j"))["devicetypes"]
                   if d["name"] == "iPhone 17 Pro")
device = run("xcrun", "simctl", "create", "SideStore Theme Launch Test",
             device_type["identifier"], runtime["identifier"]).strip()
try:
    run("xcrun", "simctl", "boot", device)
    run("xcrun", "simctl", "bootstatus", device, "-b", timeout=240)
    with tempfile.TemporaryDirectory() as temp:
        app = pathlib.Path(temp) / "ThemeLaunch.app"
        app.mkdir()
        info = {
            "CFBundleIdentifier": "com.SeanEmcee.SideStoreThemeLaunchTest",
            "CFBundleExecutable": "ThemeLaunch", "CFBundleName": "ThemeLaunch",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.0",
            "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
            "UILaunchScreen": {},
        }
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path").strip()
        arch = run("uname", "-m").strip()
        run("xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library",
            "-sdk", sdk, "-target", f"{arch}-apple-ios17.0-simulator",
            "SideStore/Core/Theme/ThemeManager.swift",
            "Shared/Extensions/UIApplication+AppExtension.swift",
            "scripts/tests/theme-launch-main.swift", "-o", str(app / "ThemeLaunch"))
        run("codesign", "--force", "--sign", "-", str(app))
        run("xcrun", "simctl", "install", device, str(app))
        output = run("xcrun", "simctl", "launch", "--console", device,
                     info["CFBundleIdentifier"], timeout=60)
        print(output)
        container = pathlib.Path(run("xcrun", "simctl", "get_app_container", device,
                                     info["CFBundleIdentifier"], "data").strip())
        result = container / "Documents" / "theme-launch-result.txt"
        deadline = time.monotonic() + 20
        while not result.is_file() and time.monotonic() < deadline:
            time.sleep(0.2)
        assert result.is_file(), "UIKit theme launch test did not complete"
        message = result.read_text()
        assert message.startswith("THEME_LAUNCH_PASS:"), message
        print(message)
finally:
    subprocess.run(["xcrun", "simctl", "shutdown", device], check=False)
    subprocess.run(["xcrun", "simctl", "delete", device], check=False)
