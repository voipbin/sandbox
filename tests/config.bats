#!/usr/bin/env bats
# Configuration validation tests
# Validates docker-compose.yml, .env.template, and generated configs

load 'test_helper'

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# =============================================================================
# docker-compose.yml - YAML Syntax Validation
# =============================================================================

@test "docker-compose.yml exists" {
    [[ -f "$PROJECT_ROOT/docker-compose.yml" ]]
}

@test "docker-compose.yml is valid YAML" {
    # Use Python's yaml parser (more portable than requiring Docker)
    # Falls back to docker compose if python3/pyyaml not available
    if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
        run python3 -c "import yaml; yaml.safe_load(open('$PROJECT_ROOT/docker-compose.yml'))"
    elif command -v docker &>/dev/null; then
        run docker compose -f "$PROJECT_ROOT/docker-compose.yml" config --quiet 2>&1
    else
        skip "Neither python3+pyyaml nor docker available for YAML validation"
    fi

    if [[ "$status" -ne 0 ]]; then
        echo "YAML validation failed:" >&2
        echo "$output" >&2
    fi
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# docker-compose.yml - Required Services
# =============================================================================

@test "docker-compose.yml defines db service" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "  db:"
}

@test "docker-compose.yml defines redis service" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "  redis:"
}

@test "docker-compose.yml defines rabbitmq service" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "  rabbitmq:"
}

@test "docker-compose.yml defines coredns service" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "  coredns:"
}

@test "docker-compose.yml defines kamailio service" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "  kamailio:"
}

@test "docker-compose.yml defines api-manager service" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "  api-manager:"
}

@test "docker-compose.yml defines square-admin service" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "  square-admin:"
}

@test "docker-compose.yml defines square-meet service" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "  square-meet:"
}

@test "docker-compose.yml defines square-talk service" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "  square-talk:"
}

# =============================================================================
# docker-compose.yml - Web Service Port Mappings
# =============================================================================

@test "docker-compose.yml maps admin to port 3003" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "0.0.0.0:3003:80"
}

@test "docker-compose.yml maps meet to port 3004" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "0.0.0.0:3004:80"
}

@test "docker-compose.yml maps talk to port 3005" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "0.0.0.0:3005:80"
}

@test "docker-compose.yml maps api-manager to port 8443" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "0.0.0.0:8443:443"
}

# =============================================================================
# docker-compose.yml - Network Configuration
# =============================================================================

@test "docker-compose.yml defines default network" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "networks:"
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "  default:"
}

@test "docker-compose.yml default network uses 10.100.0.0/16 subnet" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "10.100.0.0/16"
}

# =============================================================================
# docker-compose.yml - Container Fixed IPs
# =============================================================================

@test "docker-compose.yml assigns fixed IP 10.100.0.101 to admin" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "ipv4_address: 10.100.0.101"
}

@test "docker-compose.yml assigns fixed IP 10.100.0.102 to meet" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "ipv4_address: 10.100.0.102"
}

@test "docker-compose.yml assigns fixed IP 10.100.0.103 to talk" {
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "ipv4_address: 10.100.0.103"
}

# =============================================================================
# docker-compose.yml - Port Conflict Detection
# =============================================================================

@test "docker-compose.yml has no duplicate host port mappings" {
    # Extract all host ports from port mappings (format: "host:container" or "0.0.0.0:host:container")
    local ports=$(grep -oE '^\s*-\s*"[0-9.]*:?[0-9]+:[0-9]+"' "$PROJECT_ROOT/docker-compose.yml" | \
                  grep -oE '[0-9]+:[0-9]+"' | \
                  cut -d: -f1 | \
                  sort)

    # Validate we found ports
    if [[ -z "$ports" ]]; then
        echo "No port mappings found in docker-compose.yml" >&2
        return 1
    fi

    local unique_ports=$(echo "$ports" | sort -u)
    local port_count=$(echo "$ports" | wc -l)
    local unique_count=$(echo "$unique_ports" | wc -l)

    if [[ "$port_count" -ne "$unique_count" ]]; then
        echo "Duplicate ports found:" >&2
        echo "$ports" | uniq -d >&2
        return 1
    fi
}

# =============================================================================
# .env.template Validation
# =============================================================================

@test ".env.template exists" {
    [[ -f "$PROJECT_ROOT/.env.template" ]]
}

