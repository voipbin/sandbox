# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the **VoIPBin sandbox** - a Docker Compose development environment for running the complete VoIPBin CPaaS (Communications Platform as a Service) stack locally. It orchestrates 25+ microservices along with supporting infrastructure.

## Quick Start

```bash
# One command to start everything
./scripts/start.sh
```

The `start.sh` script handles everything:
- Environment initialization (generates .env and certificates if missing)
- Database startup and schema migration
- Starting all 25+ services
- VoIP network interface setup (prompts for sudo password)
- Creating test account and extensions automatically

### Step-by-Step Alternative

```bash
./scripts/init.sh              # 1. Generate .env and certificates
nano .env                      # 2. Add your API keys (GCP, OpenAI, etc.)
./scripts/start.sh             # 3. Start all services + create test data
```

### Other Useful Commands

```bash
# Start everything
./scripts/start.sh

# Stop all services (preserves data)
./scripts/stop.sh

# Stop and remove volumes (full reset)
./scripts/stop.sh --clean

# Stop and teardown VoIP network interfaces
./scripts/stop.sh --network

# Stop and remove DNS configuration
sudo ./scripts/stop.sh --dns

# Full cleanup: volumes + network + DNS
sudo ./scripts/stop.sh --all

# View logs for a specific service
docker compose logs -f api-manager

# Start specific services only
docker compose up -d db redis rabbitmq
```

### Database Management

The database uses vanilla MySQL with schema managed by alembic migrations from the monorepo.

```bash
# Initialize database (first time or after volume reset)
docker compose up -d db
./scripts/init_database.sh

# Re-run migrations (after schema updates)
./scripts/init_database.sh

# Access MySQL directly (for debugging only)
docker exec -it voipbin-db mysql -uroot -proot_password bin_manager
```

The `init_database.sh` script:
1. Creates `bin_manager` and `asterisk` databases
2. Downloads schema from monorepo's `bin-dbscheme-manager`
3. Runs alembic migrations to create all tables

**Note:** Requires `alembic` and `mysqlclient` Python packages installed locally.

## Environment Setup

**Prerequisites:**
- `pip3 install alembic mysqlclient PyMySQL` - for database migrations
- `mkcert` (recommended) - for browser-trusted SSL certificates
  ```bash
  sudo apt install mkcert && mkcert -install
  ```

The `./scripts/init.sh` script auto-generates `.env` with detected values. If `mkcert` is installed, it creates browser-trusted certificates. Otherwise, it falls back to self-signed certificates (browser will show warnings).

## DNS Configuration

VoIPBin uses the `.voipbin.test` domain (IANA reserved TLD per RFC 2606) for SIP routing. The setup scripts automatically configure DNS forwarding.

### Architecture

**Linux (CoreDNS on port 53):**
```
Application / SIP Client
    ↓ DNS query
/etc/resolv.conf → 127.0.0.1
    ↓
CoreDNS (Docker container, port 53)
    ↓
*.voipbin.test → host IP (from Corefile)
other queries  → 8.8.8.8 (forwarded)
```

**macOS (/etc/resolver):**
```
Application / SIP Client
    ↓ DNS query for *.voipbin.test
macOS resolver
    ↓ routes .voipbin.test queries (config: /etc/resolver/voipbin.test)
CoreDNS (Docker container, port 53)
    ↓ wildcard response
Returns host IP (from config/coredns/Corefile)
```

### Key Files

| File | Purpose |
|------|---------|
| `/etc/resolv.conf` | Linux: Points to 127.0.0.1 (CoreDNS) |
| `/etc/resolv.conf.voipbin-backup` | Linux: Backup of original resolv.conf |
| `/etc/resolver/voipbin.test` | macOS: Routes .voipbin.test to CoreDNS |
| `config/coredns/Corefile` | CoreDNS config (wildcard + forwarding) |

### Troubleshooting DNS

```bash
# Check CoreDNS is running
docker ps | grep voipbin-dns

# Test CoreDNS directly
dig @127.0.0.1 voipbin.test

# Test system DNS resolution
dig voipbin.test
ping registrar.voipbin.test

# Linux: Check resolv.conf
cat /etc/resolv.conf  # Should show nameserver 127.0.0.1

# Linux: Check backup exists
cat /etc/resolv.conf.voipbin-backup

# macOS: Check config
cat /etc/resolver/voipbin.test

# Re-run DNS setup
sudo ./scripts/setup-dns.sh
```

