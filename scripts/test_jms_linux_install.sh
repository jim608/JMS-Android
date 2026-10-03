#!/bin/bash
set -euo pipefail
test "${JMS_ISOLATED_INSTALL_TEST:-}" = 1
test "$(id -u)" = 0
test -d /candidate
pacman -Syu --noconfirm --needed base-devel git gtk3 mpv alsa-lib sqlite polkit libarchive xdg-user-dirs libsecret gnome-keyring xorg-server-xvfb xorg-xauth xorg-xwininfo dbus procps-ng pulseaudio python networkmanager
useradd -m jms-test
mkdir -p /output /run/dbus
python - <<'PY'
import hashlib,json,pathlib,tarfile,urllib.request
tag='v13.0.1'
name='yay_13.0.1_x86_64.tar.gz'
expected='1fdfcb5f7f387bc858d3a5754bdf4e4575bfbddac9560535a716d0ed7189c057'
with urllib.request.urlopen(f'https://github.com/Jguer/yay/releases/download/{tag}/{name}',timeout=30) as response:
    data=response.read(5*1024*1024+1)
assert len(data)<=5*1024*1024 and hashlib.sha256(data).hexdigest()==expected, 'Fixed yay source differs'
archive=pathlib.Path('/tmp/yay-fixed.tar.gz'); archive.write_bytes(data)
with tarfile.open(archive) as source:
    member=source.getmember('yay_13.0.1_x86_64/yay')
    assert member.isfile() and member.size<=16*1024*1024
    binary=source.extractfile(member).read()
destination=pathlib.Path('/usr/local/bin/yay'); destination.write_bytes(binary); destination.chmod(0o755)
pathlib.Path('/output/yay-tool-verification.json').write_text(json.dumps({'officialRelease':f'https://github.com/Jguer/yay/releases/tag/{tag}','archiveSha256':expected,'binarySha256':hashlib.sha256(binary).hexdigest(),'platform':'x86_64'},indent=2))
PY
yay --version > /output/yay-version.txt
# Only the isolated test user receives pacman access inside this disposable container.
printf 'jms-test ALL=(root) NOPASSWD: /usr/bin/pacman\n' > /etc/sudoers.d/jms-isolated-test
chmod 0440 /etc/sudoers.d/jms-isolated-test
visudo -cf /etc/sudoers.d/jms-isolated-test
systemd-sysusers
dbus-uuidgen --ensure
dbus-daemon --system --fork
NetworkManager --no-daemon >/output/network-manager.log 2>&1 &

