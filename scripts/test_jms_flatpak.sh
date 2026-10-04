#!/bin/bash
set -euo pipefail
# Only a newly created CI account with a disposable keyring may run this test.
test "${JMS_ISOLATED_FLATPAK_TEST:-}" = 1
test "$(id -u)" != 0
test "$(id -un)" = jms-flatpak-validation
test "$HOME" = /home/jms-flatpak-validation
test -n "${JMS_FLATPAK_BUNDLE:-}"
test -n "${JMS_FLATPAK_TEST_DIR:-}"
test -n "${JMS_FLATPAK_OUTPUT:-}"
app=com.jim608.jms
test -r "$JMS_FLATPAK_BUNDLE"
test -x "$JMS_FLATPAK_TEST_DIR/secret-test"
test -x "$JMS_FLATPAK_TEST_DIR/media-test"
test -r "$JMS_FLATPAK_TEST_DIR/synthetic.mkv"
if flatpak --user info "$app" >/dev/null 2>&1 || test -e "$HOME/.var/app/$app"; then
  echo 'Fresh-install validation requires a new isolated account' >&2; exit 1
fi
mkdir -p "$JMS_FLATPAK_OUTPUT" "$HOME/.local/share"
flatpak --user install --noninteractive --bundle "$JMS_FLATPAK_BUNDLE"
flatpak --user info "$app" > "$JMS_FLATPAK_OUTPUT/installed-info.txt"
deployment=$(flatpak --user info --show-location "$app")
commit=$(flatpak --user info --show-commit "$app")
printf '%s\n' "$deployment" > "$JMS_FLATPAK_OUTPUT/deployment-location.txt"
printf '%s\n' "$commit" > "$JMS_FLATPAK_OUTPUT/installed-commit.txt"
flatpak --user info --show-permissions "$app" > "$JMS_FLATPAK_OUTPUT/permissions.txt"
python3 - "$JMS_FLATPAK_OUTPUT/permissions.txt" <<'PY'
import configparser, sys
permissions = configparser.ConfigParser(interpolation=None)
permissions.read(sys.argv[1])
context = permissions['Context']
filesystems = {item.split(':', 1)[0] for item in context.get('filesystems', '').split(';') if item}
sockets = set(context.get('sockets', '').split(';'))
if filesystems & {'home', 'host', 'host-os', 'host-etc', 'host-root', '/'} or sockets & {'session-bus', 'system-bus'}:
    raise SystemExit('Overbroad Flatpak permissions')
PY
export JMS_FLATPAK_DEPLOYMENT="$deployment"
dbus-run-session -- xvfb-run -a bash -euo pipefail <<'TEST_SESSION'
export XDG_RUNTIME_DIR
XDG_RUNTIME_DIR=$(mktemp -d /tmp/jms-flatpak-runtime.XXXXXX)
chmod 700 "$XDG_RUNTIME_DIR"
trap 'flatpak kill com.jim608.jms 2>/dev/null || true; pulseaudio --kill 2>/dev/null || true; pkill -u "$(id -u)" -x gnome-keyring-d 2>/dev/null || true' EXIT
printf '%s' fixture-keyring-passphrase | gnome-keyring-daemon --unlock --components=secrets >/dev/null
pulseaudio --start --exit-idle-time=-1
helper="$JMS_FLATPAK_TEST_DIR/secret-test"
run_secret() {
  timeout --kill-after=5s 30s flatpak --user run --filesystem="$JMS_FLATPAK_TEST_DIR:ro" --command="$helper" com.jim608.jms "$1"
}
run_secret invalid
run_secret write
run_secret read
run_secret isolated
before=$(pgrep -u "$(id -u)" -x gnome-keyring-d | sort)
test -n "$before"
pkill -u "$(id -u)" -x gnome-keyring-d
for attempt in $(seq 1 30); do
  if ! pgrep -u "$(id -u)" -x gnome-keyring-d >/dev/null; then break; fi
  sleep .1
done
if pgrep -u "$(id -u)" -x gnome-keyring-d >/dev/null; then
  echo 'Old isolated keyring daemon did not exit' >&2; exit 1
fi
printf '%s' fixture-keyring-passphrase | gnome-keyring-daemon --unlock --components=secrets >/dev/null
after=$(pgrep -u "$(id -u)" -x gnome-keyring-d | sort)
test -n "$after"
test "$before" != "$after"
printf 'before=%s\nafter=%s\n' "$before" "$after" > "$JMS_FLATPAK_OUTPUT/keyring-daemon-restart.txt"
run_secret read
test -d "$HOME/.local/share/keyrings"
test -n "$(find "$HOME/.local/share/keyrings" -name '*.keyring' -type f -size +0c -print -quit)"
if grep -RaFq fixture-session-only "$HOME/.local/share/keyrings"; then
  echo 'Unexpected plaintext keyring session' >&2; exit 1
