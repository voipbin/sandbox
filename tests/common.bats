#!/usr/bin/env bats
# Tests for scripts/common.sh

load 'test_helper'

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# =============================================================================
# detect_host_ip() tests
# =============================================================================

@test "detect_host_ip returns IP from .env when HOST_EXTERNAL_IP is set" {
    create_env_file "HOST_EXTERNAL_IP=10.0.0.50"
    load_common

    result=$(detect_host_ip)

    assert_equal "$result" "10.0.0.50"
}

@test "detect_host_ip uses ip route when .env has no HOST_EXTERNAL_IP" {
    create_env_file "OTHER_VAR=something"
    mock_ip_route "192.168.1.100"
    load_common

    result=$(detect_host_ip)

    assert_equal "$result" "192.168.1.100"
}

@test "detect_host_ip uses ip route when .env is missing" {
    # No .env file created
    mock_ip_route "172.16.0.50"
    load_common

    result=$(detect_host_ip)

    assert_equal "$result" "172.16.0.50"
}

@test "detect_host_ip uses hostname -I when ip route fails" {
    create_env_file ""
    # Mock ip to fail
    mock_command "ip" "" 1
    mock_hostname "10.20.30.40"
    load_common

    result=$(detect_host_ip)

    assert_equal "$result" "10.20.30.40"
}

@test "detect_host_ip returns 127.0.0.1 as final fallback" {
    create_env_file ""
    # Mock all commands to fail
    mock_command "ip" "" 1
    mock_command "hostname" "" 1
    mock_command "ipconfig" "" 1
    load_common

    result=$(detect_host_ip)

    assert_equal "$result" "127.0.0.1"
}

@test "detect_host_ip returns valid IP format" {
    mock_ip_route "192.168.5.25"
    load_common

    result=$(detect_host_ip)

    assert_valid_ip "$result"
}

# =============================================================================
# generate_coredns_config() tests
# =============================================================================

@test "generate_coredns_config creates config directory if missing" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"

    generate_coredns_config "192.168.1.100" "$config_dir"

    [[ -d "$config_dir" ]]
}

@test "generate_coredns_config creates Corefile" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"

    generate_coredns_config "192.168.1.100" "$config_dir"

    [[ -f "$config_dir/Corefile" ]]
}

@test "generate_coredns_config removes Corefile if it's a directory" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"
    mkdir -p "$config_dir/Corefile"  # Create as directory (Docker mount issue)

    generate_coredns_config "192.168.1.100" "$config_dir"

    [[ -f "$config_dir/Corefile" ]]  # Should now be a file
    [[ ! -d "$config_dir/Corefile" ]]
}

@test "generate_coredns_config writes api.voipbin.test with host_ip" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"

    generate_coredns_config "10.0.0.100" "$config_dir"

    assert_file_contains "$config_dir/Corefile" 'api.voipbin.test 60 IN A 10.0.0.100'
}

@test "generate_coredns_config writes admin.voipbin.test with host_ip" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"

    generate_coredns_config "10.0.0.100" "$config_dir"

    assert_file_contains "$config_dir/Corefile" 'admin.voipbin.test 60 IN A 10.0.0.100'
}

@test "generate_coredns_config writes meet.voipbin.test with host_ip" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"

    generate_coredns_config "10.0.0.100" "$config_dir"

    assert_file_contains "$config_dir/Corefile" 'meet.voipbin.test 60 IN A 10.0.0.100'
}

@test "generate_coredns_config writes talk.voipbin.test with host_ip" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"

    generate_coredns_config "10.0.0.100" "$config_dir"

    assert_file_contains "$config_dir/Corefile" 'talk.voipbin.test 60 IN A 10.0.0.100'
}

@test "generate_coredns_config writes voipbin.test catch-all with kamailio_ip" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"

    generate_coredns_config "10.0.0.100" "$config_dir" "10.0.0.200"

    # The catch-all uses template syntax with kamailio_ip
    assert_file_contains "$config_dir/Corefile" '60 IN A 10.0.0.200'
}

@test "generate_coredns_config uses host_ip as kamailio_ip when not specified" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"

    generate_coredns_config "10.0.0.100" "$config_dir"

    # When kamailio_ip not specified, it defaults to host_ip
    # The voipbin.test block should have the host_ip
    grep -A5 '^voipbin.test {' "$config_dir/Corefile" | grep -q '10.0.0.100'
}

@test "generate_coredns_config includes forward zone with 8.8.8.8" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"

    generate_coredns_config "192.168.1.100" "$config_dir"

    assert_file_contains "$config_dir/Corefile" 'forward . 8.8.8.8 8.8.4.4'
}

@test "generate_coredns_config includes cache directive" {
    load_common
    local config_dir="$TEST_TEMP_DIR/config/coredns"

    generate_coredns_config "192.168.1.100" "$config_dir"

    assert_file_contains "$config_dir/Corefile" 'cache 30'
}

# =============================================================================
# detect_os() tests
# =============================================================================

@test "detect_os returns linux on Linux" {
    mock_uname "Linux"
    load_common

    result=$(detect_os)

    assert_equal "$result" "linux"
}

@test "detect_os returns macos on Darwin" {
    mock_uname "Darwin"
    load_common

    result=$(detect_os)

    assert_equal "$result" "macos"
}

@test "detect_os returns unknown for other systems" {
    mock_uname "FreeBSD"
    load_common

    result=$(detect_os)

    assert_equal "$result" "unknown"
}
