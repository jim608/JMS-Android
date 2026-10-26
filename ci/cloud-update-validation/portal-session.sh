#!/bin/bash
set -Eeuo pipefail
test "${JMS_ISOLATED_UPDATE_TEST:-}" = 1
case "$(id -un)" in jms-flatpak-cloud-*) ;; *) exit 2 ;; esac
test "$(id -u)" != 0
test "$#" = 1
case "$1" in signed-update|unsigned-migration) action=update; consent=yes ;;
  denied-update) action=deny; consent=no ;; *) exit 2 ;; esac
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
# This is a synthetic PermissionStore fixture in a new CI account. It does NOT
# validate a person's AccessDialog consent UI, and is never a host-user setting.
flatpak permission-set flatpak updates com.jim608.jms "$consent"
timeout --kill-after=5s 930s flatpak --user run \
  --filesystem="$JMS_INPUT_DIR:ro" --command="$JMS_INPUT_DIR/portal-probe" \
  app/com.jim608.jms/x86_64/stable "$action" "$JMS_BASELINE_COMMIT" "$JMS_TARGET_COMMIT" \
  "${JMS_PORTAL_TIMEOUT_SECONDS:-600}" > "$JMS_OUTPUT_DIR/portal.jsonl"
