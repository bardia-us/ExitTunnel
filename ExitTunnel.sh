#!/bin/bash

# ==============================================================================
# ExitTunnel Manager - Developed by @mr_bxs
# ==============================================================================
# This script sets up a secure and persistent VXLAN tunnel between two servers.
# It includes automatic "dekomodor" (traffic redirection) on the Iran server
# and sets up the Foreign server as the internet gateway with Sanayi/X-UI.
#
# Features: VXLAN tunnel, automatic port redirection (dekomodor), persistent services,
# simple 'exittunnel' command, BBR, Cronjob for restarts.
#
# GitHub: [Upload to GitHub & put your link here]
# Telegram ID: @mr_bxs
# Script Version: 11.0 (ExitTunnel VXLAN with Auto-Dekomodor)
# ==============================================================================

# --- Global Variables & Configuration ---
LOG_FILE="/var/log/exittunnel_vxlan.log"
VXLAN_CONFIG_DIR="/etc/exittunnel_vxlan" # Central directory for VXLAN configs
# VXLAN parameters (Can be configured by user if needed, but for simplicity, they are fixed for now)
VNI=88 # VXLAN Network Identifier - A unique ID for your VXLAN tunnel
VXLAN_IF="vxlan${VNI}" # Name of the VXLAN interface
IRAN_VXLAN_IP="30.0.0.1/24" # Internal IP for Iran side
KHAREJ_VXLAN_IP="30.0.0.2/24" # Internal IP for Foreign side
SCRIPT_VERSION="11.0"
SCRIPT_PATH="/usr/local/bin/exittunnel-script.sh" # Path where script will be stored for persistent access
SYMLINK_PATH="/usr/local/bin/exittunnel" # Command to run the script

# ---------------- COLORS ----------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ---------------- FUNCTIONS ----------------

# Function to get the server's public IPv4 address
function get_public_ipv4() {
    local ip=$(curl -s4 --connect-timeout 5 "https://api.ipify.org" || \
               curl -s4 --connect-timeout 5 "https://ipv4.icanhazip.com" || \
               curl -s4 --connect-timeout 5 "http://ifconfig.me/ip")
    echo "${ip:-N/A}"
}

# Function to get the server's public IPv6 address
function get_public_ipv6() {
    local ip6=$(curl -s6 --connect-timeout 5 "https://api6.ipify.org" || \
                curl -s6 --connect-timeout 5 "https://ipv6.icanhazip.com" || \
                curl -s6 --connect-timeout 5 "http://ifconfig.me/ip")
    echo "${ip6:-N/A}"
}

# Logs actions to file and prints to stdout
function log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Pauses script execution until Enter is pressed
function press_enter_to_continue() {
    echo -e "\nPress Enter to continue..."
    read -r
}

# Displays script and server information at the start
function display_header() {
    clear # Clear screen for clean display
    echo "+-------------------------------------------------------------------------+"
    echo "| _ |"
    echo "|| | |"
    echo "|| | ___ _ __ __ _ |"
    echo "|| | / _ \ '_ \ / _ | |"
    echo "|| |___| __/ | | | (_| | |"
    echo "|\_____/\___|_| |_|\__,_| V$SCRIPT_VERSION |" # Updated version
    echo "+-------------------------------------------------------------------------+"    
    echo -e "| Telegram Channel : ${MAGENTA}@mr_bxs ${NC}| Version : ${GREEN} $SCRIPT_VERSION ${NC} " # Updated Channel & Version
    echo "+-------------------------------------------------------------------------+"
    echo -e "|${GREEN}Server Country |${NC} $(curl -sS --connect-timeout 5 "http://ip-api.com/json/$(get_public_ipv4)" | jq -r '.country' 2>/dev/null || echo "N/A")"
    echo -e "|${GREEN}Server IP |${NC} $(get_public_ipv4)"
    echo -e "|${GREEN}Server ISP |${NC} $(curl -sS --connect-timeout 5 "http://ip-api.com/json/$(get_public_ipv4)" | jq -r '.isp' 2>/dev/null || echo "N/A")"
    echo "+-------------------------------------------------------------------------+"
    echo -e "|${YELLOW}Please choose an option:${NC}"
    echo "+-------------------------------------------------------------------------+"
    echo -e "1- Install new tunnel"
    echo -e "2- Uninstall tunnel(s)"
    echo -e "3- Install BBR"
    echo -e "4- Install cronjob (for HAProxy/VXLAN restart)"
    echo "+-------------------------------------------------------------------------+"
    echo -e "\033[0m"
}

