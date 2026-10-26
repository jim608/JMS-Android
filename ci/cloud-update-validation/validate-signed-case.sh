#!/bin/bash
# Existing public signed .50 to public signed .51, one NEW disposable CI account.
# The existing signed bundle must already configure the same verified origin.
# No signing operation, CLI update, private .47 fixture or credential access.
set -Eeuo pipefail
export LC_ALL=C
jms_stage=bootstrap
jms_mode=bootstrap
jms_output_ready=0
jms_failure_line=0
jms_set_stage() {
  jms_stage=$1
  if test "$jms_output_ready" = 1; then
    printf '{"mode":"%s","stage":"%s"}\n' "$jms_mode" "$jms_stage" > "$JMS_OUTPUT_DIR/case-stage.json" || :
  fi
}
jms_on_exit() {
  local status=$1 line=$2
  trap - ERR EXIT
  if test "$status" != 0; then
    if test "$jms_failure_line" != 0; then line=$jms_failure_line; fi
    local payload
    printf -v payload '{"mode":"%s","stage":"%s","line":%s,"exitCode":%s}' "$jms_mode" "$jms_stage" "$line" "$status"
    printf 'JMS_CASE_DIAGNOSTIC %s\n' "$payload" >&2 || :
    if test "$jms_output_ready" = 1; then
      printf '%s\n' "$payload" > "$JMS_OUTPUT_DIR/failure-stage.json" || :
      timeout --kill-after=2s 15s flatpak --user info --show-commit app/com.jim608.jms/x86_64/stable > "$JMS_OUTPUT_DIR/observed-at-driver-exit-commit.txt" 2>/dev/null || :
    fi
  fi
  exit "$status"
}
trap 'jms_failure_line=$LINENO' ERR
trap 'jms_on_exit "$?" "$LINENO"' EXIT
jms_set_stage guard-isolation
test "${JMS_ISOLATED_UPDATE_TEST:-}" = 1
jms_set_stage guard-account
test "$(id -u)" != 0
account=$(id -un)
case "$account" in jms-flatpak-cloud-*) ;; *) exit 2 ;; esac
jms_set_stage guard-home
test "${HOME:-}" = "/home/$account"
jms_set_stage guard-mode
test "$#" = 1
mode=$1
case "$mode" in signed-update|denied-update) ;; *) exit 2 ;; esac
jms_mode=$mode
jms_set_stage guard-paths
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
: "${JMS_INPUT_DIR:?}" "${JMS_OUTPUT_DIR:?}" "${JMS_BASELINE_COMMIT:?}" "${JMS_TARGET_COMMIT:?}"
: "${JMS_SIGNED_BASELINE_SHA256:?}" "${JMS_SIGNED_TARGET_SHA256:?}"
: "${JMS_PUBLIC_KEY_SHA256:?}" "${JMS_TARGET_RECEIPT_SHA256:?}" "${JMS_PORTAL_PROBE_SHA256:?}"
JMS_INPUT_DIR=$(realpath -- "$JMS_INPUT_DIR")
JMS_OUTPUT_DIR=$(realpath -- "$JMS_OUTPUT_DIR")
export JMS_INPUT_DIR JMS_OUTPUT_DIR
test -d "$JMS_OUTPUT_DIR"
jms_set_stage guard-empty-output
test -z "$(find "$JMS_OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)"
jms_output_ready=1
jms_set_stage verify-inputs
test "$JMS_BASELINE_COMMIT" != "$JMS_TARGET_COMMIT"
for value in "$JMS_BASELINE_COMMIT" "$JMS_TARGET_COMMIT" \
    "$JMS_SIGNED_BASELINE_SHA256" "$JMS_SIGNED_TARGET_SHA256" "$JMS_PUBLIC_KEY_SHA256" "$JMS_TARGET_RECEIPT_SHA256" "$JMS_PORTAL_PROBE_SHA256"; do
  [[ "$value" =~ ^[a-f0-9]{64}$ ]]
