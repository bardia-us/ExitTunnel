#!/bin/bash

# --- Script Metadata ---
SCRIPT_VERSION="1.4"
TELEGRAM_ID="@mr_bxs"
# -----------------------

LOG_FILE="/var/log/hysteria_reverse_tunnel.log"
HYSTERIA_CONFIG_DIR="/etc/hysteria" # Central directory for Hysteria configs

# Function to get the server's public IPv4 address
function get_public_ip() {
    local ip=$(curl -s4 "http://ifconfig.me/ip" || \
               curl -s4 "http://ipecho.net/plain" || \
               curl -s4 "http://checkip.amazonaws.com" || \
               curl -s4 "http://icanhazip.com")
    echo "$ip"
}

function log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

function press_enter_to_continue() {
    echo -e "\nPress Enter to continue..."
    read -r
}

function display_info() {
    local server_ip=$(get_public_ip)
    echo "\n-----------------------------------------------------"
    echo " Hysteria Reverse Tunnel Manager "
    echo "-----------------------------------------------------"
    echo "Script Version: $SCRIPT_VERSION"
    echo "Telegram ID : $TELEGRAM_ID"
    echo "Current Server IPv4: ${server_ip:-(Could not get IP)}"
    echo "-----------------------------------------------------\n"
}

function install_hysteria() {
    log_action "📥 Installing Hysteria (v1/v2 compatible) on this server..."
    if ! command -v curl &> /dev/null; then
        log_action "❌ curl is not installed. Please install it first (e.g., sudo apt install curl or sudo yum install curl)."
        press_enter_to_continue
        return 1
    fi

    bash <(curl -fsSL https://get.hy2.sh/) # This script now installs Hysteria 2.x, which is backward compatible for most features.
    if [ $? -eq 0 ]; then
        log_action "✅ Hysteria installed successfully."
    else
        log_action "❌ Hysteria installation failed. Please check your internet connection and try again."
        press_enter_to_continue
        return 1
    fi
    press_enter_to_continue
}

function configure_server_iran() {
    echo "\n🔧 Configuring this server as Hysteria Server (for Iran / Border Server)"
    echo "Type 'back' at any prompt to return to main menu."

    read -p "🔸 Tunnel Name (e.g., mytunnel_iran): " TUNNEL_NAME
    [[ "$TUNNEL_NAME" == "back" ]] && return

    read -p "🔸 Foreign Server IP (The public IP of your server outside Iran): " FOREIGN_IP
    [[ "$FOREIGN_IP" == "back" ]] && return

    read -p "🔸 Tunnel Protocol (tcp or udp): " TUNNEL_PROTOCOL
    [[ "$TUNNEL_PROTOCOL" == "back" ]] && return

    read -p "🔸 Port for Hysteria communication between Iran and Foreign Server: " TUNNEL_PORT
    [[ "$TUNNEL_PORT" == "back" ]] && return

    read -p "🔸 Tunnel Password (Strong recommended): " TUNNEL_PASSWORD
    [[ "$TUNNEL_PASSWORD" == "back" ]] && return

    read -p "🔸 Port for End Users (e.g., X-UI/V2Ray to connect to this Hysteria Server): " CLIENT_PORT
    [[ "$CLIENT_PORT" == "back" ]] && return

    # Ensure config directory exists
    mkdir -p "$HYSTERIA_CONFIG_DIR"

    HYSTERIA_CONFIG_FILE="$HYSTERIA_CONFIG_DIR/${TUNNEL_NAME}_server_iran.yaml"

    # Hysteria config for server in Iran (Client for the actual tunnel, but acts as a server to users)
    cat > "$HYSTERIA_CONFIG_FILE" <<EOF
# Hysteria Server config for Iran (receives traffic from X-UI and forwards to foreign client)
listen: :$CLIENT_PORT
protocol: $TUNNEL_PROTOCOL
password: [$TUNNEL_PASSWORD]
# Uncomment and configure TLS if you want client-to-Iran-server traffic to be TLS-encrypted
# tls:
# cert: /path/to/your/iran_server.crt
# key: /path/to/your/iran_server.key

# Forward traffic through the tunnel to the foreign server acting as Hysteria Client
forward:
  type: $TUNNEL_PROTOCOL
  server: $FOREIGN_IP:$TUNNEL_PORT
EOF

    log_action "✅ Hysteria Server config created: $HYSTERIA_CONFIG_FILE"
    
    # Restart Hysteria service to load new config
    # Note: Hysteria 2.x uses `hysteria-server` or `hy2` service name
    # We will assume `hysteria-server` is the common one after `get.hy2.sh` script.
    systemctl restart hysteria-server || systemctl restart hy2 || log_action "❌ Failed to restart Hysteria service. Check service name."

    if systemctl is-active --quiet hysteria-server || systemctl is-active --quiet hy2; then
        log_action "✅ Hysteria Server (Iran) configured and running."
        echo "\n🎉 Hysteria Server on Iran side is ready!"
        echo "------------------------------------"
        echo "Configure your X-UI or V2Ray on this server to listen on port: $CLIENT_PORT"
        echo "X-UI/V2Ray will then forward traffic to Hysteria."
        echo "REMEMBER to open port $CLIENT_PORT in your server's firewall in Iran."
        echo "------------------------------------"
    else
        log_action "❌ Failed to start Hysteria Server (Iran). Check logs with 'journalctl -u hysteria-server -f' or 'journalctl -u hy2 -f'."
    fi
    press_enter_to_continue
}


function configure_client_foreign() {
    echo "\n🔧 Configuring this server as Hysteria Client (for Foreign Server)"
    echo "Type 'back' at any prompt to return to main menu."

    read -p "🔸 Tunnel Name (e.g., mytunnel_foreign): " TUNNEL_NAME
    [[ "$TUNNEL_NAME" == "back" ]] && return

    read -p "🔸 Port that this Foreign Hysteria Client should listen on (This is the port Iran server connects to): " TUNNEL_PORT
    [[ "$TUNNEL_PORT" == "back" ]] && return

    read -p "🔸 Tunnel Password (Must match the one set on Iran server): " TUNNEL_PASSWORD
    [[ "$TUNNEL_PASSWORD" == "back" ]] && return

    read -p "🔸 Tunnel Protocol (tcp or udp): " TUNNEL_PROTOCOL
    [[ "$TUNNEL_PROTOCOL" == "back" ]] && return

    # Ensure config directory exists
    mkdir -p "$HYSTERIA_CONFIG_DIR"

    HYSTERIA_CONFIG_FILE="$HYSTERIA_CONFIG_DIR/${TUNNEL_NAME}_client_foreign.yaml"

    # Hysteria config for client in Foreign server (receives tunnel traffic from Iran server)
    cat > "$HYSTERIA_CONFIG_FILE" <<EOF
# Hysteria Client config for Foreign server (receives tunnel traffic from Iran server)
listen: 0.0.0.0:$TUNNEL_PORT
protocol: $TUNNEL_PROTOCOL
password: [$TUNNEL_PASSWORD]
# Uncomment and configure TLS if you want Iran-server-to-client traffic to be TLS-encrypted
# tls:
# cert: /path/to/your/foreign_server.crt
# key: /path/to/your/foreign_server.key
EOF

    log_action "✅ Hysteria Client config created: $HYSTERIA_CONFIG_FILE"

    # Restart Hysteria service to load new config
    systemctl restart hysteria-server || systemctl restart hy2 || log_action "❌ Failed to restart Hysteria service. Check service name."

    if systemctl is-active --quiet hysteria-server || systemctl is-active --quiet hy2; then
        log_action "✅ Hysteria Client (Foreign) configured and running."
        echo "\n🎉 Hysteria Client on Foreign side is ready!"
        echo "------------------------------------"
        echo "REMEMBER to open port $TUNNEL_PORT in your server's firewall in Foreign."
        echo "------------------------------------"
    else
        log_action "❌ Failed to start Hysteria Client (Foreign). Check logs with 'journalctl -u hysteria-server -f' or 'journalctl -u hy2 -f'."
    fi
    press_enter_to_continue
}

function list_tunnels() {
    echo "\n==== Hysteria Tunnel Configurations ===="
    local configs_found=0
    
    # List server configs (Iran role)
    for config_file in "$HYSTERIA_CONFIG_DIR"/*_server_iran.yaml; do
        if [ -f "$config_file" ]; then
            configs_found=1
            echo -e "\n--- Server (Iran) Config: $(basename "$config_file") ---"
            cat "$config_file"
        fi
    done

    # List client configs (Foreign role)
    for config_file in "$HYSTERIA_CONFIG_DIR"/*_client_foreign.yaml; do
        if [ -f "$config_file" ]; then
            configs_found=1
            echo -e "\n--- Client (Foreign) Config: $(basename "$config_file") ---"
            cat "$config_file"
        fi
    done

    if [ "$configs_found" -eq 0 ]; then
        echo "No Hysteria tunnel configurations found in $HYSTERIA_CONFIG_DIR."
    fi
    echo "=========================================\n"
    press_enter_to_continue
}


function check_status() {
    echo "\n==== Hysteria Service Status ===="
    systemctl status hysteria-server --no-pager || systemctl status hy2 --no-pager
    echo "\n==== Last 10 Hysteria Logs ===="
    journalctl -u hysteria-server -n 10 --no-pager || journalctl -u hy2 -n 10 --no-pager
    echo "==================================\n"
    press_enter_to_continue
}

function delete_tunnel_config() {
    echo "\n🗑 Delete Hysteria Tunnel Configuration"
    echo "Type 'back' at any prompt to return to main menu."

    read -p "🔸 Enter the full name of the config file to delete (e.g., mytunnel_iran.yaml or mytunnel_foreign.yaml): " CONFIG_TO_DELETE
    [[ "$CONFIG_TO_DELETE" == "back" ]] && return

    local CONFIG_PATH="$HYSTERIA_CONFIG_DIR/$CONFIG_TO_DELETE"

    if [ -f "$CONFIG_PATH" ]; then
        read -p "Are you sure you want to delete $CONFIG_PATH? (y/N): " CONFIRM
        [[ "$CONFIRM" == "back" ]] && return

        if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
            log_action "🗑 Deleting config file: $CONFIG_PATH"
            rm -f "$CONFIG_PATH"
            log_action "✅ Config $CONFIG_TO_DELETE deleted."
            
            # Restart Hysteria service if no other configs are active or for cleanup
            log_action "🔄 Restarting Hysteria service to apply changes..."
            systemctl restart hysteria-server || systemctl restart hy2 || log_action "❌ Failed to restart Hysteria service."
        else
            log_action "❌ Deletion cancelled."
        fi
    else
        log_action "❌ Config file not found: $CONFIG_PATH"
    fi
    press_enter_to_continue
}

function uninstall_hysteria() {
    read -p "🗑 Are you sure you want to uninstall Hysteria and remove all configs? (y/N): " CONFIRM
    [[ "$CONFIRM" == "back" ]] && return

    if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
        log_action "🗑 Stopping and disabling Hysteria service..."
        systemctl stop hysteria-server > /dev/null 2>&1
        systemctl disable hysteria-server > /dev/null 2>&1
        systemctl stop hy2 > /dev/null 2>&1 # Try both service names
        systemctl disable hy2 > /dev/null 2>&1

        log_action "🗑 Removing Hysteria binary and configs..."
        rm -f /usr/local/bin/hy2 # Main binary
        rm -f /usr/local/bin/hysteria # Older binary name
        rm -f /etc/systemd/system/hysteria-server.service # Systemd service file
        rm -f /etc/systemd/system/hy2.service # Another common service file name
        rm -rf "$HYSTERIA_CONFIG_DIR" # Remove config directory
        systemctl daemon-reload > /dev/null 2>&1 # Reload systemd
        log_action "✅ Hysteria uninstalled."
    else
        log_action "❌ Uninstallation cancelled."
    fi
    press_enter_to_continue
}

function main_menu() {
    display_info # Display script info at the start

    while true; do
        echo "\n==== Hysteria Reverse Tunnel Options ===="
        echo "1. Install Hysteria on this server"
        echo "2. Configure this server as Hysteria Server (for Iran / Border)"
        echo "3. Configure this server as Hysteria Client (for Foreign Server)"
        echo "4. List Active Tunnel Configurations"
        echo "5. Check Hysteria Service Status"
        echo "6. Delete a Tunnel Configuration"
        echo "7. Uninstall Hysteria"
        echo "8. View Script Log"
        echo "9. Exit"
        read -p "Choose an option: " CHOICE

        case $CHOICE in
            1)
                install_hysteria
                ;;
            2)
                configure_server_iran
                ;;
            3)
                configure_client_foreign
                ;;
            4)
                list_tunnels
                ;;
            5)
                check_status
                ;;
            6)
                delete_tunnel_config
                ;;
            7)
                uninstall_hysteria
                ;;
            8)
                cat "$LOG_FILE"
                press_enter_to_continue
                ;;
            9)
                exit 0
                ;;
            *)
                echo "Invalid option."
                press_enter_to_continue
                ;;
        esac
    done
}

main_menu
