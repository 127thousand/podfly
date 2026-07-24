#!/bin/sh
set -e
# Cloud Run sets PORT (default 8080). nginx must listen on it.
PORT="${PORT:-8080}"
sed -i "s/listen 8080;/listen ${PORT};/" /etc/nginx/conf.d/default.conf

# Serverpod on 8081 (see production.yaml apiServer.port).
./bin/server --mode="${runmode:-production}" --server-id="${serverid:-default}" \
  --logging="${logging:-normal}" --role="${role:-monolith}" &

i=0
while [ "$i" -lt 60 ]; do
  if nc -z 127.0.0.1 8081 2>/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 0.25
done

exec nginx -g 'daemon off;'
