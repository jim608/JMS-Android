#!/bin/bash
set -Eeuo pipefail
jms_stage=bootstrap
jms_mode=bootstrap
jms_failure_line=0
jms_output_ready=0
jms_set_stage() {
  jms_stage=$1
  if test "$jms_output_ready" = 1; then
    printf '{"mode":"%s","stage":"%s"}\n' "$jms_mode" "$jms_stage" > "$JMS_OUTPUT_DIR/portal-stage.json" || :
  fi
}
jms_on_exit() {
  local status=$1 line=$2
  trap - ERR EXIT
  if test "$status" != 0; then
    if test "$jms_failure_line" != 0; then line=$jms_failure_line; fi
    local payload
    printf -v payload '{"mode":"%s","stage":"%s","line":%s,"exitCode":%s}' "$jms_mode" "$jms_stage" "$line" "$status"
    printf 'JMS_PORTAL_DIAGNOSTIC %s\n' "$payload" >&2 || :
    if test "$jms_output_ready" = 1; then printf '%s\n' "$payload" > "$JMS_OUTPUT_DIR/portal-failure.json" || :; fi
  fi
  exit "$status"
}
trap 'jms_failure_line=$LINENO' ERR
trap 'jms_on_exit "$?" "$LINENO"' EXIT
jms_set_stage guard-isolation
test "${JMS_ISOLATED_UPDATE_TEST:-}" = 1
jms_set_stage guard-account
case "$(id -un)" in jms-flatpak-cloud-*) ;; *) exit 2 ;; esac
test "$(id -u)" != 0
jms_set_stage guard-mode
test "$#" = 1
case "$1" in signed-update|unsigned-migration) action=update; consent=yes ;;
  denied-update) action=deny; consent=no ;; *) exit 2 ;; esac
jms_mode=$1
jms_output_ready=1
jms_set_stage activation-environment
dbus-update-activation-environment DISPLAY XAUTHORITY XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
# This is a synthetic PermissionStore fixture in a new CI account. It does NOT
# validate a person's AccessDialog consent UI, and is never a host-user setting.
jms_set_stage consent-fixture
flatpak permission-set flatpak updates com.jim608.jms "$consent"
jms_set_stage probe-run
timeout --kill-after=5s 930s flatpak --user run \
  --filesystem="$JMS_INPUT_DIR:ro" --command="$JMS_INPUT_DIR/portal-probe" \
  app/com.jim608.jms/x86_64/stable "$action" "$JMS_BASELINE_COMMIT" "$JMS_TARGET_COMMIT" \
  "${JMS_PORTAL_TIMEOUT_SECONDS:-600}" > "$JMS_OUTPUT_DIR/portal.jsonl"
