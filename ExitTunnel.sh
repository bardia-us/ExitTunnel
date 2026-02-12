#!/bin/bash

# ==========================================
# QDTunnel v3.0 - English Edition
# Stable & Simple TCP Forwarder
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONF_DIR="/etc/qdtunnel"
TUNNELS_JSON="$CONF_DIR/tunnels.json"
SERVICE_DIR="/etc/systemd/system"

# --- 1. System Checks ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[!] Please run as root (sudo).${NC}"
   exit 1
fi

# Install dependencies quietly
echo -e "${CYAN}[*] Checking dependencies...${NC}"
if ! command -v socat &> /dev/null; then apt-get update -qq && apt-get install -y socat -qq; fi
if ! command -v jq &> /dev/null; then apt-get install -y jq -qq; fi

mkdir -p "$CONF_DIR"
if [[ ! -f "$TUNNELS_JSON" ]]; then echo "[]" > "$TUNNELS_JSON"; fi

# --- 2. Helper Functions ---

open_firewall() {
    local PORT=$1
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            echo -e "${YELLOW}[*] Opening port $PORT in UFW...${NC}"
            ufw allow "$PORT"/tcp > /dev/null
        fi
    fi
    # Also try iptables just in case
    iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
}

save_tunnel() {
    # Safely append to JSON
    jq ". += [$1]" "$TUNNELS_JSON" > "$TUNNELS_JSON.tmp" && mv "$TUNNELS_JSON.tmp" "$TUNNELS_JSON"
}

remove_tunnel_db() {
    jq "map(select(.name != \"$1\"))" "$TUNNELS_JSON" > "$TUNNELS_JSON.tmp" && mv "$TUNNELS_JSON.tmp" "$TUNNELS_JSON"
}

# --- 3. Core Logic ---

add_tunnel() {
    clear
    echo -e "${CYAN}=== Create New Tunnel ===${NC}"
    echo "Which server is this?"
    echo "1) IRAN Server (Bridge/Client)"
    echo "2) KHAREJ Server (Destination/Upstream)"
    read -p "Select [1-2]: " ROLE

    read -p "Enter Tunnel Name (e.g., mytunnel): " TNAME
    if [[ -z "$TNAME" ]]; then echo -e "${RED}Name is required!${NC}"; sleep 1; return; fi

    # Check for duplicates
    if grep -q "\"name\": \"$TNAME\"" "$TUNNELS_JSON"; then
        echo -e "${RED}Name already exists!${NC}"; sleep 2; return;
    fi

    if [[ "$ROLE" == "1" ]]; then
        # --- IRAN CONFIG ---
        echo -e "\n${GREEN}--- IRAN CONFIGURATION ---${NC}"
        read -p "Local Port to open (e.g., 8080): " LPORT
        read -p "Kharej Server IP: " RHOST
        read -p "Kharej Server Port: " RPORT
        
        # Optimize tcp keepalive to prevent timeouts
        CMD="socat TCP-LISTEN:${LPORT},reuseaddr,fork,keepalive,keepidle=10,keepintvl=10,keepcnt=3 TCP:${RHOST}:${RPORT},keepalive"
        
        # Save & Run
        open_firewall "$LPORT"
        create_service "$TNAME" "$CMD"
        save_tunnel "{\"name\": \"$TNAME\", \"role\": \"IRAN\", \"listen\": \"$LPORT\", \"target\": \"$RHOST:$RPORT\"}"
        
        echo -e "${GREEN}[OK] Tunnel started! Connect your apps to THIS_SERVER_IP:$LPORT${NC}"

    elif [[ "$ROLE" == "2" ]]; then
        # --- KHAREJ CONFIG ---
        echo -e "\n${GREEN}--- KHAREJ CONFIGURATION ---${NC}"
        read -p "Port to Listen on (Must match Iran's destination port): " LPORT
        read -p "Final Destination IP (usually 127.0.0.1): " RHOST
        read -p "Final Destination Port (e.g., your V2ray port): " RPORT
        
        CMD="socat TCP-LISTEN:${LPORT},reuseaddr,fork,keepalive,keepidle=10,keepintvl=10,keepcnt=3 TCP:${RHOST}:${RPORT},keepalive"
        
        open_firewall "$LPORT"
        create_service "$TNAME" "$CMD"
        save_tunnel "{\"name\": \"$TNAME\", \"role\": \"KHAREJ\", \"listen\": \"$LPORT\", \"target\": \"$RHOST:$RPORT\"}"
        
        echo -e "${GREEN}[OK] Server is ready to receive connections on port $LPORT${NC}"
    else
        echo "Invalid selection."
    fi
    read -p "Press Enter..."
}

