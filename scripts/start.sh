#!/bin/bash
# VoIPBin Sandbox - Start Script
# Orchestrates the full startup process with dependency and environment checks
#
# Usage: sudo ./voipbin start
#
# This script requires sudo for:
#   - VoIP network interface setup (macvlan)
#   - DNS forwarding configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source common functions
source "$SCRIPT_DIR/common.sh"

# Check if a command exists
check_command() {
    if command -v "$1" &> /dev/null; then
        return 0
    fi
    return 1
}

# Check all required dependencies
check_dependencies() {
    log_step "Checking dependencies..."
    local missing=()

    # Docker
    if check_command docker; then
        local docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        log_info "Docker: $docker_version"
    else
        missing+=("docker")
    fi

    # Docker Compose
    if docker compose version &>/dev/null; then
        local compose_version=$(docker compose version --short 2>/dev/null)
        log_info "Docker Compose: $compose_version"
    else
        missing+=("docker-compose")
    fi

    # Python3
    if check_command python3; then
        local python_version=$(python3 --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')
        log_info "Python: $python_version"
    else
        missing+=("python3")
    fi

    # Alembic
    if check_command alembic; then
        local alembic_version=$(alembic --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "installed")
        log_info "Alembic: $alembic_version"
    else
        log_warn "Alembic: not installed (required for database initialization)"
        log_warn "  Install with: pip3 install alembic mysqlclient PyMySQL"
    fi

    # OpenSSL (for certificate generation)
    if check_command openssl; then
        local openssl_version=$(openssl version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        log_info "OpenSSL: $openssl_version"
    else
        missing+=("openssl")
    fi

    # Git (optional, for downloading dbscheme)
    if check_command git; then
        local git_version=$(git --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')
        log_info "Git: $git_version"
    else
        log_warn "Git: not installed (optional, for downloading database schema)"
    fi

    # Check if Docker daemon is running
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running!"
        missing+=("docker-daemon")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo ""
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Please install them and try again."
        exit 1
    fi

    log_info "All required dependencies found!"
}

# Setup mkcert for browser-trusted certificates
setup_mkcert() {
    log_step "Checking SSL certificate setup..."

    # Check if mkcert is installed
    if ! command -v mkcert &> /dev/null; then
        log_warn "mkcert not installed - installing for browser-trusted certificates..."

        # Detect OS and install mkcert
        if command -v apt &> /dev/null; then
            sudo apt update && sudo apt install -y mkcert libnss3-tools
        elif command -v brew &> /dev/null; then
            brew install mkcert
        else
            log_error "Could not install mkcert automatically."
            log_error "Please install manually: https://github.com/FiloSottile/mkcert"
            return 1
        fi
    fi

    if ! command -v mkcert &> /dev/null; then
        log_error "mkcert installation failed"
        return 1
    fi

    log_info "mkcert: installed"

    # Install local CA if not already done
    if ! mkcert -check 2>/dev/null; then
        log_info "Installing mkcert local CA (may require sudo)..."
        mkcert -install
    else
        log_info "mkcert CA: already installed"
    fi

    # Check if certificates were generated with mkcert (mkcert certs are larger)
    local api_cert="$PROJECT_DIR/certs/api/cert.pem"
    local needs_regen=false

    if [ -f "$api_cert" ]; then
        # mkcert certs typically include "mkcert" in the issuer
        if ! openssl x509 -in "$api_cert" -noout -issuer 2>/dev/null | grep -qi "mkcert"; then
            log_warn "Existing certificates are self-signed (not browser-trusted)"
            needs_regen=true
        else
            log_info "Certificates: mkcert (browser-trusted)"
        fi
    else
        needs_regen=true
    fi

    if [ "$needs_regen" = true ]; then
        log_info "Regenerating certificates with mkcert..."
        rm -rf "$PROJECT_DIR/certs"

        # Get host IP for certificate
        local host_ip
        host_ip=$(grep HOST_EXTERNAL_IP "$PROJECT_DIR/.env" 2>/dev/null | cut -d'=' -f2 | head -1)
        [ -z "$host_ip" ] && host_ip="127.0.0.1"

        # Create cert directories
        mkdir -p "$PROJECT_DIR/certs/api"
        for domain in registrar.voipbin.test conference.voipbin.test sip.voipbin.test sip-service.voipbin.test trunk.voipbin.test; do
            mkdir -p "$PROJECT_DIR/certs/$domain"
            mkcert -cert-file "$PROJECT_DIR/certs/$domain/fullchain.pem" \
                   -key-file "$PROJECT_DIR/certs/$domain/privkey.pem" \
                   "$domain" "*.$domain" localhost 127.0.0.1 ::1 2>/dev/null
        done

        # Generate API certificate
        mkcert -cert-file "$PROJECT_DIR/certs/api/cert.pem" \
               -key-file "$PROJECT_DIR/certs/api/privkey.pem" \
               voipbin.test "*.voipbin.test" localhost 127.0.0.1 ::1 "$host_ip" 2>/dev/null

        # Update .env with new base64-encoded certs (if .env exists)
        if [ -f "$PROJECT_DIR/.env" ]; then
            local api_cert_b64=$(cat "$PROJECT_DIR/certs/api/cert.pem" | base64 -w0)
            local api_key_b64=$(cat "$PROJECT_DIR/certs/api/privkey.pem" | base64 -w0)

            sed -i "s|^API_SSL_CERT_BASE64=.*|API_SSL_CERT_BASE64=$api_cert_b64|" "$PROJECT_DIR/.env"
            sed -i "s|^API_SSL_PRIVKEY_BASE64=.*|API_SSL_PRIVKEY_BASE64=$api_key_b64|" "$PROJECT_DIR/.env"
            sed -i "s|^HOOK_SSL_CERT_BASE64=.*|HOOK_SSL_CERT_BASE64=$api_cert_b64|" "$PROJECT_DIR/.env"
            sed -i "s|^HOOK_SSL_PRIVKEY_BASE64=.*|HOOK_SSL_PRIVKEY_BASE64=$api_key_b64|" "$PROJECT_DIR/.env"
        else
            log_warn ".env not found - skipping certificate update in .env"
        fi

        log_info "Certificates regenerated with mkcert (browser-trusted)"

        # Restart services that use the certificates if they're running
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "voipbin-api-mgr"; then
            log_info "Restarting API services to use new certificates..."
            docker compose restart api-manager hook-manager 2>/dev/null || true
        fi
    fi

    return 0
}

# Check if this is first time run
check_first_run() {
    local is_first_run=true
    local reasons=()

    # Check .env file
    if [ -f "$PROJECT_DIR/.env" ]; then
        is_first_run=false
    else
        reasons+=(".env file not found")
    fi

    # Check certificates directory
    if [ -d "$PROJECT_DIR/certs" ] && [ "$(ls -A $PROJECT_DIR/certs 2>/dev/null)" ]; then
        is_first_run=false
    else
        reasons+=("certificates not generated")
    fi

    # Check if database volume has data
    if docker volume ls --format '{{.Name}}' | grep -q 'sandbox_db_data'; then
        is_first_run=false
    else
        reasons+=("database volume not created")
    fi

    if [ "$is_first_run" = true ]; then
        return 0  # Is first run
    fi
    return 1  # Not first run
}

# Validate .env file
validate_env() {
    log_step "Validating environment configuration..."

    if [ ! -f "$PROJECT_DIR/.env" ]; then
        log_error ".env file not found!"
        return 1
    fi

    local warnings=()
    local errors=()

    # Source the .env file
    set -a
    source "$PROJECT_DIR/.env"
    set +a

    # Check HOST_EXTERNAL_IP
    if [ -z "$HOST_EXTERNAL_IP" ] || [ "$HOST_EXTERNAL_IP" = "127.0.0.1" ]; then
        warnings+=("HOST_EXTERNAL_IP is set to localhost - external SIP clients won't work")
    else
        log_info "HOST_EXTERNAL_IP: $HOST_EXTERNAL_IP"
    fi

    # Check API SSL certificates
    if [ -z "$API_SSL_CERT_BASE64" ] || [ -z "$API_SSL_PRIVKEY_BASE64" ]; then
        errors+=("API SSL certificates not configured")
    else
        log_info "API SSL certificates: configured"
    fi

    # Check GCP credentials (optional but important)
    if [ -z "$GOOGLE_APPLICATION_CREDENTIALS" ] || [ "$GOOGLE_APPLICATION_CREDENTIALS" = "/path/to/your/google_service_account.json" ]; then
        warnings+=("GOOGLE_APPLICATION_CREDENTIALS not configured - TTS/storage features won't work")
    else
        if [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
            log_info "GCP credentials: $GOOGLE_APPLICATION_CREDENTIALS"
        else
            warnings+=("GCP credentials file not found: $GOOGLE_APPLICATION_CREDENTIALS")
        fi
    fi

    # Check optional API keys
    if [ -n "$OPENAI_API_KEY" ] && [ "$OPENAI_API_KEY" != "" ]; then
        log_info "OpenAI API key: configured"
    else
        warnings+=("OPENAI_API_KEY not set - AI features won't work")
    fi

    # Check domain configuration
    log_info "BASE_DOMAIN: ${BASE_DOMAIN:-voipbin.test}"
    log_info "DOMAIN_NAME_EXTENSION: ${DOMAIN_NAME_EXTENSION:-registrar.voipbin.test}"

    # Print warnings
    if [ ${#warnings[@]} -gt 0 ]; then
        echo ""
        log_warn "Configuration warnings:"
        for warn in "${warnings[@]}"; do
            echo "  - $warn"
        done
    fi

    # Print errors and exit if any
    if [ ${#errors[@]} -gt 0 ]; then
        echo ""
        log_error "Configuration errors:"
        for err in "${errors[@]}"; do
            echo "  - $err"
        done
        return 1
    fi

    log_info "Environment configuration is valid!"
    return 0
}

# Check if VoIP network interfaces exist
check_voip_interfaces() {
    if ip link show kamailio-int &>/dev/null && ip link show rtpengine-int &>/dev/null; then
        return 0
    fi
    return 1
}

# Check if database is initialized
check_database_initialized() {
    local result
    result=$(docker exec voipbin-db mysql -u root -proot_password -N -e \
        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'bin_manager';" 2>/dev/null || echo "0")

    if [ "$result" -gt "0" ]; then
        return 0
    fi
    return 1
}

# Wait for database to be ready (with actual connection test, not just ping)
wait_for_database() {
    log_info "Waiting for database to be ready..."
    local max_wait=60
    local waited=0

    while [ $waited -lt $max_wait ]; do
        # Use actual SELECT query to verify root authentication works
        if docker exec voipbin-db mysql -u root -proot_password -e "SELECT 1" &>/dev/null; then
            log_info "Database is ready!"
            return 0
        fi
        echo -n "."
        sleep 2
        waited=$((waited + 2))
    done

    echo ""
    log_error "Database did not become ready in time"
    return 1
}

# Check if test data setup was already completed (using marker file)
# This allows users to delete the test customer without it being recreated
check_test_data_initialized() {
    [ -f "$PROJECT_DIR/.test_data_initialized" ]
}

# Wait for API to be ready
wait_for_api() {
    log_info "Waiting for API to be ready..."
    local max_wait=60
    local waited=0

    while [ $waited -lt $max_wait ]; do
        if curl -sk -o /dev/null -w "%{http_code}" "https://localhost:8443/health" 2>/dev/null | grep -q "200\|404"; then
            log_info "API is ready!"
            return 0
        fi
        echo -n "."
        sleep 2
        waited=$((waited + 2))
    done

    echo ""
    log_warn "API may not be fully ready yet"
    return 1
}

# Fetch customer ID for existing customer
fetch_customer_id() {
    local api_host="localhost"
    local api_port="8443"
    local customer_email="admin@localhost"

    # Login to get token
    local login_response
    login_response=$(curl -sk -X POST "https://${api_host}:${api_port}/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$customer_email\", \"password\": \"$customer_email\"}" 2>/dev/null)

    local token
    token=$(echo "$login_response" | jq -r '.token' 2>/dev/null)

    if [ "$token" != "null" ] && [ -n "$token" ]; then
        local customer_info
        customer_info=$(curl -sk -X GET "https://${api_host}:${api_port}/v1.0/customer" \
            -H "Authorization: Bearer $token" 2>/dev/null)
        CUSTOMER_ID=$(echo "$customer_info" | jq -r '.id' 2>/dev/null)
    fi
}

# Setup test customer and extensions
setup_test_customer() {
    local api_host="localhost"
    local api_port="8443"
    local customer_email="admin@localhost"
    local customer_name="Sandbox Admin"

    # Create customer
    log_info "  Creating customer: $customer_email"
    docker exec voipbin-customer-mgr /app/bin/customer-control customer create \
        --name "$customer_name" \
        --email "$customer_email" 2>&1 | grep -E "(Success|ID:)" || true

    # Wait a moment for customer to be created
    sleep 2

    # Login to get token
    local login_response
    login_response=$(curl -sk -X POST "https://${api_host}:${api_port}/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\": \"$customer_email\", \"password\": \"$customer_email\"}")

    local token
    token=$(echo "$login_response" | jq -r '.token' 2>/dev/null)

    if [ "$token" == "null" ] || [ -z "$token" ]; then
        log_warn "  Could not login to create extensions. You can run setup_test_customer.sh manually."
        return 1
    fi

    # Create extensions
    for ext in 1000 2000 3000; do
        log_info "  Creating extension: $ext"
        curl -sk -X POST "https://${api_host}:${api_port}/v1.0/extensions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -d "{\"extension\": \"$ext\", \"password\": \"pass$ext\", \"name\": \"Extension $ext\"}" > /dev/null 2>&1 || true
    done

    # Get customer ID
    local customer_info
    customer_info=$(curl -sk -X GET "https://${api_host}:${api_port}/v1.0/customer" \
        -H "Authorization: Bearer $token")

    CUSTOMER_ID=$(echo "$customer_info" | jq -r '.id' 2>/dev/null)

    # Create marker file to indicate test data was initialized
    touch "$PROJECT_DIR/.test_data_initialized"

    log_info "  Test customer created successfully!"
}

main() {
    # Global variable for customer ID (set by setup_test_customer or fetch_customer_id)
    CUSTOMER_ID=""

    echo ""
    echo "=============================================="
    echo "  VoIPBin Sandbox - Startup"
    echo "=============================================="

    # Check for root/sudo access
    check_root

    cd "$PROJECT_DIR"

    # Step 1: Check dependencies
    check_dependencies

    # Step 2: Check if .env exists
    log_step "Checking installation status..."
    if [ ! -f "$PROJECT_DIR/.env" ]; then
        log_error ".env file not found!"
        echo ""
        log_info "Please run initialization first:"
        echo ""
        echo "  voipbin> init"
        echo ""
        exit 1
    else
        log_info "Configuration found"
    fi

    # Step 3: Setup mkcert for browser-trusted certificates
    setup_mkcert

    # Step 4: Validate environment
    if ! validate_env; then
        echo ""
        log_error "Environment validation failed!"
        log_error "Please fix the errors above and try again."
        log_error "You can regenerate .env with: voipbin> init"
        exit 1
    fi

    # Step 5: Start infrastructure services first
    log_step "Starting infrastructure services (db, redis, rabbitmq)..."
    # Unset all environment variables that might override .env file values
    # This ensures docker compose reads from .env only
    unset API_SSL_CERT_BASE64 API_SSL_PRIVKEY_BASE64 HOOK_SSL_CERT_BASE64 HOOK_SSL_PRIVKEY_BASE64
    unset HOST_EXTERNAL_IP KAMAILIO_INTERNAL_ADDR
    docker compose up -d db redis rabbitmq

    # Wait for db to be healthy
    wait_for_database || exit 1

    # Step 6: Initialize database if needed
    log_step "Checking database initialization..."
    if check_database_initialized; then
        log_info "Database is already initialized"
    else
        log_warn "Database not initialized. Running init_database.sh..."
        if check_command alembic; then
            "$SCRIPT_DIR/init_database.sh"
        else
            log_error "Alembic is required for database initialization!"
            log_error "Install with: pip3 install alembic mysqlclient PyMySQL"
            log_error "Then run: voipbin> start"
            exit 1
        fi
    fi

    # Step 7: Generate CoreDNS config and start all services
    log_step "Generating CoreDNS configuration..."
    local host_ip=$(grep '^HOST_EXTERNAL_IP=' "$PROJECT_DIR/.env" 2>/dev/null | cut -d'=' -f2 | head -1)
    local kamailio_ip=$(grep '^KAMAILIO_EXTERNAL_IP=' "$PROJECT_DIR/.env" 2>/dev/null | cut -d'=' -f2 | head -1)
    [ -z "$host_ip" ] && host_ip="127.0.0.1"
    [ -z "$kamailio_ip" ] && kamailio_ip="$host_ip"  # Fallback to host_ip if not set
    generate_coredns_config "$host_ip" "$PROJECT_DIR/config/coredns" "$kamailio_ip"
    log_info "  Web services → $host_ip (Docker port mapping)"
    log_info "  SIP services → $kamailio_ip"

    log_step "Starting all services..."
    docker compose up -d

    # Step 8: Check DNS configuration
    log_step "Checking DNS configuration..."
    if grep -q "nameserver 127.0.0.1" /etc/resolv.conf 2>/dev/null; then
        log_info "DNS is configured (resolv.conf → CoreDNS)"
    else
        log_warn "DNS not configured. Setting up..."
        "$SCRIPT_DIR/setup-dns.sh" -y 2>/dev/null || log_warn "DNS setup failed. Run 'dns setup' manually."
    fi

    # Step 9: Setup VoIP network interfaces
    log_step "Checking VoIP network interfaces..."
    if check_voip_interfaces; then
        log_info "VoIP network interfaces already configured"
    else
        log_warn "VoIP network interfaces not found"
        log_info "Setting up VoIP network interfaces (requires sudo)..."
        sudo "$SCRIPT_DIR/setup-voip-network.sh"

        # Restart kamailio and rtpengine
        log_info "Restarting kamailio and rtpengine..."
        docker compose restart kamailio rtpengine
    fi

    # Step 10: Wait for services to stabilize
    log_step "Waiting for services to stabilize..."
    sleep 5

    # Step 11: Wait for API to be ready
    log_step "Waiting for API..."
    wait_for_api

    # Step 12: Setup test data if needed
    log_step "Checking test data..."
    if check_test_data_initialized; then
        log_info "Test data already initialized (delete .test_data_initialized to recreate)"
        # Get customer ID for display (if customer still exists)
        fetch_customer_id
    else
        log_info "Creating test customer and extensions..."
        setup_test_customer
    fi

    # Step 13: Show status
    log_step "Service Status"
    echo ""
    docker compose ps --format "table {{.Name}}\t{{.Status}}" | head -25

    # Count services
    local total=$(docker compose ps -q 2>/dev/null | wc -l)
    local running=$(docker compose ps --status running -q 2>/dev/null | wc -l)
    echo ""
    log_info "Services: $running/$total running"

    # Show any unhealthy/restarting services
    local issues=$(docker compose ps --format "{{.Name}}\t{{.Status}}" 2>/dev/null | grep -iE "unhealthy|restarting|exit" || true)
    if [ -n "$issues" ]; then
        echo ""
        log_warn "Some services may need attention:"
        echo "$issues" | while read line; do
            echo "  - $line"
        done
        echo ""
        log_info "These may be due to missing API keys (OpenAI, GCP, etc.)"
        log_info "Core VoIP services should still work."
    fi

    echo ""
    echo "=============================================="
    echo "  Startup Complete!"
    echo "=============================================="
    echo ""
    echo "-----------------------------------------------"
    echo "  Web Consoles"
    echo "-----------------------------------------------"
    echo "  Admin UI:      http://localhost:3003"
    echo "  API Manager:   https://localhost:8443"
    echo "  RabbitMQ:      http://localhost:15672"
    echo "                 (guest / guest)"
    echo ""
    echo "-----------------------------------------------"
    echo "  Admin Account"
    echo "-----------------------------------------------"
    echo "  Username:      admin@localhost"
    echo "  Password:      admin@localhost"
    echo ""
    echo "-----------------------------------------------"
    echo "  SIP Extensions"
    echo "-----------------------------------------------"
    echo "  1000 / pass1000"
    echo "  2000 / pass2000"
    echo "  3000 / pass3000"
    if [ -n "$CUSTOMER_ID" ] && [ "$CUSTOMER_ID" != "null" ]; then
        echo ""
        echo "  SIP Domain:    ${CUSTOMER_ID}.registrar.voipbin.test"
        echo "  SIP Server:    $(grep HOST_EXTERNAL_IP "$PROJECT_DIR/.env" 2>/dev/null | cut -d'=' -f2 | head -1):5060"
    fi
    echo ""
    echo "-----------------------------------------------"
    echo "  Useful Commands"
    echo "-----------------------------------------------"
    echo "  View logs:     voipbin> logs <service>"
    echo "  Stop:          voipbin> stop"
    echo "  Full reset:    voipbin> clean --all"
    echo ""
}

main "$@"
