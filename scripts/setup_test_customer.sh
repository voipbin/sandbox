#!/bin/bash
#
# Setup test customer with extensions and API key
# Run this after docker-compose up or database reset
#

set -e

API_HOST="${API_HOST:-localhost}"
API_PORT="${API_PORT:-8443}"
CUSTOMER_EMAIL="${CUSTOMER_EMAIL:-test@example.com}"
CUSTOMER_NAME="${CUSTOMER_NAME:-Test Customer}"

echo "=== VoIPBin Sandbox Setup ==="
echo ""

# 1. Check/Create customer
echo "Step 1: Checking existing customers..."
EXISTING=$(docker exec voipbin-customer-mgr /app/bin/customer-control customer list 2>&1 | grep -c "$CUSTOMER_EMAIL" || true)

if [ "$EXISTING" -gt 0 ]; then
    echo "Customer $CUSTOMER_EMAIL already exists"
else
    echo "Creating customer: $CUSTOMER_EMAIL"
    docker exec voipbin-customer-mgr /app/bin/customer-control customer create \
        --name "$CUSTOMER_NAME" \
        --email "$CUSTOMER_EMAIL" 2>&1 | grep -E "(Success|ID:)" || true
fi

# 2. Login to get token
echo ""
echo "Step 2: Logging in as $CUSTOMER_EMAIL..."
LOGIN_RESPONSE=$(curl -sk -X POST "https://${API_HOST}:${API_PORT}/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"$CUSTOMER_EMAIL\", \"password\": \"$CUSTOMER_EMAIL\"}")

TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token')

if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to login. Response: $LOGIN_RESPONSE"
    exit 1
fi

echo "Login successful. Token obtained."

# 3. Create extensions
echo ""
echo "Step 3: Creating extensions..."

for EXT in 2000 3000; do
    echo "  Creating extension $EXT..."
    RESULT=$(curl -sk -X POST "https://${API_HOST}:${API_PORT}/v1.0/extensions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d "{\"extension\": \"$EXT\", \"password\": \"pass$EXT\", \"name\": \"Extension $EXT\"}" 2>&1)

    if echo "$RESULT" | jq -e '.id' > /dev/null 2>&1; then
        EXT_ID=$(echo "$RESULT" | jq -r '.id')
        echo "    Created: $EXT_ID"
    else
        echo "    Already exists or error: $(echo "$RESULT" | head -c 100)"
    fi
done

# 4. Create API key
echo ""
echo "Step 4: Creating API key..."
EXPIRE=$(($(date +%s) + 31536000))  # 1 year from now

ACCESSKEY_RESPONSE=$(curl -sk -X POST "https://${API_HOST}:${API_PORT}/v1.0/accesskeys" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"name\": \"Sandbox API Key\", \"detail\": \"Auto-generated for testing\", \"expire\": $EXPIRE}")

API_KEY=$(echo "$ACCESSKEY_RESPONSE" | jq -r '.token')

if [ "$API_KEY" == "null" ] || [ -z "$API_KEY" ]; then
    echo "ERROR: Failed to create API key. Response: $ACCESSKEY_RESPONSE"
else
    echo "API key created: $API_KEY"
fi

# 5. Get customer ID for SIP domain
echo ""
echo "Step 5: Getting customer info..."
CUSTOMER_INFO=$(curl -sk -X GET "https://${API_HOST}:${API_PORT}/v1.0/customer" \
    -H "Authorization: Bearer $TOKEN")

CUSTOMER_ID=$(echo "$CUSTOMER_INFO" | jq -r '.id')

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Customer ID: $CUSTOMER_ID"
echo "Admin Login: $CUSTOMER_EMAIL / $CUSTOMER_EMAIL"
echo "API Key: $API_KEY"
echo ""
echo "Extensions:"
echo "  2000 / pass2000"
echo "  3000 / pass3000"
echo ""
echo "SIP Domain: ${CUSTOMER_ID}.registrar.localhost"
echo ""
echo "Test registration:"
echo "  python3 softphone.py 2000 pass2000 --customer-id $CUSTOMER_ID"
