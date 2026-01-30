#!/bin/bash
# VoIPBin Sandbox - Common Functions
# Shared utilities used by all sandbox scripts

# =============================================================================
# Script Path Setup
# =============================================================================
# These should be set by the sourcing script before sourcing this file:
# SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# =============================================================================
# Colors
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Logging Functions
# =============================================================================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}==>${NC} $1"
}

# =============================================================================
# Root Check
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo ""
        log_error "This script must be run with sudo"
        echo ""
        echo "  sudo $0"
        echo ""
        exit 1
    fi
}

# =============================================================================
# Host IP Detection
# =============================================================================
detect_host_ip() {
    local ip=""

    # Try to get from .env first
    if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/.env" ]]; then
        ip=$(grep '^HOST_EXTERNAL_IP=' "$PROJECT_DIR/.env" 2>/dev/null | cut -d'=' -f2 | head -1)
    fi

    # Fallback: Try to get the IP of the default route interface
    if [[ -z "$ip" ]]; then
        if command -v ip &> /dev/null; then
            ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
        fi
    fi

    # Fallback: get first non-localhost IP
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # macOS fallback
    if [[ -z "$ip" ]]; then
        ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
    fi

    # Final fallback
    if [[ -z "$ip" ]]; then
        ip="127.0.0.1"
    fi

    echo "$ip"
}

# Detect current host IP (fresh detection, ignores .env)
detect_current_host_ip() {
    local ip=""

    # Try to get the IP of the default route interface
    if command -v ip &> /dev/null; then
        ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    fi

    # Fallback: get first non-localhost IP
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # macOS fallback
    if [[ -z "$ip" ]]; then
        ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
    fi

    # Final fallback
    if [[ -z "$ip" ]]; then
        ip="127.0.0.1"
    fi

    echo "$ip"
}

# Get configured host IP from .env
get_configured_host_ip() {
    if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/.env" ]]; then
        grep '^HOST_EXTERNAL_IP=' "$PROJECT_DIR/.env" 2>/dev/null | cut -d'=' -f2 | head -1
    fi
}

# Check if host IP has changed from .env configuration
# Returns 0 if changed, 1 if same
check_ip_changed() {
    local current_ip=$(detect_current_host_ip)
    local configured_ip=$(get_configured_host_ip)

    if [[ -z "$configured_ip" ]]; then
        # No .env or no configured IP
        return 0
    fi

    if [[ "$current_ip" != "$configured_ip" ]]; then
        return 0  # Changed
    fi

    return 1  # Same
}

# Generate secondary IPs (Kamailio, RTPEngine) based on host IP
# Ensures they are in the same subnet but different from host
generate_secondary_ips() {
    local host_ip="$1"
    local prefix=$(echo "$host_ip" | cut -d'.' -f1-3)
    local host_last=$(echo "$host_ip" | cut -d'.' -f4)

    # Calculate base offset: host_last + 8 (with wrap-around)
    local base=$((host_last + 8))
    if [[ $base -gt 250 ]]; then
        base=$((host_last - 50))
        if [[ $base -lt 2 ]]; then
            base=160
        fi
    fi

    echo "KAMAILIO_EXTERNAL_IP=${prefix}.${base}"
    echo "RTPENGINE_EXTERNAL_IP=${prefix}.$((base + 1))"
}

# Update .env with new IPs
update_env_ips() {
    local new_host_ip="$1"
    local env_file="${PROJECT_DIR}/.env"

    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found"
        return 1
    fi

    # Generate new secondary IPs
    local secondary_ips=$(generate_secondary_ips "$new_host_ip")
    local new_kamailio_ip=$(echo "$secondary_ips" | grep KAMAILIO | cut -d'=' -f2)
    local new_rtpengine_ip=$(echo "$secondary_ips" | grep RTPENGINE | cut -d'=' -f2)

    log_info "Updating .env with new IPs:"
    log_info "  HOST_EXTERNAL_IP: $new_host_ip"
    log_info "  KAMAILIO_EXTERNAL_IP: $new_kamailio_ip"
    log_info "  RTPENGINE_EXTERNAL_IP: $new_rtpengine_ip"

    # Update .env file
    sed -i "s|^HOST_EXTERNAL_IP=.*|HOST_EXTERNAL_IP=$new_host_ip|" "$env_file"
    sed -i "s|^KAMAILIO_EXTERNAL_IP=.*|KAMAILIO_EXTERNAL_IP=$new_kamailio_ip|" "$env_file"
    sed -i "s|^RTPENGINE_EXTERNAL_IP=.*|RTPENGINE_EXTERNAL_IP=$new_rtpengine_ip|" "$env_file"

    # Also update frontend URLs that use the host IP
    sed -i "s|^API_URL=.*|API_URL=https://api.voipbin.test:8443/|" "$env_file"
    sed -i "s|^WEBSOCKET_URL=.*|WEBSOCKET_URL=wss://api.voipbin.test:8443/v1.0/ws|" "$env_file"

    echo "$new_kamailio_ip"
}

