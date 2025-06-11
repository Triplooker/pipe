#!/bin/bash
set -e

ORANGE='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

BACKUP_DIR="/tmp/popnode_backup"
BACKUP_ARCHIVE="/tmp/popnode_backup_$(date +%Y%m%d_%H%M%S).tar.gz"

# ─── USAGE FUNCTION ────────────────────────────────────────────────────────
show_usage() {
    echo -e "${BLUE}Usage:${NC}"
    echo -e "  $0 install          - Fresh installation"
    echo -e "  $0 restore <file>   - Restore from backup archive"
    echo -e "  $0 backup           - Create backup only"
    echo ""
}

# ─── BACKUP FUNCTION ───────────────────────────────────────────────────────
create_backup() {
    echo -e "${ORANGE}📦 Creating backup...${NC}"
    
    if [[ ! -f "/opt/popcache/config.json" ]]; then
        echo -e "${RED}❌ No existing installation found to backup!${NC}"
        return 1
    fi
    
    mkdir -p "$BACKUP_DIR"
    
    # Copy important files
    cp /opt/popcache/config.json "$BACKUP_DIR/" 2>/dev/null || true
    cp /opt/popcache/.pop_state.json "$BACKUP_DIR/" 2>/dev/null || true
    cp /opt/popcache/.pop_state.json.bak "$BACKUP_DIR/" 2>/dev/null || true
    
    # Create archive
    tar -czf "$BACKUP_ARCHIVE" -C "$BACKUP_DIR" .
    rm -rf "$BACKUP_DIR"
    
    echo -e "${GREEN}✅ Backup created: $BACKUP_ARCHIVE${NC}"
    
    # Create temporary HTTP server for download
    create_download_link "$BACKUP_ARCHIVE"
}

# ─── CREATE DOWNLOAD LINK ──────────────────────────────────────────────────
create_download_link() {
    local file_path="$1"
    local filename=$(basename "$file_path")
    local port=8888
    
    echo -e "${ORANGE}🌐 Creating temporary download link...${NC}"
    
    # Find available port using ss or lsof instead of netstat
    while ss -ln 2>/dev/null | grep -q ":$port " || lsof -i :$port 2>/dev/null; do
        port=$((port + 1))
    done
    
    # Create temporary web server
    cd "$(dirname "$file_path")"
    
    echo -e "${GREEN}📁 Download your backup from:${NC}"
    echo -e "${BLUE}   http://$(curl -s https://ipinfo.io/ip):$port/$filename${NC}"
    echo -e "${ORANGE}⏰ Link will be available for 10 minutes${NC}"
    echo -e "${ORANGE}💡 Download the file and then press Ctrl+C to stop the server${NC}"
    echo ""
    echo -e "${GREEN}🔗 Direct download command:${NC}"
    echo -e "${BLUE}   wget http://$(curl -s https://ipinfo.io/ip):$port/$filename${NC}"
    echo ""
    
    # Start simple HTTP server with timeout in background
    (
        timeout 600 python3 -m http.server $port 2>/dev/null || \
        timeout 600 python -m SimpleHTTPServer $port 2>/dev/null
    ) &
    
    local server_pid=$!
    
    # Wait for user input or timeout
    echo -e "${ORANGE}Press Enter after downloading to continue, or wait 10 minutes for auto-timeout...${NC}"
    read -t 600 -p "" || true
    
    # Kill the server
    kill $server_pid 2>/dev/null || true
    wait $server_pid 2>/dev/null || true
    
    echo -e "${GREEN}✅ Download server stopped${NC}"
}

# ─── RESTORE FUNCTION ──────────────────────────────────────────────────────
restore_from_backup() {
    local backup_file="$1"
    
    if [[ ! -f "$backup_file" ]]; then
        echo -e "${RED}❌ Backup file not found: $backup_file${NC}"
        exit 1
    fi
    
    echo -e "${ORANGE}🔄 Restoring from backup: $backup_file${NC}"
    
    # Stop existing container
    docker stop popnode 2>/dev/null || true
    docker rm popnode 2>/dev/null || true
    
    # Clean existing installation
    if [[ -d "/opt/popcache" ]]; then
        sudo rm -rf /opt/popcache
    fi
    
    # Prepare directory
    sudo mkdir -p /opt/popcache
    cd /opt/popcache
    sudo chmod 777 /opt/popcache
    
    # Extract backup
    tar -xzf "$backup_file" -C /opt/popcache/
    
    # Download PoP binary
    echo -e "${ORANGE}⬇️ Downloading PoP binary...${NC}"
    wget -q https://download.pipe.network/static/pop-v0.3.2-linux-x64.tar.gz
    tar -xzf pop-v0.3.2-linux-*.tar.gz
    chmod 755 pop
    
    # Create Dockerfile
    create_dockerfile
    
    # Build and run
    build_and_run
    
    echo -e "${GREEN}✅ Restore completed successfully!${NC}"
    show_status
}

