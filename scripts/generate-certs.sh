#!/bin/bash
# Generate self-signed certificates for local VoIPBin development
# These certificates are for development only - do not use in production!

set -e

CERTS_DIR="${1:-./certs}"
DOMAIN_BASE="${2:-voipbin.net}"

# Certificate domains
DOMAINS=(
    "registrar.${DOMAIN_BASE}"
    "sip.${DOMAIN_BASE}"
    "sip-service.${DOMAIN_BASE}"
    "conference.${DOMAIN_BASE}"
)

echo "Generating self-signed certificates for local development..."
echo "Certificates will be created in: ${CERTS_DIR}"
echo ""

# Create base certs directory
mkdir -p "${CERTS_DIR}"

# Generate certificates for each domain
for DOMAIN in "${DOMAINS[@]}"; do
    DOMAIN_DIR="${CERTS_DIR}/${DOMAIN}"
    mkdir -p "${DOMAIN_DIR}"

    echo "Generating certificate for: ${DOMAIN}"

    # Generate private key
    openssl genrsa -out "${DOMAIN_DIR}/privkey.pem" 2048 2>/dev/null

    # Generate self-signed certificate
    openssl req -new -x509 \
        -key "${DOMAIN_DIR}/privkey.pem" \
        -out "${DOMAIN_DIR}/cert.pem" \
        -days 365 \
        -subj "/C=US/ST=Development/L=Local/O=VoIPBin Dev/OU=Engineering/CN=${DOMAIN}" \
        -addext "subjectAltName = DNS:${DOMAIN}, DNS:*.${DOMAIN}" \
        2>/dev/null

    # Create fullchain (in development, it's just the cert)
    cp "${DOMAIN_DIR}/cert.pem" "${DOMAIN_DIR}/fullchain.pem"

    # Create chain (empty for self-signed)
    touch "${DOMAIN_DIR}/chain.pem"

    echo "  Created: ${DOMAIN_DIR}/"
    echo "    - privkey.pem"
    echo "    - cert.pem"
    echo "    - fullchain.pem"
    echo "    - chain.pem"
done

echo ""
echo "Certificate generation complete!"
echo ""
echo "Note: These are self-signed certificates for development only."
echo "You may need to add them to your system's trusted certificates"
echo "or accept security warnings in your softphone."
