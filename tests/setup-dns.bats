#!/usr/bin/env bats
# Tests for scripts/setup-dns.sh

load 'test_helper'

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# =============================================================================
# Helper to load setup-dns.sh functions
# =============================================================================

load_dns_functions() {
    # Source common.sh first (setup-dns.sh depends on it)
    source "$SCRIPTS_DIR/common.sh"

    # Extract functions from setup-dns.sh (up to main "$@")
    local temp_dns="$TEST_TEMP_DIR/dns_functions.sh"

    sed -n '1,/^main "\$@"/p' "$SCRIPTS_DIR/setup-dns.sh" | \
        sed -e '$d' \
            -e 's/^set -e$/# set -e  # disabled for testing/' \
            -e 's|source "\$SCRIPT_DIR/common.sh"|# common.sh already sourced|' \
            -e 's|^PROJECT_DIR=.*|# PROJECT_DIR overridden by test|' > "$temp_dns"

    source "$temp_dns"

    # Override paths to use test environment (after sourcing to ensure they stick)
    SCRIPT_DIR="$SCRIPTS_DIR"
    PROJECT_DIR="$TEST_TEMP_DIR"
}

# =============================================================================
# check_coredns() tests
# =============================================================================

@test "check_coredns returns 0 when voipbin-dns container is running" {
    mock_command_script "docker" '
if [[ "$1" == "ps" ]]; then
    echo "voipbin-dns"
    echo "voipbin-db"
fi
'
    load_dns_functions

    run check_coredns

    [[ "$status" -eq 0 ]]
}

@test "check_coredns returns 1 when voipbin-dns container is not running" {
    mock_command_script "docker" '
if [[ "$1" == "ps" ]]; then
    echo "voipbin-db"
    echo "voipbin-redis"
fi
'
    load_dns_functions

    run check_coredns

    [[ "$status" -eq 1 ]]
}

@test "check_coredns returns 1 when docker fails" {
    mock_command "docker" "" 1
    load_dns_functions

    run check_coredns

    [[ "$status" -eq 1 ]]
}

# =============================================================================
# regenerate_corefile() tests
# =============================================================================

@test "regenerate_corefile creates CoreDNS config directory" {
    mock_command_script "docker" 'exit 1'  # CoreDNS not running
    load_dns_functions

    local config_dir="$PROJECT_DIR/config/coredns"

    regenerate_corefile "192.168.1.100" 2>/dev/null || true

    [[ -d "$config_dir" ]]
}

@test "regenerate_corefile reads KAMAILIO_EXTERNAL_IP from .env" {
    mock_command_script "docker" 'exit 1'  # CoreDNS not running
    create_env_file "KAMAILIO_EXTERNAL_IP=10.0.0.200"
    load_dns_functions

    regenerate_corefile "192.168.1.100" 2>/dev/null || true

    # Should use the kamailio IP from .env for SIP services
    assert_file_contains "$PROJECT_DIR/config/coredns/Corefile" "10.0.0.200"
}

@test "regenerate_corefile uses host_ip when KAMAILIO_EXTERNAL_IP not in .env" {
    mock_command_script "docker" 'exit 1'  # CoreDNS not running
    create_env_file "OTHER_VAR=value"
    load_dns_functions

    regenerate_corefile "192.168.1.100" 2>/dev/null || true

    # Should use host_ip as fallback for kamailio_ip
    assert_file_contains "$PROJECT_DIR/config/coredns/Corefile" "192.168.1.100"
}

# =============================================================================
# Script structure tests
# =============================================================================

@test "setup-dns.sh defines setup_linux function" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "setup_linux()"
}

@test "setup-dns.sh defines setup_macos function" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "setup_macos()"
}

@test "setup-dns.sh defines uninstall_linux function" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "uninstall_linux()"
}

@test "setup-dns.sh defines uninstall_macos function" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "uninstall_macos()"
}

@test "setup-dns.sh defines test_dns function" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "test_dns()"
}

@test "setup-dns.sh sources common.sh" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" 'source "$SCRIPT_DIR/common.sh"'
}

# =============================================================================
# Linux DNS configuration tests
# =============================================================================

@test "setup-dns.sh configures resolv.conf to use 127.0.0.1 on Linux" {
    # Verify the script writes nameserver 127.0.0.1 for CoreDNS
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "nameserver 127.0.0.1"
}

@test "setup-dns.sh backs up resolv.conf before modifying" {
    # Verify backup mechanism exists
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "RESOLV_BACKUP"
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "/etc/resolv.conf.voipbin-backup"
}

@test "setup-dns.sh restores resolv.conf on uninstall" {
    # Verify restore mechanism exists
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" 'cp "$RESOLV_BACKUP"'
}

# =============================================================================
# macOS DNS configuration tests
# =============================================================================

@test "setup-dns.sh creates /etc/resolver directory on macOS" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "mkdir -p /etc/resolver"
}

@test "setup-dns.sh creates resolver file for voipbin.test on macOS" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "/etc/resolver/voipbin.test"
}

@test "setup-dns.sh flushes DNS cache on macOS" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "dscacheutil -flushcache"
}

# =============================================================================
# Command line argument tests
# =============================================================================

@test "setup-dns.sh supports --uninstall flag" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "--uninstall"
}

@test "setup-dns.sh supports --test flag" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "--test"
}

@test "setup-dns.sh supports --regenerate flag" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "--regenerate"
}

@test "setup-dns.sh supports -y flag for non-interactive mode" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "|-y)"
}

# =============================================================================
# test_dns() function tests
# =============================================================================

@test "test_dns tests expected domains" {
    # Verify test_dns checks all required domains
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "api.voipbin.test"
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "admin.voipbin.test"
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "meet.voipbin.test"
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "talk.voipbin.test"
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "sip.voipbin.test"
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" "registrar.voipbin.test"
}

@test "test_dns uses dig or nslookup for resolution" {
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" 'command -v dig'
    assert_file_contains "$SCRIPTS_DIR/setup-dns.sh" 'command -v nslookup'
}