done
check_sha() { test "$(sha256sum "$1" | cut -d' ' -f1)" = "$2"; }
check_sha "$JMS_INPUT_DIR/baseline-signed.flatpak" "$JMS_SIGNED_BASELINE_SHA256"
check_sha "$JMS_INPUT_DIR/target-signed.flatpak" "$JMS_SIGNED_TARGET_SHA256"
check_sha "$JMS_INPUT_DIR/jms-release.gpg" "$JMS_PUBLIC_KEY_SHA256"
check_sha "$JMS_INPUT_DIR/target-verification.json" "$JMS_TARGET_RECEIPT_SHA256"
check_sha "$JMS_INPUT_DIR/portal-probe" "$JMS_PORTAL_PROBE_SHA256"
test -x "$JMS_INPUT_DIR/portal-probe"
jms_set_stage prepare-session
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
jms_set_stage guard-not-installed
if flatpak --user info "$ref" >/dev/null 2>&1; then exit 2; fi
jms_set_stage baseline-signed-bundle
bundle=baseline-signed.flatpak
expected=$JMS_BASELINE_COMMIT
jms_set_stage install-bundle
flatpak --user install --noninteractive --bundle "$JMS_INPUT_DIR/$bundle"
jms_set_stage installed-commit
test "$(flatpak --user info --show-commit "$ref")" = "$expected"
jms_set_stage origin-name
origin=$(flatpak --user info --show-origin "$ref")
test -n "$origin" && test "$origin" != flathub
# A signed bundle must establish the published URL and GPG verification on its
# own.  Never repair a misconfigured origin in this test.
jms_set_stage origin-trust-check
python3 "$here/check-state.py" origin "$origin" > "$JMS_OUTPUT_DIR/origin-before.json"
jms_set_stage remote-target-check
test "$(flatpak --user remote-info --show-commit "$origin" "$ref")" = "$JMS_TARGET_COMMIT"
jms_set_stage launchers-before
python3 "$here/check-state.py" launchers > "$JMS_OUTPUT_DIR/launchers-before.json"
jms_set_stage permissions-before
flatpak --user info --show-permissions "$ref" > "$JMS_OUTPUT_DIR/permissions-before.txt"
jms_set_stage synthetic-settings-fixture
fixture="$HOME/.var/app/$app/config/jms-cloud-update-fixture.txt"
mkdir -p -- "$(dirname -- "$fixture")"
printf '%s\n' 'jms-public-update-fixture-v1' > "$fixture"
sha256sum "$fixture" > "$JMS_OUTPUT_DIR/fixture-before.sha256"
jms_set_stage portal-session
timeout --kill-after=2s 15s flatpak --user info --show-commit "$ref" > "$JMS_OUTPUT_DIR/observed-before-portal-commit.txt" 2>/dev/null || :
if xvfb-run -a dbus-run-session -- bash "$here/portal-session.sh" "$mode"; then :
else
  portal_exit=$?
  timeout --kill-after=2s 15s flatpak --user info --show-commit "$ref" > "$JMS_OUTPUT_DIR/observed-after-failed-portal-commit.txt" || true
  printf '{"mode":"%s","passed":false,"portalExit":%s,"inspectInstalledCommitBeforeRetry":true}\n' \
    "$mode" "$portal_exit" > "$JMS_OUTPUT_DIR/result.json"
  exit "$portal_exit"
fi
jms_set_stage after-update-origin-check
flatpak --user info --show-commit "$ref" > "$JMS_OUTPUT_DIR/observed-after-portal-commit.txt"
test "$(flatpak --user info --show-origin "$ref")" = "$origin"
python3 "$here/check-state.py" origin "$origin" > "$JMS_OUTPUT_DIR/origin-after.json"
cmp "$JMS_OUTPUT_DIR/origin-before.json" "$JMS_OUTPUT_DIR/origin-after.json"
jms_set_stage settings-preserved
sha256sum --check "$JMS_OUTPUT_DIR/fixture-before.sha256"
if test "$mode" = denied-update; then expected=$JMS_BASELINE_COMMIT; else expected=$JMS_TARGET_COMMIT; fi
jms_set_stage after-update-commit-check
test "$(flatpak --user info --show-commit "$ref")" = "$expected"
jms_set_stage permissions-preserved
flatpak --user info --show-permissions "$ref" > "$JMS_OUTPUT_DIR/permissions-after.txt"
cmp "$JMS_OUTPUT_DIR/permissions-before.txt" "$JMS_OUTPUT_DIR/permissions-after.txt"
jms_set_stage launchers-after
python3 "$here/check-state.py" launchers > "$JMS_OUTPUT_DIR/launchers-after.json"
if test "$mode" != denied-update; then
  jms_set_stage target-contents-check
  deployment=$(flatpak --user info --show-location "$ref")
  python3 "$here/check-state.py" target "$deployment" > "$JMS_OUTPUT_DIR/target-identity.json"
fi
jms_set_stage write-result
python3 - "$mode" "$JMS_OUTPUT_DIR/result.json" <<'PY'
import json, pathlib, sys
mode, output = sys.argv[1:]
pathlib.Path(output).write_text(json.dumps({'mode': mode, 'passed': True,
  'realPortalUpdate': mode == 'signed-update',
    'signedToSignedUpgradeTested': mode == 'signed-update',
    'consentPermissionStoreFixture': True, 'realConsentUiTested': False,
    'signedOriginAndInstalledCommitChecked': True, 'syntheticFixtureRetained': True,
    'launcherMetadataOnly': True, 'realAuthenticatedMediaTested': False}, indent=2)+'\n')
PY
