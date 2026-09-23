import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile
import os

from jms_release_notes import require_current_notes

ROOT = Path(__file__).resolve().parents[1]
TEST_CERT = "4327eedb953fbf51d82b70e2e56c23122c85304d55a67fbbdb37a8f1ffd5f399"
ALLOWED_ROOTS = {"lib", "assets", "icons", "android", "ios", "linux", "macos", "windows",
                 "web", "test", "integration_test", "pigeons", "scripts", "docs", "config", "third_party", ".github"}
ALLOWED_FILES = {"pubspec.yaml", "pubspec.lock", "l10n.yaml", "analysis_options.yaml", "build.yaml",
                 "LICENSE", "README.md", "CHANGELOG.md", "NOTICE", ".metadata", ".gitignore",
                 "build.jms_ambient.yaml", ".fvmrc", "AGENTS.md"}
PRIVATE_NAMES = {"key.properties", "local.properties", ".env", "credentials.json", "google-services.json"}
SECRET = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}")

def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def run(*command):
    return subprocess.check_output(["rtk", "proxy", *map(str, command)], cwd=ROOT, text=True,
                                   encoding="utf-8", stderr=subprocess.PIPE).strip()

def validate_source_name(name):
    path = Path(name)
    if path.is_absolute() or ".." in path.parts or path.name in PRIVATE_NAMES or path.name.startswith(".env"):
        raise ValueError("Private or unsafe source path: " + name)
    if path.suffix.lower() in {".jks", ".keystore", ".p12", ".pfx", ".pem", ".key", ".apk", ".aab"}:
        raise ValueError("Private or generated source path: " + name)
    return len(path.parts) == 1 and name in ALLOWED_FILES or path.parts[0] in ALLOWED_ROOTS

def require_bound_sources(record):
    for entry in record["inputs"]:
        path = ROOT / entry["path"]
        if not path.is_file() or sha256(path) != entry["sha256"]:
            raise ValueError("Build input drift: " + entry["path"])

def validate_publication(record):
    from jms_publication import REPOSITORY, SIGNER
    if record["repository"] != REPOSITORY or record["signerSha256"] != SIGNER:
        raise ValueError("PUBLICATION BLOCKED: repository or installed-app signer differs")
    if record.get("signingCustodyAudit") != "PASS" or record["nativeSourceAudit"] != "PASS":
        raise ValueError("PUBLICATION BLOCKED: custody or corresponding-source evidence incomplete")

def apk_info(apk, sdk):
    badging = run(sdk / "aapt.exe", "dump", "badging", apk)
    package = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    minimum = re.search(r"sdkVersion:'(\d+)'", badging)
    abis = re.search(r"native-code: (.+)", badging)
    if not package or not minimum or not abis:
        raise ValueError("APK metadata incomplete")
    signature = run(sdk / "apksigner.bat", "verify", "--verbose", "--print-certs", apk)
    fingerprints = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([a-f0-9]{64})", signature)
    if len(fingerprints) != 1:
        raise ValueError("Expected one verified signer")
    info = {"applicationId": package[1], "versionCode": int(package[2]), "versionName": package[3],
            "minSdk": int(minimum[1]), "abis": re.findall(r"'([^']+)'", abis[1])}
    if info["applicationId"] != "com.jim608.jms" or info["abis"] != ["arm64-v8a"] or "split=" in package[0]:
        raise ValueError("Not a complete JMS ARM64 APK")
    with zipfile.ZipFile(apk) as archive:
        for required in ("classes.dex", "lib/arm64-v8a/libflutter.so", "lib/arm64-v8a/libapp.so"):
            archive.getinfo(required)
    return info, fingerprints[0], "CN=Android Debug" in signature, badging, signature