# Install core dependencies (iproute2, net-tools, grep, awk, sudo, iputils-ping, jq, curl, haproxy, iptables)
function install_dependencies() {
    echo "[*] Updating package list..."
    sudo apt update -y > /dev/null 2>&1 || log_action "Warning: apt update failed."

    echo "[*] Installing essential tools: iproute2, net-tools, grep, awk, sudo, iputils-ping, jq, curl, haproxy, iptables, iptables-persistent..."
    sudo apt install -y iproute2 net-tools grep awk sudo iputils-ping jq curl haproxy iptables iptables-persistent > /dev/null 2>&1

    # Check for successful installation of core tools
    if ! command -v ip >/dev/null 2>&1; then log_action "[x] iproute2 not installed. Aborting."; echo "Error: iproute2 not installed. Aborting."; press_enter_to_continue; exit 1; fi
    if ! command -v jq >/dev/null 2>&1; then log_action "[x] jq not installed. Aborting."; echo "Error: jq not installed. Aborting."; press_enter_to_continue; exit 1; fi
    if ! command -v haproxy >/dev/null 2>&1; then log_action "[x] haproxy not installed. Aborting."; echo "Error: haproxy not installed. Aborting."; press_enter_to_continue; exit 1; fi
    log_action "✅ All essential dependencies installed."
}

# Uninstalls all VXLAN tunnels, HAProxy, and cleans up
function uninstall_all_vxlan() {
    echo "[!] Deleting all VXLAN interfaces and cleaning up..."
    log_action "Starting uninstall_all_vxlan function."
    
    for i in $(ip -d link show | grep -o 'vxlan[0-9]\+'); do
        ip link del $i 2>/dev/null
        log_action "Deleted VXLAN interface: $i"
    done
    
    rm -f /usr/local/bin/vxlan_bridge.sh /etc/ping_vxlan.sh
    log_action "Removed vxlan_bridge.sh script."

    systemctl disable --now vxlan-tunnel.service 2>/dev/null
    rm -f /etc/systemd/system/vxlan-tunnel.service
    log_action "Removed vxlan-tunnel.service."
    systemctl daemon-reload

    # Stop and disable HAProxy service
    systemctl stop haproxy 2>/dev/null
    systemctl disable haproxy 2>/dev/null
    log_action "Stopped and disabled haproxy service."
    
    # Remove HAProxy package
    sudo apt remove -y haproxy 2>/dev/null
    sudo apt purge -y haproxy 2>/dev/null
    sudo apt autoremove -y 2>/dev/null
    log_action "Removed haproxy package."

    # Remove iptables rules related to VXLAN
    log_action "Flushing specific iptables rules for VXLAN and restoring defaults."
    sudo iptables -F INPUT
    sudo iptables -F FORWARD
    sudo iptables -F POSTROUTING -t nat
    sudo iptables -X
    sudo iptables -Z
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -P OUTPUT ACCEPT

    # Restore default iptables rules if a backup exists
    if [ -f /etc/iptables/rules.v4.bak ]; then
        sudo cp /etc/iptables/rules.v4.bak /etc/iptables/rules.v4
        sudo netfilter-persistent reload
        log_action "Restored iptables rules from backup."
    else
        log_action "No iptables backup found. Ensure your firewall is configured as desired."
    fi

    # Remove related cronjobs
    crontab -l 2>/dev/null | grep -v 'systemctl restart haproxy' | grep -v 'systemctl restart vxlan-tunnel' | grep -v '/etc/ping_vxlan.sh' > /tmp/cron_tmp || true
    crontab /tmp/cron_tmp
    rm -f /tmp/cron_tmp
    log_action "Removed related cronjobs."
    echo "[+] All VXLAN tunnels and related components deleted."
    press_enter_to_continue
}

# Installs BBR congestion control
function install_bbr() {
    echo "Running BBR script..."
    log_action "Starting BBR installation."
    curl -fsSL https://raw.githubusercontent.com/MrAminiDev/NetOptix/main/scripts/bbr.sh -o /tmp/bbr.sh
    bash /tmp/bbr.sh
    rm -f /tmp/bbr.sh
    log_action "✅ BBR installation script executed."
    press_enter_to_continue
}

