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

config_file=/usr/share/nginx/html/assets/config/config.json
config_temp=$(mktemp /tmp/jms-config.XXXXXX)
jq -n --arg baseUrl "${BASE_URL:-}" --arg seerrBaseUrl "${SEERR_BASE_URL:-}" \
  '{baseUrl: (if $baseUrl == "" then null else $baseUrl end), seerrBaseUrl: (if $seerrBaseUrl == "" then null else $seerrBaseUrl end)}' \
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