### Configuring SIP Devices on Your Network

SIP phones and softphones on your LAN can use the sandbox's DNS server to resolve `*.voipbin.test` domains:

1. **Find your host IP** (shown in `.env` as `HOST_EXTERNAL_IP`, e.g., `192.168.45.152`)

2. **Configure your SIP device's DNS** to point to that IP:
   - DNS Server: `192.168.45.152` (your host IP)

3. **Configure SIP registration:**
   - SIP Server: `sip.voipbin.test` or `{customer_id}.registrar.voipbin.test`
   - The device will resolve this to Kamailio's IP automatically

This works because CoreDNS listens on the host's LAN IP, not just localhost.

### Removing DNS Configuration

To completely remove the DNS configuration:
```bash
sudo ./scripts/setup-dns.sh --uninstall
# or
voipbin> clean --dns
```

This restores:
- Linux: Original `/etc/resolv.conf` from backup
- macOS: Removes `/etc/resolver/voipbin.test`

Key variables:

| Variable | Purpose |
|----------|---------|
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to GCP service account JSON |
| `API_SSL_CERT_BASE64` / `API_SSL_PRIVKEY_BASE64` | Base64-encoded TLS certs for API |
| `OPENAI_API_KEY` | AI/chatbot features |
| `TWILIO_SID` / `TWILIO_API_KEY` | Phone number provisioning |
| `TELNYX_API_KEY` / `TELNYX_CONNECTION_ID` | Telnyx telephony |
| `SENDGRID_API_KEY` / `MAILGUN_API_KEY` | Email delivery |
| `AWS_ACCESS_KEY` / `AWS_SECRET_KEY` | Transcription (AWS Transcribe) |
| `DOMAIN_NAME_EXTENSION` | SIP domain suffix for extensions (default: `registrar.voipbin.test`) |
| `HOST_EXTERNAL_IP` | Host's LAN IP (auto-detected) |
| `KAMAILIO_EXTERNAL_IP` | Kamailio's dedicated external IP for SIP signaling (auto-generated, MUST differ from host) |
| `RTPENGINE_EXTERNAL_IP` | RTPEngine's dedicated external IP for RTP media (auto-generated) |
| `API_EXTERNAL_IP` | API Manager's external IP (iptables forwards to 10.100.0.100:443) |
| `ADMIN_EXTERNAL_IP` | Admin Console's external IP (iptables forwards to 10.100.0.101:80) |
| `MEET_EXTERNAL_IP` | Meet's external IP (iptables forwards to 10.100.0.102:80) |
| `TALK_EXTERNAL_IP` | Talk's external IP (iptables forwards to 10.100.0.103:80) |
| `BASE_HOSTNAME` | Base hostname for frontend apps (default: `voipbin.test`) |
| `API_URL` | API endpoint URL for admin/talk (default: `https://api.voipbin.test:8443/`) |
| `WEBSOCKET_URL` | WebSocket URL for admin/talk (default: `wss://api.voipbin.test:8443/v1.0/ws`) |
| `REGISTRAR_URL` | SIP registrar WebSocket URL for talk (default: `wss://sip.voipbin.test:5066`) |
| `REGISTRAR_DOMAIN` | SIP registrar domain for admin/talk (default: `registrar.voipbin.test`) |
| `CONFERENCE_URL` | Conference WebSocket URL for meet (default: `wss://conference.voipbin.test`) |
| `CONFERENCE_DOMAIN` | Conference domain for meet (default: `conference.voipbin.test`) |

## VoIP Network Configuration

The VoIP stack uses a combination of Docker networks and host network interfaces for SIP/RTP traffic.

### Why Kamailio Needs a Different IP

**Important:** Kamailio MUST use a different IP than the host machine to avoid SIP loop detection. When you test SIP calls from the host:

- If Kamailio uses the same IP as the host → Kamailio sees the source IP matches its own → Drops the request as a "loop"
- If Kamailio uses a different IP → Request is processed normally

The `init` script automatically finds an available IP in your subnet for Kamailio.

### Network Architecture