# ─── CHECK PREREQUISITES ───────────────────────────────────────────────────
check_prerequisites() {
    echo -e "${ORANGE}🔍 Checking for Docker installation...${NC}"
    if ! command -v docker &> /dev/null; then
        echo -e "${ORANGE}📦 Docker not found. Installing...${NC}"
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    else
        echo -e "${ORANGE}✅ Docker is already installed.${NC}"
    fi

    echo -e "${ORANGE}🔍 Checking for required packages...${NC}"
    if ! command -v jq &> /dev/null || ! command -v ss &> /dev/null; then
        echo -e "${ORANGE}📦 Installing required packages (jq, iproute2)...${NC}"
        sudo apt update && sudo apt install -y jq iproute2 wget curl
    else
        echo -e "${ORANGE}✅ Required packages are already installed.${NC}"
    fi
}

# ─── CHECK AND FREE PORTS ─────────────────────────────────────────────────
check_ports() {
    echo -e "${ORANGE}🔍 Checking if ports 80 and 443 are available...${NC}"
    for PORT in 80 443; do
        if lsof -i :$PORT &>/dev/null; then
            echo -e "${ORANGE}⚠️ Port $PORT is in use. Killing the process...${NC}"
            fuser -k ${PORT}/tcp || true
        else
            echo -e "${ORANGE}✅ Port $PORT is free.${NC}"
        fi
    done
}

# ─── SYSTEM TUNING ────────────────────────────────────────────────────────
apply_system_tuning() {
    echo -e "${ORANGE}📜 Applying system tuning...${NC}"
    cat <<EOF | sudo tee /etc/sysctl.d/99-popcache.conf
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.core.wmem_max = 16777216
net.core.rmem_max = 16777216
EOF

    sudo sysctl -p /etc/sysctl.d/99-popcache.conf

    cat <<EOF | sudo tee /etc/security/limits.d/popcache.conf
*    hard nofile 65535
*    soft nofile 65535
EOF
}

