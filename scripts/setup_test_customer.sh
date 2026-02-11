#!/bin/bash
#
# Setup test customer with extensions and API key
# Run this after docker-compose up or database reset
#
# The agent-manager creates admin agents with random passwords,
# so this script sets the password explicitly via agent-control CLI.
#

set -e

API_HOST="${API_HOST:-localhost}"
API_PORT="${API_PORT:-8443}"
CUSTOMER_EMAIL="${CUSTOMER_EMAIL:-admin@localhost}"
CUSTOMER_PASSWORD="${CUSTOMER_PASSWORD:-admin@localhost}"
CUSTOMER_NAME="${CUSTOMER_NAME:-Sandbox Admin}"

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

# 2. Get customer ID
echo ""
echo "Step 2: Getting customer ID..."
CUSTOMER_LIST=$(docker exec voipbin-customer-mgr /app/bin/customer-control customer list 2>/dev/null || true)
CUSTOMER_ID=$(echo "$CUSTOMER_LIST" | jq -r '.[] | select(.email == "'"$CUSTOMER_EMAIL"'") | .id' 2>/dev/null | head -1)

if [ -z "$CUSTOMER_ID" ] || [ "$CUSTOMER_ID" == "null" ]; then
    echo "ERROR: Could not find customer ID for $CUSTOMER_EMAIL"
    exit 1
fi
echo "Customer ID: $CUSTOMER_ID"

# 3. Wait for admin agent to be created by agent-manager (via RabbitMQ event)
echo ""
echo "Step 3: Waiting for admin agent to be created..."
MAX_WAIT=30
WAITED=0
ADMIN_AGENT_ID=""

while [ $WAITED -lt $MAX_WAIT ]; do
    AGENT_LIST=$(docker exec voipbin-agent-mgr /app/bin/agent-control agent list \
        --customer-id "$CUSTOMER_ID" 2>/dev/null || true)

    ADMIN_AGENT_ID=$(echo "$AGENT_LIST" | jq -r '.[0].id' 2>/dev/null)

    if [ -n "$ADMIN_AGENT_ID" ] && [ "$ADMIN_AGENT_ID" != "null" ]; then
        break
    fi

    echo -n "."
    sleep 2
    WAITED=$((WAITED + 2))
done
echo ""

if [ -z "$ADMIN_AGENT_ID" ] || [ "$ADMIN_AGENT_ID" == "null" ]; then
    echo "ERROR: Admin agent was not created in time"
    exit 1
fi
echo "Admin agent ID: $ADMIN_AGENT_ID"

# 4. Set admin password using agent-control CLI
echo ""
echo "Step 4: Setting admin password..."
docker exec voipbin-agent-mgr /app/bin/agent-control agent update-password \
    --id "$ADMIN_AGENT_ID" \
    --password "$CUSTOMER_PASSWORD" 2>&1 | grep -v severity || true
echo "Password set to: $CUSTOMER_PASSWORD"

# 5. Login to get token
echo ""
echo "Step 5: Logging in as $CUSTOMER_EMAIL..."
sleep 1
LOGIN_RESPONSE=$(curl -sk -X POST "https://${API_HOST}:${API_PORT}/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"$CUSTOMER_EMAIL\", \"password\": \"$CUSTOMER_PASSWORD\"}")

TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token')

if [ "$TOKEN" == "null" ] || [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to login. Response: $LOGIN_RESPONSE"
    exit 1
fi

echo "Login successful. Token obtained."

# 6. Create extensions
echo ""
echo "Step 6: Creating extensions..."

for EXT in 1000 2000 3000; do
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

# 7. Create API key
echo ""
echo "Step 7: Creating API key..."
ACCESSKEY_OUTPUT=$(docker exec voipbin-customer-mgr /app/bin/customer-control accesskey create \
    --customer-id "$CUSTOMER_ID" \
    --name "Sandbox API Key" \
    --detail "Auto-generated for testing" \
    --expire 87600h 2>&1 | grep -v severity || true)

API_KEY=$(echo "$ACCESSKEY_OUTPUT" | grep -oP '(?<=token:\s)[^\s]+' | head -1)
if [ -z "$API_KEY" ]; then
    API_KEY=$(echo "$ACCESSKEY_OUTPUT" | jq -r '.token' 2>/dev/null || true)
fi

if [ -z "$API_KEY" ] || [ "$API_KEY" == "null" ]; then
    echo "WARNING: Could not extract API key from output"
else
    echo "API key created: $API_KEY"
fi

# 8. Add initial billing balance
echo ""
echo "Step 8: Adding initial billing balance..."
CUSTOMER_INFO=$(curl -sk -X GET "https://${API_HOST}:${API_PORT}/v1.0/customer" \
    -H "Authorization: Bearer $TOKEN")
BILLING_ACCOUNT_ID=$(echo "$CUSTOMER_INFO" | jq -r '.billing_account_id' 2>/dev/null)

if [ -n "$BILLING_ACCOUNT_ID" ] && [ "$BILLING_ACCOUNT_ID" != "null" ]; then
    docker exec voipbin-billing-mgr /app/bin/billing-control account add-balance \
        --id "$BILLING_ACCOUNT_ID" \
        --amount 100000 2>&1 | grep -v severity || true
    echo "Added initial balance to billing account"
else
    echo "WARNING: Could not find billing account ID"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Customer ID: $CUSTOMER_ID"
echo "Admin Login: $CUSTOMER_EMAIL / $CUSTOMER_PASSWORD"
echo "API Key: $API_KEY"
echo ""
echo "Extensions:"
echo "  1000 / pass1000"
echo "  2000 / pass2000"
echo "  3000 / pass3000"
echo ""
echo "SIP Domain: ${CUSTOMER_ID}.registrar.voipbin.test"
echo ""
echo "Test registration:"
echo "  python3 softphone.py 2000 pass2000 --customer-id $CUSTOMER_ID"