# Installs cronjob for HAProxy/VXLAN restart
function install_cronjob() {
    while true; do
        read -p "How many hours between each restart? (1-24): " cron_hours
        if [[ $cron_hours =~ ^[0-9]+$ ]] && (( cron_hours >= 1 && cron_hours <= 24 )); then
            break
        else
            echo "Invalid input. Please enter a number between 1 and 24."
        fi
    done
    log_action "Setting up cronjob for restarts every $cron_hours hour(s)."
    # Remove any previous cronjobs for these services
    crontab -l 2>/dev/null | grep -v 'systemctl restart haproxy' | grep -v 'systemctl restart vxlan-tunnel' | grep -v 'systemctl reload iptables' > /tmp/cron_tmp || true
    echo "0 */$cron_hours * * * systemctl restart haproxy >/dev/null 2>&1" >> /tmp/cron_tmp
    echo "0 */$cron_hours * * * systemctl restart vxlan-tunnel >/dev/null 2>&1" >> /tmp/cron_tmp
    echo "0 */$cron_hours * * * /sbin/iptables-restore < /etc/iptables/rules.v4 >/dev/null 2>&1" >> /tmp/cron_tmp # Restore iptables
    crontab /tmp/cron_tmp
    rm -f /tmp/cron_tmp
    echo -e "${GREEN}Cronjob set successfully to restart haproxy and vxlan-tunnel every $cron_hours hour(s).${NC}"
    log_action "✅ Cronjob configured."
    press_enter_to_continue
}

# --- Function to handle persistent command setup ---
function setup_persistent_command() {
    local SCRIPT_NAME=$(basename "$0") 
    local PERSISTENT_SCRIPT_PATH="/usr/local/bin/${SCRIPT_NAME}"
    local SYMLINK_COMMAND="exittunnel" # The command you want to use (e.g., 'exittunnel')

    if [ ! -f "$PERSISTENT_SCRIPT_PATH" ] || [ "$(readlink "$SYMLINK_COMMAND" 2>/dev/null)" != "$PERSISTENT_SCRIPT_PATH" ]; then
        echo "[*] Setting up persistent command '$SYMLINK_COMMAND'..."
        log_action "Setting up persistent command."
        sudo cp "$0" "$PERSISTENT_SCRIPT_PATH" # Copy the current running script to a persistent location
        sudo chmod +x "$PERSISTENT_SCRIPT_PATH"
        sudo ln -sf "$PERSISTENT_SCRIPT_PATH" "$SYMLINK_COMMAND" # Create a symlink
        echo "✅ '$SYMLINK_COMMAND' command is now set up. You can run the script by typing '$SYMLINK_COMMAND' from anywhere."
        press_enter_to_continue
        log_action "Persistent command setup complete."
    fi
}

