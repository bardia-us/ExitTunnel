#!/bin/bash
set -e

# ======== PATHS ========
BASE_DIR="/etc/exittunnel"
BIN_DIR="/opt/exittunnel"
LOG="/var/log/exittunnel/install.log"
CONFIG="$BASE_DIR/tunnels.json"
SERVICE_DIR="/etc/systemd/system"

mkdir -p "$BASE_DIR" "$BIN_DIR" "$(dirname "$LOG")"
touch "$CONFIG"

exec > >(tee -a "$LOG") 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ExitTunnel TCP (Menu Edition) starting..."

if [[ $EUID -ne 0 ]]; then
  echo "Run as root!"
  exit 1
fi

# ======== INSTALL DEPS (MINIMAL) ========
echo "Installing dependencies..."
apt update -y
apt install -y jq netcat-openbsd

# init config if empty
if [[ ! -s "$CONFIG" ]]; then
  echo "[]" > "$CONFIG"
fi

# ======== FUNCTIONS ========

add_tunnel() {
  clear
  echo "=== ADD NEW TCP TUNNEL ==="
  read -p "Tunnel name: " NAME
  read -p "Local listen port (server IRAN): " LPORT
  read -p "Outside server IP: " RHOST
  read -p "Outside server port: " RPORT

  SERVICE="exittunnel-$NAME.service"

  # save to json
  jq --arg n "$NAME" --arg lp "$LPORT" --arg rh "$RHOST" --arg rp "$RPORT" \
  '. += [{"name":$n,"lport":$lp,"rhost":$rh,"rport":$rp,"created":now}]' \
  "$CONFIG" > /tmp/t && mv /tmp/t "$CONFIG"

  # create systemd service
  cat > "$SERVICE_DIR/$SERVICE" << EOF
[Unit]
Description=ExitTunnel TCP - $NAME
After=network.target

[Service]
ExecStart=/usr/bin/nc -lk $LPORT -c "/usr/bin/nc $RHOST $RPORT"
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reexec
  systemctl enable "$SERVICE"
  systemctl start "$SERVICE"

  echo "Tunnel '$NAME' created and running."
  sleep 2
}

remove_tunnel() {
  clear
  echo "=== REMOVE TUNNEL ==="
  list_tunnels

  read -p "Enter tunnel name to REMOVE: " NAME
  SERVICE="exittunnel-$NAME.service"

  systemctl stop "$SERVICE" 2>/dev/null || true
  systemctl disable "$SERVICE" 2>/dev/null || true
  rm -f "$SERVICE_DIR/$SERVICE"

  jq --arg n "$NAME" 'map(select(.name != $n))' "$CONFIG" > /tmp/t && mv /tmp/t "$CONFIG"

  echo "Tunnel '$NAME' removed."
  sleep 2
}

list_tunnels() {
  clear
  echo "=== TUNNELS LIST ==="
  if [[ "$(jq 'length' "$CONFIG")" == "0" ]]; then
    echo "No tunnels found."
  else
    jq -r '.[] | "• \(.name) | local:\(.lport) -> \(.rhost):\(.rport)"' "$CONFIG"
  fi
  echo ""
}

restart_tunnel() {
  clear
  echo "=== RESTART TUNNEL ==="
  list_tunnels

  read -p "Enter tunnel name to RESTART: " NAME
  SERVICE="exittunnel-$NAME.service"

  if systemctl status "$SERVICE" >/dev/null 2>&1; then
    systemctl restart "$SERVICE"
    echo "Tunnel '$NAME' restarted."
  else
    echo "Tunnel not found."
  fi
  sleep 2
}

# ======== MAIN MENU ========
while true; do
  clear
  echo "=============================="
  echo "   ExitTunnel TCP Manager"
  echo "=============================="
  echo "1) Add Tunnel"
  echo "2) Remove Tunnel"
  echo "3) List Tunnels"
  echo "4) Restart Tunnel"
  echo "5) Exit"
  echo "=============================="
  read -p "Choose [1-5]: " CHOICE

  case $CHOICE in
    1) add_tunnel ;;
    2) remove_tunnel ;;
    3) list_tunnels; read -p "Press Enter..." ;;
    4) restart_tunnel ;;
    5) echo "Goodbye."; exit 0 ;;
    *) echo "Invalid option"; sleep 1 ;;
  esac
done
