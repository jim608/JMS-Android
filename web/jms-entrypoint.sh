#!/bin/sh
set -eu

webpath="${JMS_WEBPATH:-${FLADDER_WEBPATH:-/}}"
case "$webpath" in
  /|/*/) ;;
  *) echo "JMS_WEBPATH must begin and end with /" >&2; exit 1 ;;
esac
if printf '%s' "$webpath" | grep -Eq '[^A-Za-z0-9/_-]'; then
  echo "JMS_WEBPATH contains unsupported characters" >&2
  exit 1
fi

for url in "${BASE_URL:-}" "${SEERR_BASE_URL:-}"; do
  [ -z "$url" ] && continue
  if ! printf '%s' "$url" | grep -Eq '^https?://[^[:space:]]+$'; then
    echo "Service URL must be an HTTP(S) base URL" >&2
    exit 1
  fi
  case "$url" in
    *@*|*\?*|*\#*) echo "Service URL cannot contain credentials, query, or fragment" >&2; exit 1 ;;
  esac
done

# Entry configuration remains a host-managed, read-only mount. Never copy it
# into Flutter assets or the image; an absent configuration returns JSON 404.
entry_config=/run/jms-private/jms-config.json
if [ -e "$entry_config" ]; then
  test -r "$entry_config" || { echo "Entry configuration is not readable" >&2; exit 1; }
  jq -e 'type == "object" and
    ((keys - ["baseUrl", "seerrBaseUrl", "diagnosticsEndpoint"]) | length == 0) and
    (.baseUrl | type == "string" and length > 0) and
    (.seerrBaseUrl == null or (.seerrBaseUrl | type == "string")) and
    (.diagnosticsEndpoint == null or (.diagnosticsEndpoint | type == "string"))' \
    "$entry_config" >/dev/null || { echo "Entry configuration is invalid" >&2; exit 1; }
  for key in baseUrl seerrBaseUrl diagnosticsEndpoint; do
    url=$(jq -r --arg key "$key" '.[$key] // ""' "$entry_config")
    [ -z "$url" ] && continue
    printf '%s' "$url" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]]*)?$' || exit 1
    case "$url" in
      *@*|*\?*|*\#*) echo "Entry service URL is invalid" >&2; exit 1 ;;
    esac
    if [ "$key" = diagnosticsEndpoint ]; then
      printf '%s' "$url" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?/api/jms/diagnostics/v1$' || exit 1
    fi
  done
fi
sed "s|location = /jms-config.json {|location = ${webpath}jms-config.json {|" \
  /etc/nginx/jms-entry-config.template > /tmp/jms-entry-config.conf

diagnostics_endpoint="${JMS_DIAGNOSTICS_ENDPOINT:-}"
diagnostics_upstream="${JMS_DIAGNOSTICS_UPSTREAM:-}"
if [ -n "$diagnostics_endpoint" ]; then
  printf '%s' "$diagnostics_endpoint" | grep -Eq '^(/api/jms/diagnostics/v1|https://[A-Za-z0-9.-]+(:[0-9]+)?/api/jms/diagnostics/v1)$' || exit 1
fi
: > /tmp/jms-diagnostics.conf
if [ -n "$diagnostics_upstream" ]; then
  printf '%s' "$diagnostics_upstream" | grep -Eq '^http://[A-Za-z0-9_.-]+:[0-9]+$' || exit 1
  cat > /tmp/jms-diagnostics.conf <<EOF
location = /api/jms/diagnostics/v1 {
    if (\$request_method != POST) { return 405; }
    client_max_body_size 4k;
    client_body_timeout 3s;
    access_log off;
    error_log /dev/null;
    proxy_connect_timeout 2s;
    proxy_read_timeout 5s;
    proxy_send_timeout 5s;
    proxy_set_header Authorization "";
    proxy_set_header Cookie "";
    proxy_set_header X-Forwarded-For "";
    proxy_set_header X-Real-IP "";
    proxy_pass $diagnostics_upstream;
}
EOF
fi

config_file=/usr/share/nginx/html/assets/config/config.json
config_temp=$(mktemp /tmp/jms-config.XXXXXX)
jq -n --arg baseUrl "${BASE_URL:-}" --arg seerrBaseUrl "${SEERR_BASE_URL:-}" \
  --arg diagnosticsEndpoint "$diagnostics_endpoint" \
  '{baseUrl: (if $baseUrl == "" then null else $baseUrl end), seerrBaseUrl: (if $seerrBaseUrl == "" then null else $seerrBaseUrl end), diagnosticsEndpoint: (if $diagnosticsEndpoint == "" then null else $diagnosticsEndpoint end)}' \
  > "$config_temp"
mv "$config_temp" "$config_file"

sed -i "s|<base href=\"[^\"]*\">|<base href=\"$webpath\">|" /usr/share/nginx/html/index.html

if [ "$webpath" = / ]; then
  redirect=''
else
  no_slash="${webpath%/}"
  redirect="location = $no_slash { return 301 $webpath; } location / { return 404; }"
fi

cat > /tmp/jms.conf <<EOF
server {
    listen 8080;
    listen [::]:8080;
    server_name _;
    include /tmp/jms-diagnostics.conf;
    include /tmp/jms-entry-config.conf;
    root /usr/share/nginx/html;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;

    location = /healthz {
        default_type text/plain;
        return 200 'ok';
    }
    location = ${webpath}assets/config/config.json {
        alias /usr/share/nginx/html/assets/config/config.json;
        add_header Cache-Control 'no-store' always;
    }
    location = ${webpath}index.html {
        alias /usr/share/nginx/html/index.html;
        add_header Cache-Control 'no-store' always;
    }
    location = ${webpath}main.dart.js {
        alias /usr/share/nginx/html/main.dart.js;
        add_header Cache-Control 'no-store' always;
    }
    location = ${webpath}flutter_bootstrap.js {
        alias /usr/share/nginx/html/flutter_bootstrap.js;
        add_header Cache-Control 'no-store' always;
    }
    location ^~ $webpath {
        alias /usr/share/nginx/html/;
        try_files \$uri \$uri/ ${webpath}index.html;
        expires 1h;
    }
    $redirect
}
EOF

nginx -t
exec nginx -g 'daemon off;'
