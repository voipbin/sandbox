# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the **VoIPBin sandbox** - a Docker Compose development environment for running the complete VoIPBin CPaaS (Communications Platform as a Service) stack locally. It orchestrates 25+ microservices along with supporting infrastructure.

## Quick Start

```bash
# Start all services
docker compose up -d

# Start specific services (e.g., core infrastructure only)
docker compose up -d db redis rabbitmq

# View logs for a specific service
docker compose logs -f api-manager

# Stop all services
docker compose down

# Stop and remove volumes (full reset)
docker compose down -v
```

## Environment Setup

Copy `.env` and configure required API keys. Key variables:

| Variable | Purpose |
|----------|---------|
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to GCP service account JSON |
| `API_SSL_CERT_BASE64` / `API_SSL_PRIVKEY_BASE64` | Base64-encoded TLS certs for API |
| `OPENAI_API_KEY` | AI/chatbot features |
| `TWILIO_SID` / `TWILIO_API_KEY` | Phone number provisioning |
| `TELNYX_API_KEY` / `TELNYX_CONNECTION_ID` | Telnyx telephony |
| `SENDGRID_API_KEY` / `MAILGUN_API_KEY` | Email delivery |
| `AWS_ACCESS_KEY` / `AWS_SECRET_KEY` | Transcription (AWS Transcribe) |
| `DOMAIN_NAME_EXTENSION` | SIP domain suffix for extensions (default: `registrar.localhost`) |
| `KAMAILIO_EXTERNAL_ADDR` | External IP for SIP Contact headers (your LAN IP for softphone access) |

## Architecture

### Infrastructure Services

| Service | Container | Ports | Purpose |
|---------|-----------|-------|---------|
| `db` | voipbin-db | 3306 | MySQL with pre-seeded schema |
| `redis` | voipbin-redis | - | Cache and session storage |
| `rabbitmq` | voipbin-mq | 5672, 15672 | Message broker with delayed exchange plugin |

### VoIP Stack

| Service | Container | Ports | Purpose |
|---------|-----------|-------|---------|
| `kamailio` | voipbin-kamailio | 5060/udp+tcp | SIP proxy and routing |
| `asterisk-registrar` | voipbin-ast-registrar | 5082/udp | SIP registration (realtime DB) |
| `asterisk-call` | voipbin-ast-call | 5080/udp+tcp, 10000-10050/udp | Call server |
| `asterisk-call-proxy` | voipbin-ast-call-proxy | - | ARI/AMI bridge to RabbitMQ |

### Manager Services

All manager services follow this pattern:
- Connect to MySQL via `DATABASE_DSN`
- Connect to RabbitMQ via `RABBITMQ_ADDRESS`
- Connect to Redis via `REDIS_ADDRESS`
- Expose Prometheus metrics on `:2112/metrics`

Key services:
- `api-manager` (port 8443) - External REST API gateway
- `customer-manager` - Customer and extension management
- `call-manager` - Call routing and control
- `flow-manager` - Workflow execution engine
- `billing-manager` - Usage tracking
- `registrar-manager` - SIP registration

### Frontend

| Service | Container | Ports | Purpose |
|---------|-----------|-------|---------|
| `square-admin` | voipbin-admin | 3003 | Admin dashboard UI |

## Test Data Setup

**IMPORTANT: Never modify the database directly. Always use CLIs and APIs.**

The database can be reset at any time. Use the setup script or follow the manual steps below.

### Quick Setup (Recommended)

```bash
cd scripts
./setup_test_customer.sh
```

### Manual Setup Steps

#### 1. Check/Create Customer

```bash
# List existing customers
docker exec voipbin-customer-mgr /app/bin/customer-control customer list

# Create new customer (creates admin agent automatically)
# Admin username = email, password = email
docker exec voipbin-customer-mgr /app/bin/customer-control customer create \
  --name "Test Customer" \
  --email "test@example.com"
```

#### 2. Login to Get JWT Token

```bash
# Login with admin credentials (username=password=email)
curl -sk -X POST https://localhost:8443/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "test@example.com", "password": "test@example.com"}'

# Response contains: {"username": "...", "token": "JWT_TOKEN_HERE"}
```

#### 3. Create Extensions via API

```bash
TOKEN="<jwt_token_from_step_2>"

# Create extension
curl -sk -X POST https://localhost:8443/v1.0/extensions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"extension": "2000", "password": "pass2000", "name": "Extension 2000"}'
```

#### 4. Create API Key via API

```bash
# expire = Unix timestamp (required, must be in the future)
EXPIRE=$(($(date +%s) + 31536000))  # 1 year from now

curl -sk -X POST https://localhost:8443/v1.0/accesskeys \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"name\": \"API Key\", \"detail\": \"For testing\", \"expire\": $EXPIRE}"

# Response contains: {"token": "API_KEY_HERE", ...}
```