launch() {
  local executable=$1 label=$2
  local account=${3:-jms-test}
  local launch_log="/tmp/jms-$account-$label-launch.log"
  local result=0
  runuser -u "$account" -- env JMS_EXECUTABLE="$executable" JMS_LAUNCH_LOG="$launch_log" dbus-run-session -- xvfb-run -a bash -ec '
    pulseaudio --start --exit-idle-time=-1
    "$JMS_EXECUTABLE" > "$JMS_LAUNCH_LOG" 2>&1 &
    app_pid=$!
    trap "kill $app_pid 2>/dev/null || true" EXIT
    sleep 15
    kill -0 "$app_pid"
    xwininfo -root -tree | grep -i JMS
    if grep -E "Unhandled Exception|MissingPluginException|error while loading shared libraries" "$JMS_LAUNCH_LOG"; then exit 1; fi
    kill "$app_pid"
    wait "$app_pid" || test "$?" = 143
  ' >"/output/$label-window.log" 2>&1 || result=$?
  if test -f "$launch_log"; then cp "$launch_log" "/output/$label-launch.log"; fi
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
bsdtar -xOf /candidate/JMS-Linux-*-x86_64.pkg.tar.xz .PKGINFO | grep -Fx 'depend = networkmanager'
test -x /usr/bin/jms
test -f /usr/share/applications/com.jim608.jms.desktop
test -f /usr/share/icons/hicolor/512x512/apps/com.jim608.jms.png
readelf -d /opt/jms/jms > /output/loader-dynamic.txt
python - <<'PY'
# JMS_LOADER_POLICY_BEGIN
import json,pathlib,re

def verified_loader_directory(description):
    paths=re.findall(r'\((?:RUNPATH|RPATH)\).*?\[([^\]]+)\]',description)
    needed=re.findall(r'\(NEEDED\).*?\[([^\]]+)\]',description)
    if paths!=['$ORIGIN/lib'] or 'libflutter_linux_gtk.so' not in needed:
        raise ValueError('Expected executable loader context missing')
    return '/opt/jms/lib'

if __name__=='__main__':
    directory=verified_loader_directory(pathlib.Path('/output/loader-dynamic.txt').read_text())
    pathlib.Path('/output/loader-validation.json').write_text(json.dumps({'executableRpath':'$ORIGIN/lib','standalonePluginLookup':directory,'flutterPreloadedByExecutable':True,'runtimeEnvironmentModified':False},indent=2))
# JMS_LOADER_POLICY_END
PY
ldd /opt/jms/jms > /output/dependencies.txt
if grep 'not found' /output/dependencies.txt; then exit 1; fi
# Standalone plugin checks use the directory proven by the executable's own loader context.
# Application launches below retain their normal environment and executable RPATH.
LD_LIBRARY_PATH=/opt/jms/lib ldd /opt/jms/lib/*.so >> /output/dependencies.txt
if grep 'not found' /output/dependencies.txt; then exit 1; fi
launch /opt/jms/jms upgraded
mkdir /portable
tar -xzf /candidate/JMS-Linux-*-x64.tar.gz -C /portable
launch /portable/JMS/jms portable

# 本機配方來源使用已校驗的同版候選，不要求尚未公開的 Release 可下載。
recipe_archives=(/candidate/JMS-Linux-*-jms-bin-aur.tar.gz)
test "${#recipe_archives[@]}" = 1
test -f "${recipe_archives[0]}"
mkdir /aur
tar -xzf "${recipe_archives[0]}" -C /aur
cp /candidate/JMS-Linux-*-x86_64.pkg.tar.xz /aur/jms-bin/
chown -R jms-test:jms-test /aur
runuser -u jms-test -- bash -ec '
  cd /aur/jms-bin
  git init --initial-branch=jms-local
  git add -- PKGBUILD .SRCINFO README.zh-Hant.md
  git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" commit -m "chore(package): 核對 JMS 本機配方"
  git branch jms-local-source
  git branch --set-upstream-to=jms-local-source jms-local
  git rev-parse HEAD > /tmp/jms-local-recipe-commit.txt
  test -z "$(git remote)"
  makepkg --printsrcinfo > .SRCINFO.generated
  diff -u .SRCINFO .SRCINFO.generated
  makepkg --verifysource --noconfirm
  makepkg --noconfirm --log
' > /output/aur-makepkg.log 2>&1
cp /tmp/jms-local-recipe-commit.txt /output/aur-local-recipe-commit.txt
aur_packages=(/aur/jms-bin/jms-bin-*-x86_64.pkg.tar.zst)
test "${#aur_packages[@]}" = 1
test -f "${aur_packages[0]}"
mkdir /aur-payload
bsdtar -xf "${aur_packages[0]}" -C /aur-payload
python - <<'PY'
import hashlib,json,pathlib,tarfile
candidate=list(pathlib.Path('/candidate').glob('JMS-Linux-*-x86_64.pkg.tar.xz'))
assert len(candidate)==1
files=symlinks=0
with tarfile.open(candidate[0],'r:xz') as source:
    for member in source:
        if not member.name.startswith(('opt/','usr/')): continue
        installed=pathlib.Path('/aur-payload')/member.name
        if member.isfile():
            assert installed.is_file() and not installed.is_symlink(), 'AUR payload type differs'
            assert hashlib.sha256(installed.read_bytes()).digest()==hashlib.sha256(source.extractfile(member).read()).digest(), 'AUR payload bytes differ'
            files+=1
        elif member.issym():
            assert installed.is_symlink() and str(installed.readlink())==member.linkname, 'AUR shortcut differs'
            symlinks+=1
assert files>0 and symlinks>0
pathlib.Path('/output/aur-payload-validation.json').write_text(json.dumps({'identicalPayloadFiles':files,'identicalSymlinks':symlinks,'appBinaryChanged':False},indent=2))
PY
# 只在隔離容器明確同意互斥套件轉換；正式安裝由使用者確認。
printf 'y\ny\n' | runuser -u jms-test -- bash -ec 'cd /aur; yay -Bi ./jms-bin --mflags "--force" --cleanmenu=false --diffmenu=false' > /output/aur-yay-install.log 2>&1
pacman -Q jms-bin > /output/aur-package-version.txt
pacman -Qq > /output/aur-installed-packages.txt
test -s /output/aur-installed-packages.txt
if grep -Fxq jms /output/aur-installed-packages.txt; then
  echo 'Official JMS package remains installed after the community package transition.' >&2
  exit 1
fi
cmp /aur-payload/opt/jms/jms /opt/jms/jms
launch /opt/jms/jms aur
printf 'y\ny\n' | pacman -U -- /candidate/JMS-Linux-*-x86_64.pkg.tar.xz
pacman -Q jms > /output/restored-official-package-version.txt
pacman -Qq > /output/restored-official-installed-packages.txt
test -s /output/restored-official-installed-packages.txt
if grep -Fxq jms-bin /output/restored-official-installed-packages.txt; then
  echo 'Community JMS package remains installed after the official package transition.' >&2
  exit 1
fi
launch /opt/jms/jms restored-official
useradd -m jms-fresh
python - <<'PY'
import pathlib,pwd
home=pathlib.Path(pwd.getpwnam('jms-fresh').pw_dir)
assert not list(home.rglob('shared_preferences.json')), 'Fresh isolated user must have no saved application profile'
PY
pacman -R --noconfirm jms
test ! -e /opt/jms/jms
pacman -U --noconfirm /candidate/JMS-Linux-*-x86_64.pkg.tar.xz
launch /opt/jms/jms fresh jms-fresh
python - <<'PY'
import json,pathlib,pwd
p=pathlib.Path(pathlib.Path('/output/preferences-location.txt').read_text())
values=json.loads(p.read_text()); key=next(k for k in values if k.endswith('clientSettings'))
settings=json.loads(values[key]); assert settings['themeMode']=='dark' and settings['checkForUpdates'] is False
fresh=list(pathlib.Path(pwd.getpwnam('jms-fresh').pw_dir).rglob('shared_preferences.json'))
assert len(fresh)==1 and fresh[0]!=p, 'Fresh install must create its own isolated profile'
pathlib.Path('/output/validation.json').write_text(json.dumps({'launch':True,'portableLaunch':True,'upgrade':True,'freshInstall':True,'aurLocalMakepkg':True,'yayLocalRecipeInstall':True,'aurMetadataMatches':True,'officialAurRoundtrip':True,'settingsRetained':['themeMode','checkForUpdates'],'environment':'Isolated Arch x86_64, Xvfb, PulseAudio and system/session D-Bus','physicalDesktop':False,'aurPublic':False,'polkitInteractive':False},indent=2))
PY
