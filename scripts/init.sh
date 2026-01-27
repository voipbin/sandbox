#!/bin/bash
# VoIPBin Sandbox Initialization Script
# Generates .env file with auto-detected values and creates necessary certificates
#
# Usage: sudo ./voipbin init
#
# This script requires sudo for DNS forwarding configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
ENV_TEMPLATE="$PROJECT_DIR/.env.template"
CERTS_DIR="$PROJECT_DIR/certs"

# Source common functions
source "$SCRIPT_DIR/common.sh"

# Setup DNS by calling the setup-dns.sh script
setup_dns() {
    local host_ip="$1"
    local kamailio_ip="$2"
    local api_ip="$3"
    local admin_ip="$4"
    local meet_ip="$5"
    local talk_ip="$6"

    log_step "Setting up DNS..."

    # Create CoreDNS configuration using common function
    generate_coredns_config "$host_ip" "$PROJECT_DIR/config/coredns" "$kamailio_ip"
    log_info "  Created CoreDNS configuration"
    log_info "    API services   → $api_ip"
    log_info "    Admin console  → $admin_ip"
    log_info "    Meet           → $meet_ip"
    log_info "    Talk           → $talk_ip"
    log_info "    SIP services   → $kamailio_ip"

    # Call the setup-dns.sh script (handles OS-specific DNS config + starts CoreDNS)
    if [[ -f "$SCRIPT_DIR/setup-dns.sh" ]]; then
        "$SCRIPT_DIR/setup-dns.sh" -y
    else
        log_warn "  setup-dns.sh not found, skipping DNS configuration"
    fi
}

# Check if mkcert is installed and CA is set up
check_mkcert() {
    if command -v mkcert &> /dev/null; then
        return 0
    fi
    return 1
}

# Install mkcert local CA (one-time setup)
setup_mkcert_ca() {
    if mkcert -check &> /dev/null 2>&1; then
        log_info "  mkcert CA already installed"
        return 0
    fi

    log_info "  Installing mkcert local CA (may require sudo)..."
    mkcert -install
}

# Generate certificate (uses mkcert if available, otherwise OpenSSL)
generate_cert() {
    local domain=$1
    local cert_dir="$CERTS_DIR/$domain"

    if [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]]; then
        log_info "  Certificate for $domain already exists, skipping"
        return 0
    fi

    mkdir -p "$cert_dir"

    if [[ "$USE_MKCERT" == "true" ]]; then
        # Use mkcert for locally-trusted certificates
        mkcert -cert-file "$cert_dir/fullchain.pem" -key-file "$cert_dir/privkey.pem" \
            "$domain" "*.$domain" localhost 127.0.0.1 ::1 2>/dev/null
    else
        # Fallback to self-signed OpenSSL certificate
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$cert_dir/privkey.pem" \
            -out "$cert_dir/fullchain.pem" \
            -subj "/CN=*.$domain" 2>/dev/null
    fi

    log_info "  Created certificate for $domain"
}

# Generate base64-encoded certificate for API/Hook managers
generate_api_cert() {
    local cert_dir="$CERTS_DIR/api"
    local host_ip="$1"

    if [[ -f "$cert_dir/cert.pem" && -f "$cert_dir/privkey.pem" ]]; then
        log_info "  API certificate already exists"
    else
        mkdir -p "$cert_dir"

        if [[ "$USE_MKCERT" == "true" ]]; then
            # Use mkcert for locally-trusted certificates
            mkcert -cert-file "$cert_dir/cert.pem" -key-file "$cert_dir/privkey.pem" \
                voipbin.test "*.voipbin.test" localhost 127.0.0.1 ::1 "$host_ip" 2>/dev/null
            log_info "  Created API certificate (mkcert - browser trusted)"
        else
            # Fallback to self-signed OpenSSL certificate
            openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
                -keyout "$cert_dir/privkey.pem" \
                -out "$cert_dir/cert.pem" \
                -subj "/C=US/ST=Dev/L=Local/O=VoIPBin/OU=Dev/CN=voipbin.test" 2>/dev/null
            log_info "  Created API certificate (self-signed)"
        fi
    fi

    # Return base64-encoded values
    API_SSL_CERT_BASE64=$(cat "$cert_dir/cert.pem" | base64 -w0)
    API_SSL_PRIVKEY_BASE64=$(cat "$cert_dir/privkey.pem" | base64 -w0)
}

