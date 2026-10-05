import plistlib
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as ipa:
    info = plistlib.loads(ipa.read("Payload/SideStore.app/Info.plist"))
    assert info["CFBundleIdentifier"] == "com.SideStore.SideStore", info["CFBundleIdentifier"]
    executable = ipa.read("Payload/SideStore.app/" + info["CFBundleExecutable"])
    assert executable[:4] in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
    for text in (b"PrepareAppRefreshIntent", b"InstallPreparedRefreshIntent", b"RefreshWithoutDataTogglesIntent"):
        assert text in executable, f"Missing intent {text!r}"
    metadata = json.loads(ipa.read("Payload/SideStore.app/Metadata.appintents/extract.actionsdata"))
    for name in ("PrepareAppRefreshIntent", "InstallPreparedRefreshIntent", "RefreshWithoutDataTogglesIntent"):
        action = metadata["actions"][name]
        assert action["openAppWhenRun"] is False, f"{name} requests foreground launch"
        assert action["isDiscoverable"] is True
        assert "outputType" in action
    assert any(parameter["name"] == "job" and not parameter["isOptional"]
               for parameter in metadata["actions"]["InstallPreparedRefreshIntent"]["parameters"])
    assert "Payload/SideStore.app/PlugIns/AltWidgetExtension.appex/Info.plist" in ipa.namelist()
    print("IPA bundle, device binary, discoverable non-opening intent metadata, required job parameter, and widget checked.")
