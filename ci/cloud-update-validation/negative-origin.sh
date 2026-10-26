#!/bin/bash
# Public-only trust negatives. New local OSTree repos; no private GPG home.
set -Eeuo pipefail
export LC_ALL=C
test "${JMS_ISOLATED_UPDATE_TEST:-}" = 1
test "$(id -u)" != 0
case "$(id -un)" in jms-flatpak-cloud-*) ;; *) exit 2 ;; esac
test "${HOME:-}" = "/home/$(id -un)"
: "${JMS_INPUT_DIR:?}" "${JMS_OUTPUT_DIR:?}" "${JMS_TARGET_COMMIT:?}"
: "${JMS_PUBLIC_KEY_SHA256:?}" "${JMS_WRONG_PUBLIC_KEY_SHA256:?}"
: "${JMS_SUMMARY_SHA256:?}" "${JMS_SUMMARY_SIG_SHA256:?}"
test -d "$JMS_OUTPUT_DIR"
test -z "$(find "$JMS_OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)"
[[ "$JMS_TARGET_COMMIT" =~ ^[a-f0-9]{64}$ ]]
[[ "$JMS_PUBLIC_KEY_SHA256" =~ ^[a-f0-9]{64}$ ]]
[[ "$JMS_WRONG_PUBLIC_KEY_SHA256" =~ ^[a-f0-9]{64}$ ]]
[[ "$JMS_SUMMARY_SHA256" =~ ^[a-f0-9]{64}$ ]]
[[ "$JMS_SUMMARY_SIG_SHA256" =~ ^[a-f0-9]{64}$ ]]
test "$JMS_PUBLIC_KEY_SHA256" != "$JMS_WRONG_PUBLIC_KEY_SHA256"
test "$(sha256sum "$JMS_INPUT_DIR/jms-release.gpg" | cut -d' ' -f1)" = "$JMS_PUBLIC_KEY_SHA256"
test "$(sha256sum "$JMS_INPUT_DIR/wrong-public-key.gpg" | cut -d' ' -f1)" = "$JMS_WRONG_PUBLIC_KEY_SHA256"
origin=https://jim608.github.io/JMS-Linux/flatpak/repo/
ref=app/com.jim608.jms/x86_64/stable
for name in positive wrong-key tampered-source tampered-verifier; do test ! -e "$JMS_OUTPUT_DIR/$name"; done
add_remote() {
  ostree --repo="$1" init --mode=archive
  ostree --repo="$1" remote add --set=gpg-verify=true --set=gpg-verify-summary=true --gpg-import="$2" test-origin "$3"
}
pull() { ostree --repo="$1" pull --untrusted --disable-static-deltas test-origin "$ref"; }
add_remote "$JMS_OUTPUT_DIR/positive" "$JMS_INPUT_DIR/jms-release.gpg" "$origin"
pull "$JMS_OUTPUT_DIR/positive" > "$JMS_OUTPUT_DIR/positive.log" 2>&1
test "$(ostree --repo="$JMS_OUTPUT_DIR/positive" rev-parse "test-origin:$ref")" = "$JMS_TARGET_COMMIT"
add_remote "$JMS_OUTPUT_DIR/wrong-key" "$JMS_INPUT_DIR/wrong-public-key.gpg" "$origin"
if pull "$JMS_OUTPUT_DIR/wrong-key" > "$JMS_OUTPUT_DIR/wrong-key.log" 2>&1; then exit 1; fi
grep -Eiq 'GPG signatures found, but none are in trusted keyring|public key not found|No public key|NO_PUBKEY' "$JMS_OUTPUT_DIR/wrong-key.log"
if ostree --repo="$JMS_OUTPUT_DIR/wrong-key" rev-parse "test-origin:$ref" >/dev/null 2>&1; then exit 1; fi
ostree --repo="$JMS_OUTPUT_DIR/tampered-source" init --mode=archive
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --max-time 60 "${origin}summary" -o "$JMS_OUTPUT_DIR/tampered-source/summary"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --max-time 60 "${origin}summary.sig" -o "$JMS_OUTPUT_DIR/tampered-source/summary.sig"
test "$(sha256sum "$JMS_OUTPUT_DIR/tampered-source/summary" | cut -d' ' -f1)" = "$JMS_SUMMARY_SHA256"
test "$(sha256sum "$JMS_OUTPUT_DIR/tampered-source/summary.sig" | cut -d' ' -f1)" = "$JMS_SUMMARY_SIG_SHA256"
printf '\000' >> "$JMS_OUTPUT_DIR/tampered-source/summary"
add_remote "$JMS_OUTPUT_DIR/tampered-verifier" "$JMS_INPUT_DIR/jms-release.gpg" "file://$(realpath "$JMS_OUTPUT_DIR/tampered-source")"
if pull "$JMS_OUTPUT_DIR/tampered-verifier" > "$JMS_OUTPUT_DIR/tampered-summary.log" 2>&1; then exit 1; fi
grep -Eiq 'BAD signature|Bad signature|GPG signatures found, but none are in trusted keyring|GPG verification failed|Signature verification failed' "$JMS_OUTPUT_DIR/tampered-summary.log"
if ostree --repo="$JMS_OUTPUT_DIR/tampered-verifier" rev-parse "test-origin:$ref" >/dev/null 2>&1; then exit 1; fi
printf '%s\n' '{"wrongPublicKeyRejected":true,"tamperedSummaryRejected":true,"targetRefNotAcceptedByNegatives":true}' > "$JMS_OUTPUT_DIR/negative-result.json"
