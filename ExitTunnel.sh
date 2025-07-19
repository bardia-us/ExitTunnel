#!/bin/bash

# --- Script Metadata ---
SCRIPT_VERSION="2.0"
TELEGRAM_ID="@mr_bxs"
# -----------------------

LOG_FILE="/var/log/hysteria_manager.log"
HYSTERIA_CONFIG_DIR="/etc/hysteria" # Central directory for Hysteria configs
HYSTERIA_SERVICE_NAME="hysteria-server" # Common service name after get.hy2.sh install

# Function to get the server's public IPv4 address
function get_public_ip() {
    local ip=$(curl -s4 --connect-timeout 5 "http://ifconfig.me/ip" || \
               curl -s4 --connect-timeout 5 "http://ipecho.net/plain" || \
               curl -s4 --connect-timeout 5 "http://checkip.amazonaws.com" || \
               curl -s4 --connect-timeout 5 "http://icanhazip.com")
    echo "$ip"
}

function log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

function press_enter_to_continue() {
    echo -e "\nPress Enter to continue..."
    read -r
}

function display_script_info() {
    local server_ip=$(get_public_ip)
    echo "\n-----------------------------------------------------"
    echo " Hysteria Tunnel Manager (Foreign Server) "
    echo "-----------------------------------------------------"
    echo "Script Version : $SCRIPT_VERSION"
    echo "Telegram ID : $TELEGRAM_ID"
    echo "Current Server IPv4: ${server_ip:-(Could not get IP)}"
    echo "-----------------------------------------------------\n"
}

