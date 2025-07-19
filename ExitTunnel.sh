#!/bin/bash

# Xray configuration path
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
TUNNEL_UUID_FILE="/etc/xray/tunnel_params.conf" # File to store tunnel UUID and Path

# --- Helper Functions ---

# Generate UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# Save tunnel parameters
save_tunnel_params() {
    local uuid=$1
    local path=$2
    local port=$3
    echo "TUNNEL_UUID=$uuid" > "$TUNNEL_UUID_FILE"
    echo "TUNNEL_PATH=$path" >> "$TUNNEL_UUID_FILE"
    echo "TUNNEL_PORT=$port" >> "$TUNNEL_UUID_FILE"
    echo "PARAMS_SAVED=true" >> "$TUNNEL_UUID_FILE"
}

# Load tunnel parameters
load_tunnel_params() {
    if [ -f "$TUNNEL_UUID_FILE" ]; then
        source "$TUNNEL_UUID_FILE"
        echo "$TUNNEL_UUID,$TUNNEL_PATH,$TUNNEL_PORT" # Return as comma-separated
    else
        echo "" # Return empty string if file not found
    fi
}

# Check Xray status
check_xray_status() {
    if systemctl is-active --quiet xray; then
        echo "Xray is running."
    else
        echo "Xray is not running."
    fi
}