# ─── USER INPUT ───────────────────────────────────────────────────────────
get_user_input() {
    echo -e "${ORANGE}🧩 Let's configure your PoP Node...${NC}"
    read -p "Enter your POP name: " POP_NAME

    LOCATION=$(curl -s https://ipinfo.io/json | jq -r '.region + ", " + .country')
    echo -e "${ORANGE}🌍 Auto-detected location: $LOCATION${NC}"

    read -p "Enter memory cache size in MB (Default: 4096Mb Just click Enter): " MEMORY_MB
    MEMORY_MB=${MEMORY_MB:-4096}
    DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
    read -p "Enter disk cache size in GB [Default: 100Gb Just click Enter] (Free on server: $DISK_FREE): " DISK_GB
    DISK_GB=${DISK_GB:-100}

    read -p "Enter your node name (EN): " NODE_NAME
    read -p "Enter your name (EN): " NAME
    read -p "Enter your email: " EMAIL
    read -p "Enter your Discord username: " DISCORD
    read -p "Enter your Telegram username: " TELEGRAM
    read -p "Enter your Solana wallet address: " SOLANA
    read -p "Enter your POP_INVITE_CODE: " INVITE_CODE
    
    # Clean invite code from any JSON formatting
    INVITE_CODE=$(echo "$INVITE_CODE" | sed 's/.*"\([^"]*\)".*/\1/' | tr -d ' ,"')
}

# ─── CREATE CONFIG ────────────────────────────────────────────────────────
create_config() {
    cat <<EOF > config.json
{
  "pop_name": "$POP_NAME",
  "pop_location": "$LOCATION",
  "server": {
    "host": "0.0.0.0",
    "port": 443,
    "http_port": 80,
    "workers": 0
  },
  "cache_config": {
    "memory_cache_size_mb": $MEMORY_MB,
    "disk_cache_path": "./cache",
    "disk_cache_size_gb": $DISK_GB,
    "default_ttl_seconds": 86400,
    "respect_origin_headers": true,
    "max_cacheable_size_mb": 1024
  },
  "api_endpoints": {
    "base_url": "https://dataplane.pipenetwork.com"
  },
  "identity_config": {
    "node_name": "$NODE_NAME",
    "name": "$NAME",
    "email": "$EMAIL",
    "website": "https://your-website.com",
    "discord": "$DISCORD",
    "telegram": "$TELEGRAM",
    "solana_pubkey": "$SOLANA"
  }
}
EOF
}

# ─── CREATE DOCKERFILE ────────────────────────────────────────────────────
create_dockerfile() {
    cat <<EOF > Dockerfile
FROM ubuntu:24.04

RUN apt update && apt install -y \\
    ca-certificates \\
    curl \\
    libssl-dev \\
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/popcache

COPY pop .
COPY config.json .

RUN chmod +x ./pop

CMD ["./pop"]
EOF
}

# ─── BUILD AND RUN ─────────────────────────────────────────────────────────
build_and_run() {
    echo -e "${ORANGE}🔧 Applying file descriptor limit for current shell (ulimit)...${NC}"
    ulimit -n 65535 || echo -e "${ORANGE}⚠️ ulimit couldn't be changed. You may need to relogin.${NC}"

    echo -e "${ORANGE}🏗️ Building Docker image...${NC}"
    docker build -t popnode .

    echo -e "${ORANGE}🚀 Launching container...${NC}"
    docker run -d \
      --name popnode \
      -p 80:80 \
      -p 443:443 \
      -v /opt/popcache:/app \
      -w /app \
      -e POP_INVITE_CODE=$INVITE_CODE \
      --restart unless-stopped \
      popnode
}

# ─── SHOW STATUS ───────────────────────────────────────────────────────────
show_status() {
    IP=$(curl -s https://ipinfo.io/ip)
    echo -e "${GREEN}✅ Setup complete!${NC}"
    echo -e "${ORANGE}📦 View logs:${NC} docker logs -f popnode"
    echo -e "${ORANGE}🧪 Check health in browser:${NC} http://$IP/health"
    echo -e "${ORANGE}🔒 Check secure status:${NC} https://$IP/state"
    echo -e "${ORANGE}💾 Important files location:${NC} /opt/popcache/"
    echo -e "${ORANGE}📦 To change or view the configuration file:${NC} nano /opt/popcache/config.json"
}

# ─── FRESH INSTALLATION ───────────────────────────────────────────────────
fresh_install() {
    check_prerequisites
    check_ports
    apply_system_tuning
    get_user_input
    
    # Clean previous installation
    if [[ -d "/opt/popcache" ]]; then
        echo -e "${ORANGE}🧹 Removing existing /opt/popcache directory...${NC}"
        sudo rm -rf /opt/popcache
    fi

    # Prepare directory
    echo -e "${ORANGE}📁 Setting up /opt/popcache...${NC}"
    sudo mkdir -p /opt/popcache
    cd /opt/popcache
    sudo chmod 777 /opt/popcache

    # Download PoP binary
    echo -e "${ORANGE}⬇️ Downloading PoP binary...${NC}"
    wget -q https://download.pipe.network/static/pop-v0.3.2-linux-x64.tar.gz
    tar -xzf pop-v0.3.2-linux-*.tar.gz
    chmod 755 pop

    create_config
    create_dockerfile
    build_and_run
    
    show_status
    
    # Wait a bit for node to initialize
    echo -e "${ORANGE}⏳ Waiting for node to initialize (30 seconds)...${NC}"
    sleep 30
    
    # Create automatic backup
    echo -e "${ORANGE}🔄 Creating automatic backup...${NC}"
    create_backup
}

# ─── MAIN SCRIPT LOGIC ─────────────────────────────────────────────────────
case "${1:-install}" in
    "install")
        fresh_install
        ;;
    "restore")
        if [[ -z "$2" ]]; then
            echo -e "${RED}❌ Please provide backup file path${NC}"
            echo -e "${BLUE}Usage: $0 restore /path/to/backup.tar.gz${NC}"
            exit 1
        fi
        check_prerequisites
        check_ports
        apply_system_tuning
        restore_from_backup "$2"
        ;;
    "backup")
        create_backup
        ;;
    "-h"|"--help"|"help")
        show_usage
        ;;
    *)
        echo -e "${RED}❌ Unknown command: $1${NC}"
        show_usage
        exit 1
        ;;
esac
