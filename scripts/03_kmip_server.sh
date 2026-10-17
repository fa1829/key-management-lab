#!/usr/bin/env bash
# Module 03a -- Run a KMIP key-management server (PyKMIP) over mutual TLS.
# Its server and client certificates come from the HSM-backed PKI built in module 02.
# Usage: 03_kmip_server.sh start|stop|status
set -euo pipefail
source "$(dirname "$0")/../config/lab.env"
mkdir -p "$KMIP_DIR/policies"
PIDFILE="$KMIP_DIR/server.pid"; LOG="$KMIP_DIR/server.log"

cat > "$KMIP_DIR/server.conf" <<EOF
[server]
hostname=127.0.0.1
port=5696
certificate_path=$PKI_DIR/certs/kmip-server.crt
key_path=$PKI_DIR/keys/kmip-server.key
ca_path=$PKI_DIR/chain.pem
auth_suite=TLS1.2
enable_tls_client_auth=True
policy_path=$KMIP_DIR/policies
database_path=$KMIP_DIR/pykmip.db
logging_level=INFO
EOF

case "${1:-status}" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "already running (pid $(cat "$PIDFILE"))"; exit 0; fi
    # PyKMIP reads OpenSSL config too; give it the default one, not our PKCS#11 config.
    OPENSSL_CONF=/dev/null nohup "$LAB_HOME/.venv-kmip/bin/pykmip-server" -f "$KMIP_DIR/server.conf" -l "$LOG" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    for _ in $(seq 1 20); do (echo > /dev/tcp/127.0.0.1/5696) 2>/dev/null && break; sleep 0.5; done
    (echo > /dev/tcp/127.0.0.1/5696) 2>/dev/null && echo "KMIP server listening on 127.0.0.1:5696 (mTLS), pid $(cat "$PIDFILE")" \
      || { echo "KMIP server failed to start; see $LOG"; tail -20 "$LOG"; exit 1; } ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null && rm -f "$PIDFILE" && echo "stopped" || echo "not running" ;;
  status)
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && echo "running (pid $(cat "$PIDFILE"))" || echo "not running" ;;
esac
