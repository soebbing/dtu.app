#!/bin/sh
# Container entrypoint for the dtu.app release.
#
# Runs pending Ecto migrations against the configured DATABASE_URL and then
# starts the BEAM release in the foreground. Putting migrations here (instead
# of the compose `command:`) means every container start — first boot or
# restart — reconciles the schema before serving, with clean PID 1 / signal
# handling handed off to the release via `exec`.
set -e

# Migrations are best-effort at boot: if the DB isn't up yet we retry a few
# times so `docker compose up` doesn't race the healthcheck on a cold db.
echo "[entrypoint] running migrations…"
for i in 1 2 3 4 5 6 7 8 9 10; do
  if /app/bin/dtu_app eval 'DtuApp.Release.migrate'; then
    break
  fi
  echo "[entrypoint] migration attempt $i failed, retrying in 3s…"
  sleep 3
done

echo "[entrypoint] starting release…"
exec /app/bin/dtu_app start