```
Docker Network:
└── default (10.100.0.0/16)         # All services
    ├── api-manager: 10.100.0.100
    ├── square-admin: 10.100.0.101
    ├── square-meet: 10.100.0.102
    ├── square-talk: 10.100.0.103
    ├── kamailio-int: 10.100.0.200
    ├── rtpengine-int: 10.100.0.201
    ├── ast-call: 10.100.0.210
    ├── ast-registrar: 10.100.0.211
    └── ast-conf: 10.100.0.212

Host Network (macvlan interfaces):
├── kamailio-int (10.100.0.200)     # Kamailio internal communication
└── rtpengine-int (10.100.0.201)    # RTPEngine internal communication

External (host's physical interface - SEVEN IPs):
├── HOST_EXTERNAL_IP (e.g., 192.168.45.152)        # Host's primary IP
├── KAMAILIO_EXTERNAL_IP (e.g., 192.168.45.252)    # Kamailio's dedicated IP (SIP signaling)
├── RTPENGINE_EXTERNAL_IP (e.g., 192.168.45.253)   # RTPEngine's dedicated IP (RTP media)
├── API_EXTERNAL_IP (e.g., 192.168.45.202)         # API (iptables → 10.100.0.100:443)
├── ADMIN_EXTERNAL_IP (e.g., 192.168.45.201)       # Admin (iptables → 10.100.0.101:80)
├── MEET_EXTERNAL_IP (e.g., 192.168.45.203)        # Meet (iptables → 10.100.0.102:80)
└── TALK_EXTERNAL_IP (e.g., 192.168.45.204)        # Talk (iptables → 10.100.0.103:80)
```

### DNS Resolution

| Domain | Resolves To | Purpose |
|--------|-------------|---------|
| api.voipbin.test | API_EXTERNAL_IP | API Manager (iptables → 10.100.0.100:443) |
| admin.voipbin.test | ADMIN_EXTERNAL_IP | Admin Console (iptables → 10.100.0.101:80) |
| meet.voipbin.test | MEET_EXTERNAL_IP | Meet (iptables → 10.100.0.102:80) |
| talk.voipbin.test | TALK_EXTERNAL_IP | Talk (iptables → 10.100.0.103:80) |
| sip.voipbin.test | KAMAILIO_EXTERNAL_IP | SIP proxy |
| pstn.voipbin.test | KAMAILIO_EXTERNAL_IP | PSTN gateway |
| trunk.voipbin.test | KAMAILIO_EXTERNAL_IP | SIP trunking |
| *.registrar.voipbin.test | KAMAILIO_EXTERNAL_IP | SIP registration |

**External IP Architecture:**
```
External Client → EXTERNAL_IP:port
                      ↓ iptables DNAT
                  Container IP:port

Examples:
  api.voipbin.test:443   → 10.100.0.100:443 (api-manager)
  admin.voipbin.test:80  → 10.100.0.101:80 (square-admin)
  meet.voipbin.test:80   → 10.100.0.102:80 (square-meet)
  talk.voipbin.test:80   → 10.100.0.103:80 (square-talk)
```

### Internal Interfaces

The `setup-voip-network.sh` script creates macvlan interfaces that bridge Docker's internal network to the host:

- **kamailio-int** (10.100.0.200): Allows Kamailio to communicate with containerized services
- **rtpengine-int** (10.100.0.201): Allows RTPEngine to communicate with containerized services

### CLI Commands

```bash
# Show network configuration status
sudo ./voipbin network status

# Setup VoIP network interfaces
sudo ./voipbin network setup

# Setup with specific external IP (if auto-detected one doesn't work)
sudo ./voipbin network setup --external-ip 192.168.45.160

# Teardown network interfaces
sudo ./voipbin network teardown

# Check DNS resolution
sudo ./voipbin dns status
sudo ./voipbin dns test
```

### Manual IP Configuration

If you need to change external IPs after initialization:

```bash
# Edit .env
nano .env
# Change any of:
#   KAMAILIO_EXTERNAL_IP=192.168.45.xxx
#   RTPENGINE_EXTERNAL_IP=192.168.45.xxx
#   API_EXTERNAL_IP=192.168.45.xxx
#   ADMIN_EXTERNAL_IP=192.168.45.xxx
#   MEET_EXTERNAL_IP=192.168.45.xxx
#   TALK_EXTERNAL_IP=192.168.45.xxx

# Regenerate DNS and network configuration
sudo ./voipbin dns regenerate
sudo ./voipbin network setup
sudo ./voipbin restart kamailio
```