#### 5. Get Customer ID

```bash
curl -sk -X GET https://localhost:8443/v1.0/customer \
  -H "Authorization: Bearer $TOKEN"

# Response contains customer_id needed for SIP domain
```

### SIP Domain Format

All SIP requests from external clients must use the correct domain for Kamailio routing:

```
{customer_id}.registrar.localhost
```

Example: `9e75d9a8-c289-4104-9ea6-8f6e238501f4.registrar.localhost`

**Important**: Configure `DOMAIN_NAME_EXTENSION=registrar.localhost` in `.env` for correct domain format. The registrar-manager uses this to generate the full domain `{customer_id}.registrar.localhost`.

**Troubleshooting**: If extensions are created with wrong domain (e.g., `.localhost` instead of `.registrar.localhost`):
1. Check for shell environment variables overriding `.env`: `env | grep DOMAIN_NAME`
2. Unset any conflicting vars: `unset DOMAIN_NAME_EXTENSION DOMAIN_NAME_TRUNK`
3. Verify docker compose sees correct values: `docker compose config | grep DOMAIN`
4. Recreate registrar-manager: `docker compose rm -fsv registrar-manager && docker compose up -d registrar-manager`
5. Delete and recreate extensions via API to regenerate with correct domain

## Common Operations

```bash
# Rebuild a specific service after code changes
docker compose build api-manager
docker compose up -d api-manager

# Access MySQL (for debugging only - don't modify data directly)
docker exec -it voipbin-db mysql -uroot -proot_password bin_manager

# Access RabbitMQ management UI
# Open http://localhost:15672 (guest/guest)

# Check service health
docker compose ps
docker exec voipbin-ast-call asterisk -rx "core show help"

# View Asterisk CLI
docker exec -it voipbin-ast-call asterisk -rvvv

# View Kamailio logs
docker logs -f voipbin-kamailio

# Check PJSIP endpoints (asterisk-registrar uses realtime DB - no reload needed)
docker exec voipbin-ast-registrar asterisk -rx "pjsip show endpoints"
```

## Service Dependencies

```
db, redis, rabbitmq (infrastructure)
    └── All manager services depend on these
        └── asterisk-call-proxy depends on asterisk-call
            └── call-manager depends on asterisk-call-proxy
                └── square-admin depends on api-manager
```

## Volumes

| Volume | Purpose |
|--------|---------|
| `db_data` | MySQL data persistence |
| `asterisk-call-recording` | Call recordings |

## Testing Extension-to-Extension Calls

### SIP Registration Test

```bash
# Register extension (use customer_id from setup)
python3 scripts/softphone.py 2000 pass2000 \
  --server 192.168.45.152 \
  --customer-id <customer_id>

# Verify registration in Asterisk
docker exec voipbin-ast-registrar asterisk -rx "pjsip show contacts"
```

### Test Call Script

```bash
# Run test call from 2000 to 3000
python3 scripts/test_call.py
```

### SIP Routing Architecture

```
External SIP Client
    ↓
Kamailio (192.168.45.152:5060)
    ↓ filters by domain: {customer_id}.registrar.localhost
Asterisk Registrar (5082) - for REGISTER
Asterisk Call (5080) - for INVITE
    ↓
Back through Kamailio to destination
```

### Known Limitations

**Flow Execution Timing Issue**: The VoIPBin platform's `confbridge_join` action completes immediately after the B-leg starts joining the conference, rather than waiting for the call to end. This causes the A-leg flow to terminate and send BYE/CANCEL before the B-leg can fully answer.

- **SIP routing works correctly**: INVITE reaches the softphone, 180/200 responses return through Kamailio
- **Call terminates prematurely**: The flow-manager's `confbridge_join` action completes too early
- **Workaround**: For testing SIP routing, verify that:
  1. INVITE is relayed to the softphone
  2. 180 Ringing is received
  3. 200 OK is received
  4. This confirms the SIP layer is functioning correctly

## API Reference

Base URL: `https://localhost:8443`

### Authentication
- `POST /auth/login` - Get JWT token (body: `{"username": "email", "password": "email"}`)

### Extensions
- `GET /v1.0/extensions` - List extensions
- `POST /v1.0/extensions` - Create extension
- `GET /v1.0/extensions/:id` - Get extension
- `DELETE /v1.0/extensions/:id` - Delete extension

### Access Keys
- `GET /v1.0/accesskeys` - List API keys
- `POST /v1.0/accesskeys` - Create API key (requires `expire` timestamp)
- `DELETE /v1.0/accesskeys/:id` - Delete API key

### Customer
- `GET /v1.0/customer` - Get current customer info

## Commit Message Format

Use project prefix `sandbox:` for changes:

```
Summary of changes (max 72 chars)

- sandbox: Specific change description
```
