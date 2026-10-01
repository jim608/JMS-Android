#!/bin/bash
set -euo pipefail
test "${JMS_ISOLATED_DIAGNOSTICS_TEST:-}" = 1
test -f build/web/index.html
test -n "${JMS_DIAGNOSTICS_WEB_IMAGE:-}"

prefix="jms-diag-smoke-$$"
containers=()
cleanup() {
  local result=$?
  if test "$result" != 0; then
    for container in "${containers[@]}"; do docker logs "$container" --tail 20 || true; done
  fi
  if test "${#containers[@]}" != 0; then docker rm -f "${containers[@]}" >/dev/null || true; fi
  docker network rm "$prefix" >/dev/null || true
  exit "$result"
}
trap cleanup EXIT

docker build -f Dockerfile.diagnostics -t "$prefix-receiver" .
docker build -f Dockerfile -t "$prefix-root" .
docker build -f Dockerfile-rootless -t "$prefix-rootless" .
docker network create "$prefix" >/dev/null
receiver=$(docker run -d --network "$prefix" --network-alias jms-diagnostics "$prefix-receiver")
containers+=("$receiver")
docker exec -i "$receiver" python - <<'PY'
import time, urllib.error, urllib.request
for attempt in range(30):
    try:
        assert urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status == 204
        break
    except (OSError, urllib.error.URLError):
        time.sleep(1)
else:
    raise SystemExit('Isolated receiver did not become ready')
PY

for runtime in root rootless production; do
  image="$prefix-$runtime"
  port=8080
  test "$runtime" != root || port=80
  test "$runtime" != production || image="$JMS_DIAGNOSTICS_WEB_IMAGE"
  alias="$prefix-$runtime"
  container=$(docker run -d --network "$prefix" --network-alias "$alias" \
    -e JMS_DIAGNOSTICS_ENDPOINT=/api/jms/diagnostics/v1 \
    -e JMS_DIAGNOSTICS_UPSTREAM=http://jms-diagnostics:8080 "$image")
  containers+=("$container")
  docker exec -i "$receiver" python - "$alias" "$port" "$runtime" <<'PY'
import http.client, json, sys, time
host, port, runtime = sys.argv[1], int(sys.argv[2]), sys.argv[3]
def request(method, path, value=None):
    connection = http.client.HTTPConnection(host, port, timeout=3)
    body = json.dumps(value) if value is not None else None
    connection.request(method, path, body, {'Content-Type': 'application/json',
        'Authorization': 'Bearer synthetic-only', 'Cookie': 'connect.sid=fixture-synthetic-only'})
    response = connection.getresponse()
    status, content = response.status, response.read()
    connection.close()
    return status, content
for attempt in range(30):
    try:
        status, content = request('GET', '/assets/config/config.json')
        assert status == 200
        assert json.loads(content)['diagnosticsEndpoint'] == '/api/jms/diagnostics/v1'
        break
    except (OSError, ValueError, AssertionError):
        time.sleep(1)
else:
    raise SystemExit('Isolated nginx runtime did not become ready: ' + runtime)
event = dict(schemaVersion=1, event='runtime_error', platform='web',
    version='0.11.1-jms.25', buildId='JMS-0.11.1-jms.25-web-0123456789ab', category='flutter_framework')
assert request('POST', '/api/jms/diagnostics/v1', event)[0] == 202
assert request('POST', '/api/jms/diagnostics/v1', dict(event, unknown='fixture-only'))[0] == 400
assert request('GET', '/api/jms/diagnostics/v1')[0] == 405
if runtime == 'production':
    assert request('GET', '/healthz')[0] == 200
print(runtime + ': runtime config, accepted event, unknown-field refusal and write-only route verified')
PY
  docker exec "$container" nginx -t
done

docker exec -i "$receiver" python - <<'PY'
import json, sqlite3
connection = sqlite3.connect('/data/diagnostics.sqlite3')
rows = connection.execute('SELECT payload FROM events').fetchall()
assert len(rows) == 3
for row in rows:
    event = json.loads(row[0])
    assert set(event) == {'schemaVersion', 'event', 'platform', 'version', 'buildId', 'category'}
    assert 'synthetic-only' not in row[0] and 'connect.sid' not in row[0]
connection.close()
print('Receiver persisted three bounded synthetic events without request credentials')
PY
