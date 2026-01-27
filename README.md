# VoIPBin Sandbox

Your personal phone system in a box. Make calls, video conferences, and build communication apps - all running on your own computer.

## What's Included

- **Admin Console** - Manage your account from a web browser
- **Meet** - Video conferencing
- **Talk** - Make calls from your browser
- **Phone Extensions** - Connect SIP phones and softphones
- **API** - Build your own apps (for developers)

## Installation

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

### Step 2: Start VoIPBin

```bash
sudo ./voipbin start
```

Done! Everything is set up automatically.

## Using VoIPBin

All commands use the `voipbin` script. Run `sudo ./voipbin` to enter interactive mode:

```
voipbin> help
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

### Test Phone Extensions

Three extensions are created automatically:
- 1000 (password: pass1000)
- 2000 (password: pass2000)
- 3000 (password: pass3000)

Use any SIP phone app to register and make test calls between them.

## Common Commands

### Start and Stop

```bash
sudo ./voipbin start          # Start all services
sudo ./voipbin stop           # Stop all services
sudo ./voipbin restart        # Restart all services
```

### Check Status

```bash
voipbin> status               # See what's running
voipbin> logs api-manager     # View logs for a service
voipbin> logs -f kamailio     # Follow logs in real-time
```

### Manage Data

```bash
voipbin> customer list                    # List customers
voipbin> registrar extension list         # List phone extensions
voipbin> billing account list             # View billing accounts
```

### Update and Maintenance

```bash
voipbin> update                # Update to latest version
voipbin> update --check        # Check for updates without applying
voipbin> clean --volumes       # Reset database (start fresh)
voipbin> clean --all           # Complete reset
```

### Network and DNS

```bash
voipbin> network status        # Check network configuration
voipbin> dns status            # Check DNS configuration
voipbin> dns test              # Test domain resolution
```

## Uninstall

To completely remove VoIPBin Sandbox:

```bash
sudo ./voipbin stop
sudo ./voipbin clean --all
```

This stops all services, removes data, and cleans up network settings.

## Troubleshooting

### Can't access the web interface?

```bash
voipbin> dns status            # Check if DNS is working
voipbin> dns setup             # Fix DNS if needed
```

### Services not starting?

```bash
voipbin> status                # Check which services are running
voipbin> logs <service>        # Check logs for errors
voipbin> restart               # Try restarting
```

### Need a fresh start?

```bash
sudo ./voipbin stop
sudo ./voipbin clean --all
sudo ./voipbin start
```

### Still having issues?

```bash
voipbin> help                  # See all available commands
voipbin> help <command>        # Get help for specific command
```

## Optional Features

Edit `.env` to enable additional capabilities:

| Feature | What to Add |
|---------|-------------|
| AI Assistant | `OPENAI_API_KEY=your-key` |
| Real Phone Numbers | `TWILIO_SID` and `TWILIO_API_KEY` |
| Cloud Storage | `GOOGLE_APPLICATION_CREDENTIALS=path/to/file.json` |
| Email Sending | `SENDGRID_API_KEY=your-key` |

The core features work without any API keys.

## For Developers

### API Access

```bash
voipbin> api                   # Enter API mode for testing
api> get /v1.0/extensions      # Make API calls
```

Or use curl:
```bash
curl -sk https://api.voipbin.test:8443/v1.0/extensions \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### Database Access

```bash
voipbin> db                    # Enter database mode
db> SELECT * FROM extensions LIMIT 5
```

### Asterisk and Kamailio

```bash
voipbin> ast                   # Enter Asterisk CLI
voipbin> kam                   # Enter Kamailio CLI
```

## More Information

For detailed technical documentation, see [CLAUDE.md](CLAUDE.md).

## License

See LICENSE file for details.
