#!/bin/sh
set -e

# The optional write-only receiver runs on the private container network.
DIAGNOSTICS_ENDPOINT=${JMS_DIAGNOSTICS_ENDPOINT:-}
DIAGNOSTICS_UPSTREAM=${JMS_DIAGNOSTICS_UPSTREAM:-}
if [ -n "$DIAGNOSTICS_ENDPOINT" ]; then
    printf '%s' "$DIAGNOSTICS_ENDPOINT" | grep -Eq '^(/api/jms/diagnostics/v1|https://[A-Za-z0-9.-]+(:[0-9]+)?/api/jms/diagnostics/v1)$' || exit 1
fi
mkdir -p /etc/nginx/jms
: > /etc/nginx/jms/diagnostics.conf
if [ -n "$DIAGNOSTICS_UPSTREAM" ]; then
    printf '%s' "$DIAGNOSTICS_UPSTREAM" | grep -Eq '^http://[A-Za-z0-9_.-]+:[0-9]+$' || exit 1
    cat > /etc/nginx/jms/diagnostics.conf <<EOF
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
    proxy_pass $DIAGNOSTICS_UPSTREAM;
}
EOF
fi

# Generate config.json from environment variables
cat > /usr/share/nginx/html/assets/config/config.json <<EOF
{
  "baseUrl": "$BASE_URL",
  "seerrBaseUrl": "$SEERR_BASE_URL",
  "diagnosticsEndpoint": "$DIAGNOSTICS_ENDPOINT"
}
EOF

# Normalize FLADDER_WEBPATH (e.g. /fladder/)
WEBPATH=$(echo "${FLADDER_WEBPATH:-/}" | sed 's|^/*|/|; s|/*$|/|')

# Update base href in index.html (always at root of build/web)
if [ -f "/usr/share/nginx/html/index.html" ]; then
  sed -i "s|<base href=\"[^\"]*\">|<base href=\"$WEBPATH\">|g" /usr/share/nginx/html/index.html
fi

# Determine port (standard Nginx uses 80, rootless typically 8080)
if [ "$(id -u)" = "0" ]; then
    PORT=80
else
    PORT=8080
fi

if [ "$WEBPATH" = "/" ]; then
    echo "Configuring Fladder at root path"
    cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen $PORT;
    listen [::]:$PORT;
    server_name localhost;
    include /etc/nginx/jms/diagnostics.conf;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
else
    echo "Configuring Fladder on subpath: $WEBPATH"
    WEBPATH_NO_SLASH=$(echo "$WEBPATH" | sed 's|/*$||')
    
    cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen $PORT;
    listen [::]:$PORT;
    server_name localhost;
    include /etc/nginx/jms/diagnostics.conf;

    # Handle the subpath
    location $WEBPATH {
        alias /usr/share/nginx/html/;
        index index.html;
        try_files \$uri \$uri/ $WEBPATH/index.html;
    }

    # Redirect without trailing slash
    location = $WEBPATH_NO_SLASH {
        return 301 $WEBPATH;
    }

    # Fallback for root or other paths
    location / {
        return 404;
    }
}
EOF
fi

exec nginx -g "daemon off;"