def main():
    parser = argparse.ArgumentParser(description="Local only; never creates or uploads a GitHub release")
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--apk", required=True)
    parser.add_argument("--notes", required=True)
    parser.add_argument("--build-record")
    parser.add_argument("--require-publication-ready", action="store_true")
    args = parser.parse_args()
    apk = Path(args.apk).resolve()
    notes = Path(args.notes).read_text(encoding="utf-8")
    if not notes.strip():
        raise ValueError("Release notes are required")
    sdk = ROOT / ".jms-tools/android-sdk/build-tools/35.0.0"
    info, signer, test_signing, badging, signature = apk_info(apk, sdk)
    version = info["versionName"]
    if not re.fullmatch(r"[A-Za-z0-9._+-]+", version):
        raise ValueError("Unsafe version name")
    notes = require_current_notes(ROOT / 'CHANGELOG.md', Path(args.notes), version)
    inputs_path = Path(args.build_record) if args.build_record else ROOT / ("artifacts/checks/build-" + version + "-inputs.json")
    record = json.loads(inputs_path.read_text(encoding="utf-8-sig"))
    if record["version"] != version or info["versionCode"] != 2000 + record["baseVersionCode"]:
        raise ValueError("APK does not match ARM64 build record")
    with zipfile.ZipFile(apk) as archive:
        if record["buildId"].encode() not in archive.read("lib/arm64-v8a/libapp.so"):
            raise ValueError("APK build ID does not match source record")
    require_bound_sources(record)
    commit = record["sourceCommit"]
    snapshot = record.get("publicationSnapshot", False)
    if snapshot:
        from verify_jms_snapshot import verify_snapshot
        verify_snapshot(commit, record["inputs"])
    elif commit != run("git", "rev-parse", "HEAD"):
        raise ValueError("Source commit drift")
    source_config = json.loads((ROOT / "config/jms_updates.json").read_text(encoding="utf-8-sig"))
    repository = source_config["owner"] + "/" + source_config["repo"] if source_config["owner"] and source_config["repo"] else ""
    from jms_publication import publication_gates, read_json
    policy_path = ROOT / 'config/jms_publication.json'
    failures = publication_gates(read_json(policy_path), apk, signer) if policy_path.exists() else ['No publication policy']
    publication = {"repository": repository, "signerSha256": signer, "testSigning": test_signing,
                   "signingCustodyAudit": "PASS" if not any(item.startswith('SIGNING:') for item in failures) and policy_path.exists() else "BLOCKED",
                   "nativeSourceAudit": "PASS" if not failures else "BLOCKED", "status": "LOCAL_ONLY", "blockers": failures}
    if args.require_publication_ready:
        validate_publication(publication)
    final_destination = ROOT / "artifacts/releases" / record["buildId"]
    if final_destination.exists():
        raise ValueError("Refusing to overwrite an existing release preparation: " + str(final_destination))
    destination = final_destination.with_name('.pending-' + record['buildId'])
    owner_path = destination / 'PREPARATION.json'
    owner = {'buildId': record['buildId'], 'sourceCommit': commit, 'apkSha256': sha256(apk)}
    if destination.exists() and (not owner_path.is_file() or json.loads(owner_path.read_text(encoding='utf-8')) != owner):
        raise ValueError('Incomplete preparation belongs to another input; refusing overwrite')
    destination.mkdir(parents=True, exist_ok=True)
    owner_path.write_text(json.dumps(owner), encoding='utf-8')
    source_archive = destination / ("JMS-" + version + "-source.zip")
    names = run("git", "ls-tree", "-rz", "--name-only", commit).split("\0") if snapshot else run("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0")
    source_manifest = {}
    with zipfile.ZipFile(source_archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name in sorted(set(names)):
            if not name or not (ROOT / name).is_file() or not validate_source_name(name):
                continue
            path = ROOT / name
            if path.is_symlink():
                raise ValueError("Source symlink requires manual review: " + name)
            if snapshot:
                data = subprocess.check_output(['rtk', 'proxy', 'git', 'cat-file', 'blob', f'{commit}:{name}'], cwd=ROOT)
            else:
                data = path.read_bytes()
            if SECRET.search(data):
                raise ValueError("Potential secret in source: " + name)
            archive.writestr("JMS/" + name, data)
            source_manifest[name] = hashlib.sha256(data).hexdigest()
        missing = [entry["path"] for entry in record["inputs"] if entry["path"] not in source_manifest]
        if missing:
            raise ValueError("Build inputs missing from source package: " + ", ".join(missing))
        archive.writestr("JMS/build-inputs.json", json.dumps(record, indent=2))
        archive.writestr("JMS/source-manifest.json", json.dumps({"sourceCommit": commit, "dirty": not snapshot,
                          "files": source_manifest}, indent=2))
        archive.writestr("JMS/source-changes.patch", run("git", "show", "--format=", "--binary", commit) if snapshot else run("git", "diff", "--binary", "HEAD", "--", *sorted(ALLOWED_ROOTS), *sorted(ALLOWED_FILES)))
    shutil.copy2(apk, destination / apk.name)
    metadata = {"schemaVersion": 1, **info, "sourceCommit": commit, "buildId": record["buildId"],
                "apk": {"name": apk.name, "size": apk.stat().st_size, "sha256": sha256(apk)},
                "source": {"name": source_archive.name, "size": source_archive.stat().st_size, "sha256": sha256(source_archive)}}
    (destination / "update.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    (destination / "RELEASE_NOTES.zh-Hant.md").write_text(notes, encoding="utf-8")
    (destination / "publication-status.json").write_text(json.dumps(publication, indent=2), encoding="utf-8")
    (destination / "apk-badging.txt").write_text(badging, encoding="utf-8")
    (destination / "apk-signature.txt").write_text(signature, encoding="utf-8")
    (destination / "SHA256SUMS.txt").write_text("".join(sha256(path) + "  " + path.name + "\n"
        for path in sorted(destination.iterdir()) if path.is_file() and path.name != 'SHA256SUMS.txt'), encoding="utf-8")
    require_bound_sources(record)
    os.replace(destination, final_destination)
    print(json.dumps({"directory": str(final_destination), "metadata": metadata, "publication": publication}, indent=2))

if __name__ == "__main__":
    main()