# Generate random string for JWT key
generate_random_key() {
    openssl rand -hex 32
}

# Generate sequential external IPs for services
# Uses a fixed offset from host IP to ensure unique, predictable IPs
generate_service_ips() {
    local host_ip="$1"

    # Extract the network prefix (first 3 octets) and last octet
    local prefix=$(echo "$host_ip" | cut -d'.' -f1-3)
    local host_last=$(echo "$host_ip" | cut -d'.' -f4)

    # Calculate base for service IPs (host + 8, wrapped if needed)
    local base=$((host_last + 8))
    if [[ $base -gt 250 ]]; then
        base=$((host_last - 50))
    fi
    if [[ $base -lt 2 ]]; then
        base=160
    fi

    # Assign sequential IPs (only for VoIP services that need dedicated IPs)
    KAMAILIO_EXTERNAL_IP="${prefix}.$((base))"
    RTPENGINE_EXTERNAL_IP="${prefix}.$((base + 1))"
}

# Main initialization
main() {
    echo ""
    echo "=============================================="
    echo "  VoIPBin Sandbox Initialization"
    echo "=============================================="
    echo ""

    # Check for root/sudo access
    check_root

    # Check if .env already exists
    if [[ -f "$ENV_FILE" ]]; then
        log_warn ".env file already exists at $ENV_FILE"
        read -p "Do you want to overwrite it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Keeping existing .env file"
            echo ""
            exit 0
        fi
    fi

    # Check template exists
    if [[ ! -f "$ENV_TEMPLATE" ]]; then
        log_error ".env.template not found at $ENV_TEMPLATE"
        exit 1
    fi

    # Step 1: Check for mkcert
    log_step "Checking certificate tools..."
    USE_MKCERT="false"
    if check_mkcert; then
        log_info "  mkcert found - will generate browser-trusted certificates"
        setup_mkcert_ca
        USE_MKCERT="true"
    else
        log_warn "  mkcert not found - will use self-signed certificates"
        log_warn "  Install mkcert for browser-trusted certs: sudo apt install mkcert && mkcert -install"
    fi
    echo ""

    # Step 2: Detect host IP and find external IPs for services
    log_step "Detecting network configuration..."
    HOST_IP=$(detect_host_ip)
    log_info "  Host IP: $HOST_IP"

    log_info "  Generating external IPs for VoIP services..."
    generate_service_ips "$HOST_IP"
    log_info "  Kamailio External IP:  $KAMAILIO_EXTERNAL_IP"
    log_info "  RTPEngine External IP: $RTPENGINE_EXTERNAL_IP"
    log_info "  (VoIP services need different IPs than host to avoid SIP loop detection)"
    echo ""

    # Step 3: Generate SSL certificates for SIP/TLS
    log_step "Generating SIP TLS certificates..."
    for domain in registrar.voipbin.test conference.voipbin.test sip.voipbin.test sip-service.voipbin.test trunk.voipbin.test; do
        generate_cert "$domain"
    done
    echo ""

    # Step 4: Generate API certificates
    log_step "Generating API SSL certificates..."
    generate_api_cert "$HOST_IP"
    echo ""

    # Step 5: Generate random keys
    log_step "Generating security keys..."
    STORAGE_JWT_KEY=$(generate_random_key)
    log_info "  Generated STORAGE_JWT_KEY"
    echo ""

    # Step 6: Create dummy GCP credentials file
    log_step "Creating config files..."
    mkdir -p "$PROJECT_DIR/config"
    # Remove if it's accidentally a directory
    if [ -d "$PROJECT_DIR/config/dummy-gcp-credentials.json" ]; then
        rm -rf "$PROJECT_DIR/config/dummy-gcp-credentials.json"
    fi
    cat > "$PROJECT_DIR/config/dummy-gcp-credentials.json" << 'GCPEOF'
{
  "type": "service_account",
  "project_id": "dummy-project",
  "private_key_id": "dummy",
  "private_key": "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBALRiMLAHudeSA2ai+XPJL6ym1QoXJdKbXj0AKQN2EvPcpNN/wSuP\nXtEFdOFVzFO+Y++2ABFAYBIelO4DMHXg0hECAwEAAQJAYPdAPokyZ0UPpP+pu3rq\nwNroFnEMGCKjLPq2F87h3H8cIg+X8MpNJfWfIEKlFyjJfG4P8lNz+uN+Qk7lJI/p\noQIhAOEAx+qYBvP9Tdr3MJk0CJ9JQYUcEUhz5BNLaOrfa+VtAiEAzB0bvEG1Lx8k\nUlxNoqB+IY2M6FXDWHI6fNZ7R3HSqkkCIHdq6s1bLjH0gGsR4LzJPmB8zPfY4u4v\n8i6x6xIPAd+tAiEAj8vQrNPr/5L7VELVah+D6bKDL4Qo3eiH5xcxP+J/f3ECIENY\nrh3PQJN1sObumL6LglGu+l0u+KYoPql4EbdWzaEv\n-----END RSA PRIVATE KEY-----\n",
  "client_email": "dummy@dummy-project.iam.gserviceaccount.com",
  "client_id": "123456789",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token"
}
GCPEOF
    log_info "  Created dummy GCP credentials (replace with real credentials for full functionality)"
    echo ""

    # Step 7: Create .env file
    log_step "Creating .env file..."

    cat > "$ENV_FILE" << EOF
# ==============================================================================
# VoIPBin Sandbox - Environment Configuration
# ==============================================================================
# Generated by init.sh on $(date)
# ==============================================================================

# ==============================================================================
# Google Cloud Platform (Optional - for TTS, storage, and AI features)
# Set to your service account JSON path for full functionality
# Default uses a dummy file that allows services to start without GCP
# ==============================================================================
GOOGLE_APPLICATION_CREDENTIALS=./config/dummy-gcp-credentials.json
GCP_PROJECT_ID=
GCP_BUCKET_NAME_TMP=
GCP_BUCKET_NAME_MEDIA=

# ==============================================================================
# API SSL Certificates (Auto-generated)
# ==============================================================================
API_SSL_CERT_BASE64=$API_SSL_CERT_BASE64
API_SSL_PRIVKEY_BASE64=$API_SSL_PRIVKEY_BASE64

HOOK_SSL_CERT_BASE64=$API_SSL_CERT_BASE64
HOOK_SSL_PRIVKEY_BASE64=$API_SSL_PRIVKEY_BASE64

# ==============================================================================
# SIP/VoIP Network Configuration
# ==============================================================================
# Base domain for SIP routing
BASE_DOMAIN=voipbin.test

# Host's external IP (your machine's LAN IP)
HOST_EXTERNAL_IP=$HOST_IP

# Kamailio's dedicated external IP (auto-detected available IP in your subnet)
# This MUST be different from HOST_EXTERNAL_IP to avoid SIP loop detection
KAMAILIO_EXTERNAL_IP=$KAMAILIO_EXTERNAL_IP

# RTPEngine's dedicated external IP (for RTP media traffic)
# Auto-detected available IP in your subnet
RTPENGINE_EXTERNAL_IP=$RTPENGINE_EXTERNAL_IP

# ==============================================================================
# Admin Console Configuration
# ==============================================================================
# Base hostname for Admin Console API connections (includes port)
# Default: voipbin.test:8443 (for local browser access)
# For remote access: set to server's IP or hostname:port (e.g., 192.168.1.100:8443)
BASE_HOSTNAME=voipbin.test:8443

# Domain names for extension and trunk registration
DOMAIN_NAME_EXTENSION=registrar.voipbin.test
DOMAIN_NAME_TRUNK=trunk.voipbin.test

# SIP TLS certificates path
CERTS_PATH=./certs

# ==============================================================================
# Telephony Providers (OPTIONAL - configure if needed)
# ==============================================================================
TWILIO_SID=
TWILIO_API_KEY=

TELNYX_API_KEY=
TELNYX_CONNECTION_ID=
TELNYX_PROFILE_ID=

MESSAGEBIRD_API_KEY=

# ==============================================================================
# Email Providers (OPTIONAL)
# ==============================================================================
SENDGRID_API_KEY=
MAILGUN_API_KEY=

# ==============================================================================
# AI/ML Services (OPTIONAL - for AI assistant features)
# ==============================================================================
OPENAI_API_KEY=
CARTESIA_API_KEY=
ELEVENLABS_API_KEY=
DEEPGRAM_API_KEY=

# ==============================================================================
# AWS (OPTIONAL - for transcription)
# ==============================================================================
AWS_ACCESS_KEY=
AWS_SECRET_KEY=

# ==============================================================================
# Storage
# ==============================================================================
STORAGE_JWT_KEY=$STORAGE_JWT_KEY

# ==============================================================================
# Monitoring (OPTIONAL)
# ==============================================================================
HOMER_URI=

# PSTN whitelist - defaults to HOST_EXTERNAL_IP in docker-compose.yml
PSTN_WHITELIST_IPS=
EOF

    log_info "  Created $ENV_FILE"
    echo ""

    # Step 8: Setup DNS for SIP domains
    setup_dns "$HOST_IP" "$KAMAILIO_EXTERNAL_IP" "$API_EXTERNAL_IP" "$ADMIN_EXTERNAL_IP" "$MEET_EXTERNAL_IP" "$TALK_EXTERNAL_IP"
    echo ""

    # Summary
    echo "=============================================="
    echo "  Initialization Complete!"
    echo "=============================================="
    echo ""
    log_info "Configuration:"
    log_info "  Host IP:            $HOST_IP (web services)"
    log_info "  Kamailio IP:        $KAMAILIO_EXTERNAL_IP (SIP signaling)"
    log_info "  RTPEngine IP:       $RTPENGINE_EXTERNAL_IP (RTP media)"
    log_info "  Base Domain:        voipbin.test"
    log_info "  Certificates:       $CERTS_DIR"
    log_info "  Environment:        $ENV_FILE"
    echo ""
    log_info "Web Services (Docker port mapping):"
    log_info "  http://admin.voipbin.test:3003"
    log_info "  http://meet.voipbin.test:3004"
    log_info "  http://talk.voipbin.test:3005"
    log_info "  https://api.voipbin.test:8443"
    echo ""
    log_info "SIP Services:"
    log_info "  sip.voipbin.test    → $KAMAILIO_EXTERNAL_IP"
    if [[ "$USE_MKCERT" == "true" ]]; then
        log_info "  SSL Certs:      mkcert (browser-trusted)"
    else
        log_warn "  SSL Certs:      self-signed (browser will show warnings)"
        echo ""
        log_warn "To avoid browser certificate warnings, install mkcert:"
        echo "    sudo apt install mkcert    # or: brew install mkcert"
        echo "    mkcert -install"
        echo "    rm -rf $CERTS_DIR"
        echo "    voipbin> init"
    fi
    echo ""
    log_info "Next steps:"
    echo "  1. (Optional) Edit .env to add your API keys (GCP, OpenAI, etc.)"
    echo "  2. Run: voipbin> start"
    echo ""
}

main "$@"