function install_hysteria() {
    log_action "📥 Installing Hysteria on this server..."
    if ! command -v curl &> /dev/null; then
        log_action "❌ Error: 'curl' is not installed. Please install it first (e.g., sudo apt install curl or sudo yum install curl)."
        press_enter_to_continue
        return 1
    fi

    bash <(curl -fsSL https://get.hy2.sh/)
    if [ $? -eq 0 ]; then
        log_action "✅ Hysteria installed successfully."
    else
        log_action "❌ Hysteria installation failed. Please check your internet connection and try again."
    fi
    press_enter_to_continue
}

function uninstall_hysteria() {
    echo "\n🗑 Uninstall Hysteria"
    read -p "Are you sure you want to uninstall Hysteria and remove all configs? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[bB][aA][cC][kK]$ ]] && return

    if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
        log_action "🗑 Stopping and disabling Hysteria service..."
        systemctl stop "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl stop hy2 > /dev/null 2>&1
        systemctl disable "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl disable hy2 > /dev/null 2>&1

        log_action "🗑 Removing Hysteria binary and configs..."
        rm -f /usr/local/bin/hy2 # Main binary
        rm -f /usr/local/bin/hysteria # Older binary name for compatibility
        rm -f "/etc/systemd/system/$HYSTERIA_SERVICE_NAME.service" # Systemd service file
        rm -f "/etc/systemd/system/hy2.service" # Another common service file name
        rm -rf "$HYSTERIA_CONFIG_DIR" # Remove config directory
        systemctl daemon-reload > /dev/null 2>&1 # Reload systemd
        log_action "✅ Hysteria uninstalled."
    else
        log_action "❌ Uninstallation cancelled."
    fi
    press_enter_to_continue
}

function generate_tls_cert() {
    log_action "🔑 Generating self-signed TLS certificate for Hysteria Server..."
    mkdir -p "$HYSTERIA_CONFIG_DIR"
    openssl genrsa -out "$HYSTERIA_CONFIG_DIR/ca.key" 2048 > /dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "$HYSTERIA_CONFIG_DIR/ca.key" -out "$HYSTERIA_CONFIG_DIR/ca.crt" -subj "/CN=Hysteria_Tunnel" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_action "❌ Failed to generate TLS certificate."
        return 1
    fi
    log_action "✅ TLS certificate generated."
    return 0
}

function configure_hysteria_server() {
    echo "\n🔧 Create New Hysteria Server Tunnel (Foreign Server)"
    echo "Type 'back' at any prompt to return to main menu."

    read -p "🔸 Tunnel Name (e.g., mytunnel_foreign_hy): " TUNNEL_NAME
    [[ "$TUNNEL_NAME" == "back" ]] && return

    read -p "🔸 Choose a Port for Hysteria Server (e.g., 443, 8443): " HY_PORT
    [[ "$HY_PORT" == "back" ]] && return

    read -p "🔸 Set a Strong Password for Hysteria: " HY_PASSWORD
    [[ "$HY_PASSWORD" == "back" ]] && return

    read -p "🔸 Tunnel Protocol (tcp or udp, default: udp): " HY_PROTOCOL
    HY_PROTOCOL=${HY_PROTOCOL:-udp} # Set default to udp
    [[ "$HY_PROTOCOL" == "back" ]] && return

    read -p "🔸 Choose an Obfuscation Password (optional, leave blank for no obfuscation): " OBFS_PASSWORD
    [[ "$OBFS_PASSWORD" == "back" ]] && return

    read -p "🔸 Do you want to use a custom SNI (e.g., google.com)? (Leave blank for default): " CUSTOM_SNI
    [[ "$CUSTOM_SNI" == "back" ]] && return

    if ! generate_tls_cert; then # Generate certs if not already done or failed
        press_enter_to_continue
        return 1
    fi

    HY_CONFIG_FILE="$HYSTERIA_CONFIG_DIR/${TUNNEL_NAME}_server.yaml"

    cat > "$HY_CONFIG_FILE" <<EOF
listen: :$HY_PORT
protocol: $HY_PROTOCOL
password: [$HY_PASSWORD]
tls:
  cert: $HYSTERIA_CONFIG_DIR/ca.crt
  key: $HYSTERIA_CONFIG_DIR/ca.key
EOF

    if [ -n "$CUSTOM_SNI" ]; then
        echo " sni: $CUSTOM_SNI" >> "$HY_CONFIG_FILE"
    fi

    if [ -n "$OBFS_PASSWORD" ]; then
        echo "obfs:" >> "$HY_CONFIG_FILE"
        echo " password: $OBFS_PASSWORD" >> "$HY_CONFIG_FILE"
    fi

    log_action "✅ Hysteria Server config created: $HY_CONFIG_FILE"
    
    # Reload systemd and restart Hysteria service
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl restart hy2 > /dev/null 2>&1

    if systemctl is-active --quiet "$HYSTERIA_SERVICE_NAME" || systemctl is-active --quiet hy2; then
        log_action "✅ Hysteria Server configured and running on port $HY_PORT."
        local server_ip=$(get_public_ip)
        echo "\n🎉 Hysteria Server is ready for direct connection from Iran!"
        echo "--------------------------------------------------------"
        echo " Server IP : ${server_ip:-(Your Server IP)}"
        echo " Port : $HY_PORT"
        echo " Password : $HY_PASSWORD"
        echo " Protocol : $HY_PROTOCOL"
        if [ -n "$OBFS_PASSWORD" ]; then
            echo " Obfuscation : $OBFS_PASSWORD"
        fi
        if [ -n "$CUSTOM_SNI" ]; then
            echo " Custom SNI : $CUSTOM_SNI"
        fi
        echo "--------------------------------------------------------"
        echo "IMPORTANT: Open port $HY_PORT in your server's firewall (e.g., ufw, firewalld)."
        echo "You can now connect to this server directly from clients in Iran (e.g., Xray/V2Ray with Hysteria protocol)."
    else
        log_action "❌ Failed to start Hysteria Server. Check logs with 'journalctl -u $HYSTERIA_SERVICE_NAME -f' or 'journalctl -u hy2 -f'."
    fi
    press_enter_to_continue
}

function create_tunnel_menu() {
    while true; do
        echo "\n==== Create New Tunnel ===="
        echo "1. Foreign Server (Hysteria Server)"
        echo "2. Iran Server (Xray/V2Ray Client to Foreign Hysteria - Not implemented in this script)"
        echo "3. Back to Main Menu"
        read -p "Choose an option: " CHOICE

        case $CHOICE in
            1)
                configure_hysteria_server
                ;;
            2)
                echo "This option is for the Iran server script and is not implemented here."
                press_enter_to_continue
                ;;
            3)
                return
                ;;
            *)
                echo "Invalid option."
                press_enter_to_continue
                ;;
        esac
    done
}


