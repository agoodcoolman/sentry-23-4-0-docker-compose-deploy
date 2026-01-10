#!/bin/bash

set -e

prep_init_db() {
  cp /opt/sentry/init_hba.sh /docker-entrypoint-initdb.d/init_hba.sh
}

cdc_setup_hba_conf() {
  PG_HBA="$PGDATA/pg_hba.conf"
  if [ ! -f "$PG_HBA" ]; then
    echo "DB not initialized. Postgres will take care of pg_hba"
  elif [ "$(grep -c -E "^host\\s+replication" "$PGDATA"/pg_hba.conf)" != 0 ]; then
    echo "Replication config already present in pg_hba. Not changing anything."
  else
    /opt/sentry/init_hba.sh
  fi
}

bind_wal2json() {
  cp /opt/sentry/wal2json/wal2json.so $(pg_config --pkglibdir)/wal2json.so
}

echo "Setting up Change Data Capture"

prep_init_db
if [ "$1" = 'postgres' ]; then
  cdc_setup_hba_conf
  bind_wal2json
fi
exec /usr/local/bin/docker-entrypoint.sh "$@"
