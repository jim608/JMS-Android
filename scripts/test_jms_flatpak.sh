#!/bin/bash
set -Eeuo pipefail
trap 'printf "Flatpak validation failed at line %s\n" "$LINENO" >&2' ERR
guard() {
  local label=$1
  shift
  if ! "$@"; then
    printf 'Flatpak validation guard failed: %s\n' "$label" >&2
    return 1
  fi
}
# Only a newly created CI account with a disposable keyring may run this test.
guard explicit-isolated-test test "${JMS_ISOLATED_FLATPAK_TEST:-}" = 1
guard nonroot-account test "$(id -u)" != 0
guard expected-account test "$(id -un)" = jms-flatpak-validation
guard isolated-home test "${HOME:-}" = /home/jms-flatpak-validation
guard bundle-variable test -n "${JMS_FLATPAK_BUNDLE:-}"
guard helpers-variable test -n "${JMS_FLATPAK_TEST_DIR:-}"
guard output-variable test -n "${JMS_FLATPAK_OUTPUT:-}"
app=com.jim608.jms
guard readable-bundle test -r "$JMS_FLATPAK_BUNDLE"
guard executable-secret-helper test -x "$JMS_FLATPAK_TEST_DIR/secret-test"
guard executable-media-helper test -x "$JMS_FLATPAK_TEST_DIR/media-test"
guard readable-synthetic-media test -r "$JMS_FLATPAK_TEST_DIR/synthetic.mkv"
# Do not inherit runner-image XDG paths into the disposable account's keyring.
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
# Establish the disposable account's runtime before GLib, D-Bus or portals start.
unset DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID DBUS_STARTER_ADDRESS DBUS_STARTER_BUS_TYPE
unset WAYLAND_DISPLAY SESSION_MANAGER
XDG_RUNTIME_DIR=$(mktemp -d /tmp/jms-flatpak-runtime.XXXXXX)
export XDG_RUNTIME_DIR
chmod 700 "$XDG_RUNTIME_DIR"
guard runtime-owner test "$(stat -c %u "$XDG_RUNTIME_DIR")" = "$(id -u)"
guard runtime-mode test "$(stat -c %a "$XDG_RUNTIME_DIR")" = 700
if flatpak --user info "$app" >/dev/null 2>&1 || test -e "$HOME/.var/app/$app"; then
  echo 'Fresh-install validation requires a new isolated account' >&2; exit 1
fi
mkdir -p "$JMS_FLATPAK_OUTPUT" "$HOME/.local/share"
echo 'Flatpak validation phase: install'
flatpak --user install --noninteractive --bundle "$JMS_FLATPAK_BUNDLE"
LC_ALL=C flatpak --user info "$app" > "$JMS_FLATPAK_OUTPUT/installed-info.txt"
deployment=$(flatpak --user info --show-location "$app")
commit=$(flatpak --user info --show-commit "$app")
printf '%s\n' "$deployment" > "$JMS_FLATPAK_OUTPUT/deployment-location.txt"
printf '%s\n' "$commit" > "$JMS_FLATPAK_OUTPUT/installed-commit.txt"
python3 - "$deployment/files/share/jms/JMS_BUILD_INFO.json" "$JMS_FLATPAK_OUTPUT/installed-info.txt" <<'PY_VERSION'
import json, pathlib, re, sys
build = json.loads(pathlib.Path(sys.argv[1]).read_text())
info = pathlib.Path(sys.argv[2]).read_text()
match = re.search(r'^\s*Version:\s*(\S+)\s*$', info, re.M)
if match is None or match[1] != build['versionName']:
    raise SystemExit('Installed AppStream version differs from native build identity')
PY_VERSION
flatpak --user info --show-permissions "$app" > "$JMS_FLATPAK_OUTPUT/permissions.txt"
# Save the actual exported launcher Steam selects, including Flatpak's rewrite.
deck_entry="$HOME/.local/share/flatpak/exports/share/applications/com.jim608.jms.SteamDeck.desktop"
test -f "$deck_entry"
cp -L "$deck_entry" "$JMS_FLATPAK_OUTPUT/steamdeck.desktop"
python3 - "$JMS_FLATPAK_OUTPUT/steamdeck.desktop" <<'PY_DESKTOP'
import configparser, shlex, sys
entry = configparser.ConfigParser(interpolation=None)
entry.read(sys.argv[1])
command = shlex.split(entry['Desktop Entry']['Exec'])
if '--handheld' not in command or 'com.jim608.jms' not in command:
    raise SystemExit('Exported Steam Deck launcher lacks application or handheld argument')
