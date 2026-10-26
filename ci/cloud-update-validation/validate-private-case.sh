#!/bin/bash
# Private old unsigned fixture or public target, one NEW disposable CI account.
# Explicit origin trust migration is fixture setup, not legacy UI self-migration.
# No signing operation, CLI update, old public-baseline fetch, or upload.
set -Eeuo pipefail
export LC_ALL=C
test "${JMS_ISOLATED_UPDATE_TEST:-}" = 1
test "$(id -u)" != 0
account=$(id -un)
case "$account" in jms-flatpak-cloud-*) ;; *) exit 2 ;; esac
test "${HOME:-}" = "/home/$account"
test "$#" = 1
mode=$1
case "$mode" in fresh-target|unsigned-migration|denied-update) ;; *) exit 2 ;; esac
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
: "${JMS_INPUT_DIR:?}" "${JMS_OUTPUT_DIR:?}" "${JMS_BASELINE_COMMIT:?}" "${JMS_TARGET_COMMIT:?}"
: "${JMS_UNSIGNED_BASELINE_SHA256:?}" "${JMS_SIGNED_TARGET_SHA256:?}"
: "${JMS_PUBLIC_KEY_SHA256:?}" "${JMS_TARGET_RECEIPT_SHA256:?}" "${JMS_PORTAL_PROBE_SHA256:?}"
JMS_INPUT_DIR=$(realpath -- "$JMS_INPUT_DIR")
JMS_OUTPUT_DIR=$(realpath -- "$JMS_OUTPUT_DIR")
export JMS_INPUT_DIR JMS_OUTPUT_DIR
test -d "$JMS_OUTPUT_DIR"
test -z "$(find "$JMS_OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)"
test "$JMS_BASELINE_COMMIT" != "$JMS_TARGET_COMMIT"
for value in "$JMS_BASELINE_COMMIT" "$JMS_TARGET_COMMIT" \
    "$JMS_UNSIGNED_BASELINE_SHA256" "$JMS_SIGNED_TARGET_SHA256" "$JMS_PUBLIC_KEY_SHA256" "$JMS_TARGET_RECEIPT_SHA256" "$JMS_PORTAL_PROBE_SHA256"; do
  [[ "$value" =~ ^[a-f0-9]{64}$ ]]
done
check_sha() { test "$(sha256sum "$1" | cut -d' ' -f1)" = "$2"; }
if test "$mode" != fresh-target; then
  check_sha "$JMS_INPUT_DIR/baseline-unsigned.flatpak" "$JMS_UNSIGNED_BASELINE_SHA256"
fi
check_sha "$JMS_INPUT_DIR/target-signed.flatpak" "$JMS_SIGNED_TARGET_SHA256"
check_sha "$JMS_INPUT_DIR/jms-release.gpg" "$JMS_PUBLIC_KEY_SHA256"
check_sha "$JMS_INPUT_DIR/target-verification.json" "$JMS_TARGET_RECEIPT_SHA256"
check_sha "$JMS_INPUT_DIR/portal-probe" "$JMS_PORTAL_PROBE_SHA256"
test -x "$JMS_INPUT_DIR/portal-probe"
test ! -e "$JMS_OUTPUT_DIR/result.json"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache" XDG_STATE_HOME="$HOME/.local/state"
unset DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID DBUS_STARTER_ADDRESS DBUS_STARTER_BUS_TYPE
unset WAYLAND_DISPLAY SESSION_MANAGER
export XDG_RUNTIME_DIR=$(mktemp -d /tmp/jms-flatpak-cloud.XXXXXX)
chmod 700 "$XDG_RUNTIME_DIR"
test "$(stat -c %u "$XDG_RUNTIME_DIR")" = "$(id -u)"
test "$(stat -c %a "$XDG_RUNTIME_DIR")" = 700
app=com.jim608.jms
ref=app/com.jim608.jms/x86_64/stable
origin_url=https://jim608.github.io/JMS-Linux/flatpak/repo/
test ! -e "$HOME/.var/app/$app"
if flatpak --user info "$ref" >/dev/null 2>&1; then exit 2; fi
if test "$mode" = fresh-target; then bundle=target-signed.flatpak; expected=$JMS_TARGET_COMMIT
else bundle=baseline-unsigned.flatpak; expected=$JMS_BASELINE_COMMIT; fi
flatpak --user install --noninteractive --bundle "$JMS_INPUT_DIR/$bundle"
test "$(flatpak --user info --show-commit "$ref")" = "$expected"
origin=$(flatpak --user info --show-origin "$ref")
test -n "$origin" && test "$origin" != flathub
if test "$mode" != fresh-target; then
  # Scope is this account's freshly installed, exact original CI bundle only.
  flatpak --user remote-modify --url="$origin_url" --gpg-import="$JMS_INPUT_DIR/jms-release.gpg" --gpg-verify "$origin"
