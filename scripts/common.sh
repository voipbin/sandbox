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
