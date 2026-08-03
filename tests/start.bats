#!/usr/bin/env bats
# Tests for scripts/start.sh (dual-mode DNS, VOIP-1275 Phase 3)
# check_host_prereqs branch matrix and the unprivileged fail-fast/proceed
# behavior that replaces check_root.
#
# Isolation rule: ip/dig/docker are stubbed via MOCK_BIN_DIR and
# PROJECT_DIR=$TEST_TEMP_DIR — nothing may touch the real host or daemon.
# The root×missing cell of the matrix (setup-host.sh subprocess invocation)
# cannot be exercised without real root operations; it is covered by the
# live internal-mode verification (plan DoD item 5).

load 'test_helper'

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# =============================================================================
# check_host_prereqs matrix (design §2.5)
# =============================================================================

@test "check_host_prereqs passes with interfaces present in external mode (no DNS requirement)" {
    load_start_functions
    create_env_file "DOMAIN_MODE=external" "BASE_DOMAIN=example.com" "COMPOSE_PROFILES="
    mock_command_script "ip" 'exit 0'
    RESOLV_CONF="$TEST_TEMP_DIR/resolv.conf"
    echo "nameserver 8.8.8.8" > "$RESOLV_CONF"

    run check_host_prereqs

    [[ "$status" -eq 0 ]]
}

@test "check_host_prereqs passes with interfaces present and resolv.conf at 127.0.0.1 (internal)" {
    load_start_functions
    create_env_file "DOMAIN_MODE=internal" "COMPOSE_PROFILES=internal-dns"
    mock_command_script "ip" 'exit 0'
    RESOLV_CONF="$TEST_TEMP_DIR/resolv.conf"
    echo "nameserver 127.0.0.1" > "$RESOLV_CONF"

    run check_host_prereqs

    [[ "$status" -eq 0 ]]
}

@test "check_host_prereqs fails in internal mode when DNS is not configured" {
    load_start_functions
    create_env_file "DOMAIN_MODE=internal" "COMPOSE_PROFILES=internal-dns"
    mock_command_script "ip" 'exit 0'
    mock_command_script "dig" 'exit 1'
    RESOLV_CONF="$TEST_TEMP_DIR/resolv.conf"
    echo "nameserver 8.8.8.8" > "$RESOLV_CONF"

    run check_host_prereqs

    [[ "$status" -eq 1 ]]
}

@test "check_host_prereqs does not accept a commented-out nameserver line (internal)" {
    load_start_functions
    create_env_file "DOMAIN_MODE=internal" "COMPOSE_PROFILES=internal-dns"
    mock_command_script "ip" 'exit 0'
    mock_command_script "dig" 'exit 1'
    RESOLV_CONF="$TEST_TEMP_DIR/resolv.conf"
    printf '#nameserver 127.0.0.1\nnameserver 8.8.8.8\n' > "$RESOLV_CONF"

    run check_host_prereqs

    [[ "$status" -eq 1 ]]
}

@test "check_host_prereqs accepts an answering CoreDNS when resolv.conf is untouched (internal)" {
    load_start_functions
    create_env_file "DOMAIN_MODE=internal" "COMPOSE_PROFILES=internal-dns"
    mock_command_script "ip" 'exit 0'
    mock_command_script "dig" 'echo "192.168.1.100"'
    RESOLV_CONF="$TEST_TEMP_DIR/resolv.conf"
    echo "nameserver 8.8.8.8" > "$RESOLV_CONF"

    run check_host_prereqs

    [[ "$status" -eq 0 ]]
}

@test "check_host_prereqs fails when both VoIP interfaces are missing" {
    load_start_functions
    create_env_file "DOMAIN_MODE=external" "BASE_DOMAIN=example.com" "COMPOSE_PROFILES="
    mock_command_script "ip" 'exit 1'

    run check_host_prereqs

    [[ "$status" -eq 1 ]]
}

@test "check_host_prereqs fails when only one VoIP interface exists (both are required)" {
    load_start_functions
    create_env_file "DOMAIN_MODE=external" "BASE_DOMAIN=example.com" "COMPOSE_PROFILES="
    mock_command_script "ip" '
if [[ "$1" == "link" && "$2" == "show" && "$3" == "kamailio-int" ]]; then exit 0; fi
exit 1'

    run check_host_prereqs

    [[ "$status" -eq 1 ]]
}

@test "check_host_prereqs sets HOST_PREREQS_MISSING with the missing prerequisite" {
    load_start_functions
    create_env_file "DOMAIN_MODE=internal" "COMPOSE_PROFILES=internal-dns"
    mock_command_script "ip" 'exit 1'

    check_host_prereqs || true

    [[ "$HOST_PREREQS_MISSING" == *'kamailio-int/rtpengine-int'* ]]
}

