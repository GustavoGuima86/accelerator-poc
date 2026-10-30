#!/bin/bash
set -euxo pipefail

dnf install -y socat

# socat resolves the Aurora hostname each time it forks for a new connection,
# so a failover (new writer IP) is picked up without restarting anything.
cat > /etc/systemd/system/db-forwarder.service <<'UNIT'
[Unit]
Description=TCP forwarder to Aurora writer
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:5432,reuseaddr,fork TCP:${aurora_endpoint}:${aurora_port}
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

# Trivial listener used only by Global Accelerator health checks.
cat > /etc/systemd/system/db-forwarder-health.service <<'UNIT'
[Unit]
Description=Health check listener for Global Accelerator
After=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:${health_check_port},reuseaddr,fork SYSTEM:"echo ok"
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now db-forwarder.service db-forwarder-health.service
