# VoIPBin Sandbox

```
          ████████
   ██████████████████████    __     __   ___ ____  ____  _
  ██                    ██   \ \   / /__|_ _|  _ \| __ )(_)_ __
 ██████████████████████████   \ \ / / _ \| || |_) |  _ \| | '_ \
 ██                      ██    \ V / (_) | ||  __/| |_) | | | | |
  ██    ██   ██   ██    ██      \_/ \___/___|_|   |____/|_|_| |_|
  ██    ██   ██   ██    ██          Connect & Collaborate for all
  ██    ██   ██   ██    ██                S A N D B O X
  ██    ██   ██   ██    ██
   ██   ██   ██   ██   ██
   ██████████████████████
```

Your all-in-one communication platform. Voice calls, video conferencing, messaging, and APIs - running on your own machine.

## What's Included

- **Admin Console** - Manage everything from your browser
- **Meet** - Video conferencing and collaboration
- **Talk** - Voice and messaging client
- **SIP Integration** - Connect phones and softphones
- **REST API** - Build your own communication apps

## Getting Started

### Step 1: Install Requirements

**Ubuntu/Debian:**
```bash
sudo apt install docker.io docker-compose python3-pip mkcert
pip3 install alembic mysqlclient PyMySQL
mkcert -install
```

**macOS:**
```bash
brew install docker docker-compose python3 mkcert
pip3 install alembic mysqlclient PyMySQL
mkcert -install
```

### Step 2: Run VoIPBin

```bash
sudo ./voipbin
```

This opens the interactive CLI. Follow the guided setup:

```
voipbin> init      # First time: initialize configuration
voipbin> start     # Start all services
voipbin> status    # Check everything is running
```

That's it! The CLI guides you through the entire process.

## Using VoIPBin

Everything is managed through the `voipbin` CLI:

```bash
sudo ./voipbin
```

### Web Access

After starting, open these in your browser:

| Service | Address |
|---------|---------|
| Admin Console | http://admin.voipbin.test:3003 |
| Meet | http://meet.voipbin.test:3004 |
| Talk | http://talk.voipbin.test:3005 |

**First time login:**
- Username: `admin@localhost`
- Password: `admin@localhost`

**Certificate warning?** Visit https://api.voipbin.test:8443 first and accept the certificate.

### Test Extensions

Three SIP extensions are created automatically:
- 1000 (password: pass1000)
- 2000 (password: pass2000)
- 3000 (password: pass3000)

Connect any SIP phone app to make test calls.

## Connecting from Other Machines

You can access VoIPBin from other computers, phones, or SIP devices on your network.

### Step 1: Find the Host IP

On the machine running VoIPBin:
```
voipbin> network status
```

Look for `Host IP` (e.g., `192.168.45.152`).

### Step 2: Configure DNS

On the other machine, set DNS to point to the VoIPBin host:

**Option A: System-wide (recommended for dedicated devices)**
- Set DNS Server to: `192.168.45.152` (the host IP)

**Option B: Add to hosts file (for computers)**

Linux/macOS (`/etc/hosts`) or Windows (`C:\Windows\System32\drivers\etc\hosts`):
```
192.168.45.152  api.voipbin.test
192.168.45.152  admin.voipbin.test
192.168.45.152  meet.voipbin.test
192.168.45.152  talk.voipbin.test
192.168.45.160  sip.voipbin.test
```

(Replace IPs with your actual `HOST_EXTERNAL_IP` and `KAMAILIO_EXTERNAL_IP` from `.env`)

### Step 3: Access Services

**Web Browser:**
- Admin: http://admin.voipbin.test:3003
- Meet: http://meet.voipbin.test:3004
- Talk: http://talk.voipbin.test:3005

**SIP Phones/Softphones:**
- DNS Server: `192.168.45.152` (host IP)
- SIP Server: `sip.voipbin.test`
- Domain: `{customer_id}.registrar.voipbin.test`
- Extensions: 1000, 2000, 3000
- Passwords: pass1000, pass2000, pass3000

The SIP phone will resolve `sip.voipbin.test` to Kamailio automatically.

## Common Commands

Run `sudo ./voipbin` to enter interactive mode, then:

### Setup and Control

```
voipbin> init                  # Initialize (first time setup)
voipbin> start                 # Start all services
voipbin> stop                  # Stop all services
voipbin> restart               # Restart all services
voipbin> status                # Check what's running
```

### View Logs

```
voipbin> logs api-manager      # View service logs
voipbin> logs -f kamailio      # Follow logs in real-time
```

### Manage Data

```
voipbin> customer list                    # List customers
voipbin> registrar extension list         # List extensions
voipbin> billing account list             # View billing
```

### Update and Maintenance

```
voipbin> update                # Update to latest version
voipbin> update --check        # Check for updates
voipbin> rollback              # Rollback to previous version
voipbin> rollback --list       # List available backups
```

### Network and DNS

```
voipbin> network status        # Check network
voipbin> dns status            # Check DNS
voipbin> dns test              # Test domain resolution
```

### Cleanup

```
voipbin> clean --containers    # Remove containers (keep data)
voipbin> clean --volumes       # Reset database
voipbin> clean --all           # Complete reset
```

## Uninstall

To completely remove VoIPBin Sandbox:

```
voipbin> stop
voipbin> clean --all
```

This stops all services, removes data, and cleans up network settings.

## Troubleshooting

### Can't access the web interface?

```
voipbin> dns status            # Check if DNS is working
voipbin> dns setup             # Fix DNS if needed
```

### Services not starting?

```
voipbin> status                # Check which services are running
voipbin> logs <service>        # Check logs for errors
voipbin> restart               # Try restarting
```

### Need a fresh start?

```
voipbin> stop
voipbin> clean --all
voipbin> init
voipbin> start
```

### Get Help

```
voipbin> help                  # See all commands
voipbin> help <command>        # Help for specific command
```

## Optional Features

Edit `.env` to enable additional capabilities:

| Feature | What to Add |
|---------|-------------|
| AI Assistant | `OPENAI_API_KEY=your-key` |
| Phone Numbers | `TWILIO_SID` and `TWILIO_API_KEY` |
| Cloud Storage | `GOOGLE_APPLICATION_CREDENTIALS=path/to/file.json` |
| Email | `SENDGRID_API_KEY=your-key` |

Core features work without any API keys.

## For Developers

### API Access

```
voipbin> api                   # Enter API mode
api> get /v1.0/extensions      # Make API calls
```

Or use curl:
```bash
curl -sk https://api.voipbin.test:8443/v1.0/extensions \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### Database Access

```
voipbin> db                    # Enter database mode
db> SELECT * FROM extensions LIMIT 5
```

### VoIP CLI

```
voipbin> ast                   # Asterisk CLI
voipbin> kam                   # Kamailio CLI
```

## More Information

For detailed technical documentation, see [CLAUDE.md](CLAUDE.md).

## License

See LICENSE file for details.