# Install Xray
install_xray() {
    echo "Installing Xray..."
    bash <(curl -Ls https://raw.githubusercontent.com/XrayR-project/XrayR-release/master/install.sh)
    sudo systemctl stop xray
    echo "Xray installed."
}

# --- Main Script Functions ---

# Create a new tunnel
create_tunnel() {
    echo "--- Creating New Tunnel ---"
    read -p "Server Role (iran_bridge / foreign_gateway): " SERVER_ROLE
    SERVER_ROLE=$(echo "$SERVER_ROLE" | tr '[:upper:]' '[:lower:]') # Convert to lowercase

    if [ "$SERVER_ROLE" != "iran_bridge" ] && [ "$SERVER_ROLE" != "foreign_gateway" ]; then
        echo "Invalid role. Please enter 'iran_bridge' or 'foreign_gateway'."
        return 1
    fi

    if [ "$SERVER_ROLE" == "foreign_gateway" ]; then
        echo "This server will act as the Gateway (Foreign)."
        read -p "Port for Xray (e.g., 2078): " XRAY_PORT
        if ! [[ "$XRAY_PORT" =~ ^[0-9]+$ ]]; then
            echo "Invalid port."
            return 1
        fi
        NEW_UUID=$(generate_uuid)
        read -p "Path for WSS (e.g., /mywsssecretpath): " WSS_PATH
        if [ -z "$WSS_PATH" ]; then
            echo "Path cannot be empty."
            return 1
        fi
        
        save_tunnel_params "$NEW_UUID" "$WSS_PATH" "$XRAY_PORT"

        # Xray config for Foreign Gateway
        cat > "$XRAY_CONFIG_PATH" <<EOF
{
  "log": {
    "loglevel": "info"
  },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$NEW_UUID",
            "flow": "none"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WSS_PATH"
        },
        "security": "none"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
        echo "Xray config for Gateway created."
        echo "Tunnel UUID: $NEW_UUID"
        echo "Tunnel Path: $WSS_PATH"
        echo "Xray Port: $XRAY_PORT"

    elif [ "$SERVER_ROLE" == "iran_bridge" ]; then
        echo "This server will act as the Bridge (Iran)."
        read -p "Foreign Gateway IP or Domain: " FOREIGN_SERVER_ADDR
        read -p "Foreign Gateway Port (Xray port set on Gateway): " FOREIGN_SERVER_PORT
        
        LOADED_PARAMS=$(load_tunnel_params)
        if [ -z "$LOADED_PARAMS" ]; then
            echo "!!! WARNING: Tunnel UUID, Path, or Port from Gateway not found on this server. Please run the script on the Gateway first, or manually enter the parameters. !!!"
            read -p "Tunnel UUID (from Gateway): " TUNNEL_UUID_VAL
            read -p "Tunnel Path (from Gateway): " TUNNEL_PATH_VAL
            read -p "Tunnel Port (from Gateway): " TUNNEL_PORT_VAL
        else
            IFS=',' read -r TUNNEL_UUID_VAL TUNNEL_PATH_VAL TUNNEL_PORT_VAL <<< "$LOADED_PARAMS"
            echo "Tunnel UUID, Path, and Port loaded from file: UUID=$TUNNEL_UUID_VAL, Path=$TUNNEL_PATH_VAL, Port=$TUNNEL_PORT_VAL"
        fi

        # UUID for client connection to Iran bridge (can be new)
        CLIENT_UUID=$(generate_uuid)
        read -p "Port for client connection to this server (e.g., 2078): " CLIENT_PORT

        # Xray config for Iran Bridge
        cat > "$XRAY_CONFIG_PATH" <<EOF
{
  "log": {
    "loglevel": "info"
  },
  "inbounds": [
    {
      "port": $CLIENT_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$CLIENT_UUID",
            "flow": "none"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/iran_bridge_path" // Default path for client connection
        },
        "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$FOREIGN_SERVER_ADDR",
            "port": $FOREIGN_SERVER_PORT,
            "users": [
              {
                "id": "$TUNNEL_UUID_VAL",
                "flow": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "allowInsecure": false,
          "servername": "$FOREIGN_SERVER_ADDR",
          "fingerprint": "chrome"
        },
        "wsSettings": {
          "path": "$TUNNEL_PATH_VAL"
        }
      },
      "tag": "proxy_foreign_tunnel"
    },
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "proxy_foreign_tunnel",
        "ip": [
          "0.0.0.0/0"
        ]
      },
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF
        echo "Xray config for Bridge created."
        echo "Client UUID for this server: $CLIENT_UUID"
        echo "Client Port: $CLIENT_PORT"
        echo "Foreign Gateway Address: $FOREIGN_SERVER_ADDR"
        echo "Foreign Gateway Port: $FOREIGN_SERVER_PORT"
        echo "WSS Tunnel UUID: $TUNNEL_UUID_VAL"
        echo "WSS Tunnel Path: $TUNNEL_PATH_VAL"
        
        # Client config for end-user
        LOCAL_IP=$(curl -s ifconfig.me)
        echo "--- Client Config for connecting to Iran Bridge (Vless WSS): ---"
        echo "vless://$CLIENT_UUID@$LOCAL_IP:$CLIENT_PORT?encryption=none&security=none&type=ws&host=$LOCAL_IP&path=%2Firan_bridge_path#Iran_Bridge_to_Freedom"
        echo "------------------------------------------------------"
    fi

    echo "Applying firewall rules..."
    if command -v ufw &> /dev/null; then
        sudo ufw allow "$XRAY_PORT"/tcp
        if [ "$SERVER_ROLE" == "iran_bridge" ]; then
            sudo ufw allow "$CLIENT_PORT"/tcp
        fi
        sudo ufw enable
        echo "UFW firewall configured."
    else
        echo "UFW not found. Please manually open port $XRAY_PORT (and $CLIENT_PORT if bridge) in your server's firewall."
    fi

    sudo systemctl restart xray
    sudo systemctl enable xray
    echo "Xray started and enabled."
    echo "Tunnel created successfully!"
}

# Delete tunnel
delete_tunnel() {
    echo "--- Deleting Tunnel ---"
    read -p "Are you sure you want to delete the tunnel and reset Xray? (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        sudo systemctl stop xray
        rm -f "$XRAY_CONFIG_PATH"
        rm -f "$TUNNEL_UUID_FILE"
        echo "Xray stopped, config file and tunnel parameters removed."
        echo "Xray and tunnel successfully deleted."
    else
        echo "Deletion cancelled."
    fi
}

# Show tunnel information
show_tunnels() {
    echo "--- Tunnel Information ---"
    if [ -f "$XRAY_CONFIG_PATH" ]; then
        echo "Xray config file found: $XRAY_CONFIG_PATH"
        echo "Config content:"
        cat "$XRAY_CONFIG_PATH"
        echo "---------------------"
    else
        echo "Xray config file not found."
    fi

    if [ -f "$TUNNEL_UUID_FILE" ]; then
        echo "Tunnel parameters file found: $TUNNEL_UUID_FILE"
        cat "$TUNNEL_UUID_FILE"
        echo "---------------------"
    fi
    check_xray_status
}

# Main menu
main_menu() {
    clear
    echo "--- Xray Tunnel Manager ---"
    echo "1. Create New Tunnel"
    echo "2. Delete Tunnel"
    echo "3. Show Tunnel Info"
    echo "4. Exit"
    read -p "Please choose an option: " choice

    case $choice in
        1) create_tunnel ;;
        2) delete_tunnel ;;
        3) show_tunnels ;;
        4) echo "Exiting script."; exit 0 ;;
        *) echo "Invalid option. Please choose between 1 and 4." ;;
    esac
    echo
    read -n 1 -s -r -p "Press any key to continue..."
    main_menu
}

# Check and install Xray if not found
if ! command -v xray &> /dev/null; then
    install_xray
fi

# Start menu
main_menu