fi
timeout --kill-after=5s 30s flatpak --user run --no-talk-name=org.freedesktop.secrets --filesystem="$JMS_FLATPAK_TEST_DIR:ro" --command="$helper" com.jim608.jms unavailable
timeout --kill-after=5s 30s flatpak --user run --filesystem="$JMS_FLATPAK_TEST_DIR:ro" --command="$JMS_FLATPAK_TEST_DIR/media-test" com.jim608.jms "$JMS_FLATPAK_TEST_DIR/synthetic.mkv" > "$JMS_FLATPAK_OUTPUT/media-test.log"
launch() {
  label=$1
  flatpak --user run com.jim608.jms > "$JMS_FLATPAK_OUTPUT/$label.log" 2>&1 &
  app_pid=$!
  found=false
  for attempt in $(seq 1 30); do
    kill -0 "$app_pid"
    xwininfo -root -tree > "$JMS_FLATPAK_OUTPUT/$label-windows.txt"
    if grep -q 'JMS' "$JMS_FLATPAK_OUTPUT/$label-windows.txt"; then found=true; break; fi
    sleep 1
  done
  test "$found" = true
  sleep 5
  kill -0 "$app_pid"
  if grep -Eiq 'cannot open shared object|symbol lookup error|Unhandled Exception|Failed to load dynamic library' "$JMS_FLATPAK_OUTPUT/$label.log"; then
    echo 'Flatpak runtime error' >&2; exit 1
  fi
  flatpak kill com.jim608.jms
  wait "$app_pid" || true
}
launch first-launch
# Preserve all product-created settings and a known file during reinstall.
app_data="$HOME/.var/app/com.jim608.jms"
mkdir -p "$app_data/config" "$app_data/data"
settings="$app_data/config/jms-flatpak-validation.json"
printf '%s\n' '{"fixture":"retained-local-setting","themeMode":"dark"}' > "$settings"
sha256sum "$settings" > "$JMS_FLATPAK_OUTPUT/settings-before.txt"
find "$app_data/config" "$app_data/data" -type f -print0 | sort -z | xargs -0 -r sha256sum > "$JMS_FLATPAK_OUTPUT/config-before.txt"
flatpak --user install --noninteractive --reinstall --bundle "$JMS_FLATPAK_BUNDLE"
sha256sum --check "$JMS_FLATPAK_OUTPUT/config-before.txt"
sha256sum "$settings" > "$JMS_FLATPAK_OUTPUT/settings-after.txt"
cmp "$JMS_FLATPAK_OUTPUT/settings-before.txt" "$JMS_FLATPAK_OUTPUT/settings-after.txt"
test "$(flatpak --user info --show-commit com.jim608.jms)" = "$(cat "$JMS_FLATPAK_OUTPUT/installed-commit.txt")"
run_secret read
run_secret isolated
launch restart
sha256sum --check "$JMS_FLATPAK_OUTPUT/settings-before.txt"
run_secret clear
run_secret empty
if grep -RaFq fixture-session-only "$HOME/.local/share/keyrings"; then
  echo 'Unexpected plaintext keyring session after reinstall' >&2; exit 1
fi
echo 'Sandbox Secret Service cross-process restore, verified daemon restart, account isolation, same-bundle reinstall retention, clear and denied-service passed' > "$JMS_FLATPAK_OUTPUT/secret-service-test.log"
TEST_SESSION
python3 - "$JMS_FLATPAK_OUTPUT" <<'PY'
import json, pathlib, sys
output = pathlib.Path(sys.argv[1])
(output / 'runtime-validation.json').write_text(json.dumps({
  'install': True, 'launch': True, 'freshInstall': True, 'reinstall': True, 'restart': True,
  'configurationFilesRetainedOnReinstall': True,
  'syntheticSettingsFixtureRetained': True,
  'secretServiceSandbox': True, 'secretServiceCrossProcessRestore': True,
  'secretServiceDaemonRestartRestore': True, 'secretServiceRetainedOnReinstall': True,
  'secretServiceAccountIsolation': True, 'secretServiceClear': True,
  'secretServiceDeniedWithoutFallback': True, 'syntheticMediaDecode': True,
  'syntheticMediaSoftwareRenderedPixels': True, 'syntheticMediaDecodedPcmBytes': True,
  'syntheticMediaAssTextDecoded': True, 'productSettingsUserInteraction': False,
  'environment': 'Isolated Ubuntu x86_64 account, real Flatpak sandbox, Xvfb and PulseAudio',
  'physicalDesktop': False, 'realAccountLogin': False, 'hardwareGpuAudio': False,
  'upgradeFromPreviousFlatpak': False,
}, indent=2) + '\n')
PY