# Regenerate SSL certificates with new IP and update .env
regenerate_ssl_certs() {
    local new_host_ip="$1"
    local env_file="${PROJECT_DIR}/.env"
    local cert_dir="${PROJECT_DIR}/certs/api"

    # Check if mkcert is available
    if ! command -v mkcert &> /dev/null; then
        log_warn "mkcert not installed, skipping certificate regeneration"
        log_warn "Install mkcert for automatic certificate updates: sudo apt install mkcert && mkcert -install"
        return 1
    fi

    # Create cert directory if needed
    mkdir -p "$cert_dir"

    log_info "Regenerating SSL certificate for IP: $new_host_ip"

    # Generate new certificate
    mkcert -cert-file "$cert_dir/cert.pem" -key-file "$cert_dir/privkey.pem" \
        "voipbin.test" "*.voipbin.test" "localhost" "127.0.0.1" "::1" "$new_host_ip" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to generate certificate"
        return 1
    fi

    # Update base64-encoded certificates in .env
    if [[ -f "$env_file" ]]; then
        local new_cert_b64=$(base64 -w0 "$cert_dir/cert.pem")
        local new_key_b64=$(base64 -w0 "$cert_dir/privkey.pem")

        sed -i "s|^API_SSL_CERT_BASE64=.*|API_SSL_CERT_BASE64=$new_cert_b64|" "$env_file"
        sed -i "s|^API_SSL_PRIVKEY_BASE64=.*|API_SSL_PRIVKEY_BASE64=$new_key_b64|" "$env_file"
        # Hook certs use the same as API certs
        sed -i "s|^HOOK_SSL_CERT_BASE64=.*|HOOK_SSL_CERT_BASE64=$new_cert_b64|" "$env_file"
        sed -i "s|^HOOK_SSL_PRIVKEY_BASE64=.*|HOOK_SSL_PRIVKEY_BASE64=$new_key_b64|" "$env_file"

        log_info "SSL certificate regenerated and .env updated"
    fi

    return 0
}

# Full IP regeneration: detect current IP, update .env, regenerate CoreDNS and certs
regenerate_ip_config() {
    local current_ip=$(detect_current_host_ip)
    local configured_ip=$(get_configured_host_ip)

    if [[ "$current_ip" == "$configured_ip" ]]; then
        log_info "Host IP unchanged: $current_ip"
        return 1
    fi

    log_warn "Host IP changed: $configured_ip -> $current_ip"

    # Update .env and get new Kamailio IP
    local new_kamailio_ip=$(update_env_ips "$current_ip")

    # Regenerate CoreDNS config
    generate_coredns_config "$current_ip" "$PROJECT_DIR/config/coredns" "$new_kamailio_ip"
    log_info "CoreDNS configuration regenerated"

    # Regenerate SSL certificates
    regenerate_ssl_certs "$current_ip"

    return 0
}

# =============================================================================
# CoreDNS Configuration
# =============================================================================
# Fixed IPs for specific services (on default bridge network 10.100.0.0/16)
API_MANAGER_IP="10.100.0.100"
ADMIN_IP="10.100.0.101"
MEET_IP="10.100.0.102"
TALK_IP="10.100.0.103"

generate_coredns_config() {
    local host_ip="$1"
    local config_dir="${2:-$PROJECT_DIR/config/coredns}"
    local kamailio_ip="${3:-$host_ip}"  # Kamailio needs dedicated IP for SIP
    local corefile="$config_dir/Corefile"

    # Create directory
    mkdir -p "$config_dir"

    # Remove if it's a directory (Docker creates dir if file doesn't exist at mount time)
    if [[ -d "$corefile" ]]; then
        rm -rf "$corefile"
    fi

    cat > "$corefile" << EOF
# CoreDNS configuration for VoIPBin Sandbox
# Auto-generated - do not edit directly
#
# Web Services (resolve to host IP, Docker port mapping handles routing):
#   http://admin.voipbin.test       -> $host_ip:80
#   https://api.voipbin.test        -> $host_ip:8443
#   http://meet.voipbin.test:3004   -> $host_ip:3004
#   http://talk.voipbin.test:3005   -> $host_ip:3005
#
# SIP Services (resolve to Kamailio's dedicated external IP):
#   sip.voipbin.test                -> $kamailio_ip
#   pstn.voipbin.test               -> $kamailio_ip
#   trunk.voipbin.test              -> $kamailio_ip
#   *.registrar.voipbin.test        -> $kamailio_ip

# Web services - resolve to host IP (Docker handles port mapping)
api.voipbin.test {
    template IN A {
        answer "api.voipbin.test 60 IN A $host_ip"
    }
    template IN AAAA {
        rcode NOERROR
    }
}

admin.voipbin.test {
    template IN A {
        answer "admin.voipbin.test 60 IN A $host_ip"
    }
    template IN AAAA {
        rcode NOERROR
    }
}

meet.voipbin.test {
    template IN A {
        answer "meet.voipbin.test 60 IN A $host_ip"
    }
    template IN AAAA {
        rcode NOERROR
    }
}

talk.voipbin.test {
    template IN A {
        answer "talk.voipbin.test 60 IN A $host_ip"
    }
    template IN AAAA {
        rcode NOERROR
    }
}

# SIP services and catch-all - resolve to Kamailio's dedicated IP
voipbin.test {
    template IN A {
        answer "{{ .Name }} 60 IN A $kamailio_ip"
    }
    template IN AAAA {
        rcode NOERROR
    }
}

. {
    forward . 8.8.8.8 8.8.4.4
    cache 30
}
EOF
}

# =============================================================================
# OS Detection
# =============================================================================
detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}