function list_tunnels() {
    echo "\n==== My Tunnel Configurations ===="
    local configs_found=0
    local i=1
    declare -A config_files_map # To map numbers to file paths

    for config_file in "$HYSTERIA_CONFIG_DIR"/*_server.yaml; do
        if [ -f "$config_file" ]; then
            configs_found=1
            local config_name=$(basename "$config_file" | sed 's/\.yaml$//')
            config_files_map["$i"]="$config_file"
            echo -e "[$i] Name: ${config_name}"
            echo " --- Details ---"
            grep -E "listen:|password:|protocol:|obfs:|sni:" "$config_file" | sed 's/^/ /'
            echo " ---------------"
            i=$((i+1))
        fi
    done

    if [ "$configs_found" -eq 0 ]; then
        echo "No Hysteria server configurations found."
    fi
    echo "=========================================\n"
    
    # If there are configs, offer deletion
    if [ "$configs_found" -gt 0 ]; then
        read -p "Do you want to delete a tunnel? (y/N/back): " DELETE_CHOICE
        [[ "$DELETE_CHOICE" =~ ^[bB][aA][cC][kK]$ ]] && return
        if [[ "$DELETE_CHOICE" =~ ^[yY]$ ]]; then
            read -p "Enter the number of the tunnel to delete (or 'back' to return): " TUNNEL_NUM
            [[ "$TUNNEL_NUM" =~ ^[bB][aA][cC][kK]$ ]] && return

            if [[ "$TUNNEL_NUM" =~ ^[0-9]+$ ]] && [ -n "${config_files_map[$TUNNEL_NUM]}" ]; then
                local file_to_delete="${config_files_map[$TUNNEL_NUM]}"
                local config_name_to_delete=$(basename "$file_to_delete" | sed 's/\.yaml$//')
                read -p "Are you sure you want to delete '$config_name_to_delete'? (y/N): " CONFIRM_DELETE
                [[ "$CONFIRM_DELETE" =~ ^[bB][aA][cC][kK]$ ]] && return
                if [[ "$CONFIRM_DELETE" =~ ^[yY]$ ]]; then
                    log_action "🗑 Deleting tunnel config: $file_to_delete"
                    rm -f "$file_to_delete"
                    log_action "✅ Tunnel '$config_name_to_delete' deleted successfully."
                    log_action "🔄 Restarting Hysteria service to apply changes..."
                    systemctl restart "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl restart hy2 > /dev/null 2>&1
                    if systemctl is-active --quiet "$HYSTERIA_SERVICE_NAME" || systemctl is-active --quiet hy2; then
                        log_action "✅ Hysteria service restarted with updated configs."
                    else
                        log_action "❌ Hysteria service failed to restart after config deletion. Check logs."
                    fi
                else
                    log_action "❌ Deletion cancelled."
                fi
            else
                echo "Invalid tunnel number."
                log_action "Invalid tunnel number entered for deletion."
            fi
        fi
    fi
    press_enter_to_continue
}


function check_status() {
    echo "\n==== Hysteria Service Status ===="
    systemctl status "$HYSTERIA_SERVICE_NAME" --no-pager || systemctl status hy2 --no-pager
    echo "\n==== Last 10 Hysteria Logs ===="
    journalctl -u "$HYSTERIA_SERVICE_NAME" -n 10 --no-pager || journalctl -u hy2 -n 10 --no-pager
    echo "==================================\n"
    press_enter_to_continue
}

function view_script_log() {
    echo "\n==== Script Log ===="
    if [ -f "$LOG_FILE" ]; then
        cat "$LOG_FILE"
    else
        echo "Log file not found: $LOG_FILE"
    fi
    echo "====================\n"
    press_enter_to_continue
}

function main_menu() {
    display_script_info

    while true; do
        echo "\n==== Main Menu ===="
        echo "1. Create New Tunnel"
        echo "2. My Tunnel Configurations & Delete" # Merged list and delete
        echo "3. Install Hysteria"
        echo "4. Uninstall Hysteria"
        echo "5. Check Hysteria Service Status"
        echo "6. View Script Log"
        echo "7. Exit"
        read -p "Choose an option: " CHOICE

        case $CHOICE in
            1)
                create_tunnel_menu
                ;;
            2)
                list_tunnels # Now handles both listing and deletion
                ;;
            3)
                install_hysteria
                ;;
            4)
                uninstall_hysteria
                ;;
            5)
                check_status
                ;;
            6)
                view_script_log
                ;;
            7)
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