# Function to configure HAProxy for port forwarding
function configure_haproxy_port_forwarding() {
    echo "[*] Configuring HAProxy for automatic port forwarding..."
    log_action "Starting HAProxy configuration for port forwarding."

    # Ensure haproxy is installed
    if ! command -v haproxy >/dev/null 2>&1; then
        echo "[x] HAProxy is not installed. Installing..."
        sudo apt update > /dev/null 2>&1 && sudo apt install -y haproxy > /dev/null 2>&1
    fi

    # Ensure config directory exists
    sudo mkdir -p /etc/haproxy

    # Default HAProxy config file
    local CONFIG_FILE="/etc/haproxy/haproxy.cfg"
    local BACKUP_FILE="/etc/haproxy/haproxy.cfg.bak"

    # Backup old config if it's not our default template
    if [ -f "$CONFIG_FILE" ]; then
        if ! grep -q "### ExitTunnel HAProxy Config ###" "$CONFIG_FILE"; then
            cp "$CONFIG_FILE" "$BACKUP_FILE"
            log_action "Backed up existing HAProxy config to $BACKUP_FILE"
        fi
    fi

    # Write base config for HAProxy
    cat <<EOL > "$CONFIG_FILE"
### ExitTunnel HAProxy Config ###
global
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 4096

defaults
    mode tcp
    option dontlognull
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms
    retries 3
    option tcpka
EOL

    local local_public_ip=$(hostname -I | awk '{print $1}' | head -n1)
    local vxlan_internal_ip="${IRAN_VXLAN_IP%/*}" # 30.0.0.1 for Iran side

    read -p "Enter public ports on this server (Iran) to forward (comma-separated, e.g., 80,443): " user_public_ports
    IFS=',' read -ra public_ports_array <<< "$user_public_ports"

    for public_port in "${public_ports_array[@]}"; do
        cat <<EOL >> "$CONFIG_FILE"

frontend frontend_$public_port
    bind $local_public_ip:$public_port # Bind to public IP
    default_backend backend_$public_port
    option tcpka

backend backend_$public_port
    option tcpka
    server server1 $vxlan_internal_ip:$public_port check maxconn 2048 # Forward to VXLAN internal IP
EOL
    done

    # Validate haproxy config
    if haproxy -c -f "$CONFIG_FILE"; then
        echo "[*] Restarting HAProxy service..."
        systemctl restart haproxy
        systemctl enable haproxy
        echo -e "${GREEN}HAProxy configured and restarted successfully for port forwarding.${NC}"
        log_action "✅ HAProxy configured and restarted."
    else
        echo -e "${YELLOW}Warning: HAProxy configuration is invalid! Attempting to restore backup or clean up.${NC}"
        log_action "HAProxy config validation failed."
        [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$CONFIG_FILE" && systemctl restart haproxy && log_action "Restored HAProxy config from backup."
        echo "HAProxy config is invalid. Please check manually."
    fi
}


# --- Main tunnel setup logic ---
function install_new_tunnel_core() {
    # Check if ip command is available (already checked by install_dependencies)
    if ! command -v ip >/dev/null 2>&1; then
        echo "[x] iproute2 is not installed. Aborting tunnel setup."
        press_enter_to_continue
        return 1
    fi

    # ------------- VARIABLES --------------
    # VNI, VXLAN_IF, IRAN_VXLAN_IP, KHAREJ_VXLAN_IP are global

    # --------- Choose Server Role ----------
    echo "Choose server role:"
    echo "1- Iran (Border Server with Auto-Dekomodor)"
    echo "2- Kharej (Main Server with Sanayi/X-UI)"
    read -p "Enter choice (1/2): " role_choice

    local REMOTE_IP="" # Public IP of the other server
    local MY_VXLAN_IP="" # Internal VXLAN IP for this server

    if [[ "$role_choice" == "1" ]]; then # Iran Server
        read -p "Enter Foreign Server Public IP (Kharej IP): " KHAREJ_IP
        if [ -z "$KHAREJ_IP" ]; then echo "IP cannot be empty."; press_enter_to_continue; return 1; fi

        read -p "Enter Tunnel Port (e.g., 4789 - standard VXLAN UDP port): " DSTPORT
        # Input validation for DSTPORT
        while true; do
            if [[ $DSTPORT =~ ^[0-9]+$ ]] && (( DSTPORT >= 1 && DSTPORT <= 65535 )); then
                break
            else
                echo "Invalid port. Please enter a number between 1 and 65535."
                read -p "Tunnel port: " DSTPORT
            fi
        done

        # Configure HAProxy for automatic dekomodor (port forwarding from public to VXLAN internal IP)
        configure_haproxy_port_forwarding # This will ask for public ports and forward to VXLAN IP

        MY_VXLAN_IP=$IRAN_VXLAN_IP
        REMOTE_IP=$KHAREJ_IP
        log_action "Configuring Iran Server (Forwarder)."

    elif [[ "$role_choice" == "2" ]]; then # Kharej Server
        read -p "Enter Iran Server Public IP (IRAN IP): " IRAN_IP
        if [ -z "$IRAN_IP" ]; then echo "IP cannot be empty."; press_enter_to_continue; return 1; fi

        read -p "Enter Tunnel Port (e.g., 4789 - Must match Iran Server's Tunnel Port): " DSTPORT
        # Input validation for DSTPORT
        while true; do
            if [[ $DSTPORT =~ ^[0-9]+$ ]] && (( DSTPORT >= 1 && DSTPORT <= 65535 )); then
                break
            else
                echo "Invalid port. Please enter a number between 1 and 65535."
                read -p "Tunnel port: " DSTPORT
            fi
        done

        MY_VXLAN_IP=$KHAREJ_VXLAN_IP
        REMOTE_IP=$IRAN_IP
        log_action "Configuring Kharej Server (Receiver)."

    else
        echo "[x] Invalid role selected. Aborting tunnel setup."
        press_enter_to_continue
        return 1
    fi

    # Detect default interface for VXLAN
    INTERFACE=$(ip route get 1.1.1.1 | awk '{print $5}' | head -n1)
    if [ -z "$INTERFACE" ]; then
        echo "[x] Could not detect main network interface. Aborting VXLAN setup."
        press_enter_to_continue
        return 1
    fi
    log_action "Detected main interface: $INTERFACE"


    # ------------ Setup VXLAN Interface --------------
    echo "[+] Creating VXLAN interface ${VXLAN_IF}..."
    log_action "Creating VXLAN interface."
    # Ensure the interface is not already present before adding
    ip link del $VXLAN_IF 2>/dev/null
    ip link add $VXLAN_IF type vxlan id $VNI local $(hostname -I | awk '{print $1}') remote $REMOTE_IP dev $INTERFACE dstport $DSTPORT nolearning
    
    echo "[+] Assigning IP $MY_VXLAN_IP to $VXLAN_IF"
    ip addr add $MY_VXLAN_IP dev $VXLAN_IF
    ip link set $VXLAN_IF up
    log_action "VXLAN interface configured and brought up."

    # ------------ Setup IPTables Rules --------------
    echo "[+] Adding iptables rules for VXLAN tunnel on port ${DSTPORT}..."
    log_action "Adding iptables rules."
    # Backup existing iptables rules before adding new ones
    sudo iptables-save > /etc/iptables/rules.v4.bak # Backup current rules
    if command -v ip6tables-save >/dev/null 2>&1; then
        sudo ip6tables-save > /etc/iptables/rules.v6.bak
    fi

    # Accept UDP traffic on the VXLAN port
    iptables -I INPUT 1 -p udp --dport $DSTPORT -j ACCEPT
    # Accept traffic from the remote VXLAN public IP
    iptables -I INPUT 1 -s $REMOTE_IP -j ACCEPT
    # Accept traffic from the remote VXLAN internal IP
    # This assumes the remote VXLAN internal IP is the other part of 30.0.0.0/24
    if [[ "$role_choice" == "1" ]]; then # If Iran server
        iptables -I INPUT 1 -s ${KHAREJ_VXLAN_IP%/*} -j ACCEPT # Accept from Kharej VXLAN IP (e.g., 30.0.0.2)
        # Enable IP forwarding
        sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
        log_action "Enabled IPv4 forwarding on Iran server."
    elif [[ "$role_choice" == "2" ]]; then # If Kharej server
        iptables -I INPUT 1 -s ${IRAN_VXLAN_IP%/*} -j ACCEPT # Accept from Iran VXLAN IP (e.g., 30.0.0.1)
        # Enable IP forwarding and NAT for internet access
        sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
        # Add NAT (Masquerade) rule for traffic coming from VXLAN internal network to go to the internet
        iptables -t nat -A POSTROUTING -o "$INTERFACE" -j MASQUERADE
        log_action "Enabled IPv4 forwarding and NAT on Kharej server."
    fi

    # Save iptables rules persistently
    if command -v iptables-save >/dev/null 2>&1 && command -v netfilter-persistent >/dev/null 2>&1; then
        sudo netfilter-persistent save > /dev/null 2>&1
        log_action "✅ iptables rules saved persistently."
    else
        log_action "⚠️ Warning: iptables-persistent is not installed. Rules might not survive reboot. Install 'iptables-persistent'."
        echo "Warning: 'iptables-persistent' is not installed. IPtables rules might not survive reboot. Consider installing it."
    fi

    # ---------------- CREATE SYSTEMD SERVICE ----------------
    echo "[+] Creating systemd service for VXLAN tunnel persistence..."
    log_action "Creating systemd service for VXLAN."

    cat <<EOF > /usr/local/bin/vxlan_bridge.sh
#!/bin/bash
# Script to bring up VXLAN interface persistently
ip link add $VXLAN_IF type vxlan id $VNI local \$(hostname -I | awk '{print \$1}') remote $REMOTE_IP dev $INTERFACE dstport $DSTPORT nolearning
ip addr add $MY_VXLAN_IP dev $VXLAN_IF
ip link set $VXLAN_IF up

# Add iptables rules on boot (in case iptables-persistent is not fully relied upon)
iptables -I INPUT 1 -p udp --dport $DSTPORT -j ACCEPT
iptables -I INPUT 1 -s $REMOTE_IP -j ACCEPT
if [[ "$role_choice" == "1" ]]; then # If Iran server
    iptables -I INPUT 1 -s ${KHAREJ_VXLAN_IP%/*} -j ACCEPT
elif [[ "$role_choice" == "2" ]]; then # If Kharej server
    iptables -I INPUT 1 -s ${IRAN_VXLAN_IP%/*} -j ACCEPT
    iptables -t nat -A POSTROUTING -o "$INTERFACE" -j MASQUERADE
fi
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1 # Ensure forwarding is enabled

# Persistent keepalive: ping remote every 30s in background to keep tunnel alive
( while true; do ping -c 1 $REMOTE_IP >/dev/null 2>&1; sleep 30; done ) &
EOF

    chmod +x /usr/local/bin/vxlan_bridge.sh

    cat <<EOF > /etc/systemd/system/vxlan-tunnel.service
[Unit]
Description=ExitTunnel VXLAN Tunnel Interface
After=network.target network-online.target

[Service]
ExecStart=/usr/local/bin/vxlan_bridge.sh
Type=oneshot
RemainAfterExit=yes
# Ensure ping process is killed on service stop
ExecStop=/bin/bash -c 'pkill -f "ping -c 1 $REMOTE_IP"' 
ExecStop=/sbin/ip link del $VXLAN_IF 2>/dev/null || true # Ensure interface is cleaned up on stop

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 /etc/systemd/system/vxlan-tunnel.service
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable vxlan-tunnel.service
    systemctl start vxlan-tunnel.service
    log_action "✅ VXLAN tunnel service enabled and started."

    echo -e "\n${GREEN}[✓] VXLAN tunnel setup completed successfully.${NC}"

    echo -e "\n${YELLOW}Next Steps:${NC}"
    if [[ "$role_choice" == "1" ]]; then # Iran Server
        echo -e " - On your Iran Server (IP: $(get_public_ipv4)): You can now configure X-UI/Sanayi."
        echo -e " - Create Inbounds (e.g., VLESS/TCP) on public ports (e.g., 443, 80)."
        echo -e " - For the Outbound of these Inbounds, configure them to connect to your Foreign Server's VXLAN internal IP: ${GREEN}${KHAREJ_VXLAN_IP%/*}${NC}"
        echo -e " - Example for VLESS/TCP Outbound: Server IP: ${GREEN}${KHAREJ_VXLAN_IP%/*}${NC}, Port: (Any port that your Sanayi/X-UI connects to on foreign server, e.g., 443 or 80)"
        echo -e " - Make sure to open your X-UI Inbound ports (e.g., 443, 80) in your Iran Server's firewall."
        echo -e " - ${MAGENTA}HAProxy is configured to automatically redirect traffic from your public ports to the VXLAN tunnel.${NC}"
        echo -e " If you chose to install HAProxy, ensure it's configured for the ports you intend to use."
        echo -e " Traffic will come into public ports (e.g., 443) -> HAProxy -> VXLAN ${KHAREJ_VXLAN_IP%/*}:${PUBLIC_PORT} (via X-UI on Kharej)."
    elif [[ "$role_choice" == "2" ]]; then # Kharej Server
        echo -e " - On your Kharej Server (IP: $(get_public_ipv4)): You need to install Sanayi/X-UI here."
        echo -e " - Create Inbounds (e.g., VLESS/TCP) listening on the VXLAN internal IP: ${GREEN}${KHAREJ_VXLAN_IP%/*}${NC}"
        echo -e " - Example for VLESS/TCP Inbound: Listen IP: ${GREEN}${KHAREJ_VXLAN_IP%/*}${NC}, Port: (Any port e.g., 443 or 80)"
        echo -e " - Ensure your firewall on Kharej server allows traffic from Iran's VXLAN internal IP (${IRAN_VXLAN_IP%/*}) to reach ${KHAREJ_VXLAN_IP%/*}:${PUBLIC_PORT}."
        echo -e " - NAT (Masquerade) rules are automatically applied to allow internet access from VXLAN."
    fi
    echo -e "\n${MAGENTA}Remember to run this script on BOTH your Iran and Foreign servers!${NC}"
    press_enter_to_continue
}


# ---------------- MAIN EXECUTION ----------------

# Set up persistent command on first run
setup_persistent_command

while true; do
    display_header
    echo "Select an option:"
    echo "1- Install new tunnel"
    echo "2- Uninstall tunnel(s)"
    echo "3- Install BBR"
    echo "4- Install cronjob (for HAProxy/VXLAN restart)"
    echo "5- Exit" # Added Exit option for clarity
    read -p "Enter your choice [1-5]: " main_action
    case $main_action in
        1)
            install_new_tunnel_core # Renamed to encapsulate tunnel logic
            ;;
        2)
            uninstall_all_vxlan
            ;;
        3)
            install_bbr
            ;;
        4)
            install_cronjob
            ;;
        5)
            log_action "Exiting script."
            echo "Exiting ExitTunnel Manager. Goodbye!"
            exit 0
            ;;
        *)
            echo "[x] Invalid option. Try again."
            sleep 1
            ;;
    esac
done

