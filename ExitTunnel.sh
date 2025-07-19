#!/bin/bash

# ==============================================================================
# ExitTunnel Simple TCP/UDP Manager - Developed by @mr_bxs
# ==============================================================================
# This script sets up a basic TCP/UDP tunnel between two servers.
# It configures one server as the 'Forwarder' (Iran side, for X-UI/Sanayi)
# and another as the 'Receiver' (Foreign side, connected by Iran Server).
#
# GitHub: [Upload to GitHub & put your link here]
# Telegram ID: @mr_bxs
# Script Version: 7.0 (ExitTunnel Simple TCP/UDP)
# ==============================================================================

# --- Global Variables & Configuration ---
LOG_FILE="/var/log/exittunnel_simple_tcpudp.log"
TUNNEL_CONFIG_DIR="/etc/exittunnel" # Central directory for tunnel configs

# --- Helper Functions ---

# Function to get the server's public IPv4 address
function get_public_ipv4() {
    local ip=$(dig @resolver4.opendns.com myip.opendns.com +short -4 || \
               curl -s4 --connect-timeout 5 "https://api.ipify.org" || \
               curl -s4 --connect-timeout 5 "https://ipv4.icanhazip.com")
    echo "${ip:-N/A}"
}

# Function to get the server's public IPv6 address (optional for this simple tunnel)
function get_public_ipv6() {
    local ip6=$(dig @resolver4.opendns.com myip.opendns.com +short -6 || \
                curl -s6 --connect-timeout 5 "https://api6.ipify.org" || \
                curl -s6 --connect-timeout 5 "https://ipv6.icanhazip.com")
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
    echo "================================================================================"
    echo "Developed by @mr_bxs | GitHub: [Upload to GitHub & put your link here]"
    echo "Telegram Channel => @mr_bxs"
    echo "Tunnel script based on Simple TCP/UDP Forwarding"
    echo "========================================"
    echo "     🌐 Server Information"
    echo "========================================"
    echo "  IPv4 Address: $(get_public_ipv4)"
    echo "  IPv6 Address: $(get_public_ipv6)"
    echo "  Script Version: $SCRIPT_VERSION"
    echo "========================================\n"
}

# --- Tunnel Configuration Functions ---

# Installs socat for TCP/UDP forwarding
function install_socat() {
    log_action "📥 Installing 'socat' for TCP/UDP forwarding..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -y > /dev/null 2>&1
        sudo apt-get install socat -y > /dev/null 2>&1
    elif command -v yum &> /dev/null; then
        sudo yum install socat -y > /dev/null 2>&1
    elif command -v dnf &> /dev/null; then
        sudo dnf install socat -y > /dev/null 2>&1
    else
        log_action "❌ Error: Could not detect package manager (apt, yum, dnf). Please install socat manually."
        echo "Error: Could not install 'socat'. Please install it manually."
        press_enter_to_continue
        return 1
    fi

    if ! command -v socat &> /dev/null; then
        log_action "❌ 'socat' installation failed."
        echo "Error: 'socat' could not be installed. Please check your internet connection or install manually."
        return 1
    else
        log_action "✅ 'socat' installed successfully."
        echo "'socat' installed."
        return 0
    fi
}

