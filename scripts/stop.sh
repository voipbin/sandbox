#!/bin/bash
# VoIPBin Sandbox - Stop Script
# Stops all services, preserves data
#
# Usage: sudo ./voipbin stop

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source common functions
source "$SCRIPT_DIR/common.sh"

show_usage() {
    echo "Usage: voipbin> stop"
    echo ""
    echo "Stops all VoIPBin sandbox services. Data is preserved in volumes."
    echo ""
    echo "For cleanup operations:"
    echo "  voipbin> clean --volumes   # Remove docker volumes"
    echo "  voipbin> clean --purge     # Remove .env, certs, configs"
    echo "  voipbin> clean --all       # Full reset to pre-init state"
    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

restore_dns() {
    # Restore original DNS configuration before stopping CoreDNS
    # This prevents internet from dropping when CoreDNS stops

    local os_type=$(detect_os)

    if [[ "$os_type" == "linux" ]]; then
        # Check if we modified resolv.conf (backup exists)
        if [[ -f "/etc/resolv.conf.voipbin-backup" ]]; then
            log_info "Restoring original DNS configuration..."
            cp /etc/resolv.conf.voipbin-backup /etc/resolv.conf
            log_info "  Restored /etc/resolv.conf from backup"
        fi
    elif [[ "$os_type" == "macos" ]]; then
        # macOS uses /etc/resolver directory - just remove our config
        if [[ -f "/etc/resolver/voipbin.test" ]]; then
            log_info "Removing macOS DNS resolver config..."
            rm -f /etc/resolver/voipbin.test
            log_info "  Removed /etc/resolver/voipbin.test"
        fi
    fi
}

main() {
    echo ""
    echo "=============================================="
    echo "  VoIPBin Sandbox - Stop"
    echo "=============================================="

    # Check for root (needed to restore DNS)
    if [[ $EUID -ne 0 ]]; then
        log_warn "Running without sudo - DNS configuration will not be restored"
        log_warn "Internet may be unavailable after stop. Run with sudo to avoid this."
        echo ""
    fi

    cd "$PROJECT_DIR"

    # Restore DNS before stopping CoreDNS to prevent internet dropout
    if [[ $EUID -eq 0 ]]; then
        log_step "Restoring DNS configuration..."
        restore_dns
    fi

    log_step "Stopping all services..."
    docker compose down

    echo ""
    echo "=============================================="
    echo "  Stopped"
    echo "=============================================="
    echo ""
    log_info "All services stopped. Data preserved in volumes."
    log_info "DNS restored to system default."
    log_info "Run 'start' to restart."
    echo ""
    log_info "For cleanup: voipbin> clean --help"
    echo ""
}

main "$@"
