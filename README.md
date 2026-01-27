# VoIPBin Sandbox

Your local playground for exploring VoIPBin - a complete Communications Platform as a Service (CPaaS). Perfect for testing, development, and small-scale deployments.

## What You Get

- **Admin Console** - Web dashboard to manage your account
- **SIP/VoIP Services** - Make and receive calls
- **REST API** - Build your own integrations
- **Video Conferencing** - Meet with others
- **Voice Client** - Browser-based calling

## Quick Start

### 1. Install Prerequisites

```bash
# Ubuntu/Debian
sudo apt install docker.io docker-compose python3-pip mkcert
pip3 install alembic mysqlclient PyMySQL
mkcert -install

# macOS
brew install docker docker-compose python3 mkcert
pip3 install alembic mysqlclient PyMySQL
mkcert -install
```

### 2. Start Everything

```bash
sudo ./scripts/start.sh
```

That's it! The script handles all the setup automatically.

### 3. Access Your Services

| Service | URL | Login |
|---------|-----|-------|
| Admin Console | http://admin.voipbin.test:3003 | admin@localhost / admin@localhost |
| Meet | http://meet.voipbin.test:3004 | - |
| Talk | http://talk.voipbin.test:3005 | - |
| API | https://api.voipbin.test:8443 | JWT token |

A test account with 3 phone extensions (1000, 2000, 3000) is created automatically.

## Common Tasks

### Stop Services
```bash
./scripts/stop.sh
```

### Start Fresh (Reset Everything)
```bash
./scripts/stop.sh --clean
sudo ./scripts/start.sh
```

### View Logs
```bash
docker compose logs -f api-manager
```

### Check Status
```bash
docker compose ps
```

## Troubleshooting

### Can't access admin.voipbin.test?

**DNS not working:**
```bash
sudo ./scripts/setup-dns.sh
```

**Certificate error in browser:**
```bash
# Regenerate trusted certificates
sudo rm -rf certs/
sudo ./scripts/init.sh
docker compose restart api-manager
# Then restart your browser
```

### Services won't start?

```bash
# Restart everything
docker compose down
sudo ./scripts/start.sh
```

### Need more help?

Check the detailed logs:
```bash
docker compose logs -f
```

## Optional: Add API Keys

Edit `.env` to enable additional features:

| Feature | Environment Variable |
|---------|---------------------|
| AI/Chatbot | `OPENAI_API_KEY` |
| Phone Numbers | `TWILIO_SID`, `TWILIO_API_KEY` |
| Cloud Storage | `GOOGLE_APPLICATION_CREDENTIALS` |
| Email | `SENDGRID_API_KEY` |

Core calling features work without any API keys.

## Network Configuration

The sandbox uses two types of IP addresses:

**Web Services** - Use your host IP with Docker port mapping:
```
http://admin.voipbin.test:3003  → HOST_IP:3003 → container
http://meet.voipbin.test:3004   → HOST_IP:3004 → container
http://talk.voipbin.test:3005   → HOST_IP:3005 → container
https://api.voipbin.test:8443   → HOST_IP:8443 → container
```

**VoIP Services** - Use a dedicated IP for SIP (to avoid loop detection):
```
Your Host IP:  192.168.45.152
Kamailio:      192.168.45.160  (SIP signaling, ports 5060/5061/80/443)
RTPEngine:     192.168.45.161  (RTP media, ports 20000-30000)
```

These IPs are generated when you run `init.sh` and stored in `.env`.

## For Developers

### API Access

Base URL: `https://api.voipbin.test`

```bash
# Get auth token
curl -sk -X POST https://api.voipbin.test/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin@localhost", "password": "admin@localhost"}'
```

### SIP Registration

Extensions can register using SIP:
- **Server:** Use your machine's IP (check with `hostname -I`)
- **Domain:** `{customer_id}.registrar.voipbin.test`
- **Extensions:** 1000, 2000, 3000
- **Passwords:** pass1000, pass2000, pass3000

### CLI Tool

```bash
sudo ./voipbin help
sudo ./voipbin network status
sudo ./voipbin dns status
```

## Architecture Overview

```
Browser/SIP Phone
       ↓
   VoIPBin Sandbox
       ↓
┌─────────────────────────────────┐
│  Kamailio (SIP Proxy)           │
│  RTPEngine (Media)              │
│  Asterisk (Call Processing)     │
│  Manager Services (Business)    │
│  MySQL / Redis / RabbitMQ       │
└─────────────────────────────────┘
```

## License

See LICENSE file for details.