# Creates a new tunnel configuration (Iran Server - Forwarder)
function create_iran_forwarder_tunnel() {
    echo "\n=== Configure Iran Server (Forwarder) ==="
    echo "This server will forward traffic from X-UI/Sanayi to the Foreign Server."
    echo "Type 'back' at any prompt to return to the main menu."

    if ! command -v socat &> /dev/null; then
        echo "'socat' is not installed. Installing now..."
        if ! install_socat; then
            echo "Failed to install socat. Cannot create tunnel."
            return
        fi
    fi

    read -p "🔸 Foreign Server IP (The public IP of your Foreign Server): " FOREIGN_IP
    [[ "$FOREIGN_IP" == "back" ]] && return
    if [ -z "$FOREIGN_IP" ]; then
        echo "Foreign Server IP cannot be empty."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Tunnel Port (e.g., 2078 - Must match the port on Foreign Server): " TUNNEL_PORT
    [[ "$TUNNEL_PORT" == "back" ]] && return
    if ! [[ "$TUNNEL_PORT" =~ ^[0-9]+$ ]] || [ "$TUNNEL_PORT" -lt 1 ] || [ "$TUNNEL_PORT" -gt 65535 ]; then
        echo "Invalid port number. Please enter a number between 1 and 65535."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Choose Tunnel Protocol (tcp or udp): " PROTOCOL
    [[ "$PROTOCOL" == "back" ]] && return
    if [[ "$PROTOCOL" != "tcp" && "$PROTOCOL" != "udp" ]]; then
        echo "Invalid protocol. Please choose 'tcp' or 'udp'."
        press_enter_to_continue
        return
    fi

    # Create systemd service for the forwarder
    SERVICE_NAME="exittunnel-forwarder-${TUNNEL_PORT}-${PROTOCOL}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    mkdir -p "$TUNNEL_CONFIG_DIR"
    
    # Store config details for listing/deletion
    echo "${FOREIGN_IP}:${TUNNEL_PORT}:${PROTOCOL}" > "$TUNNEL_CONFIG_DIR/${SERVICE_NAME}.conf"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ExitTunnel Forwarder TCP/UDP on Port ${TUNNEL_PORT}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/socat ${PROTOCOL}-LISTEN:${TUNNEL_PORT},fork ${PROTOCOL}-CONNECT:${FOREIGN_IP}:${TUNNEL_PORT}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    log_action "✅ Forwarder service config created: ${SERVICE_FILE}"

    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable "$SERVICE_NAME" --now > /dev/null 2>&1

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_action "✅ ExitTunnel Forwarder (${PROTOCOL}) started on port ${TUNNEL_PORT} (Iran Server)."
        echo "\n🎉 ExitTunnel Forwarder on your Iran Server is ready!"
        echo "--------------------------------------------------------------------------------"
        echo "  X-UI/Sanayi Configuration Details:"
        echo "  - Protocol: VLESS/VMess (or desired protocol)"
        echo "  - Server IP: Your Iran Server's Public IP"
        echo "  - Server Port: Any port for X-UI Inbound (e.g., 443, 8080)"
        echo "  - External Proxy: Yes (or Outbound/Route settings)"
        echo "  - External Proxy IP: 127.0.0.1 (localhost)"
        echo "  - External Proxy Port: ${TUNNEL_PORT} (This is the port socat is listening on)"
        echo "  - External Proxy Protocol: ${PROTOCOL} (Must match socat's protocol)"
        echo "--------------------------------------------------------------------------------"
        echo "IMPORTANT: Open port ${TUNNEL_PORT} (${PROTOCOL}) and your X-UI Inbound ports (e.g., 443, 8080) in your Iran Server's firewall!"
        echo "Restart X-UI/Sanayi after making changes."
    else
        log_action "❌ Failed to start ExitTunnel Forwarder. Check logs with 'journalctl -u ${SERVICE_NAME} -f'."
        echo "❌ ExitTunnel Forwarder failed to start."
        echo "   Check logs with 'journalctl -u ${SERVICE_NAME} -f'."
    fi
    press_enter_to_continue
}

# Creates a new tunnel configuration (Foreign Server - Receiver)
function create_foreign_receiver_tunnel() {
    echo "\n=== Configure Foreign Server (Receiver) ==="
    echo "This server will act as the tunnel endpoint, receiving traffic and sending it to the internet."
    echo "Type 'back' at any prompt to return to the main menu."

    if ! command -v socat &> /dev/null; then
        echo "'socat' is not installed. Installing now..."
        if ! install_socat; then
            echo "Failed to install socat. Cannot create tunnel."
            return
        fi
    fi

    read -p "🔸 Tunnel Port (e.g., 2078 - Must match the port on Iran Server): " TUNNEL_PORT
    [[ "$TUNNEL_PORT" == "back" ]] && return
    if ! [[ "$TUNNEL_PORT" =~ ^[0-9]+$ ]] || [ "$TUNNEL_PORT" -lt 1 ] || [ "$TUNNEL_PORT" -gt 65535 ]; then
        echo "Invalid port number. Please enter a number between 1 and 65535."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Choose Tunnel Protocol (tcp or udp): " PROTOCOL
    [[ "$PROTOCOL" == "back" ]] && return
    if [[ "$PROTOCOL" != "tcp" && "$PROTOCOL" != "udp" ]]; then
        echo "Invalid protocol. Please choose 'tcp' or 'udp'."
        press_enter_to_continue
        return
    fi

    # Create systemd service for the receiver
    SERVICE_NAME="exittunnel-receiver-${TUNNEL_PORT}-${PROTOCOL}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    
    mkdir -p "$TUNNEL_CONFIG_DIR"
    
    # Store config details for listing/deletion
    echo "${TUNNEL_PORT}:${PROTOCOL}" > "$TUNNEL_CONFIG_DIR/${SERVICE_NAME}.conf"


    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ExitTunnel Receiver TCP/UDP on Port ${TUNNEL_PORT}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/socat ${PROTOCOL}-LISTEN:${TUNNEL_PORT},fork SOCKS4:127.0.0.1:9050,socksclient,retry=3,timeout=10 # Assuming Tor's SOCKS port (9050) for internet access
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    log_action "✅ Receiver service config created: ${SERVICE_FILE}"

    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable "$SERVICE_NAME" --now > /dev/null 2>&1

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_action "✅ ExitTunnel Receiver (${PROTOCOL}) started on port ${TUNNEL_PORT} (Foreign Server)."
        echo "\n🎉 ExitTunnel Receiver on your Foreign Server is ready!"
        echo "--------------------------------------------------------------------------------"
        echo "  Foreign Server Details for Iran Server to connect to:"
        echo "  Server IP      : $(get_public_ipv4)"
        echo "  Tunnel Port    : ${TUNNEL_PORT}"
        echo "  Protocol       : ${PROTOCOL}"
        echo "--------------------------------------------------------------------------------"
        echo "IMPORTANT: Open port ${TUNNEL_PORT} (${PROTOCOL}) in your Foreign Server's firewall!"
        echo "  Also, ensure a local SOCKS proxy (e.g., Tor, Shadowsocks) is running on 127.0.0.1:9050 on this server."
        echo "  Otherwise, you might not have internet access through the tunnel."
    else
        log_action "❌ Failed to start ExitTunnel Receiver. Check logs with 'journalctl -u ${SERVICE_NAME} -f'."
        echo "❌ ExitTunnel Receiver failed to start."
        echo "   Check logs with 'journalctl -u ${SERVICE_NAME} -f'."
    fi
    press_enter_to_continue
}

