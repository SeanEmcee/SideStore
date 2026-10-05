import plistlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as ipa:
    info = plistlib.loads(ipa.read("Payload/SideStore.app/Info.plist"))
    assert info["CFBundleIdentifier"] == "com.SideStore.SideStore", info["CFBundleIdentifier"]
    executable = ipa.read("Payload/SideStore.app/" + info["CFBundleExecutable"])
    assert executable[:4] in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
    for text in (b"PrepareAppRefreshIntent", b"InstallPreparedRefreshIntent"):
        assert text in executable, f"Missing intent {text!r}"
    assert "Payload/SideStore.app/PlugIns/AltWidgetExtension.appex/Info.plist" in ipa.namelist()
    print("IPA main bundle, device binary, both background intents, and widget checked.")
