#!/bin/bash

# ==========================================
# QDTunnel Pro - Advanced Socat Manager
# Optimized for Stability & Anti-Censorship
# ==========================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Paths ---
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="qdtunnel"
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"
CONF_DIR="/etc/qdtunnel"
LOG_DIR="/var/log/qdtunnel"
TUNNELS_JSON="$CONF_DIR/tunnels.json"

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] This script must be run as root.${NC}"
   exit 1
fi

# --- Self-Installation (Fixing the "Disappearing" Bug) ---
install_self() {
    if [[ "$0" != "$SCRIPT_PATH" ]]; then
        echo -e "${BLUE}[*] Installing QDTunnel to system...${NC}"
        mkdir -p "$CONF_DIR" "$LOG_DIR"
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo -e "${GREEN}[+] Installed successfully! Type 'qdtunnel' to run it anytime.${NC}"
        echo -e "${YELLOW}[*] Relaunching from installed path...${NC}"
        sleep 1
        exec "$SCRIPT_PATH" "$@"
        exit 0
    fi
}

# --- Dependencies ---
check_dependencies() {
    local MISSING_PACKAGES=()
    
    if ! command -v socat &> /dev/null; then MISSING_PACKAGES+=("socat"); fi
    if ! command -v jq &> /dev/null; then MISSING_PACKAGES+=("jq"); fi
    if ! command -v curl &> /dev/null; then MISSING_PACKAGES+=("curl"); fi

    if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
        echo -e "${YELLOW}[*] Installing missing dependencies: ${MISSING_PACKAGES[*]}...${NC}"
        apt-get update -qq
        apt-get install -y -qq "${MISSING_PACKAGES[@]}"
    fi
}

# --- Optimization (BBR & Sysctl) ---
optimize_network() {
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo -e "${BLUE}[*] Enabling BBR for better speed...${NC}"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p &> /dev/null
    fi
}

# --- JSON Database Helpers ---
init_db() {
    if [[ ! -f "$TUNNELS_JSON" ]]; then
        echo "[]" > "$TUNNELS_JSON"
    fi
}

save_tunnel() {
    # $1 = json object
    jq ". += [$1]" "$TUNNELS_JSON" > "${TUNNELS_JSON}.tmp" && mv "${TUNNELS_JSON}.tmp" "$TUNNELS_JSON"
}

remove_tunnel_db() {
    # $1 = name
    jq "map(select(.name != \"$1\"))" "$TUNNELS_JSON" > "${TUNNELS_JSON}.tmp" && mv "${TUNNELS_JSON}.tmp" "$TUNNELS_JSON"
}