create_service() {
    local NAME=$1
    local CMD=$2
    local SFILE="$SERVICE_DIR/qdtunnel-${NAME}.service"

    cat > "$SFILE" <<EOF
[Unit]
Description=QDTunnel-$NAME
After=network.target

[Service]
ExecStart=/usr/bin/env bash -c '$CMD'
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "qdtunnel-${NAME}"
}

list_tunnels() {
    clear
    echo -e "${CYAN}=== Active Tunnels ===${NC}"
    if [[ ! -s "$TUNNELS_JSON" || "$(cat $TUNNELS_JSON)" == "[]" ]]; then
        echo "No tunnels found."
    else
        printf "%-15s %-10s %-10s %-25s\n" "NAME" "ROLE" "PORT" "TARGET"
        echo "-----------------------------------------------------------"
        jq -r '.[] | "\(.name) \(.role) \(.listen) \(.target)"' "$TUNNELS_JSON" | while read -r name role listen target; do
            printf "%-15s %-10s %-10s %-25s\n" "$name" "$role" "$listen" "$target"
        done
    fi
    echo ""
    read -p "Press Enter..."
}

check_status() {
    clear
    echo -e "${CYAN}=== System Status ===${NC}"
    echo -e "${YELLOW}1. Checking Services:${NC}"
    jq -r '.[] | .name' "$TUNNELS_JSON" | while read -r name; do
        STATUS=$(systemctl is-active "qdtunnel-$name")
        if [[ "$STATUS" == "active" ]]; then
            echo -e "  $name: ${GREEN}RUNNING${NC}"
        else
            echo -e "  $name: ${RED}STOPPED/ERROR${NC}"
        fi
    done
    echo ""
    echo -e "${YELLOW}2. Checking Ports (Listening):${NC}"
    netstat -tuln | grep -E "(socat|python)" || echo "  No active listeners found."
    echo ""
    read -p "Press Enter..."
}

remove_tunnel() {
    clear
    echo -e "${CYAN}=== Remove Tunnel ===${NC}"
    jq -r '.[] | .name' "$TUNNELS_JSON"
    echo ""
    read -p "Enter tunnel name to DELETE: " TNAME
    
    if [[ -z "$TNAME" ]]; then return; fi
    
    systemctl stop "qdtunnel-${TNAME}" 2>/dev/null
    systemctl disable "qdtunnel-${TNAME}" 2>/dev/null
    rm "$SERVICE_DIR/qdtunnel-${TNAME}.service" 2>/dev/null
    systemctl daemon-reload
    
    remove_tunnel_db "$TNAME"
    echo -e "${GREEN}[✓] Tunnel $TNAME deleted.${NC}"
    sleep 1
}

# --- Main Menu ---
while true; do
    clear
    echo -e "${GREEN}QDTunnel Manager (English)${NC}"
    echo "1. Add Tunnel"
    echo "2. List Tunnels"
    echo "3. Check Status / Diagnose"
    echo "4. Remove Tunnel"
    echo "0. Exit"
    echo "--------------------------"
    read -p "Choose: " OPT

    case $OPT in
        1) add_tunnel ;;
        2) list_tunnels ;;
        3) check_status ;;
        4) remove_tunnel ;;
        0) exit 0 ;;
        *) ;;
    esac
done