PY_DESKTOP
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
# Start X first so D-Bus-activated GTK portals inherit its display and authority.
xvfb-run -a dbus-run-session -- bash -euo pipefail <<'TEST_SESSION'
set -E
trap 'printf "Flatpak sandbox validation failed at line %s\n" "$LINENO" >&2' ERR
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
trap 'flatpak kill com.jim608.jms 2>/dev/null || true; pulseaudio --kill 2>/dev/null || true; pkill -u "$(id -u)" -x gnome-keyring-d 2>/dev/null || true' EXIT
printf '%s' fixture-keyring-passphrase | gnome-keyring-daemon --unlock --components=secrets >/dev/null
pulseaudio --start --exit-idle-time=-1
helper="$JMS_FLATPAK_TEST_DIR/secret-test"
echo 'Flatpak validation phase: secret-service'
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
echo 'Flatpak validation phase: media-decode'
timeout --kill-after=5s 30s flatpak --user run --filesystem="$JMS_FLATPAK_TEST_DIR:ro" --command="$JMS_FLATPAK_TEST_DIR/media-test" com.jim608.jms "$JMS_FLATPAK_TEST_DIR/synthetic.mkv" > "$JMS_FLATPAK_OUTPUT/media-test.log"
launch() {
  label=$1
  shift
  flatpak --user run com.jim608.jms "$@" > "$JMS_FLATPAK_OUTPUT/$label.log" 2>&1 &
  app_pid=$!
  found=false
  for attempt in $(seq 1 30); do
    kill -0 "$app_pid"
    xwininfo -root -tree > "$JMS_FLATPAK_OUTPUT/$label-windows.txt"
    if flatpak ps --columns=application | grep -Fxq com.jim608.jms &&
       python3 "$JMS_FLATPAK_TEST_DIR/jms_flatpak_window.py" "$JMS_FLATPAK_OUTPUT/$label-windows.txt" --output "$JMS_FLATPAK_OUTPUT/$label-window.json"; then
      found=true; break
    fi
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
echo 'Flatpak validation phase: product-launch'
launch first-launch --handheld
# Preserve all product-created settings and a known file during reinstall.
app_data="$HOME/.var/app/com.jim608.jms"
mkdir -p "$app_data/config" "$app_data/data"
settings="$app_data/config/jms-flatpak-validation.json"
printf '%s\n' '{"fixture":"retained-local-setting","themeMode":"dark"}' > "$settings"
sha256sum "$settings" > "$JMS_FLATPAK_OUTPUT/settings-before.txt"
find "$app_data/config" "$app_data/data" -type f -print0 | sort -z | xargs -0 -r sha256sum > "$JMS_FLATPAK_OUTPUT/config-before.txt"
# Flatpak 1.14 refuses an identical already-installed bundle even with --reinstall.
# Exercise an actual remove/install cycle without --delete-data instead of accepting
# that error or pretending it is an upgrade from a previous published Flatpak.
echo 'Flatpak validation phase: uninstall-retains-data'
flatpak --user uninstall --noninteractive --keep-ref app/com.jim608.jms/x86_64/stable
if flatpak --user info com.jim608.jms >/dev/null 2>&1; then
  echo 'Flatpak application still installed after uninstall' >&2; exit 1
fi
sha256sum --check "$JMS_FLATPAK_OUTPUT/config-before.txt"
echo 'Flatpak validation phase: reinstall-retention'
flatpak --user install --noninteractive --bundle "$JMS_FLATPAK_BUNDLE"
sha256sum --check "$JMS_FLATPAK_OUTPUT/config-before.txt"
sha256sum "$settings" > "$JMS_FLATPAK_OUTPUT/settings-after.txt"
cmp "$JMS_FLATPAK_OUTPUT/settings-before.txt" "$JMS_FLATPAK_OUTPUT/settings-after.txt"
test "$(flatpak --user info --show-commit com.jim608.jms)" = "$(cat "$JMS_FLATPAK_OUTPUT/installed-commit.txt")"
flatpak --user info --show-location com.jim608.jms > "$JMS_FLATPAK_OUTPUT/deployment-location.txt"
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
  'uninstallRemovesApplication': True, 'uninstallRetainsDataWithoutDeleteData': True,
  'reinstallAfterUninstall': True,
  'secretServiceSandbox': True, 'secretServiceCrossProcessRestore': True,
  'secretServiceDaemonRestartRestore': True, 'secretServiceRetainedOnReinstall': True,
  'secretServiceAccountIsolation': True, 'secretServiceClear': True,
  'secretServiceDeniedWithoutFallback': True, 'syntheticMediaDecode': True,
  'syntheticMediaSoftwareRenderedPixels': True, 'syntheticMediaDecodedPcmBytes': True,
  'syntheticMediaAssTextDecoded': True, 'productSettingsUserInteraction': False,
  'environment': 'Isolated Ubuntu x86_64 account, real Flatpak sandbox, Xvfb and PulseAudio',
  'physicalDesktop': False, 'realAccountLogin': False, 'hardwareGpuAudio': False,
  'upgradeFromPreviousFlatpak': False,
  'exportedSteamDeckLauncherHandheldArgument': True, 'firstLaunchArguments': ['--handheld'],
}, indent=2) + '\n')
PY