# =============================================================================
# ensure_scheduled_backup_enabled (VOIP-1281): database-backup ships disabled
# upstream; start.sh turns it on idempotently.
# =============================================================================

@test "ensure_scheduled_backup_enabled is a no-op when already enabled" {
    load_start_functions
    mock_command_script "docker" '
if [[ "$1" == "exec" && "$*" == *"schedule list"* ]]; then
    printf "%s" "[{\"name\":\"database-backup\",\"enabled\":true}]"
    exit 0
fi
if [[ "$1" == "exec" && "$*" == *"schedule enable"* ]]; then
    echo "SHOULD NOT BE CALLED" >> "'"$TEST_TEMP_DIR"'/enable_calls.log"
    exit 0
fi
exit 1'

    run ensure_scheduled_backup_enabled

    [[ ! -f "$TEST_TEMP_DIR/enable_calls.log" ]]
}

@test "ensure_scheduled_backup_enabled enables a disabled schedule" {
    load_start_functions
    mock_command_script "docker" '
if [[ "$1" == "exec" && "$*" == *"schedule list"* ]]; then
    printf "%s" "[{\"name\":\"database-backup\",\"enabled\":false}]"
    exit 0
fi
if [[ "$1" == "exec" && "$*" == *"schedule enable database-backup"* ]]; then
    exit 0
fi
exit 1'

    run ensure_scheduled_backup_enabled

    [[ "$output" == *'Enabled scheduled DB backup'* ]]
}

@test "ensure_scheduled_backup_enabled warns when schedule-manager is unreachable" {
    load_start_functions
    mock_command_script "docker" 'exit 1'

    run ensure_scheduled_backup_enabled

    [[ "$output" == *'Could not reach schedule-manager'* ]]
    [[ "$output" == *'schedule-control schedule enable database-backup'* ]]
}

@test "ensure_scheduled_backup_enabled warns when the enable command itself fails" {
    load_start_functions
    mock_command_script "docker" '
if [[ "$1" == "exec" && "$*" == *"schedule list"* ]]; then
    printf "%s" "[{\"name\":\"database-backup\",\"enabled\":false}]"
    exit 0
fi
exit 1'

    run ensure_scheduled_backup_enabled

    [[ "$output" == *'Could not enable database-backup'* ]]
}

# =============================================================================
# Script-level behavior: the gate that replaced check_root (design §2.5)
# =============================================================================

@test "start.sh unprivileged with missing prereqs fails fast with next=setup-host" {
    if [[ $EUID -eq 0 ]]; then
        skip "test requires an unprivileged user"
    fi
    create_env_file "DOMAIN_MODE=internal" "COMPOSE_PROFILES=internal-dns" "BASE_DOMAIN=voipbin.test"
    mock_command "docker" ""
    mock_command_script "ip" 'exit 1'
    mock_command_script "dig" 'exit 1'
    export RESOLV_CONF="$TEST_TEMP_DIR/resolv.conf"
    echo "nameserver 8.8.8.8" > "$RESOLV_CONF"

    run env -u COMPOSE_PROFILES bash "$SCRIPTS_DIR/start.sh"

    [[ "$status" -eq 1 ]]
    [[ "$output" == *'VOIPBIN_START: status=error reason="host setup missing" next="sudo ./scripts/setup-host.sh"'* ]]
}

@test "start.sh unprivileged with satisfied prereqs proceeds past the gate" {
    if [[ $EUID -eq 0 ]]; then
        skip "test requires an unprivileged user"
    fi
    # byo mode with the cert missing: the run must get PAST the host-prereq
    # gate and die later at setup_mkcert's byo fail-fast — proving the
    # unprivileged path proceeds when prerequisites are satisfied.
    create_env_file "DOMAIN_MODE=internal" "COMPOSE_PROFILES=internal-dns" \
        "BASE_DOMAIN=voipbin.test" "TLS_MODE=byo" "HOST_EXTERNAL_IP=192.168.1.100"
    mock_command "docker" ""
    mock_command_script "ip" 'exit 0'
    export RESOLV_CONF="$TEST_TEMP_DIR/resolv.conf"
    echo "nameserver 127.0.0.1" > "$RESOLV_CONF"

    run env -u COMPOSE_PROFILES bash "$SCRIPTS_DIR/start.sh"

    [[ "$status" -ne 0 ]]
    [[ "$output" != *'host setup missing'* ]]
    [[ "$output" == *'TLS_MODE=byo but'* ]]
    [[ "$output" == *'install-certs.sh'* ]]
    # Result-line guarantee (§2.2): even a set -e abort closes with a line
    local last_line
    last_line=$(echo "$output" | tail -1)
    [[ "$last_line" =~ ^VOIPBIN_START:\ status=error ]]
}

