import hashlib
import json
from pathlib import Path
import re
import struct
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "artifacts/checks/m10"
MATERIALS = ROOT / "artifacts/native-materials-m10"
OUT.mkdir(parents=True, exist_ok=True)
MATERIALS.mkdir(parents=True, exist_ok=True)
HOME = Path.home()
CACHE = HOME / ".gradle/caches/modules-2/files-2.1"
FVP = HOME / "AppData/Local/Pub/Cache/hosted/pub.dev/fvp-0.35.0"

def digest(data):
    return hashlib.sha256(data).hexdigest()

def build_id(data):
    if data[:5] != b"\x7fELF\x02":
        return None
    section_offset = struct.unpack_from("<Q", data, 40)[0]
    size, count, names_index = struct.unpack_from("<HHH", data, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, section_offset + index * size) for index in range(count)]
    names = sections[names_index]
    strings = data[names[4]:names[4] + names[5]]
    for section in sections:
        name = strings[section[0]:].split(b"\0", 1)[0]
        if name == b".note.gnu.build-id":
            note = data[section[4]:section[4] + section[5]]
            name_size, desc_size, kind = struct.unpack_from("<III", note)
            start = 12 + (name_size + 3) // 4 * 4
            return note[start:start + desc_size].hex()
    return None

apk = ROOT / "artifacts/JMS-Android-0.11.1-jms.6-release-arm64-test-signed.apk"
inventory = {}
with zipfile.ZipFile(apk) as archive:
    for name in archive.namelist():
        if name.startswith("lib/arm64-v8a/") and name.endswith(".so"):
            data = archive.read(name)
            inventory[Path(name).name] = {"bytes": len(data), "sha256": digest(data),
                                         "buildId": build_id(data), "candidates": []}
            signatures = [match.decode("utf-8", "replace") for match in re.findall(rb"[\x20-\x7e]{10,}", data)
                          if re.search(rb"^(?:FFmpeg version|ffmpeg version|Lavc\d|Lavf\d|0\.38\.|v0\.36)|--enable-gpl|--disable-gpl|libass API version", match)]
            inventory[Path(name).name]["versionEvidence"] = signatures[:8]

archives = []
for group in ["io.github.peerless2012", "org.jellyfin.media3", "androidx.graphics", "androidx.datastore", "eu.simonbinder"]:
    archives.extend((CACHE / group).rglob("*.aar"))
archives.extend((ROOT / "build/media_kit_libs_android_video").rglob("full-arm64-v8a.jar"))

def candidate(name, data, origin):
    if name not in inventory:
        return
    expected = inventory[name]
    exact = digest(data) == expected["sha256"]
    same_id = build_id(data) and build_id(data) == expected["buildId"]
    if exact or same_id:
        expected["candidates"].append({"origin": str(origin), "sha256": digest(data),
                                      "match": "exact" if exact else "ELF build ID (stripped binary)"})

for path in archives:
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if "/arm64-v8a/" in name and name.endswith(".so"):
                candidate(Path(name).name, archive.read(name), str(path) + "!" + name)
for path in (FVP / "android/mdk-sdk/lib/arm64-v8a").glob("*.so"):
    candidate(path.name, path.read_bytes(), path)
for path in (ROOT / ".jms-tools/flutter/bin/cache/artifacts/engine/android-arm64-release").glob("*.so"):
    candidate(path.name, path.read_bytes(), path)
for group in ["fvp", "media_kit", "media_kit_video"]:
    for path in (ROOT / "build" / group).rglob("*.so"):
        if "arm64-v8a" in str(path) and path.name in inventory:
            candidate(path.name, path.read_bytes(), path)

(OUT / "native-inventory.json").write_text(json.dumps(inventory, indent=2), encoding="utf-8")
for name, entry in inventory.items():
    print(name, len(entry["candidates"]), entry["versionEvidence"][:2])

sources = [
    ("mpv-build", "media-kit/libmpv-android-video-build", "23d81c8a50c6c9c662ce612422b850016ae54dc6"),
    ("ass-android", "peerless2012/libass-android", "2e7f6a6116b401414352f18e72ced73640ca886e"),
    ("jellyfin-media3", "jellyfin/jellyfin-androidx-media", "84ef4b7201a9e1edfc699c31acbc505511a4af1f"),
]
manifest = []
for label, repository, commit in sources:
    url = "https://codeload.github.com/" + repository + "/zip/" + commit
    destination = MATERIALS / (label + "-" + commit[:12] + ".zip")
    if not destination.exists():
        request = urllib.request.Request(url, headers={"User-Agent": "JMS-native-source-audit"})
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read(64 * 1024 * 1024 + 1)
        if len(data) > 64 * 1024 * 1024:
            raise RuntimeError("Source archive exceeds audit limit")
        destination.write_bytes(data)
    manifest.append({"file": destination.name, "url": url, "sourceCommit": commit,
                     "sha256": digest(destination.read_bytes()), "bytes": destination.stat().st_size,
                     "status": "root source and build recipe; submodule coverage must be checked"})
(MATERIALS / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print("Saved source archives:", len(manifest))
