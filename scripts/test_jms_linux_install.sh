#!/bin/bash
set -euo pipefail
test "${JMS_ISOLATED_INSTALL_TEST:-}" = 1
test "$(id -u)" = 0
test -d /candidate
pacman -Syu --noconfirm --needed gtk3 mpv alsa-lib sqlite polkit libarchive xdg-user-dirs libsecret gnome-keyring xorg-server-xvfb xorg-xauth xorg-xwininfo dbus procps-ng pulseaudio python networkmanager
useradd -m jms-test
mkdir -p /output /run/dbus
systemd-sysusers
dbus-uuidgen --ensure
dbus-daemon --system --fork
NetworkManager --no-daemon >/output/network-manager.log 2>&1 &

launch() {
  local executable=$1 label=$2
  local result=0
  runuser -u jms-test -- env JMS_EXECUTABLE="$executable" dbus-run-session -- xvfb-run -a bash -ec '
    pulseaudio --start --exit-idle-time=-1
    "$JMS_EXECUTABLE" > /tmp/jms-launch.log 2>&1 &
    app_pid=$!
    trap "kill $app_pid 2>/dev/null || true" EXIT
    sleep 15
    kill -0 "$app_pid"
    xwininfo -root -tree | grep -i JMS
    if grep -E "Unhandled Exception|MissingPluginException|error while loading shared libraries" /tmp/jms-launch.log; then exit 1; fi
    kill "$app_pid"
    wait "$app_pid" || test "$?" = 143
  ' >"/output/$label-window.log" 2>&1 || result=$?
  if test -f /tmp/jms-launch.log; then cp /tmp/jms-launch.log "/output/$label-launch.log"; fi
  test "$result" = 0
}

pacman -U --noconfirm /candidate/previous.pkg.tar.xz
launch /opt/jms/jms previous
python - <<'PY'
import json, pathlib, pwd
files=list(pathlib.Path(pwd.getpwnam('jms-test').pw_dir).rglob('shared_preferences.json'))
assert len(files)==1, 'One isolated preferences store required'
p=files[0]; values=json.loads(p.read_text())
key=next(k for k in values if k.endswith('clientSettings'))
settings=json.loads(values[key]); settings.update(themeMode='dark',checkForUpdates=False)
values[key]=json.dumps(settings); p.write_text(json.dumps(values))
pathlib.Path('/output/preferences-location.txt').write_text(str(p))
PY
pacman -U --noconfirm /candidate/JMS-Linux-*-x86_64.pkg.tar.xz
pacman -Q jms > /output/package-version.txt
test -x /usr/bin/jms
test -f /usr/share/applications/com.jim608.jms.desktop
test -f /usr/share/icons/hicolor/512x512/apps/com.jim608.jms.png
ldd /opt/jms/jms /opt/jms/lib/*.so > /output/dependencies.txt
! grep 'not found' /output/dependencies.txt
launch /opt/jms/jms upgraded
mkdir /portable
tar -xzf /candidate/JMS-Linux-*-x64.tar.gz -C /portable
launch /portable/JMS/jms portable
python - <<'PY'
import json,pathlib
p=pathlib.Path(pathlib.Path('/output/preferences-location.txt').read_text())
values=json.loads(p.read_text()); key=next(k for k in values if k.endswith('clientSettings'))
settings=json.loads(values[key]); assert settings['themeMode']=='dark' and settings['checkForUpdates'] is False
pathlib.Path('/output/validation.json').write_text(json.dumps({'launch':True,'portableLaunch':True,'upgrade':True,'settingsRetained':['themeMode','checkForUpdates'],'environment':'Isolated Arch x86_64, Xvfb, PulseAudio and system/session D-Bus','physicalDesktop':False},indent=2))
PY