@test ".env.template has no duplicate keys" {
    # Extract all KEY= patterns (ignoring comments and empty lines)
    local keys=$(grep -E '^[A-Z_]+=' "$PROJECT_ROOT/.env.template" | cut -d= -f1 | sort)
    local unique_keys=$(echo "$keys" | sort -u)
    local key_count=$(echo "$keys" | wc -l)
    local unique_count=$(echo "$unique_keys" | wc -l)

    if [[ "$key_count" -ne "$unique_count" ]]; then
        echo "Duplicate keys found:" >&2
        echo "$keys" | uniq -d >&2
        return 1
    fi
}

@test ".env.template contains HOST_EXTERNAL_IP" {
    assert_file_contains "$PROJECT_ROOT/.env.template" "HOST_EXTERNAL_IP="
}

@test ".env.template contains KAMAILIO_EXTERNAL_IP" {
    assert_file_contains "$PROJECT_ROOT/.env.template" "KAMAILIO_EXTERNAL_IP="
}

@test ".env.template contains RTPENGINE_EXTERNAL_IP" {
    assert_file_contains "$PROJECT_ROOT/.env.template" "RTPENGINE_EXTERNAL_IP="
}

@test ".env.template contains API_SSL_CERT_BASE64" {
    assert_file_contains "$PROJECT_ROOT/.env.template" "API_SSL_CERT_BASE64="
}

@test ".env.template contains DOMAIN_NAME_EXTENSION" {
    assert_file_contains "$PROJECT_ROOT/.env.template" "DOMAIN_NAME_EXTENSION="
}

@test ".env.template contains BASE_DOMAIN" {
    assert_file_contains "$PROJECT_ROOT/.env.template" "BASE_DOMAIN="
}

# =============================================================================
# CoreDNS Corefile Validation (when generated)
# =============================================================================

@test "generate_coredns_config creates valid Corefile structure" {
    load_common
    local config_dir="$TEST_TEMP_DIR/coredns"

    generate_coredns_config "192.168.1.100" "$config_dir" "192.168.1.200"

    # Check required blocks exist
    assert_file_contains "$config_dir/Corefile" "api.voipbin.test {"
    assert_file_contains "$config_dir/Corefile" "admin.voipbin.test {"
    assert_file_contains "$config_dir/Corefile" "meet.voipbin.test {"
    assert_file_contains "$config_dir/Corefile" "talk.voipbin.test {"
    assert_file_contains "$config_dir/Corefile" "voipbin.test {"
    assert_file_contains "$config_dir/Corefile" ". {"
}

@test "generate_coredns_config includes template directive for dynamic DNS" {
    load_common
    local config_dir="$TEST_TEMP_DIR/coredns"

    generate_coredns_config "192.168.1.100" "$config_dir"

    assert_file_contains "$config_dir/Corefile" "template IN A"
}

@test "generate_coredns_config includes AAAA handling" {
    load_common
    local config_dir="$TEST_TEMP_DIR/coredns"

    generate_coredns_config "192.168.1.100" "$config_dir"

    # Should handle AAAA queries (return NOERROR to prevent IPv6 failures)
    assert_file_contains "$config_dir/Corefile" "template IN AAAA"
    assert_file_contains "$config_dir/Corefile" "rcode NOERROR"
}

# =============================================================================
# Script Consistency Checks
# =============================================================================

@test "common.sh defines same container IPs as docker-compose.yml" {
    # common.sh defines these for reference
    source "$SCRIPTS_DIR/common.sh"

    # Verify they match docker-compose.yml
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "ipv4_address: $ADMIN_IP"
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "ipv4_address: $MEET_IP"
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "ipv4_address: $TALK_IP"
}

@test "setup-voip-network.sh defines same internal IPs as expected" {
    # The internal network IPs should be consistent
    assert_file_contains "$SCRIPTS_DIR/setup-voip-network.sh" '["kamailio-int"]="10.100.0.200"'
    assert_file_contains "$SCRIPTS_DIR/setup-voip-network.sh" '["rtpengine-int"]="10.100.0.201"'
}

@test "docker-compose.yml kamailio uses expected internal IP" {
    # Kamailio should reference the internal IP for the internal network
    assert_file_contains "$PROJECT_ROOT/docker-compose.yml" "KAMAILIO_INTERNAL_ADDR=10.100.0.200"
}