fi
python3 "$here/check-state.py" origin "$origin" > "$JMS_OUTPUT_DIR/origin-before.json"
test "$(flatpak --user remote-info --show-commit "$origin" "$ref")" = "$JMS_TARGET_COMMIT"
python3 "$here/check-state.py" launchers > "$JMS_OUTPUT_DIR/launchers-before.json"
flatpak --user info --show-permissions "$ref" > "$JMS_OUTPUT_DIR/permissions-before.txt"
fixture="$HOME/.var/app/$app/config/jms-cloud-update-fixture.txt"
mkdir -p -- "$(dirname -- "$fixture")"
printf '%s\n' 'jms-public-update-fixture-v1' > "$fixture"
sha256sum "$fixture" > "$JMS_OUTPUT_DIR/fixture-before.sha256"
if test "$mode" != fresh-target; then
  if xvfb-run -a dbus-run-session -- bash "$here/portal-session.sh" "$mode"; then :
  else
    portal_exit=$?
    flatpak --user info --show-commit "$ref" > "$JMS_OUTPUT_DIR/observed-after-failed-portal-commit.txt" || true
    printf '{"mode":"%s","passed":false,"portalExit":%s,"inspectInstalledCommitBeforeRetry":true}\n' \
      "$mode" "$portal_exit" > "$JMS_OUTPUT_DIR/result.json"
    exit "$portal_exit"
  fi
fi
flatpak --user info --show-commit "$ref" > "$JMS_OUTPUT_DIR/observed-after-portal-commit.txt"
test "$(flatpak --user info --show-origin "$ref")" = "$origin"
python3 "$here/check-state.py" origin "$origin" > "$JMS_OUTPUT_DIR/origin-after.json"
cmp "$JMS_OUTPUT_DIR/origin-before.json" "$JMS_OUTPUT_DIR/origin-after.json"
sha256sum --check "$JMS_OUTPUT_DIR/fixture-before.sha256"
if test "$mode" = denied-update; then expected=$JMS_BASELINE_COMMIT; else expected=$JMS_TARGET_COMMIT; fi
test "$(flatpak --user info --show-commit "$ref")" = "$expected"
flatpak --user info --show-permissions "$ref" > "$JMS_OUTPUT_DIR/permissions-after.txt"
cmp "$JMS_OUTPUT_DIR/permissions-before.txt" "$JMS_OUTPUT_DIR/permissions-after.txt"
python3 "$here/check-state.py" launchers > "$JMS_OUTPUT_DIR/launchers-after.json"
if test "$mode" != denied-update; then
  deployment=$(flatpak --user info --show-location "$ref")
  python3 "$here/check-state.py" target "$deployment" > "$JMS_OUTPUT_DIR/target-identity.json"
fi
python3 - "$mode" "$JMS_OUTPUT_DIR/result.json" <<'PY'
import json, pathlib, sys
mode, output = sys.argv[1:]
pathlib.Path(output).write_text(json.dumps({'mode': mode, 'passed': True,
    'realPortalUpdate': mode == 'unsigned-migration',
    'consentPermissionStoreFixture': mode != 'fresh-target', 'realConsentUiTested': False,
    'signedOriginAndInstalledCommitChecked': True, 'syntheticFixtureRetained': True,
    'launcherMetadataOnly': True, 'realAuthenticatedMediaTested': False}, indent=2)+'\n')
PY
