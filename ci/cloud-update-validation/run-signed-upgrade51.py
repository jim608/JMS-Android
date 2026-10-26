"""Offline draft: verify the published signed .50 -> signed .51 Portal update.

This is a CI-only candidate. It does not run until a reviewed workflow copies
it into JMS-Android and pins a new public descriptor SHA-256. It never reads the
old private .47 fixture, App credentials, or a signing key.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pwd
import re
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path


SOURCE = Path(__file__).resolve().parent
APP_SOURCE = "5ce90eeadc7d466b58d066be194ef6124d87c9a5"
ORIGIN = "https://jim608.github.io/JMS-Linux/flatpak/repo/"
REF = "app/com.jim608.jms/x86_64/stable"
RUNTIME = "org.gnome.Platform/x86_64/50"
BASELINE_COMMIT = "a5fc24872bedd67933ef3b882d7fcc539c376738b35ade02a67db2f27f118e8a"
TARGET_COMMIT = "4b1e7452a33527d0eacf5bcfb586d42832fa4a4cd9d7caa373315e5633fc52b2"
BASELINE_SHA = "c2701964bfcbcdbd12a2dfce22c6993b20e058834475e118f84279d92cd0ef31"
KEY_SHA = "e708e8459f4be5143ce6cfa20ca69a0b3a10b8ecc248b006354d36e57ecc02d3"
DESCRIPTOR_URL = ORIGIN + "ci-fixtures/signed-upgrade51.json"
URLS = {
    "baseline-signed.flatpak": ORIGIN + "JMS-Linux-0.11.1-jms.50-x86_64-signed.flatpak",
    "target-signed.flatpak": ORIGIN + "JMS-Linux-0.11.1-jms.51-x86_64-signed.flatpak",
    "target-verification.json": ORIGIN + "ci-fixtures/signed-upgrade51-target.json",
    "jms-release.gpg": ORIGIN + "jms-release.gpg",
}
LIMITS = {
    "baseline-signed.flatpak": 512 * 1024**2,
    "target-signed.flatpak": 512 * 1024**2,
    "target-verification.json": 8 * 1024**2,
    "jms-release.gpg": 256 * 1024,
}
HARNESS = ("portal-probe.c", "portal-session.sh", "check-state.py",
           "validate-signed-case.sh")


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise ValueError(reason)


def hex64(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        raise ValueError("Public update fixture redirect refused")


def fetch(url: str, item: dict, limit: int, target: Path) -> None:
    require(url == DESCRIPTOR_URL or url in URLS.values(),
            "URL is outside the reviewed JMS origin fixture set")
    require(set(item) == {"url", "sha256", "bytes"} and item["url"] == url,
            "Fixture URL or fields differ from reviewed origin")
    require(hex64(item["sha256"]) and type(item["bytes"]) is int
            and 0 < item["bytes"] <= limit, "Fixture size/hash pin is invalid")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request(url, headers={"User-Agent": "JMS-signed51-validation/1"})
    with opener.open(request, timeout=60) as response, target.open("xb") as output:
        require(response.status == 200, "Public fixture HTTP status differs")
        total = 0
        digest = hashlib.sha256()
        while True:
            block = response.read(min(1024 * 1024, limit + 1 - total))
            if not block:
                break
            total += len(block)
            require(total <= limit, "Public fixture exceeds limit")
            output.write(block)
            digest.update(block)
    require(total == item["bytes"] and digest.hexdigest() == item["sha256"],
            "Public fixture differs from pinned bytes")
    target.chmod(0o444)


def validate_descriptor(data: dict) -> None:
    require(set(data) == {"schemaVersion", "origin", "ref", "runtime",
                          "sourceCommit", "baselineCommit", "targetCommit", "fixtures"},
            "Signed-upgrade descriptor fields differ")
    require(data["schemaVersion"] == 1 and type(data["schemaVersion"]) is int
            and data["origin"] == ORIGIN and data["ref"] == REF
            and data["runtime"] == RUNTIME and data["sourceCommit"] == APP_SOURCE,
            "Signed-upgrade descriptor identity differs")
    require(data["baselineCommit"] == BASELINE_COMMIT
            and data["targetCommit"] == TARGET_COMMIT
            and TARGET_COMMIT != BASELINE_COMMIT, "Commit pin differs")
    require(set(data["fixtures"]) == set(URLS), "Signed-upgrade fixture set differs")
    for name, url in URLS.items():
        item = data["fixtures"][name]
        require(set(item) == {"url", "sha256", "bytes"} and item["url"] == url
                and hex64(item["sha256"]) and type(item["bytes"]) is int
                and 0 < item["bytes"] <= LIMITS[name], "Fixture pin differs")
    require(data["fixtures"]["baseline-signed.flatpak"]["sha256"] == BASELINE_SHA
            and data["fixtures"]["baseline-signed.flatpak"]["bytes"] == 48664368,
            "Published signed .50 baseline differs")
    require(data["fixtures"]["jms-release.gpg"]["sha256"] == KEY_SHA,
            "JMS public key differs")


def run_checked(args: list[str], log: Path, timeout: int = 1200) -> None:
    with log.open("xb") as stream:
        result = subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT,
                                timeout=timeout, check=False)
    require(result.returncode == 0, "CI stage failed: " + log.name)


def safe_case_failure(output: Path) -> dict:
    """Preserve only fixed diagnostic fields before disposing the CI account."""
    summary = {"needsCommitInspectionBeforeRetry": True}
    for filename, key in (("failure-stage.json", "driver"),
                          ("portal-failure.json", "portal")):
        path = output / filename
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text())
            if (isinstance(data, dict) and
                    re.fullmatch(r"[a-z0-9-]{1,64}", str(data.get("stage", ""))) and
                    type(data.get("exitCode")) is int and
                    0 <= data["exitCode"] <= 255):
                summary[key] = {"stage": data["stage"],
                                "exitCode": data["exitCode"]}
        except (OSError, UnicodeError, ValueError, TypeError):
            pass
    for filename in ("observed-at-driver-exit-commit.txt",
                     "observed-after-failed-portal-commit.txt"):
        path = output / filename
        try:
            value = path.read_text().strip()
            if hex64(value):
                summary["installedCommitAtFailure"] = value
                break
        except (OSError, UnicodeError):
            pass
    return summary


def run(args: argparse.Namespace) -> None:
    require(os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("GITHUB_REPOSITORY") == "jim608/JMS-Android"
            and os.environ.get("GITHUB_REF") == "refs/heads/jms",
            "Reviewed jms-branch GitHub Actions runner required")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    require(re.fullmatch(r"[1-9][0-9]{0,11}", run_id)
            and re.fullmatch(r"[a-f0-9]{40}", os.environ.get("GITHUB_SHA", "")),
            "Exact CI run and source commit required")
    require(os.getuid() != 0, "Runner must not be root")
    root = args.work_root
    require(root.is_absolute() and root.parent.resolve() == Path("/var/tmp")
            and root.name == "jms-signed51-" + run_id
            and not root.exists() and not root.is_symlink(),
            "Fresh exact CI output directory required")
    require(hex64(args.descriptor_sha256), "Unready public descriptor pin")
    root.mkdir(mode=0o755)
    inputs, harness, results, safe = (root / name for name in
                                      ("inputs", "harness", "results", "safe-evidence"))
    for path in (inputs, harness, results, safe):
        path.mkdir(mode=0o755)
    record = {
        "status": "started", "sourceCommit": APP_SOURCE,
        "workflowCommit": os.environ["GITHUB_SHA"], "workflowRunId": run_id,
        "descriptorSHA256": args.descriptor_sha256, "origin": ORIGIN,
        "ref": REF, "baselineCommit": BASELINE_COMMIT,
        "signedToSignedUpgradeTested": False, "realConsentUiTested": False,
        "physicalSteamDeckTested": False, "appRebuilt": False,
        "oldPrivateFixtureUsed": False, "cases": [],
    }
    created: list[tuple[str, int, str]] = []
    stage = "fetch-descriptor"
    try:
        descriptor_pin = {"url": DESCRIPTOR_URL, "sha256": args.descriptor_sha256,
                          "bytes": args.descriptor_bytes}
        fetch(DESCRIPTOR_URL, descriptor_pin, 64 * 1024, root / "descriptor.json")
        descriptor = json.loads((root / "descriptor.json").read_text())
        validate_descriptor(descriptor)
        record["targetCommit"] = descriptor["targetCommit"]
        stage = "fetch-public-fixtures"
        for name, url in URLS.items():
            fetch(url, descriptor["fixtures"][name], LIMITS[name], inputs / name)
        stage = "check-target-receipt"
        target = json.loads((inputs / "target-verification.json").read_text())
        require(target.get("applicationId") == "com.jim608.jms"
                and target.get("architecture") == "x86_64"
                and target.get("branch") == "stable"
                and target.get("runtime") == RUNTIME
                and target.get("sourceCommit") == APP_SOURCE
                and target.get("versionName") == "0.11.1-jms.51"
                and target.get("versionCode") == 56
                and target.get("ostreeCommit") == descriptor["targetCommit"],
                "Published target receipt identity differs")
        stage = "copy-reviewed-harness"
        require(all((SOURCE / item).is_file() for item in HARNESS),
                "Signed-upgrade harness files missing")
        for name in HARNESS:
            shutil.copyfile(SOURCE / name, harness / name)
            (harness / name).chmod(0o444)
        stage = "compile-portal-probe"
        flags = subprocess.check_output(["pkg-config", "--cflags", "--libs",
                                         "gio-2.0"], text=True).split()
        run_checked(["cc", "-std=c11", "-O2", "-Wall", "-Wextra",
                     str(harness / "portal-probe.c"), *flags,
                     "-o", str(inputs / "portal-probe")], root / "compile.log", 120)
        (inputs / "portal-probe").chmod(0o555)
        probe_sha = sha256(inputs / "portal-probe")
        public_env = {
            "JMS_ISOLATED_UPDATE_TEST": "1", "JMS_INPUT_DIR": str(inputs),
            "JMS_BASELINE_COMMIT": BASELINE_COMMIT,
            "JMS_TARGET_COMMIT": descriptor["targetCommit"],
            "JMS_SIGNED_BASELINE_SHA256": BASELINE_SHA,
            "JMS_SIGNED_TARGET_SHA256":
                descriptor["fixtures"]["target-signed.flatpak"]["sha256"],
            "JMS_PUBLIC_KEY_SHA256": KEY_SHA,
            "JMS_TARGET_RECEIPT_SHA256":
                descriptor["fixtures"]["target-verification.json"]["sha256"],
            "JMS_PORTAL_PROBE_SHA256": probe_sha,
            "JMS_PORTAL_TIMEOUT_SECONDS": "600",
        }
        for index, mode in enumerate(("signed-update", "denied-update")):
            stage = "create-account-" + mode
            name = "jms-flatpak-cloud-" + run_id + "-s" + str(index)
            try:
                pwd.getpwnam(name)
                raise ValueError("CI account exists; refusing reuse")
            except KeyError:
                pass
            try:
                run_checked(["sudo", "useradd", "--create-home", "--user-group",
                             "--shell", "/bin/bash", name],
                            root / (mode + "-account.log"), 120)
            finally:
                try:
                    account = pwd.getpwnam(name)
                except KeyError:
                    account = None
                if account and account.pw_uid != 0 and account.pw_dir == "/home/" + name:
                    created.append((name, account.pw_uid, account.pw_dir))
            account = pwd.getpwnam(name)
            require(account.pw_uid != 0 and account.pw_dir == "/home/" + name,
                    "Unexpected disposable account identity")
            output = results / mode
            run_checked(["sudo", "install", "-d", "-m755", "-o", name,
                         "-g", name, str(output)], root / (mode + "-output.log"), 30)
            stage = "run-" + mode
            environment = dict(public_env, JMS_OUTPUT_DIR=str(output))
            invocation = ["sudo", "-u", name, "env", "-i",
                          "PATH=/usr/bin:/bin", "HOME=" + account.pw_dir,
                          *[key + "=" + value for key, value in environment.items()],
                          "bash", str(harness / "validate-signed-case.sh"), mode]
            try:
                run_checked(invocation, root / (mode + "-driver.log"))
            except Exception:
                record["caseFailure"] = {"mode": mode,
                                         **safe_case_failure(output)}
                raise
            result = json.loads((output / "result.json").read_text())
            require(result.get("mode") == mode and result.get("passed") is True
                    and result.get("signedOriginAndInstalledCommitChecked") is True
                    and result.get("syntheticFixtureRetained") is True
                    and result.get("realConsentUiTested") is False
                    and result.get("signedToSignedUpgradeTested") is (mode == "signed-update"),
                    "Signed-update case result is incomplete")
            record["cases"].append({
                "mode": mode, "passed": True,
                "realPortalUpdate": result.get("realPortalUpdate") is True,
                "signedOriginAndInstalledCommitChecked": True,
                "syntheticFixtureRetained": True,
                "consentPermissionStoreFixture": True,
            })
        require(record["cases"][0]["realPortalUpdate"] is True
                and record["cases"][1]["realPortalUpdate"] is False,
                "Signed-update/denial outcomes differ")
        record["signedToSignedUpgradeTested"] = True
        record["status"] = "signed-upgrade-and-denial-passed"
    except Exception as error:
        record["status"] = "failed"
        record["failureStage"] = stage
        record["errorClass"] = type(error).__name__
        raise
    finally:
        cleanup = []
        for name, uid, home in reversed(created):
            try:
                account = pwd.getpwnam(name)
                require(account.pw_uid == uid and account.pw_dir == home,
                        "Disposable account identity changed; cleanup refused")
                subprocess.run(["sudo", "pkill", "-TERM", "-u", str(uid)],
                               capture_output=True, timeout=10)
                time.sleep(1)
                result = subprocess.run(["sudo", "userdel", "--remove", name],
                                        capture_output=True, timeout=30)
                cleanup.append({"account": name, "removed": result.returncode == 0})
            except Exception:
                cleanup.append({"account": name, "removed": False})
        record["disposableAccountCleanup"] = cleanup
        record["cleanupComplete"] = all(item["removed"] for item in cleanup)
        if record["status"] == "signed-upgrade-and-denial-passed" and not record["cleanupComplete"]:
            record["status"] = "cleanup-incomplete"
        (safe / "sanitized-results.json").write_text(json.dumps(record, indent=2) + "\n")
        require(record["status"] == "signed-upgrade-and-denial-passed",
                "Signed upgrade is incomplete; inspect sanitized stage")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--descriptor-sha256", required=True)
    parser.add_argument("--descriptor-bytes", required=True, type=int)
    parser.add_argument("--work-root", required=True, type=Path)
    run(parser.parse_args())
