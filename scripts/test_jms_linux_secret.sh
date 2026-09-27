#!/bin/bash
set -euo pipefail
# Run only in an isolated test account/container, never against a user's keyring.
test "${JMS_ISOLATED_SECRET_TEST:-}" = 1
export HOME=/tmp/jms-secret-test
mkdir -p "$HOME" /tmp/jms-runtime
chmod 700 "$HOME" /tmp/jms-runtime
export XDG_RUNTIME_DIR=/tmp/jms-runtime
clang++ -std=c++14 -Wall -Wextra -Werror -I/src/linux /src/linux/seerr_secret_store.cc \
  /src/test/native/linux_seerr_secret_test.cc $(pkg-config --cflags --libs libsecret-1) -o /tmp/jms-secret-test-bin
/tmp/jms-secret-test-bin invalid
DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/no-jms-bus /tmp/jms-secret-test-bin unavailable
dbus-run-session -- bash -euo pipefail -c '
  printf "%s" "fixture-keyring-passphrase" | gnome-keyring-daemon --unlock --components=secrets >/dev/null
  /tmp/jms-secret-test-bin write
  /tmp/jms-secret-test-bin read
  /tmp/jms-secret-test-bin isolated
  if grep -RaFq fixture-session-only "$HOME/.local/share/keyrings"; then
    echo "Unexpected plaintext before logout" >&2
    exit 1
  fi
  before=$(pgrep -u "$(id -u)" -x gnome-keyring-d | sort)
  test -n "$before"
  pkill -u "$(id -u)" -x gnome-keyring-d || true
  sleep 1
  printf "%s" "fixture-keyring-passphrase" | gnome-keyring-daemon --unlock --components=secrets >/dev/null
  /tmp/jms-secret-test-bin read
  after=$(pgrep -u "$(id -u)" -x gnome-keyring-d | sort)
  test -n "$after"
  test "$before" != "$after"
  if grep -RaFq fixture-session-only "$HOME/.local/share/keyrings"; then
    echo "Unexpected plaintext after restart" >&2
    exit 1
  fi
  /tmp/jms-secret-test-bin clear
  /tmp/jms-secret-test-bin empty
  /tmp/jms-secret-test-bin clear
'
if grep -RaFq fixture-session-only "$HOME/.local/share/keyrings"; then
  echo 'Unexpected plaintext session in keyring files' >&2
  exit 1
fi
echo 'Secret Service cross-process restore, daemon restart, isolation, clear and unavailable-service checks passed'