# --- Tunnel Management Functions ---

# Lists existing tunnel configurations and offers deletion
function list_and_delete_tunnels() {
    echo "\n=== My ExitTunnel Configurations ==="
    local configs_found=0
    local i=1
    declare -A config_files_map # To map numbers to file paths
    declare -A service_names_map # To map numbers to service names

    mkdir -p "$TUNNEL_CONFIG_DIR" # Ensure config directory exists
    
    # List all tunnel config files
    for config_file in "$TUNNEL_CONFIG_DIR"/*.conf; do
        if [ -f "$config_file" ]; then
            configs_found=1
            local filename=$(basename "$config_file")
            local service_name=$(echo "$filename" | sed 's/\.conf$//')
            local role_display=""
            local details=""

            if [[ "$filename" == exittunnel-forwarder-*.conf ]]; then
                role_display="Iran Server (Forwarder)"
                local config_data=$(cat "$config_file" 2>/dev/null)
                local foreign_ip=$(echo "$config_data" | awk -F':' '{print $1}')
                local tunnel_port=$(echo "$config_data" | awk -F':' '{print $2}')
                local protocol=$(echo "$config_data" | awk -F':' '{print $3}')
                details="    - Forwarding to: ${foreign_ip}:${tunnel_port} (${protocol})"
            elif [[ "$filename" == exittunnel-receiver-*.conf ]]; then
                role_display="Foreign Server (Receiver)"
                local config_data=$(cat "$config_file" 2>/dev/null)
                local tunnel_port=$(echo "$config_data" | awk -F':' '{print $1}')
                local protocol=$(echo "$config_data" | awk -F':' '{print $2}')
                details="    - Listening on: ${tunnel_port} (${protocol})"
            fi

            config_files_map["$i"]="$config_file"
            service_names_map["$i"]="$service_name"
            
            echo -e "\n[$i] Role: ${role_display} | Service: ${service_name}"
            echo "    Path: ${config_file}"
            echo "${details}"
            echo "    Status: $(systemctl is-active "$service_name" 2>/dev/null || echo "inactive")"
            i=$((i+1))
        fi
    done

    if [ "$configs_found" -eq 0 ]; then
        echo "No ExitTunnel configurations found."
    else
        echo -e "\n-----------------------------------------"
        read -p "Enter the number of the tunnel config to delete, or 'back' to return: " TUNNEL_NUM_TO_DELETE
        [[ "$TUNNEL_NUM_TO_DELETE" =~ ^[bB][aA][cC][kK]$ ]] && return

        if [[ "$TUNNEL_NUM_TO_DELETE" =~ ^[0-9]+$ ]] && [ -n "${config_files_map[$TUNNEL_NUM_TO_DELETE]}" ]; then
            local file_to_delete="${config_files_map[$TUNNEL_NUM_TO_DELETE]}"
            local service_to_delete="${service_names_map[$TUNNEL_NUM_TO_DELETE]}"
            
            read -p "Are you sure you want to delete service '${service_to_delete}'? (y/N): " CONFIRM_DELETE
            [[ "$CONFIRM_DELETE" =~ ^[bB][aA][cC][kK]$ ]] && return

            if [[ "$CONFIRM_DELETE" =~ ^[yY]$ ]]; then
                log_action "🗑 Stopping and disabling service: ${service_to_delete}..."
                systemctl stop "$service_to_delete" > /dev/null 2>&1
                systemctl disable "$service_to_delete" > /dev/null 2>&1
                log_action "🗑 Deleting service file and config: ${service_to_delete}.service and ${file_to_delete}..."
                rm -f "/etc/systemd/system/${service_to_delete}.service"
                rm -f "$file_to_delete"
                systemctl daemon-reload > /dev/null 2>&1
                log_action "✅ Tunnel '${service_to_delete}' deleted successfully."
                echo "Tunnel '${service_to_delete}' deleted."
            else
                log_action "❌ Deletion cancelled by user."
                echo "Deletion cancelled."
            fi
        else
            echo "Invalid tunnel number. Please enter a valid number from the list or 'back'."
            log_action "Invalid tunnel number entered for deletion: $TUNNEL_NUM_TO_DELETE."
        fi
    fi
    press_enter_to_continue
}

# --- Service Status & Logs ---
function check_tunnel_status() {
    echo "\n=== ExitTunnel Service Status & Logs ==="
    local configs_found=0
    mkdir -p "$TUNNEL_CONFIG_DIR"

    for config_file in "$TUNNEL_CONFIG_DIR"/*.conf; do
        if [ -f "$config_file" ]; then
            configs_found=1
            local service_name=$(basename "$config_file" | sed 's/\.conf$//')
            echo -e "\n--- Service: ${service_name} ---"
            systemctl status "$service_name" --no-pager 2>/dev/null || echo "Service not found or inactive."
            echo "--- Last 5 Logs for ${service_name} ---"
            journalctl -u "$service_name" -n 5 --no-pager 2>/dev/null || echo "No logs found."
            echo "-----------------------------------"
        fi
    done

    if [ "$configs_found" -eq 0 ]; then
        echo "No ExitTunnel configurations found to check status."
    fi
    echo "========================================\n"
    press_enter_to_continue
}

# --- Main Menu Logic ---
function main_menu() {
    while true; do
        display_header
        echo "Select an option:"
        echo "1) Create New Tunnel"
        echo "2) List & Delete Tunnels"
        echo "3) Check Tunnel Status & Logs"
        echo "4) Uninstall Socat and Tunnel Configs" # Change to uninstall socat + tunnel
        echo "5) Exit"
        read -p "👉 Your choice: " CHOICE

        case $CHOICE in
            1)
                create_tunnel_menu
                ;;
            2)
                list_and_delete_tunnels
                ;;
            3)
                check_tunnel_status
                ;;
            4)
                # This should uninstall socat and all configs.
                # For simplicity, we just delete configs for now.
                # Actual socat uninstall depends on package manager.
                read -p "Are you sure you want to remove ALL tunnel configs and stop services? (y/N): " CONFIRM_CLEAN
                if [[ "$CONFIRM_CLEAN" =~ ^[yY]$ ]]; then
                    log_action "🗑 Stopping and deleting all ExitTunnel services and configs..."
                    for service_file in /etc/systemd/system/exittunnel-*.service; do
                        if [ -f "$service_file" ]; then
                            local service_name_to_stop=$(basename "$service_file" | sed 's/\.service$//')
                            systemctl stop "$service_name_to_stop" > /dev/null 2>&1
                            systemctl disable "$service_name_to_stop" > /dev/null 2>&1
                            rm -f "$service_file"
                            log_action "Stopped and removed service: $service_name_to_stop"
                        fi
                    done
                    rm -rf "$TUNNEL_CONFIG_DIR"
                    systemctl daemon-reload > /dev/null 2>&1
                    log_action "✅ All ExitTunnel configs removed and services stopped."
                    echo "All ExitTunnel configurations removed and services stopped. You may manually uninstall 'socat'."
                else
                    echo "Cleanup cancelled."
                fi
                press_enter_to_continue
                ;;
            5)
                log_action "Exiting script."
                echo "Exiting ExitTunnel Manager. Goodbye!"
                exit 0
                ;;
            *)
                echo "Invalid option. Please choose a number from the menu."
                press_enter_to_continue
                ;;
        esac
    done
}

# --- Tunnel Creation Sub-Menu ---
function create_tunnel_menu() {
    while true; do
        display_header
        echo "==== Create New Tunnel ===="
        echo "1) Configure this server as Iran Forwarder (for X-UI/Sanayi)"
        echo "2) Configure this server as Foreign Receiver (Internet Gateway)"
        echo "3) Back to Main Menu"
        read -p "👉 Your choice: " TUNNEL_CHOICE

        case $TUNNEL_CHOICE in
            1)
                create_iran_forwarder_tunnel
                ;;
            2)
                create_foreign_receiver_tunnel
                ;;
            3)
                return # Exit this sub-menu
                ;;
            *)
                echo "Invalid option. Please choose a number from the menu."
                press_enter_to_continue
                ;;
        esac
    done
}

# --- Start the script ---
main_menu
