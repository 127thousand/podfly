#!/bin/sh
set -e
# Cloud Run sets PORT (default 8080). nginx must listen on it.
PORT="${PORT:-8080}"
sed -i "s/listen 8080;/listen ${PORT};/" /etc/nginx/conf.d/default.conf

# Serverpod on 8081 (see production.yaml apiServer.port).
# Log to file so a crash is visible when wait-for-port fails.
./bin/server --mode="${runmode:-production}" --server-id="${serverid:-default}" \
  --logging="${logging:-normal}" --role="${role:-monolith}" \
  > /tmp/serverpod.log 2>&1 &
SERVER_PID=$!

i=0
while [ "$i" -lt 60 ]; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "ERROR: Serverpod exited before binding :8081" >&2
    cat /tmp/serverpod.log >&2 || true
    exit 1
  fi
  if nc -z 127.0.0.1 8081 2>/dev/null; then
    # Keep streaming server logs alongside nginx (Cloud Run captures stdout).
    tail -F /tmp/serverpod.log &
    exec nginx -g 'daemon off;'
  fi
  i=$((i + 1))
  sleep 0.25
done

echo "ERROR: Serverpod did not bind 127.0.0.1:8081 within 15s" >&2
cat /tmp/serverpod.log >&2 || true
kill "$SERVER_PID" 2>/dev/null || true
exit 1