# --- Service Management ---
create_service() {
    local NAME=$1
    local CMD=$2
    local SERVICE_FILE="/etc/systemd/system/qdtunnel-${NAME}.service"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=QDTunnel - ${NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -c '${CMD}'
Restart=always
RestartSec=3
StartLimitIntervalSec=0
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "qdtunnel-${NAME}"
}

# --- Menu Functions ---
add_tunnel() {
    clear
    echo -e "${CYAN}=== Add New Tunnel ===${NC}"
    echo "1) IRAN Mode (Listen Local -> Forward to Kharej)"
    echo "2) KHAREJ Mode (Listen Public -> Forward to internal/other)"
    read -p "Select Role [1-2]: " ROLE

    read -p "Tunnel Name (English, no spaces): " TNAME
    if [[ -z "$TNAME" ]]; then echo -e "${RED}Name required!${NC}"; sleep 1; return; fi
    
    # Check duplicate
    if grep -q "\"name\": \"$TNAME\"" "$TUNNELS_JSON"; then
        echo -e "${RED}Tunnel with this name already exists!${NC}"; sleep 2; return;
    fi

    if [[ "$ROLE" == "1" ]]; then
        read -p "Local Port (e.g. 8080): " LPORT
        read -p "Kharej IP/Domain: " RHOST
        read -p "Kharej Port: " RPORT
        read -p "Enable HTTP Obfuscation? (y/n): " OBFUSCATE

        CMD="socat TCP-LISTEN:${LPORT},reuseaddr,fork,keepalive,keepidle=10,keepintvl=10,keepcnt=3 TCP:${RHOST}:${RPORT},keepalive,keepidle=10,keepintvl=10,keepcnt=3"

        if [[ "$OBFUSCATE" =~ ^[Yy]$ ]]; then
            read -p "Fake Host Header (e.g. update.microsoft.com): " FAKE_HOST
            # Advanced Socat wrapper for HTTP injection
            # Note: This is a basic injection. For full obfuscation, use Gost/V2Ray.
            # We create a small script for the wrapper
            WRAPPER_SCRIPT="$CONF_DIR/${TNAME}_wrapper.sh"
            cat > "$WRAPPER_SCRIPT" <<EOF
#!/bin/bash
# Inject HTTP Header then connect
(echo -ne "GET / HTTP/1.1\r\nHost: ${FAKE_HOST}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"; cat) | socat - TCP:${RHOST}:${RPORT}
EOF
            chmod +x "$WRAPPER_SCRIPT"
            CMD="socat TCP-LISTEN:${LPORT},reuseaddr,fork SYSTEM:\"$WRAPPER_SCRIPT\""
        fi

        create_service "$TNAME" "$CMD"
        save_tunnel "{\"name\": \"$TNAME\", \"type\": \"iran\", \"lport\": \"$LPORT\", \"rhost\": \"$RHOST\", \"rport\": \"$RPORT\"}"
        echo -e "${GREEN}[✓] Tunnel '$TNAME' Created!${NC}"

    elif [[ "$ROLE" == "2" ]]; then
        read -p "Listen Port (Public): " LPORT
        read -p "Target IP (usually 127.0.0.1): " RHOST
        read -p "Target Port: " RPORT
        
        CMD="socat TCP-LISTEN:${LPORT},reuseaddr,fork,keepalive TCP:${RHOST}:${RPORT},keepalive"
        create_service "$TNAME" "$CMD"
        save_tunnel "{\"name\": \"$TNAME\", \"type\": \"kharej\", \"lport\": \"$LPORT\", \"rhost\": \"$RHOST\", \"rport\": \"$RPORT\"}"
        echo -e "${GREEN}[✓] Tunnel '$TNAME' Created!${NC}"
    fi
    sleep 2
}

list_tunnels() {
    clear
    echo -e "${CYAN}=== Active Tunnels ===${NC}"
    printf "%-15s %-10s %-10s %-25s\n" "NAME" "TYPE" "LOCAL" "REMOTE"
    echo "------------------------------------------------------------"
    jq -r '.[] | "\(.name) \(.type) \(.lport) \(.rhost):\(.rport)"' "$TUNNELS_JSON" | while read -r name type lport remote; do
        printf "%-15s %-10s %-10s %-25s\n" "$name" "$type" "$lport" "$remote"
    done
    echo ""
    read -p "Press Enter to return..."
}

remove_tunnel() {
    clear
    echo -e "${CYAN}=== Remove Tunnel ===${NC}"
    jq -r '.[] | .name' "$TUNNELS_JSON"
    echo ""
    read -p "Type tunnel name to remove: " TNAME
    
    if [[ -z "$TNAME" ]]; then return; fi

    echo -e "${YELLOW}[*] Stopping service...${NC}"
    systemctl stop "qdtunnel-${TNAME}"
    systemctl disable "qdtunnel-${TNAME}"
    rm "/etc/systemd/system/qdtunnel-${TNAME}.service"
    systemctl daemon-reload
    
    # Remove wrapper if exists
    if [[ -f "$CONF_DIR/${TNAME}_wrapper.sh" ]]; then
        rm "$CONF_DIR/${TNAME}_wrapper.sh"
    fi

    remove_tunnel_db "$TNAME"
    echo -e "${GREEN}[✓] Tunnel removed.${NC}"
    sleep 1
}

show_logs() {
    clear
    echo -e "${CYAN}=== Tunnel Logs ===${NC}"
    jq -r '.[] | .name' "$TUNNELS_JSON"
    echo ""
    read -p "Type tunnel name to see logs: " TNAME
    if [[ -z "$TNAME" ]]; then return; fi
    
    echo -e "${BLUE}Press CTRL+C to exit logs${NC}"
    journalctl -u "qdtunnel-${TNAME}" -f -n 50
}

# --- Main Logic ---

install_self
check_dependencies
optimize_network
init_db

while true; do
    clear
    echo -e "${GREEN}  ___  ____  _____                          _ ${NC}"
    echo -e "${GREEN} / _ \|  _ \|_   _|   _ _ __  _ __   ___| |${NC}"
    echo -e "${GREEN}| | | | | | | | || | | | '_ \| '_ \ / _ \ |${NC}"
    echo -e "${GREEN}| |_| | |_| | | || |_| | | | | | | |  __/ |${NC}"
    echo -e "${GREEN} \__\_\____/  |_| \__,_|_| |_|_| |_|\___|_|${NC}"
    echo -e "${CYAN}           Advanced Tunnel Manager v2.0     ${NC}"
    echo "-----------------------------------------------"
    echo "1. Add Tunnel"
    echo "2. List Tunnels"
    echo "3. Remove Tunnel"
    echo "4. Show Logs"
    echo "5. Restart All Services"
    echo "0. Exit"
    echo "-----------------------------------------------"
    read -p "Select Option: " OPT

    case $OPT in
        1) add_tunnel ;;
        2) list_tunnels ;;
        3) remove_tunnel ;;
        4) show_logs ;;
        5) 
           echo "Restarting services..."
           systemctl daemon-reload
           jq -r '.[] | .name' "$TUNNELS_JSON" | xargs -I {} systemctl restart "qdtunnel-{}"
           sleep 1
           ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo "Invalid option"; sleep 1 ;;
    esac
done