## Architecture

### Infrastructure Services

| Service | Container | Ports | Purpose |
|---------|-----------|-------|---------|
| `db` | voipbin-db | 3306 | MySQL with pre-seeded schema |
| `redis` | voipbin-redis | - | Cache and session storage |
| `rabbitmq` | voipbin-mq | 5672, 15672 | Message broker with delayed exchange plugin |
| `coredns` | voipbin-dns | 53 | DNS server (*.voipbin.test + forwarding) |

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

| Service | Container | Container IP | Purpose |
|---------|-----------|--------------|---------|
| `square-admin` | voipbin-admin | 10.100.0.101:80 | Admin dashboard UI |
| `square-meet` | voipbin-meet | 10.100.0.102:80 | Video conferencing |
| `square-talk` | voipbin-talk | 10.100.0.103:80 | Voice client |

Each frontend service has a dedicated external IP with iptables forwarding (see DNS Resolution section).

## Web Access

All web services use dedicated external IPs with iptables forwarding to containers:

| Service | URL | External IP → Container |
|---------|-----|-------------------------|
| API Manager | https://api.voipbin.test | API_EXTERNAL_IP:443 → 10.100.0.100:443 |
| Admin Console | http://admin.voipbin.test | ADMIN_EXTERNAL_IP:80 → 10.100.0.101:80 |
| Meet | http://meet.voipbin.test | MEET_EXTERNAL_IP:80 → 10.100.0.102:80 |
| Talk | http://talk.voipbin.test | TALK_EXTERNAL_IP:80 → 10.100.0.103:80 |

SIP services (sip.voipbin.test, pstn.voipbin.test, etc.) resolve to KAMAILIO_EXTERNAL_IP.

**Check configured IPs:**
```bash
sudo ./voipbin network status
sudo ./voipbin dns status
```

### SSL Certificate Trust (Important!)

When using self-signed certificates, browsers block API requests from the Admin Console because the certificate is not trusted. **You must manually accept the API certificate first:**

1. Open a new browser tab and navigate to: `https://api.voipbin.test`
2. You'll see a "Your connection is not private" warning
3. Click **"Advanced"** → **"Proceed to api.voipbin.test (unsafe)"**
4. You should see a JSON response or error page from the API
5. Now go to `http://admin.voipbin.test` and login will work

**Note:** This step is required because browser fetch/XHR requests don't show certificate acceptance prompts - they fail silently with `ERR_CERT_AUTHORITY_INVALID`.

### Browser-Trusted Certificates (Recommended)

To avoid the manual certificate acceptance step, use `mkcert`:

```bash
# Install mkcert
sudo apt install mkcert   # Ubuntu/Debian
brew install mkcert       # macOS

# Install the CA (makes certificates browser-trusted)
mkcert -install

# Regenerate certificates
rm -rf certs/
sudo ./voipbin init

# Restart browser
```

After this, `https://api.voipbin.test` will be trusted automatically.

## Test Data Setup

The `start.sh` script automatically creates a test account on first run:
- **Customer:** admin@localhost (login: admin@localhost / admin@localhost)
- **Extensions:** 1000, 2000, 3000 (passwords: pass1000, pass2000, pass3000)

**IMPORTANT: Never modify the database directly. Always use CLIs and APIs.**

### Manual Setup (if needed)

If you need to recreate test data after a reset:

```bash
./scripts/setup_test_customer.sh
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
  --email "admin@localhost"
```

#### 2. Login to Get JWT Token

```bash
# Login with admin credentials (username=password=email)
curl -sk -X POST https://localhost:8443/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin@localhost", "password": "admin@localhost"}'

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
{customer_id}.registrar.voipbin.test
```

Example: `9e75d9a8-c289-4104-9ea6-8f6e238501f4.registrar.voipbin.test`

**Important**: Configure `DOMAIN_NAME_EXTENSION=registrar.voipbin.test` in `.env` for correct domain format. The registrar-manager uses this to generate the full domain `{customer_id}.registrar.voipbin.test`.

**Troubleshooting**: If extensions are created with wrong domain (e.g., `.voipbin.test` instead of `.registrar.voipbin.test`):
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
    ↓ filters by domain: {customer_id}.registrar.voipbin.test
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