# =============================================================================
# check_database_initialized (VOIP-1289): a partial migration must not be
# mistaken for "done" — bin_manager alone having tables is not sufficient,
# both schemas must be at some alembic revision.
# =============================================================================

@test "check_database_initialized fails when only bin_manager has tables (asterisk never migrated)" {
    load_start_functions
    mock_command_script "docker" '
if [[ "$*" == *"bin_manager.alembic_version"* ]]; then
    echo "a5e6f559299c"
elif [[ "$*" == *"asterisk.alembic_version"* ]]; then
    exit 1
elif [[ "$*" == *"information_schema.TABLES"* ]]; then
    echo "42"
fi
'

    run check_database_initialized

    [[ "$status" -eq 1 ]]
}

@test "check_database_initialized passes when both schemas have an alembic version" {
    load_start_functions
    mock_command_script "docker" '
if [[ "$*" == *"bin_manager.alembic_version"* ]]; then
    echo "a5e6f559299c"
elif [[ "$*" == *"asterisk.alembic_version"* ]]; then
    echo "c07b40884361"
elif [[ "$*" == *"information_schema.TABLES"* ]]; then
    echo "42"
fi
'

    run check_database_initialized

    [[ "$status" -eq 0 ]]
}

@test "check_database_initialized fails on a completely fresh (empty) database" {
    load_start_functions
    mock_command_script "docker" '
if [[ "$*" == *"information_schema.TABLES"* ]]; then
    echo "0"
fi
'

    run check_database_initialized

    [[ "$status" -eq 1 ]]
}

# =============================================================================
# setup_test_customer marker gating (VOIP-1289): the .test_data_initialized
# marker must only be written when all 3 extensions actually got created,
# so a broken run doesn't defeat the "just re-run start.sh" recovery path.
# =============================================================================

# Shared docker stub covering every `docker exec` call setup_test_customer
# makes, other than extension creation (that's over curl, not docker).
stub_docker_for_test_customer() {
    mock_command_script "docker" '
case "$*" in
    *"customer-control customer create"*) exit 0 ;;
    *"customer-control customer list"*) echo "[{\"email\":\"admin@localhost\",\"id\":\"cust-1\"}]" ;;
    *"agent-control agent list"*) echo "[{\"id\":\"agent-1\"}]" ;;
    *"agent-control agent update-password"*) exit 0 ;;
    *"customer-control accesskey create"*) echo "token: fake-accesskey" ;;
    *"billing-control account update-plan-type"*) exit 0 ;;
    *"billing-control account add-balance"*) exit 0 ;;
    *) exit 0 ;;
esac
'
}

@test "setup_test_customer writes the marker when all 3 extensions succeed" {
    load_start_functions
    stub_docker_for_test_customer
    mock_command_script "curl" '
case "$*" in
    *"/auth/login"*) echo "{\"token\":\"fake-jwt\"}" ;;
    *"/v1.0/extensions"*)
        if [[ "$*" == *"-w"* ]]; then printf "{}\n201"; else echo "{}"; fi
        ;;
    *"/v1.0/customer"*) echo "{\"billing_account_id\":\"bill-1\"}" ;;
    *) echo "{}" ;;
esac
'

    run setup_test_customer

    [[ "$status" -eq 0 ]]
    [[ -f "$PROJECT_DIR/.test_data_initialized" ]]
    [[ "$output" == *"Test customer created successfully!"* ]]
}

@test "setup_test_customer does not write the marker when an extension creation fails" {
    load_start_functions
    stub_docker_for_test_customer
    mock_command_script "curl" '
case "$*" in
    *"/auth/login"*) echo "{\"token\":\"fake-jwt\"}" ;;
    *"/v1.0/extensions"*)
        if [[ "$*" == *"\"extension\": \"2000\""* ]]; then
            if [[ "$*" == *"-w"* ]]; then printf "{\"error\":\"boom\"}\n500"; else echo "{\"error\":\"boom\"}"; fi
        else
            if [[ "$*" == *"-w"* ]]; then printf "{}\n201"; else echo "{}"; fi
        fi
        ;;
    *"/v1.0/customer"*) echo "{\"billing_account_id\":\"bill-1\"}" ;;
    *) echo "{}" ;;
esac
'

    run setup_test_customer

    [[ ! -f "$PROJECT_DIR/.test_data_initialized" ]]
    [[ "$output" == *"Could not create extension 2000"* ]]
    [[ "$output" == *"only 2/3 extensions succeeded"* ]]
}
