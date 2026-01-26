#!/usr/bin/env python3
"""
VoIPBin Sandbox Interactive CLI

An interactive command-line interface for managing VoIPBin sandbox,
inspired by Asterisk CLI and Claude Code.

This CLI requires sudo for full functionality (network setup, DNS config, etc.)
"""

import atexit
import getpass
import json
import os
import readline
import shlex
import signal
import subprocess
import sys
from pathlib import Path


def check_root():
    """Check if running as root, exit if not"""
    if os.geteuid() != 0:
        print("\033[91m[ERROR]\033[0m This CLI requires sudo for full functionality.")
        print("")
        print("  Usage: sudo ./voipbin")
        print("")
        sys.exit(1)

# =============================================================================
# Configuration
# =============================================================================

CONFIG_FILE = Path.home() / ".voipbin-cli.conf"
HISTORY_FILE = Path.home() / ".voipbin-cli-history"

DEFAULT_CONFIG = {
    "api_host": "localhost",
    "api_port": 8443,
    "log_lines": 50,
    "history_size": 1000,
    "colors": True,
    "asterisk_container": "voipbin-ast-call",
    "registrar_container": "voipbin-ast-registrar",
    "kamailio_container": "voipbin-kamailio",
    "db_container": "voipbin-db",
    "db_password": "root_password",
    "project_dir": str(Path(__file__).parent.parent),
}

# =============================================================================
# Colors
# =============================================================================

class Colors:
    """ANSI color codes"""
    GREEN = "\033[92m"
    RED = "\033[91m"
    YELLOW = "\033[93m"
    BLUE = "\033[94m"
    GRAY = "\033[90m"
    WHITE = "\033[97m"
    BOLD = "\033[1m"
    RESET = "\033[0m"

    @classmethod
    def disable(cls):
        cls.GREEN = cls.RED = cls.YELLOW = cls.BLUE = ""
        cls.GRAY = cls.WHITE = cls.BOLD = cls.RESET = ""


def green(text):
    return f"{Colors.GREEN}{text}{Colors.RESET}"

def red(text):
    return f"{Colors.RED}{text}{Colors.RESET}"

def yellow(text):
    return f"{Colors.YELLOW}{text}{Colors.RESET}"

def blue(text):
    return f"{Colors.BLUE}{text}{Colors.RESET}"

def gray(text):
    return f"{Colors.GRAY}{text}{Colors.RESET}"

def white(text):
    return f"{Colors.WHITE}{text}{Colors.RESET}"

def bold(text):
    return f"{Colors.BOLD}{text}{Colors.RESET}"


# =============================================================================
# Welcome Dashboard
# =============================================================================

# ASCII Logo - Phone icon + VoIPBin text
# Each icon line is padded to 28 characters for consistent alignment
LOGO_LINES = [
    ("          ████████          ", ""),
    ("   ██████████████████████   ", " __     __   ___ ____  ____  _"),
    ("  ██                    ██  ", " \\ \\   / /__|_ _|  _ \\| __ )(_)_ __"),
    (" ██████████████████████████ ", "  \\ \\ / / _ \\| || |_) |  _ \\| | '_ \\"),
    (" ██                      ██ ", "   \\ V / (_) | ||  __/| |_) | | | | |"),
    ("  ██    ██   ██   ██    ██  ", "    \\_/ \\___/___|_|   |____/|_|_| |_|"),
    ("  ██    ██   ██   ██    ██  ", "        Connect & Collaborate for all"),
    ("  ██    ██   ██   ██    ██  ", "              S A N D B O X"),
    ("  ██    ██   ██   ██    ██  ", ""),
    ("   ██   ██   ██   ██   ██   ", ""),
    ("   ██████████████████████   ", ""),
]

# =============================================================================
# Sidecar Command Registry
# =============================================================================

SIDECAR_COMMANDS = {
    "billing": {
        "container": "voipbin-billing-mgr",
        "binary": "/app/bin/billing-control",
        "subcommands": {
            "account": {
                "commands": ["list", "create", "get", "delete", "add-balance", "subtract-balance"],
                "description": "Manage billing accounts",
            },
            "billing": {
                "commands": ["list", "get"],
                "description": "View billing records",
            },
        },
    },
    "customer": {
        "container": "voipbin-customer-mgr",
        "binary": "/app/bin/customer-control",
        "subcommands": {
            "customer": {
                "commands": ["list", "create", "get", "delete"],
                "description": "Manage customers",
            },
        },
    },
    "number": {
        "container": "voipbin-number-mgr",
        "binary": "/app/bin/number-control",
        "subcommands": {
            "number": {
                "commands": ["list", "create", "get", "delete", "register"],
                "description": "Manage phone numbers",
            },
        },
    },
}

# Required arguments for sidecar commands
SIDECAR_REQUIRED_ARGS = {
    ("billing", "account", "create"): ["customer-id"],
    ("billing", "account", "get"): ["id"],
    ("billing", "account", "delete"): ["id"],
    ("billing", "account", "add-balance"): ["id", "amount"],
    ("billing", "account", "subtract-balance"): ["id", "amount"],
    ("billing", "billing", "get"): ["id"],
    ("customer", "customer", "create"): ["email"],
    ("customer", "customer", "get"): ["id"],
    ("customer", "customer", "delete"): ["id"],
    ("number", "number", "create"): ["number"],
    ("number", "number", "get"): ["id"],
    ("number", "number", "delete"): ["id"],
    ("number", "number", "register"): ["number"],
}

# Commands that require delete confirmation
SIDECAR_DELETE_COMMANDS = [
    ("billing", "account", "delete"),
    ("customer", "customer", "delete"),
    ("number", "number", "delete"),
]

# Table columns for list commands (command_key -> [(display_name, json_key, width)])
SIDECAR_TABLE_COLUMNS = {
    ("billing", "account", "list"): [
        ("ID", "id", 36),
        ("Name", "name", 25),
        ("Balance", "balance", 10),
        ("Payment", "payment_type", 10),
    ],
    ("billing", "billing", "list"): [
        ("ID", "id", 36),
        ("Account ID", "account_id", 36),
        ("Type", "type", 15),
        ("Cost", "cost", 10),
    ],
    ("customer", "customer", "list"): [
        ("ID", "id", 36),
        ("Name", "name", 25),
        ("Email", "email", 30),
    ],
    ("number", "number", "list"): [
        ("ID", "id", 36),
        ("Number", "number", 16),
        ("Name", "name", 25),
    ],
}

# Detail field mappings for get commands (command_key -> [(display_name, json_key)])
SIDECAR_DETAIL_FIELDS = {
    ("billing", "account", "get"): [
        ("ID", "id"),
        ("Customer ID", "customer_id"),
        ("Name", "name"),
        ("Detail", "detail"),
        ("Balance", "balance"),
        ("Payment Type", "payment_type"),
        ("Payment Method", "payment_method"),
        ("Created", "tm_create"),
    ],
    ("billing", "billing", "get"): [
        ("ID", "id"),
        ("Account ID", "account_id"),
        ("Customer ID", "customer_id"),
        ("Type", "type"),
        ("Cost", "cost"),
        ("Created", "tm_create"),
    ],
    ("customer", "customer", "get"): [
        ("ID", "id"),
        ("Name", "name"),
        ("Email", "email"),
        ("Detail", "detail"),
        ("Phone", "phone_number"),
        ("Address", "address"),
        ("Created", "tm_create"),
    ],
    ("number", "number", "get"): [
        ("ID", "id"),
        ("Number", "number"),
        ("Name", "name"),
        ("Detail", "detail"),
        ("Customer ID", "customer_id"),
        ("Call Flow ID", "call_flow_id"),
        ("Message Flow ID", "message_flow_id"),
        ("Created", "tm_create"),
    ],
}


def get_logo():
    """Return the combined ASCII logo with colors"""
    combined = []
    for icon_part, text_part in LOGO_LINES:
        if "Connect & Collaborate" in text_part:
            combined.append(f"{white(icon_part)}{gray(text_part)}")
        elif "S A N D B O X" in text_part:
            combined.append(f"{white(icon_part)}{bold(gray(text_part))}")
        elif text_part:
            combined.append(f"{white(icon_part)}{bold(text_part)}")
        else:
            combined.append(f"{white(icon_part)}")

    return '\n'.join(combined)


def detect_dashboard_state():
    """Detect the current system state for dashboard display"""
    env_exists = os.path.exists(".env")

    if not env_exists:
        return "not_initialized"

    # Check for running containers
    output = run_cmd("docker compose ps --format '{{.Name}}' 2>/dev/null")
    if output and output.strip():
        return "running"

    return "stopped"


def get_quick_status():
    """Get quick status for running state dashboard"""
    # Get running containers
    output = run_cmd("docker compose ps --format '{{.Name}}\t{{.Status}}' 2>/dev/null")

    running = []
    stopped = []

    if output:
        for line in output.strip().split('\n'):
            if not line:
                continue
            parts = line.split('\t')
            if len(parts) >= 2:
                name = parts[0].replace("voipbin-", "")
                status = parts[1]
                if "up" in status.lower():
                    running.append(name)
                else:
                    stopped.append(name)

    # Get total services
    total_output = run_cmd("docker compose config --services 2>/dev/null")
    total = len(total_output.strip().split('\n')) if total_output else 0

    # Check DNS status
    coredns_running = "dns" in running or "voipbin-dns" in run_cmd("docker ps --format '{{.Names}}' 2>/dev/null")
    resolv_configured = "nameserver 127.0.0.1" in run_cmd("cat /etc/resolv.conf 2>/dev/null")
    dns_active = coredns_running and resolv_configured

    # Check network status
    kamailio_int = run_cmd("ip addr show kamailio-int 2>/dev/null | grep -oP 'inet [\\d./]+' | head -1")
    network_configured = bool(kamailio_int)

    # Get host IP for endpoints
    host_ip = run_cmd("grep '^HOST_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or "localhost"

    return {
        "running_count": len(running),
        "total_count": total,
        "stopped_services": stopped[:3],  # Show max 3
        "dns_active": dns_active,
        "network_configured": network_configured,
        "host_ip": host_ip,
    }


def show_welcome_dashboard():
    """Display the welcome dashboard based on system state"""
    state = detect_dashboard_state()

    # Print logo
    print()
    print(get_logo())
    print()

    # Separator
    separator = "━" * 75
    print(separator)
    print()

    if state == "not_initialized":
        # Warning triangle in yellow
        warning = f"""{yellow("      /\\")}
{yellow("     /  \\")}       Not initialized. Let's get started:
{yellow("    / !! \\")}
{yellow("   /______\\")}        1. {bold("init")}          Generate .env and SSL certificates
                   2. {bold("nano .env")}     Add your API keys (GCP, OpenAI, etc.)
                   3. {bold("start")}         Launch all services

                Quick start: {green("init")} → {green("nano .env")} → {green("start")}"""
        print(warning)
        print()
        print(separator)
        print()
        print(f"Type '{bold('help')}' for all commands, '{bold('exit')}' to quit.")

    elif state == "stopped":
        # Circle icon in gray
        stopped_msg = f"""{gray("     ○○○")}        Services stopped. Ready to start.
{gray("    ○   ○")}
{gray("     ○○○")}           Type '{green("start")}' to launch all services
                   Type '{blue("status")}' for detailed configuration"""
        print(stopped_msg)
        print()
        print(separator)
        print()
        print(f"Type '{bold('help')}' for all commands, '{bold('exit')}' to quit.")

    else:  # running
        status = get_quick_status()

        # Status indicators
        running_indicator = green("●") if status["running_count"] > 0 else gray("○")
        dns_indicator = green("●") if status["dns_active"] else gray("○")
        dns_status = "active" if status["dns_active"] else "not configured"
        network_indicator = green("●") if status["network_configured"] else gray("○")
        network_status = "configured" if status["network_configured"] else "not configured"

        # Helper to pad string accounting for ANSI codes
        def pad(text, width, colored_text=None):
            """Pad text to width, using colored_text for display if provided"""
            display = colored_text if colored_text else text
            padding = width - len(text)
            return display + (' ' * max(0, padding))

        # Build content (plain text for width calc, colored for display)
        svc1_plain = f"* {status['running_count']}/{status['total_count']} running"
        svc1_color = f"{running_indicator} {status['running_count']}/{status['total_count']} running"

        svc2_plain = ""
        svc2_color = ""
        if status["stopped_services"]:
            stopped_str = ', '.join(status['stopped_services'][:3])
            svc2_plain = f"* {stopped_str}"
            svc2_color = f"{gray('○')} {gray(stopped_str)}"

        svc4_plain = f"DNS: * {dns_status}"
        svc4_color = f"DNS: {dns_indicator} {dns_status}"

        svc5_plain = f"Network: * {network_status}"
        svc5_color = f"Network: {network_indicator} {network_status}"

        col_width = 36

        print(f"  {'Services':<34}  {'Endpoints'}")
        print(f"  {'─' * 34}  {'─' * 33}")
        print(f"  {pad(svc1_plain, col_width, svc1_color)}  Admin   {blue('http://localhost:3003')}")
        print(f"  {pad(svc2_plain, col_width, svc2_color)}  API     {blue('https://localhost:8443')}")
        print(f"  {'':<{col_width}}  Meet    {blue('http://localhost:3004')}")
        print(f"  {pad(svc4_plain, col_width, svc4_color)}  Talk    {blue('http://localhost:3005')}")
        print(f"  {pad(svc5_plain, col_width, svc5_color)}  SIP     {blue('sip.voipbin.test:5060')}")
        print()
        print(separator)
        print()
        print(f"Type '{bold('help')}' for all commands, '{bold('status')}' for details, '{bold('exit')}' to quit.")

    print()


# =============================================================================
# Configuration Management
# =============================================================================

class Config:
    def __init__(self):
        self.data = DEFAULT_CONFIG.copy()
        self.load()

    def load(self):
        if CONFIG_FILE.exists():
            try:
                with open(CONFIG_FILE) as f:
                    saved = json.load(f)
                    self.data.update(saved)
            except (json.JSONDecodeError, IOError):
                pass

    def save(self):
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump(self.data, f, indent=2)
        except IOError as e:
            print(red(f"Error saving config: {e}"))

    def get(self, key, default=None):
        # Check environment variable first
        env_key = f"VOIPBIN_{key.upper()}"
        if env_key in os.environ:
            return os.environ[env_key]
        return self.data.get(key, default)

    def set(self, key, value):
        # Try to convert to appropriate type
        if key in self.data:
            orig_type = type(self.data[key])
            try:
                if orig_type == bool:
                    value = value.lower() in ("true", "1", "yes")
                elif orig_type == int:
                    value = int(value)
            except (ValueError, AttributeError):
                pass
        self.data[key] = value
        self.save()

    def reset(self):
        self.data = DEFAULT_CONFIG.copy()
        self.save()


# =============================================================================
# Command Execution Helpers
# =============================================================================

def run_cmd(cmd, capture=True, check=False):
    """Run a shell command and return output"""
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=capture,
            text=True,
            check=check
        )
        return result.stdout.strip() if capture else ""
    except subprocess.CalledProcessError as e:
        return e.stderr.strip() if e.stderr else str(e)


def docker_exec(container, cmd, interactive=False):
    """Execute command in a docker container"""
    if interactive:
        os.system(f"docker exec -it {container} {cmd}")
        return ""
    return run_cmd(f"docker exec {container} {cmd}")


def get_running_containers():
    """Get list of running voipbin containers"""
    output = run_cmd("docker compose ps --format '{{.Name}}' 2>/dev/null")
    if output:
        return [c.replace("voipbin-", "") for c in output.split("\n") if c.startswith("voipbin-")]
    return []


def get_all_services():
    """Get list of all services from docker-compose"""
    output = run_cmd("docker compose config --services 2>/dev/null")
    return output.split("\n") if output else []


# =============================================================================
# Sidecar Command Helpers
# =============================================================================

def check_container_running(container):
    """Check if a container is running"""
    output = run_cmd(f"docker ps --filter 'name={container}' --format '{{{{.Names}}}}'")
    return container in output if output else False


def run_sidecar_command(container, binary, args, verbose=False):
    """
    Execute a sidecar command via docker exec.
    Returns (success, data_or_error) tuple.
    data_or_error is parsed JSON on success, error message on failure.
    """
    # Check container is running
    if not check_container_running(container):
        return False, f"Service unavailable: {container} is not running.\n  Run 'start' to launch services."

    # Build command
    args_str = " ".join(f'--{k} "{v}"' if isinstance(v, str) and " " in v else f"--{k} {v}"
                        for k, v in args.items() if v is not None)
    cmd = f'docker exec {container} {binary} {args_str} 2>&1'

    output = run_cmd(cmd)
    if not output:
        return True, []

    # Parse output - filter log lines and extract JSON
    lines = output.split("\n")
    json_lines = []
    log_lines = []

    for line in lines:
        line = line.strip()
        if not line:
            continue
        # Check if it's a log line (JSON with severity field)
        if line.startswith("{") and '"severity"' in line:
            log_lines.append(line)
        else:
            json_lines.append(line)

    # Show logs if verbose
    if verbose and log_lines:
        for log_line in log_lines:
            try:
                log = json.loads(log_line)
                severity = log.get("severity", "INFO")
                message = log.get("message", "")
                if severity == "ERROR":
                    print(f"{red('[ERROR]')} {message}")
                elif severity == "DEBUG":
                    print(f"{gray('[DEBUG]')} {message}")
                else:
                    print(f"[{severity}] {message}")
            except json.JSONDecodeError:
                print(log_line)
        print()

    # Parse JSON result
    json_str = "\n".join(json_lines)
    if not json_str:
        return True, []

    try:
        data = json.loads(json_str)
        return True, data
    except json.JSONDecodeError:
        # Check for common error patterns
        if "not found" in json_str.lower():
            return False, "Resource not found."
        if "error" in json_str.lower():
            return False, json_str
        return False, f"Invalid response: {json_str}"


def parse_sidecar_args(args):
    """
    Parse --flag value style arguments from a list.
    Returns dict of flag -> value.
    """
    result = {}
    i = 0
    while i < len(args):
        arg = args[i]
        if arg.startswith("--"):
            key = arg[2:]
            # Check if next arg is a value (not another flag)
            if i + 1 < len(args) and not args[i + 1].startswith("--"):
                result[key] = args[i + 1]
                i += 2
            else:
                result[key] = True
                i += 1
        else:
            i += 1
    return result


def prompt_missing_args(command_key, provided_args):
    """
    Check for missing required args and prompt for them.
    Returns updated args dict or None if cancelled.
    """
    required = SIDECAR_REQUIRED_ARGS.get(command_key, [])
    updated_args = provided_args.copy()

    for arg in required:
        if arg not in updated_args or updated_args[arg] is None:
            print(f"\nMissing required argument: {yellow('--' + arg)}\n")
            try:
                value = input(f"Enter {arg}: ").strip()
                if not value:
                    print("Cancelled.")
                    return None
                updated_args[arg] = value
            except (KeyboardInterrupt, EOFError):
                print("\nCancelled.")
                return None

    return updated_args


def confirm_delete(resource_type, resource_data):
    """
    Show delete confirmation dialog.
    Returns True if confirmed, False otherwise.
    """
    print(f"\n{yellow('⚠')} Delete {resource_type}?")

    # Show resource details
    if isinstance(resource_data, dict):
        for key in ["name", "email", "number", "id"]:
            if key in resource_data and resource_data[key]:
                display_key = key.replace("_", " ").title()
                print(f"  {display_key}:  {resource_data[key]}")

    print(f"\n  {red('This action cannot be undone.')}\n")

    try:
        confirm = input("Type 'yes' to confirm: ").strip().lower()
        if confirm == "yes":
            return True
        print("Cancelled.")
        return False
    except (KeyboardInterrupt, EOFError):
        print("\nCancelled.")
        return False


def format_table(data, columns):
    """
    Format list of dicts as a table.
    columns: list of (display_name, json_key, width)
    """
    if not data:
        return

    # Calculate column widths (at least header width)
    col_widths = []
    for display_name, json_key, default_width in columns:
        max_val_width = max((len(str(row.get(json_key, ""))) for row in data), default=0)
        col_widths.append(max(len(display_name), min(max_val_width, default_width)))

    # Print header
    header = "  ".join(display_name.ljust(col_widths[i])
                       for i, (display_name, _, _) in enumerate(columns))
    separator = "  ".join("─" * w for w in col_widths)

    print(separator)
    print(header)
    print(separator)

    # Print rows
    for row in data:
        values = []
        for i, (_, json_key, _) in enumerate(columns):
            val = row.get(json_key, "")
            if val is None:
                val = "-"
            elif isinstance(val, float):
                val = f"{val:.2f}"
            val_str = str(val)[:col_widths[i]].ljust(col_widths[i])
            values.append(val_str)
        print("  ".join(values))

    print(separator)


def format_details(data, fields):
    """
    Format a single dict as key-value pairs.
    fields: list of (display_name, json_key)
    """
    if not data:
        return

    # Find max label width
    max_label = max(len(display_name) for display_name, _ in fields)

    print("─" * 40)
    for display_name, json_key in fields:
        val = data.get(json_key, "")
        if val is None or val == "":
            val = "-"
        elif isinstance(val, float):
            val = f"{val:.2f}"
        # Truncate timestamps
        if "tm_" in json_key and isinstance(val, str) and len(val) > 19:
            val = val[:19]
        print(f"  {display_name}:{' ' * (max_label - len(display_name) + 2)}{val}")
    print()


# =============================================================================
# CLI Commands
# =============================================================================

class VoIPBinCLI:
    def __init__(self):
        self.config = Config()
        self.context = None  # None = top-level, or "asterisk", "kamailio", "db", "api"
        self.api_token = None
        self.running = True

        # Disable colors if configured
        if not self.config.get("colors", True):
            Colors.disable()

        # Command handlers
        self.commands = {
            "help": self.cmd_help,
            "?": self.cmd_help,
            "status": self.cmd_status,
            "ps": self.cmd_status,
            "start": self.cmd_start,
            "stop": self.cmd_stop,
            "restart": self.cmd_restart,
            "logs": self.cmd_logs,
            "ast": self.cmd_ast,
            "asterisk": self.cmd_ast,
            "kam": self.cmd_kam,
            "kamailio": self.cmd_kam,
            "db": self.cmd_db,
            "mysql": self.cmd_db,
            "api": self.cmd_api,
            "ext": self.cmd_ext,
            "extension": self.cmd_ext,
            "billing": self.cmd_billing,
            "customer": self.cmd_customer,
            "number": self.cmd_number,
            "config": self.cmd_config,
            "dns": self.cmd_dns,
            "certs": self.cmd_certs,
            "network": self.cmd_network,
            "init": self.cmd_init,
            "clean": self.cmd_clean,
            "update": self.cmd_update,
            "exit": self.cmd_exit,
            "quit": self.cmd_exit,
            "clear": self.cmd_clear,
        }

        # Help text for commands
        self.help_text = {
            "status": ("Show service status", "status"),
            "ps": ("Alias for status", "ps"),
            "start": ("Start services", "start [service]\n  start           Start all services\n  start api-manager  Start specific service"),
            "stop": ("Stop services", "stop [service]\n  stop            Stop all services\n  stop kamailio   Stop specific service"),
            "restart": ("Restart services", "restart [service]"),
            "logs": ("View service logs", "logs [-f] <service>\n  logs api-manager     Last 50 lines\n  logs -f api-manager  Follow logs (Ctrl+C to stop)"),
            "ast": ("Asterisk CLI", "ast [command]\n  ast                    Enter Asterisk context\n  ast pjsip show endpoints   Run single command"),
            "kam": ("Kamailio kamcmd", "kam [command]\n  kam                    Enter Kamailio context\n  kam ul.dump            Run single command"),
            "db": ("MySQL queries", "db [query]\n  db                     Enter database context\n  db SELECT * FROM extensions LIMIT 5"),
            "api": ("REST API client", "api [method] [path] [data]\n  api                    Enter API context\n  api get /v1.0/extensions"),
            "ext": ("Manage extensions", "ext <command>\n  ext list               List all extensions\n  ext create 4000 pass   Create extension\n  ext delete <id>        Delete extension"),
            "billing": ("Billing management", "billing <subcommand> <action> [options]\n  billing account list              List billing accounts\n  billing account create --customer-id ID  Create account\n  billing account get --id ID       Get account details\n  billing account delete --id ID    Delete account\n  billing account add-balance --id ID --amount N  Add balance\n  billing billing list              List billing records\n  Type 'billing help' for more details"),
            "customer": ("Customer management", "customer <action> [options]\n  customer list           List all customers\n  customer create --email EMAIL  Create customer\n  customer get --id ID    Get customer details\n  customer delete --id ID Delete customer\n  customer info           Show current customer (legacy)\n  Type 'customer help' for more details"),
            "number": ("Phone number management", "number <action> [options]\n  number list             List all numbers\n  number create --number +1555...  Create number\n  number get --id ID      Get number details\n  number delete --id ID   Delete number\n  number register --number +1555...  Register number\n  Type 'number help' for more details"),
            "config": ("View/set configuration", "config [key] [value]\n  config                 Show all settings\n  config log_lines 100   Set value\n  config reset           Reset to defaults"),
            "dns": ("DNS setup for SIP domains", "dns [status|list|setup|regenerate|test]\n  dns status      Check DNS configuration\n  dns list        List all DNS domains and their purposes\n  dns setup       Setup DNS forwarding to CoreDNS (requires sudo)\n  dns regenerate  Regenerate Corefile and restart CoreDNS (requires sudo)\n  dns test        Test domain resolution"),
            "certs": ("Manage SSL certificates", "certs [status|trust]\n  certs status    Check certificate configuration\n  certs trust     Install mkcert CA for browser-trusted certificates"),
            "network": ("Manage VoIP network interfaces", "network [status|setup|teardown]\n  network status                     Show current network configuration\n  network setup                      Setup VoIP network interfaces\n  network setup --external-ip X.X.X.X  Setup with fixed external IP\n  network teardown                   Remove VoIP network interfaces"),
            "init": ("Initialize sandbox", "init\n  Runs initialization script to generate .env and certificates"),
            "clean": ("Cleanup sandbox", "clean [options]\n  clean --volumes   Remove docker volumes (database, recordings)\n  clean --images    Remove docker images\n  clean --network   Teardown VoIP network interfaces\n  clean --dns       Remove DNS configuration\n  clean --purge     Remove generated files (.env, certs, configs)\n  clean --all       All of the above (full reset)"),
            "update": ("Update sandbox", "update [options]\n  update            Pull latest images and run DB migrations\n  update --images   Only pull latest Docker images\n  update --migrate  Only run database migrations"),
            "exit": ("Exit CLI", "exit"),
            "clear": ("Clear screen", "clear"),
        }

    def get_prompt(self):
        """Get the current prompt string"""
        if self.context:
            ctx_name = {
                "asterisk": "asterisk",
                "kamailio": "kam",
                "db": "db",
                "api": "api"
            }.get(self.context, self.context)
            return f"{bold('voipbin')}({blue(ctx_name)})> "
        return f"{bold('voipbin')}> "

    def parse_input(self, line):
        """Parse input line into command and arguments"""
        line = line.strip()
        if not line:
            return None, []

        try:
            parts = shlex.split(line)
        except ValueError:
            parts = line.split()

        return parts[0].lower(), parts[1:]

    def run_in_context(self, line):
        """Handle input when in a context"""
        if line.lower() in ("exit", "quit", ".."):
            self.context = None
            return

        if self.context == "asterisk":
            self.asterisk_cmd(line)
        elif self.context == "kamailio":
            self.kamailio_cmd(line)
        elif self.context == "db":
            self.db_cmd(line)
        elif self.context == "api":
            self.api_cmd(line)

    # -------------------------------------------------------------------------
    # Command Handlers
    # -------------------------------------------------------------------------

    def cmd_help(self, args):
        """Show help"""
        if args:
            cmd = args[0].lower()
            if cmd in self.help_text:
                desc, usage = self.help_text[cmd]
                print(f"\n{bold(cmd)} - {desc}\n")
                print(f"Usage:\n  {usage}\n")
            else:
                print(f"Unknown command: {cmd}")
            return

        print(f"""
{bold('VoIPBin Sandbox CLI')}

{blue('Service Commands:')}
  status, ps        Show service status
  start [service]   Start services
  stop [service]    Stop services
  restart [service] Restart services
  logs <service>    View logs (-f to follow)

{blue('Setup & Cleanup:')}
  init              Initialize sandbox (.env, certs)
  update            Pull latest images and run DB migrations
  clean [options]   Cleanup (--volumes, --images, --network, --dns, --purge, --all)

{blue('Contexts:')}
  ast [cmd]         Asterisk CLI
  kam [cmd]         Kamailio kamcmd
  db [query]        MySQL queries
  api               REST API client

{blue('Data Management:')}
  billing           Billing and account management
  customer          Customer management
  number            Phone number management
  ext               Extension management

{blue('Infrastructure:')}
  dns               DNS setup for SIP domains
  certs             Manage SSL certificates
  network           Manage VoIP network interfaces

{blue('Other:')}
  config            View/set configuration
  clear             Clear screen
  help [command]    Show help
  exit, quit        Exit CLI

Type 'help <command>' for detailed usage.
""")

    def cmd_status(self, args):
        """Show service status"""
        output = run_cmd("docker compose ps --format '{{.Name}}\t{{.Status}}' 2>/dev/null")
        if not output:
            print(yellow("No services running. Run 'start' to start services."))
            return

        # Get host IP for endpoints
        host_ip = run_cmd("grep '^HOST_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or "localhost"

        # Parse services into a dict
        services = {}
        for line in output.strip().split("\n"):
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                name = parts[0].replace("voipbin-", "")
                status = parts[1]
                services[name] = status

        # Key services with endpoints (service_name: (label, endpoint, credentials))
        # Web services resolve to Docker container IPs for direct access on standard ports
        endpoint_services = {
            "admin": ("Admin Console", "http://admin.voipbin.test", "admin@localhost / admin@localhost"),
            "api-mgr": ("API Manager", "https://api.voipbin.test", None),
            "mq": ("RabbitMQ", "http://localhost:15672", "guest / guest"),
            "db": ("MySQL", "localhost:3306", "root / root_password"),
        }

        # SIP/VoIP endpoints (shown separately)
        voip_endpoints = {
            "kamailio": [
                ("SIP (UDP/TCP)", f"{host_ip}:5060"),
                ("SIP (TLS)", f"{host_ip}:5061"),
                ("SIP (WSS)", f"wss://{host_ip}:443"),
            ],
            "rtpengine": [("RTPEngine", f"{host_ip}:22222")],
            "ast-registrar": [("Asterisk Registrar", f"{host_ip}:5082")],
            "ast-call": [("Asterisk Call", f"{host_ip}:5080")],
        }

        # Count running services
        running = sum(1 for s in services.values() if "up" in s.lower())
        total = len(services)

        # Helper to get status icon
        def get_status_icon(svc_name):
            status = services.get(svc_name, "")
            if "up" in status.lower():
                return green("●")
            elif "restarting" in status.lower():
                return yellow("◐")
            elif status:
                return red("○")
            return gray("○")

        # Print Web/Management endpoints
        print(f"\n{bold('Web Interfaces')}")
        print("-" * 70)
        for svc_name, (label, endpoint, creds) in endpoint_services.items():
            line = f"  {get_status_icon(svc_name)} {label:<20} {blue(endpoint)}"
            if creds:
                line += f"  {gray('(' + creds + ')')}"
            print(line)

        # Print VoIP endpoints
        print(f"\n{bold('VoIP Endpoints')}")
        print("-" * 70)
        for svc_name, endpoints in voip_endpoints.items():
            status_icon = get_status_icon(svc_name)
            for i, (label, endpoint) in enumerate(endpoints):
                if i == 0:
                    print(f"  {status_icon} {label:<20} {blue(endpoint)}")
                else:
                    print(f"    {label:<20} {blue(endpoint)}")

        # Print services summary
        print(f"\n{bold('Services')} ({running}/{total} running)")
        print("-" * 60)

        # Group by status
        running_svcs = []
        warning_svcs = []
        stopped_svcs = []

        # Services already shown in endpoints sections
        shown_services = set(endpoint_services.keys()) | set(voip_endpoints.keys())

        for name, status in sorted(services.items()):
            if name in shown_services:
                continue  # Already shown above
            if "up" in status.lower():
                running_svcs.append(name)
            elif "restarting" in status.lower():
                warning_svcs.append((name, status))
            else:
                stopped_svcs.append((name, status))

        # Show running services compactly (3 per line)
        if running_svcs:
            print(f"  {green('●')} Running: ", end="")
            for i, name in enumerate(running_svcs):
                if i > 0 and i % 3 == 0:
                    print(f"\n             ", end="")
                print(f"{name:<20}", end="")
            print()

        # Show warning services
        for name, status in warning_svcs:
            print(f"  {yellow('◐')} {name}: {yellow(status)}")

        # Show stopped services
        for name, status in stopped_svcs:
            print(f"  {red('○')} {name}: {red(status)}")

        # Show configuration status
        print(f"\n{bold('Configuration')}")
        print("-" * 60)

        # Helper to check env var
        def get_env_var(var_name):
            result = run_cmd(f"grep '^{var_name}=' .env 2>/dev/null | cut -d'=' -f2 | head -1")
            return result.strip() if result else ""

        # Check GCP credentials
        gcp_creds_path = get_env_var("GOOGLE_APPLICATION_CREDENTIALS")
        if gcp_creds_path:
            # Check if it's the dummy file
            is_dummy = False
            if "dummy" in gcp_creds_path.lower():
                is_dummy = True
            elif os.path.exists(gcp_creds_path):
                # Check file contents for dummy marker
                try:
                    with open(gcp_creds_path, 'r') as f:
                        content = f.read()
                        if "dummy-project" in content:
                            is_dummy = True
                except:
                    pass

            if is_dummy:
                print(f"  {yellow('!')} GCP Credentials:    {yellow('dummy')} {gray('(TTS/storage disabled)')}")
            else:
                print(f"  {green('●')} GCP Credentials:    {green('configured')}")
        else:
            print(f"  {gray('○')} GCP Credentials:    {gray('not set')}")

        # AI Services
        openai_key = get_env_var("OPENAI_API_KEY")
        if openai_key:
            print(f"  {green('●')} OpenAI:             {green('configured')}")
        else:
            print(f"  {gray('○')} OpenAI:             {gray('not set')}")

        # Check other AI services (group them)
        ai_services = []
        if get_env_var("DEEPGRAM_API_KEY"):
            ai_services.append("Deepgram")
        if get_env_var("CARTESIA_API_KEY"):
            ai_services.append("Cartesia")
        if get_env_var("ELEVENLABS_API_KEY"):
            ai_services.append("ElevenLabs")

        if ai_services:
            print(f"  {green('●')} AI Services:        {green(', '.join(ai_services))}")

        # Telephony Providers
        print(f"\n  {bold('Telephony')}")

        twilio_sid = get_env_var("TWILIO_SID")
        twilio_key = get_env_var("TWILIO_API_KEY")
        if twilio_sid and twilio_key:
            print(f"  {green('●')} Twilio:             {green('configured')}")
        else:
            print(f"  {gray('○')} Twilio:             {gray('not set')}")

        telnyx_key = get_env_var("TELNYX_API_KEY")
        if telnyx_key:
            print(f"  {green('●')} Telnyx:             {green('configured')}")
        else:
            print(f"  {gray('○')} Telnyx:             {gray('not set')}")

        # Email Providers
        print(f"\n  {bold('Email')}")

        sendgrid_key = get_env_var("SENDGRID_API_KEY")
        if sendgrid_key:
            print(f"  {green('●')} SendGrid:           {green('configured')}")
        else:
            print(f"  {gray('○')} SendGrid:           {gray('not set')}")

        mailgun_key = get_env_var("MAILGUN_API_KEY")
        if mailgun_key:
            print(f"  {green('●')} Mailgun:            {green('configured')}")
        else:
            print(f"  {gray('○')} Mailgun:            {gray('not set')}")

        # AWS (transcription)
        print(f"\n  {bold('Cloud Services')}")

        aws_access = get_env_var("AWS_ACCESS_KEY")
        aws_secret = get_env_var("AWS_SECRET_KEY")
        if aws_access and aws_secret:
            print(f"  {green('●')} AWS:                {green('configured')} {gray('(transcription)')}")
        else:
            print(f"  {gray('○')} AWS:                {gray('not set')}")

        # DNS Configuration
        print(f"\n{bold('DNS Domains')} (*.voipbin.test → {host_ip})")
        print("-" * 60)

        # Check if CoreDNS is running and DNS is configured
        coredns_running = "voipbin-dns" in run_cmd("docker ps --format '{{.Names}}' 2>/dev/null")
        dns_configured = "nameserver 127.0.0.1" in run_cmd("cat /etc/resolv.conf 2>/dev/null")

        if coredns_running and dns_configured:
            print(f"  {green('●')} DNS Status: {green('active')}")
        elif coredns_running:
            print(f"  {yellow('!')} DNS Status: {yellow('CoreDNS running, but resolv.conf not configured')}")
        else:
            print(f"  {red('○')} DNS Status: {red('CoreDNS not running')}")

        print(f"\n  {bold('Web Services')} (resolve to Docker container IPs)")
        print(f"    https://api.voipbin.test          API Manager")
        print(f"    http://admin.voipbin.test         Admin Console")
        print(f"    http://meet.voipbin.test          Meet")
        print(f"    http://talk.voipbin.test          Talk")

        print(f"\n  {bold('SIP Services')} (Kamailio: {host_ip})")
        print(f"    sip.voipbin.test                  SIP proxy")
        print(f"    sip-service.voipbin.test          SIP proxy (alias)")
        print(f"    pstn.voipbin.test                 PSTN gateway")
        print(f"    trunk.voipbin.test                SIP trunking")
        print(f"    *.registrar.voipbin.test          SIP registration")

        print(f"\n  Run 'dns list' for full domain reference.")
        print()

    def cmd_start(self, args):
        """Start services"""
        service = args[0] if args else ""

        if service:
            # Start specific service
            print(f"Starting {service}...")
            result = run_cmd(f"docker compose up -d {service} 2>&1")
            if result:
                print(result)
            print(green("✓ Done"))
        else:
            # Full startup - use start.sh for all setup (network, DNS, etc.)
            script_dir = self.config.get("project_dir", ".")
            script_path = os.path.join(script_dir, "scripts", "start.sh")

            if os.path.exists(script_path):
                print("Running full startup (network, DNS, services)...")
                os.system(script_path)
            else:
                # Fallback to docker compose
                print("Starting all services...")
                result = run_cmd("docker compose up -d 2>&1")
                if result:
                    print(result)
                print(green("✓ Done"))

    def cmd_stop(self, args):
        """Stop services"""
        service = args[0] if args else ""

        if service:
            # Stop specific service (but warn if stopping coredns)
            if service == "coredns" or service == "dns":
                print(yellow("Warning: Stopping CoreDNS may cause DNS resolution to fail."))
                print(yellow("         Run 'dns setup' after restarting to restore DNS."))
            print(f"Stopping {service}...")
            result = run_cmd(f"docker compose stop {service} 2>&1")
            if result:
                print(result)
            print(green("✓ Done"))
        else:
            # Stop all - use stop.sh (which restores DNS automatically)
            script_dir = self.config.get("project_dir", ".")
            script_path = os.path.join(script_dir, "scripts", "stop.sh")

            if os.path.exists(script_path):
                os.system(script_path)
            else:
                # Fallback to docker compose
                print("Stopping all services...")
                result = run_cmd("docker compose down 2>&1")
                if result:
                    print(result)
                print(green("✓ Done"))

    def cmd_restart(self, args):
        """Restart services"""
        service = args[0] if args else ""
        print(f"Restarting {service or 'all services'}...")

        if service:
            result = run_cmd(f"docker compose restart {service} 2>&1")
        else:
            result = run_cmd("docker compose restart 2>&1")

        if result:
            print(result)
        print(green("✓ Done"))

    def cmd_logs(self, args):
        """View service logs"""
        if not args:
            print("Usage: logs [-f] <service>")
            print("Services:", ", ".join(get_all_services()[:10]))
            return

        follow = False
        service = args[0]

        if args[0] == "-f":
            follow = True
            if len(args) < 2:
                print("Usage: logs -f <service>")
                return
            service = args[1]

        lines = self.config.get("log_lines", 50)

        if follow:
            print(f"Following logs for {service}... (Ctrl+C to stop)")
            try:
                os.system(f"docker compose logs -f --tail={lines} {service}")
            except KeyboardInterrupt:
                print()
        else:
            result = run_cmd(f"docker compose logs --tail={lines} {service} 2>&1")
            print(result)

    def cmd_ast(self, args):
        """Asterisk CLI"""
        if not args:
            self.context = "asterisk"
            print(f"Entering Asterisk context. Type 'exit' to return.")
            return

        cmd = " ".join(args)
        self.asterisk_cmd(cmd)

    def asterisk_cmd(self, cmd):
        """Execute Asterisk command"""
        container = self.config.get("asterisk_container")
        result = docker_exec(container, f'asterisk -rx "{cmd}"')
        print(result)

    def cmd_kam(self, args):
        """Kamailio kamcmd"""
        if not args:
            self.context = "kamailio"
            print(f"Entering Kamailio context. Type 'exit' to return.")
            return

        cmd = " ".join(args)
        self.kamailio_cmd(cmd)

    def kamailio_cmd(self, cmd):
        """Execute Kamailio command"""
        container = self.config.get("kamailio_container")
        result = docker_exec(container, f'kamcmd {cmd}')
        print(result)

    def cmd_db(self, args):
        """MySQL queries"""
        if not args:
            self.context = "db"
            print(f"Entering database context. Type 'exit' to return.")
            print(f"Database: bin_manager")
            return

        query = " ".join(args)
        self.db_cmd(query)

    def db_cmd(self, query):
        """Execute MySQL query"""
        container = self.config.get("db_container")
        password = self.config.get("db_password")
        result = docker_exec(container, f'mysql -u root -p{password} bin_manager -e "{query}"')
        print(result)

    def cmd_api(self, args):
        """REST API client"""
        if not args:
            self.context = "api"
            print(f"Entering API context. Type 'exit' to return.")
            print(f"Commands: login <email>, get <path>, post <path> <json>")
            if self.api_token:
                print(green("✓ Logged in"))
            return

        cmd = " ".join(args)
        self.api_cmd(cmd)

    def api_cmd(self, line):
        """Execute API command"""
        parts = line.split(None, 2)
        if not parts:
            return

        cmd = parts[0].lower()

        if cmd == "login":
            email = parts[1] if len(parts) > 1 else "admin@localhost"
            password = getpass.getpass(f"Password for {email}: ")
            self.api_login(email, password)
        elif cmd in ("get", "post", "put", "delete"):
            if len(parts) < 2:
                print(f"Usage: {cmd} <path> [data]")
                return
            path = parts[1]
            data = parts[2] if len(parts) > 2 else None
            self.api_request(cmd.upper(), path, data)
        else:
            print(f"Unknown API command: {cmd}")
            print("Commands: login, get, post, put, delete")

    def api_login(self, email, password):
        """Login to API"""
        host = self.config.get("api_host")
        port = self.config.get("api_port")

        data = json.dumps({"username": email, "password": password})
        result = run_cmd(
            f'curl -sk -X POST "https://{host}:{port}/auth/login" '
            f'-H "Content-Type: application/json" '
            f"-d '{data}'"
        )

        try:
            resp = json.loads(result)
            if "token" in resp:
                self.api_token = resp["token"]
                print(green("✓ Login successful"))
            else:
                print(red(f"✗ Login failed: {resp.get('message', result)}"))
        except json.JSONDecodeError:
            print(red(f"✗ Login failed: {result}"))

    def api_request(self, method, path, data=None):
        """Make API request"""
        if not self.api_token:
            print(yellow("Not logged in. Use 'login <email>' first."))
            return

        host = self.config.get("api_host")
        port = self.config.get("api_port")

        if not path.startswith("/"):
            path = "/" + path

        cmd = f'curl -sk -X {method} "https://{host}:{port}{path}" '
        cmd += f'-H "Authorization: Bearer {self.api_token}" '
        cmd += '-H "Content-Type: application/json" '

        if data:
            cmd += f"-d '{data}'"

        result = run_cmd(cmd)

        try:
            parsed = json.loads(result)
            print(json.dumps(parsed, indent=2))
        except json.JSONDecodeError:
            print(result)

    def cmd_ext(self, args):
        """Manage extensions"""
        if not args:
            print("Usage: ext list|create|delete")
            return

        subcmd = args[0].lower()

        if subcmd == "list":
            self.ext_list()
        elif subcmd == "create":
            if len(args) < 3:
                print("Usage: ext create <extension> <password> [name]")
                return
            ext = args[1]
            password = args[2]
            name = args[3] if len(args) > 3 else f"Extension {ext}"
            self.ext_create(ext, password, name)
        elif subcmd == "delete":
            if len(args) < 2:
                print("Usage: ext delete <id>")
                return
            self.ext_delete(args[1])
        else:
            print(f"Unknown subcommand: {subcmd}")

    def ensure_login(self):
        """Ensure we have an API token"""
        if self.api_token:
            return True

        print("Logging in as admin@localhost...")
        self.api_login("admin@localhost", "admin@localhost")
        return self.api_token is not None

    def ext_list(self):
        """List extensions"""
        if not self.ensure_login():
            return

        host = self.config.get("api_host")
        port = self.config.get("api_port")

        result = run_cmd(
            f'curl -sk "https://{host}:{port}/v1.0/extensions" '
            f'-H "Authorization: Bearer {self.api_token}"'
        )

        try:
            data = json.loads(result)
            if isinstance(data, list):
                print(f"\n{'Extension':<12} {'Name':<20} {'ID'}")
                print("-" * 60)
                for ext in data:
                    print(f"{ext.get('extension', 'N/A'):<12} {ext.get('name', ''):<20} {gray(ext.get('id', ''))}")
                print()
            else:
                print(json.dumps(data, indent=2))
        except json.JSONDecodeError:
            print(result)

    def ext_create(self, extension, password, name):
        """Create extension"""
        if not self.ensure_login():
            return

        host = self.config.get("api_host")
        port = self.config.get("api_port")

        data = json.dumps({"extension": extension, "password": password, "name": name})
        result = run_cmd(
            f'curl -sk -X POST "https://{host}:{port}/v1.0/extensions" '
            f'-H "Authorization: Bearer {self.api_token}" '
            f'-H "Content-Type: application/json" '
            f"-d '{data}'"
        )

        try:
            resp = json.loads(result)
            if "id" in resp:
                print(green(f"✓ Created extension {extension}"))
                print(f"  ID: {gray(resp['id'])}")
            else:
                print(red(f"✗ Failed: {resp.get('message', result)}"))
        except json.JSONDecodeError:
            print(result)

    def ext_delete(self, ext_id):
        """Delete extension"""
        if not self.ensure_login():
            return

        host = self.config.get("api_host")
        port = self.config.get("api_port")

        result = run_cmd(
            f'curl -sk -X DELETE "https://{host}:{port}/v1.0/extensions/{ext_id}" '
            f'-H "Authorization: Bearer {self.api_token}"'
        )

        if not result or result == "{}":
            print(green(f"✓ Deleted extension {ext_id}"))
        else:
            print(result)

    def cmd_customer(self, args):
        """Manage customer - delegates to new sidecar-based implementation"""
        # Delegate to the new implementation
        self.cmd_customer_new(args)

    def customer_info(self):
        """Show customer info"""
        if not self.ensure_login():
            return

        host = self.config.get("api_host")
        port = self.config.get("api_port")

        result = run_cmd(
            f'curl -sk "https://{host}:{port}/v1.0/customer" '
            f'-H "Authorization: Bearer {self.api_token}"'
        )

        try:
            data = json.loads(result)
            print(f"\n{bold('Customer Info')}")
            print("-" * 40)
            print(f"  ID:    {data.get('id', 'N/A')}")
            print(f"  Name:  {data.get('name', 'N/A')}")
            print(f"  Email: {data.get('email', 'N/A')}")
            print()
        except json.JSONDecodeError:
            print(result)

    def customer_create(self, email):
        """Create customer (legacy method for backward compatibility)"""
        name = email.split("@")[0].replace(".", " ").title()
        result = run_cmd(
            f'docker exec voipbin-customer-mgr /app/bin/customer-control customer create '
            f'--name "{name}" --email "{email}" 2>&1'
        )
        print(result)

    # -------------------------------------------------------------------------
    # Sidecar Commands (billing, customer, number)
    # -------------------------------------------------------------------------

    def cmd_billing(self, args):
        """Billing management (accounts and billing records)"""
        if not args or args[0] in ("help", "-h", "--help"):
            self._show_billing_help(args[1:] if len(args) > 1 else [])
            return

        subcmd = args[0].lower()

        if subcmd not in ("account", "billing"):
            print(f"{red('✗')} Unknown subcommand: {subcmd}")
            print("  Available: account, billing")
            print("  Type 'billing help' for usage.")
            return

        if len(args) < 2 or args[1] in ("help", "-h", "--help"):
            self._show_billing_subcommand_help(subcmd, args[2:] if len(args) > 2 else [])
            return

        action = args[1].lower()
        cmd_args = parse_sidecar_args(args[2:])
        verbose = cmd_args.pop("verbose", False)

        self._run_billing_command(subcmd, action, cmd_args, verbose)

    def _show_billing_help(self, args):
        """Show billing command help"""
        print(f"""
{bold('Billing Management')}

{blue('Available Commands:')}
  billing account        Manage billing accounts
  billing billing        View billing records

Type 'billing <subcommand> help' for more details.
""")

    def _show_billing_subcommand_help(self, subcmd, args):
        """Show help for billing subcommand"""
        if subcmd == "account":
            if args and args[0] not in ("help", "-h", "--help"):
                self._show_billing_action_help(subcmd, args[0])
                return
            print(f"""
{bold('Billing Account Management')}

{blue('Available Commands:')}
  list             List billing accounts
  create           Create a new billing account
  get              Get account details by ID
  delete           Delete an account
  add-balance      Add balance to an account
  subtract-balance Subtract balance from an account

{blue('Usage:')} billing account <command> [options]

{blue('Examples:')}
  billing account list
  billing account list --customer-id abc123
  billing account create --customer-id abc123 --name "Main Account"
  billing account get --id xyz789
  billing account add-balance --id xyz789 --amount 100
""")
        elif subcmd == "billing":
            if args and args[0] not in ("help", "-h", "--help"):
                self._show_billing_action_help(subcmd, args[0])
                return
            print(f"""
{bold('Billing Records')}

{blue('Available Commands:')}
  list             List billing records
  get              Get billing record by ID

{blue('Usage:')} billing billing <command> [options]

{blue('Examples:')}
  billing billing list
  billing billing list --customer-id abc123 --account-id xyz789
  billing billing get --id record123
""")

    def _show_billing_action_help(self, subcmd, action):
        """Show help for specific billing action"""
        help_info = {
            ("account", "list"): ("List billing accounts", [], [("customer-id", "Filter by customer ID"), ("limit", "Max results (default: 100)")]),
            ("account", "create"): ("Create a new billing account", [("customer-id", "Customer ID")], [("name", "Account name"), ("detail", "Description"), ("payment-type", "Payment type (default: prepaid)")]),
            ("account", "get"): ("Get account details", [("id", "Account ID")], []),
            ("account", "delete"): ("Delete an account", [("id", "Account ID")], []),
            ("account", "add-balance"): ("Add balance to an account", [("id", "Account ID"), ("amount", "Amount to add")], []),
            ("account", "subtract-balance"): ("Subtract balance from an account", [("id", "Account ID"), ("amount", "Amount to subtract")], []),
            ("billing", "list"): ("List billing records", [], [("customer-id", "Filter by customer ID"), ("account-id", "Filter by account ID"), ("limit", "Max results (default: 100)")]),
            ("billing", "get"): ("Get billing record details", [("id", "Billing record ID")], []),
        }

        key = (subcmd, action)
        if key not in help_info:
            print(f"{red('✗')} Unknown command: billing {subcmd} {action}")
            return

        desc, required, optional = help_info[key]
        print(f"\n{bold(desc)}\n")
        print(f"{blue('Usage:')} billing {subcmd} {action} [options]\n")

        if required:
            print(f"{blue('Required:')}")
            for arg, desc in required:
                print(f"  --{arg:<20} {desc}")
            print()

        if optional:
            print(f"{blue('Optional:')}")
            for arg, desc in optional:
                print(f"  --{arg:<20} {desc}")
            print()

    def _run_billing_command(self, subcmd, action, args, verbose):
        """Execute a billing command"""
        config = SIDECAR_COMMANDS["billing"]
        container = config["container"]
        binary = config["binary"]
        command_key = ("billing", subcmd, action)

        # Check if action is valid
        valid_actions = config["subcommands"].get(subcmd, {}).get("commands", [])
        if action not in valid_actions:
            print(f"{red('✗')} Unknown command: billing {subcmd} {action}")
            print(f"  Available: {', '.join(valid_actions)}")
            return

        # Prompt for missing required args
        args = prompt_missing_args(command_key, args)
        if args is None:
            return

        # Confirm delete
        if command_key in SIDECAR_DELETE_COMMANDS:
            # First get the resource to show details
            get_args = {"id": args.get("id")}
            success, data = run_sidecar_command(container, f"{binary} {subcmd} get", get_args, verbose=False)
            if success and data:
                if not confirm_delete("billing account", data):
                    return

        # Build and run command
        cmd_args = {subcmd: None}  # Add subcommand
        cmd_args[action] = None  # Add action
        cmd_args.update(args)

        # Remove subcommand and action from args, build proper command
        actual_args = {k: v for k, v in args.items()}
        success, data = run_sidecar_command(container, f"{binary} {subcmd} {action}", actual_args, verbose)

        if not success:
            print(f"{red('✗')} {data}")
            return

        # Format output
        self._format_billing_output(subcmd, action, data, command_key)

    def _format_billing_output(self, subcmd, action, data, command_key):
        """Format and display billing command output"""
        if action == "list":
            if not data:
                entity = "accounts" if subcmd == "account" else "billing records"
                print(f"\nNo {entity} found.\n")
                return
            columns = SIDECAR_TABLE_COLUMNS.get(command_key)
            if columns:
                entity = "Billing Accounts" if subcmd == "account" else "Billing Records"
                print(f"\n{bold(entity)} ({len(data)} found)\n")
                format_table(data, columns)
                print()

        elif action == "get":
            if not data:
                print(f"{red('✗')} Not found.")
                return
            fields = SIDECAR_DETAIL_FIELDS.get(command_key)
            if fields:
                entity = "Billing Account" if subcmd == "account" else "Billing Record"
                print(f"\n{bold(entity)}")
                format_details(data, fields)

        elif action == "create":
            if data:
                item_id = data.get("id", "unknown")
                print(f"{green('✓')} Created: {item_id}")

        elif action == "delete":
            print(f"{green('✓')} Deleted.")

        elif action in ("add-balance", "subtract-balance"):
            if data:
                new_balance = data.get("balance", "unknown")
                name = data.get("name", "account")
                print(f"{green('✓')} Balance updated for \"{name}\"")
                print(f"  New balance: {new_balance}")

    def cmd_customer_new(self, args):
        """Customer management using sidecar commands"""
        if not args or args[0] in ("help", "-h", "--help"):
            self._show_customer_help(args[1:] if len(args) > 1 else [])
            return

        subcmd = args[0].lower()

        # Handle legacy "info" command
        if subcmd == "info":
            self.customer_info()
            return

        # Map commands to actions
        valid_actions = ["list", "create", "get", "delete"]
        if subcmd not in valid_actions:
            print(f"{red('✗')} Unknown subcommand: {subcmd}")
            print(f"  Available: {', '.join(valid_actions)}")
            print("  Type 'customer help' for usage.")
            return

        if subcmd in ("help", "-h", "--help"):
            self._show_customer_action_help(args[1] if len(args) > 1 else None)
            return

        cmd_args = parse_sidecar_args(args[1:])
        verbose = cmd_args.pop("verbose", False)

        self._run_customer_command(subcmd, cmd_args, verbose)

    def _show_customer_help(self, args):
        """Show customer command help"""
        if args and args[0] not in ("help", "-h", "--help"):
            self._show_customer_action_help(args[0])
            return
        print(f"""
{bold('Customer Management')}

{blue('Available Commands:')}
  list             List all customers
  create           Create a new customer
  get              Get customer details by ID
  delete           Delete a customer
  info             Show current customer info (legacy)

{blue('Usage:')} customer <command> [options]

{blue('Examples:')}
  customer list
  customer create --email user@example.com --name "John Doe"
  customer get --id abc123
  customer delete --id abc123
""")

    def _show_customer_action_help(self, action):
        """Show help for specific customer action"""
        help_info = {
            "list": ("List all customers", [], [("limit", "Max results (default: 100)")]),
            "create": ("Create a new customer", [("email", "Customer email")], [("name", "Customer name"), ("detail", "Description"), ("address", "Physical address"), ("phone_number", "Phone number")]),
            "get": ("Get customer details", [("id", "Customer ID")], []),
            "delete": ("Delete a customer", [("id", "Customer ID")], []),
        }

        if action not in help_info:
            self._show_customer_help([])
            return

        desc, required, optional = help_info[action]
        print(f"\n{bold(desc)}\n")
        print(f"{blue('Usage:')} customer {action} [options]\n")

        if required:
            print(f"{blue('Required:')}")
            for arg, desc in required:
                print(f"  --{arg:<20} {desc}")
            print()

        if optional:
            print(f"{blue('Optional:')}")
            for arg, desc in optional:
                print(f"  --{arg:<20} {desc}")
            print()

    def _run_customer_command(self, action, args, verbose):
        """Execute a customer command"""
        config = SIDECAR_COMMANDS["customer"]
        container = config["container"]
        binary = config["binary"]
        command_key = ("customer", "customer", action)

        # Prompt for missing required args
        args = prompt_missing_args(command_key, args)
        if args is None:
            return

        # Confirm delete
        if command_key in SIDECAR_DELETE_COMMANDS:
            # First get the resource to show details
            get_args = {"id": args.get("id")}
            success, data = run_sidecar_command(container, f"{binary} customer get", get_args, verbose=False)
            if success and data:
                if not confirm_delete("customer", data):
                    return

        success, data = run_sidecar_command(container, f"{binary} customer {action}", args, verbose)

        if not success:
            print(f"{red('✗')} {data}")
            return

        # Format output
        self._format_customer_output(action, data, command_key)

    def _format_customer_output(self, action, data, command_key):
        """Format and display customer command output"""
        if action == "list":
            if not data:
                print("\nNo customers found.\n")
                return
            columns = SIDECAR_TABLE_COLUMNS.get(command_key)
            if columns:
                print(f"\n{bold('Customers')} ({len(data)} found)\n")
                format_table(data, columns)
                print()

        elif action == "get":
            if not data:
                print(f"{red('✗')} Customer not found.")
                return
            fields = SIDECAR_DETAIL_FIELDS.get(command_key)
            if fields:
                print(f"\n{bold('Customer')}")
                format_details(data, fields)

        elif action == "create":
            if data:
                item_id = data.get("id", "unknown")
                email = data.get("email", "")
                print(f"{green('✓')} Customer created: {email}")
                print(f"  ID: {item_id}")

        elif action == "delete":
            print(f"{green('✓')} Customer deleted.")

    def cmd_number(self, args):
        """Phone number management"""
        if not args or args[0] in ("help", "-h", "--help"):
            self._show_number_help(args[1:] if len(args) > 1 else [])
            return

        action = args[0].lower()

        valid_actions = ["list", "create", "get", "delete", "register"]
        if action not in valid_actions:
            print(f"{red('✗')} Unknown subcommand: {action}")
            print(f"  Available: {', '.join(valid_actions)}")
            print("  Type 'number help' for usage.")
            return

        cmd_args = parse_sidecar_args(args[1:])
        verbose = cmd_args.pop("verbose", False)

        self._run_number_command(action, cmd_args, verbose)

    def _show_number_help(self, args):
        """Show number command help"""
        if args and args[0] not in ("help", "-h", "--help"):
            self._show_number_action_help(args[0])
            return
        print(f"""
{bold('Phone Number Management')}

{blue('Available Commands:')}
  list             List all phone numbers
  create           Create a new number entry
  get              Get number details by ID
  delete           Delete a number
  register         Register a new number

{blue('Usage:')} number <command> [options]

{blue('Examples:')}
  number list
  number list --customer-id abc123
  number create --number +15551234567 --name "Main Line"
  number get --id xyz789
  number delete --id xyz789
  number register --number +15551234567 --customer-id abc123
""")

    def _show_number_action_help(self, action):
        """Show help for specific number action"""
        help_info = {
            "list": ("List all phone numbers", [], [("customer-id", "Filter by customer ID"), ("limit", "Max results (default: 100)")]),
            "create": ("Create a new number entry", [("number", "Phone number (e.g., +15551234567)")], [("customer-id", "Customer ID"), ("name", "Number name"), ("detail", "Description"), ("call-flow-id", "Call flow ID"), ("message-flow-id", "Message flow ID")]),
            "get": ("Get number details", [("id", "Number ID")], []),
            "delete": ("Delete a number", [("id", "Number ID")], []),
            "register": ("Register a new number", [("number", "Phone number (e.g., +15551234567)")], [("customer-id", "Customer ID"), ("name", "Number name"), ("detail", "Description"), ("call-flow-id", "Call flow ID"), ("message-flow-id", "Message flow ID")]),
        }

        if action not in help_info:
            self._show_number_help([])
            return

        desc, required, optional = help_info[action]
        print(f"\n{bold(desc)}\n")
        print(f"{blue('Usage:')} number {action} [options]\n")

        if required:
            print(f"{blue('Required:')}")
            for arg, desc in required:
                print(f"  --{arg:<20} {desc}")
            print()

        if optional:
            print(f"{blue('Optional:')}")
            for arg, desc in optional:
                print(f"  --{arg:<20} {desc}")
            print()

    def _run_number_command(self, action, args, verbose):
        """Execute a number command"""
        config = SIDECAR_COMMANDS["number"]
        container = config["container"]
        binary = config["binary"]
        command_key = ("number", "number", action)

        # Prompt for missing required args
        args = prompt_missing_args(command_key, args)
        if args is None:
            return

        # Confirm delete
        if command_key in SIDECAR_DELETE_COMMANDS:
            # First get the resource to show details
            get_args = {"id": args.get("id")}
            success, data = run_sidecar_command(container, f"{binary} number get", get_args, verbose=False)
            if success and data:
                if not confirm_delete("number", data):
                    return

        success, data = run_sidecar_command(container, f"{binary} number {action}", args, verbose)

        if not success:
            print(f"{red('✗')} {data}")
            return

        # Format output
        self._format_number_output(action, data, command_key)

    def _format_number_output(self, action, data, command_key):
        """Format and display number command output"""
        if action == "list":
            if not data:
                print("\nNo numbers found.\n")
                return
            columns = SIDECAR_TABLE_COLUMNS.get(command_key)
            if columns:
                print(f"\n{bold('Phone Numbers')} ({len(data)} found)\n")
                format_table(data, columns)
                print()

        elif action == "get":
            if not data:
                print(f"{red('✗')} Number not found.")
                return
            fields = SIDECAR_DETAIL_FIELDS.get(command_key)
            if fields:
                print(f"\n{bold('Phone Number')}")
                format_details(data, fields)

        elif action in ("create", "register"):
            if data:
                number = data.get("number", "unknown")
                item_id = data.get("id", "unknown")
                print(f"{green('✓')} Number {'registered' if action == 'register' else 'created'}: {number}")
                print(f"  ID: {item_id}")

        elif action == "delete":
            print(f"{green('✓')} Number deleted.")

    def cmd_config(self, args):
        """View/set configuration"""
        if not args:
            print(f"\n{bold('Configuration')} ({CONFIG_FILE})\n")
            for key, value in self.config.data.items():
                print(f"  {key}: {value}")
            print()
            return

        if args[0] == "reset":
            self.config.reset()
            print(green("✓ Configuration reset to defaults"))
            return

        key = args[0]
        if len(args) > 1:
            value = " ".join(args[1:])
            self.config.set(key, value)
            print(green(f"✓ Set {key} = {value}"))
        else:
            print(f"{key}: {self.config.get(key)}")

    def cmd_dns(self, args):
        """DNS setup for SIP domains"""
        subcmd = args[0].lower() if args else "status"

        if subcmd == "status":
            self.dns_status()
        elif subcmd == "list":
            self.dns_list()
        elif subcmd == "setup":
            self.dns_setup()
        elif subcmd == "regenerate":
            self.dns_regenerate()
        elif subcmd == "test":
            self.dns_test()
        else:
            print("Usage: dns [status|list|setup|regenerate|test]")

    def dns_status(self):
        """Check DNS configuration status"""
        host_ip = run_cmd("grep '^HOST_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or "127.0.0.1"
        kamailio_ip = run_cmd("grep '^KAMAILIO_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or host_ip
        rtpengine_ip = run_cmd("grep '^RTPENGINE_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or kamailio_ip

        print(f"\n{bold('DNS Configuration Status')}")
        print("-" * 50)

        # Check if CoreDNS container is running
        coredns_running = "voipbin-dns" in run_cmd("docker ps --format '{{.Names}}' 2>/dev/null")
        if coredns_running:
            print(f"  {green('●')} CoreDNS container: running (port 53)")
        else:
            print(f"  {red('○')} CoreDNS container: not running")

        # Check OS-specific configuration
        import platform
        if platform.system() == "Darwin":
            # macOS
            config_exists = os.path.exists("/etc/resolver/voipbin.test")
            if config_exists:
                print(f"  {green('●')} macOS resolver: configured (/etc/resolver/voipbin.test)")
            else:
                print(f"  {gray('○')} macOS resolver: not configured")
        else:
            # Linux - check resolv.conf points to 127.0.0.1
            resolv_conf = run_cmd("cat /etc/resolv.conf 2>/dev/null") or ""
            config_exists = "nameserver 127.0.0.1" in resolv_conf
            if config_exists:
                print(f"  {green('●')} resolv.conf: configured (nameserver 127.0.0.1)")
            else:
                print(f"  {gray('○')} resolv.conf: not configured")

        # Show IP configuration
        print(f"\n{bold('IP Configuration')}")
        print("-" * 50)
        print(f"  Host IP:      {host_ip} (web services)")
        print(f"  Kamailio IP:  {kamailio_ip} (SIP signaling)")
        print(f"  RTPEngine IP: {rtpengine_ip} (RTP media)")
        if kamailio_ip == host_ip:
            print(f"  {yellow('!')} Warning: Kamailio uses same IP as host (SIP loop issues possible)")

        # Test resolution
        print(f"\n{bold('Resolution Test')}")
        print("-" * 50)

        # Web services resolve to HOST_IP (Docker port mapping)
        # SIP services resolve to KAMAILIO_IP
        test_domains = [
            ("api.voipbin.test", host_ip, "API (:8443)"),
            ("admin.voipbin.test", host_ip, "Admin (:3003)"),
            ("meet.voipbin.test", host_ip, "Meet (:3004)"),
            ("talk.voipbin.test", host_ip, "Talk (:3005)"),
            ("sip.voipbin.test", kamailio_ip, "SIP (Kamailio)"),
            ("pstn.voipbin.test", kamailio_ip, "SIP (Kamailio)"),
            ("test.registrar.voipbin.test", kamailio_ip, "SIP (Kamailio)"),
        ]

        for domain, expected, desc in test_domains:
            # Try CoreDNS directly first (port 53)
            result = run_cmd(f"dig +short {domain} @127.0.0.1 2>/dev/null | head -1")
            if not result:
                # Fallback to system resolver
                result = run_cmd(f"dig +short {domain} 2>/dev/null | head -1") or run_cmd(f"getent hosts {domain} 2>/dev/null | awk '{{print $1}}'")
            if result == expected:
                print(f"  {green('✓')} {domain} → {result} {gray('(' + desc + ')')}")
            elif result:
                print(f"  {yellow('!')} {domain} → {result} (expected: {expected})")
            else:
                print(f"  {red('✗')} {domain} → (no resolution)")

        if not coredns_running:
            print(f"\n{yellow('Hint')}: Start CoreDNS with 'docker compose up -d coredns'")
        elif not config_exists:
            print(f"\n{yellow('Hint')}: Run 'dns setup' to configure DNS forwarding")
        print()

    def dns_list(self):
        """List all DNS domains and their purposes"""
        host_ip = run_cmd("grep '^HOST_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or "localhost"
        kamailio_ip = run_cmd("grep '^KAMAILIO_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or host_ip
        rtpengine_ip = run_cmd("grep '^RTPENGINE_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or kamailio_ip

        print(f"""
{bold('VoIPBin DNS Domains')}
{'=' * 70}

{bold('IP Configuration')}
  Host IP:      {host_ip} (web services)
  Kamailio IP:  {kamailio_ip} (SIP signaling)
  RTPEngine IP: {rtpengine_ip} (RTP media)

{bold('Web Services')} (resolve to Host IP, Docker port mapping)
{'-' * 70}
  {'Domain':<35} {'Resolves To':<18} {'Port'}
  {'api.voipbin.test':<35} {host_ip:<18} :8443
  {'admin.voipbin.test':<35} {host_ip:<18} :3003
  {'meet.voipbin.test':<35} {host_ip:<18} :3004
  {'talk.voipbin.test':<35} {host_ip:<18} :3005

{bold('SIP/VoIP Services')} (resolve to Kamailio IP: {kamailio_ip})
{'-' * 70}
  {'Domain':<35} {'Port':<8} {'Description'}
  {'sip.voipbin.test':<35} {'5060':<8} SIP proxy (UDP/TCP)
  {'sip-service.voipbin.test':<35} {'5060':<8} SIP proxy (alias)
  {'pstn.voipbin.test':<35} {'5060':<8} PSTN gateway
  {'trunk.voipbin.test':<35} {'5060':<8} SIP trunking
  {'*.registrar.voipbin.test':<35} {'5060':<8} SIP registration
                                             (e.g., {{customer_id}}.registrar.voipbin.test)

{bold('Internal Services')} (Docker bridge network)
{'-' * 70}
  {'Service':<35} {'IP':<16} {'Description'}
  {'api-manager':<35} {'172.28.0.100':<16} API Manager container
  {'square-admin':<35} {'172.28.0.101':<16} Admin Console container
  {'square-meet':<35} {'172.28.0.102':<16} Meet container
  {'square-talk':<35} {'172.28.0.103':<16} Talk container

{bold('Example SIP URIs')}
{'-' * 70}
  Extension registration:  sip:1000@{{customer_id}}.registrar.voipbin.test
  Extension call:          sip:2000@{{customer_id}}.registrar.voipbin.test
  PSTN call:               sip:+15551234567@pstn.voipbin.test

{bold('DNS Commands')}
{'-' * 70}
  dns status    Check DNS configuration status
  dns list      Show this domain reference
  dns setup     Configure DNS forwarding to CoreDNS
  dns test      Test domain resolution
""")

    def dns_setup(self):
        """Setup DNS forwarding to CoreDNS"""
        script_dir = self.config.get("project_dir", ".")
        script_path = os.path.join(script_dir, "scripts", "setup-dns.sh")

        if not os.path.exists(script_path):
            print(red(f"Setup script not found: {script_path}"))
            return

        print("Configuring DNS forwarding for *.voipbin.test to CoreDNS...\n")
        os.system(script_path)

    def dns_regenerate(self):
        """Regenerate CoreDNS configuration"""
        script_dir = self.config.get("project_dir", ".")
        script_path = os.path.join(script_dir, "scripts", "setup-dns.sh")

        if not os.path.exists(script_path):
            print(red(f"Setup script not found: {script_path}"))
            return

        print("Regenerating CoreDNS configuration (Corefile)...\n")
        os.system(f"{script_path} --regenerate")

    def dns_test(self):
        """Test DNS resolution for SIP domains"""
        host_ip = run_cmd("grep '^HOST_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or "localhost"
        kamailio_ip = run_cmd("grep '^KAMAILIO_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or host_ip

        # Get a customer ID if available
        customer_id = run_cmd(
            "docker exec voipbin-db mysql -u root -proot_password -N -e "
            "\"SELECT id FROM bin_manager.customer LIMIT 1\" 2>/dev/null"
        ) or "f1504bd0-9fd4-495b-a360-a73a6fa088b0"

        print(f"\n{bold('Testing DNS Domain Resolution')}")
        print("-" * 60)
        print(f"Host IP:     {host_ip} (web services)")
        print(f"Kamailio IP: {kamailio_ip} (SIP services)\n")

        all_ok = True

        # Web services (resolve to HOST_IP, Docker port mapping)
        print(f"  {bold('Web Services')} (Docker port mapping)")
        external_tests = [
            ("api.voipbin.test", host_ip),
            ("admin.voipbin.test", host_ip),
            ("meet.voipbin.test", host_ip),
            ("talk.voipbin.test", host_ip),
        ]
        for domain, expected in external_tests:
            result = run_cmd(f"dig +short {domain} @127.0.0.1 2>/dev/null | head -1")
            if not result:
                result = run_cmd(f"dig +short {domain} 2>/dev/null | head -1") or run_cmd(f"getent hosts {domain} 2>/dev/null | awk '{{print $1}}'")
            if result == expected:
                print(f"    {green('✓')} {domain} → {result}")
            elif result:
                print(f"    {yellow('!')} {domain} → {result} (expected: {expected})")
                all_ok = False
            else:
                print(f"    {red('✗')} {domain} → (no resolution)")
                all_ok = False

        # SIP services - resolve to Kamailio IP
        print(f"\n  {bold('SIP Services')} (expect {kamailio_ip})")
        sip_domains = [
            "sip.voipbin.test",
            "sip-service.voipbin.test",
            "pstn.voipbin.test",
            "trunk.voipbin.test",
            "registrar.voipbin.test",
            f"{customer_id[:8]}...registrar.voipbin.test",  # Shortened for display
        ]
        sip_domains_full = [
            "sip.voipbin.test",
            "sip-service.voipbin.test",
            "pstn.voipbin.test",
            "trunk.voipbin.test",
            "registrar.voipbin.test",
            f"{customer_id}.registrar.voipbin.test",
        ]

        for i, domain in enumerate(sip_domains_full):
            display_domain = sip_domains[i]
            result = run_cmd(f"dig +short {domain} @127.0.0.1 2>/dev/null | head -1")
            if not result:
                result = run_cmd(f"dig +short {domain} 2>/dev/null | head -1") or run_cmd(f"getent hosts {domain} 2>/dev/null | awk '{{print $1}}'")

            if result == kamailio_ip:
                print(f"    {green('✓')} {display_domain} → {result}")
            elif result:
                print(f"    {yellow('!')} {display_domain} → {result} (expected: {kamailio_ip})")
                all_ok = False
            else:
                print(f"    {red('✗')} {display_domain} → (no resolution)")
                all_ok = False

        print()
        if all_ok:
            print(green("All domains resolve correctly!"))
        else:
            print(yellow("Some domains are not resolving. Run 'dns setup' or 'dns regenerate' to fix."))
        print()

    def cmd_certs(self, args):
        """Manage SSL certificates"""
        subcmd = args[0].lower() if args else "status"

        if subcmd == "status":
            self.certs_status()
        elif subcmd == "trust":
            self.certs_trust()
        else:
            print("Usage: certs [status|trust]")

    def certs_status(self):
        """Check certificate configuration"""
        project_dir = self.config.get("project_dir", ".")
        certs_dir = os.path.join(project_dir, "certs")

        print(f"\n{bold('Certificate Status')}")
        print("-" * 50)

        # Check if mkcert is installed
        mkcert_installed = run_cmd("which mkcert 2>/dev/null")
        if mkcert_installed:
            print(f"  {green('●')} mkcert: installed")

            # Check if CA is installed
            ca_check = run_cmd("mkcert -check 2>&1")
            if "is not installed" in ca_check.lower():
                print(f"  {yellow('!')} mkcert CA: {yellow('not installed')}")
                print(f"      Run 'certs trust' to install CA for browser-trusted certificates")
            else:
                print(f"  {green('●')} mkcert CA: installed (browser-trusted)")
        else:
            print(f"  {gray('○')} mkcert: not installed")
            print(f"      Install with: sudo apt install mkcert  # or: brew install mkcert")

        # Check certificates directory
        print(f"\n  {bold('Certificates')}")
        if os.path.isdir(certs_dir):
            api_cert = os.path.join(certs_dir, "api", "cert.pem")
            if os.path.exists(api_cert):
                print(f"  {green('●')} API certificate: {api_cert}")
            else:
                print(f"  {red('○')} API certificate: not found")

            # List other cert directories
            for item in sorted(os.listdir(certs_dir)):
                item_path = os.path.join(certs_dir, item)
                if os.path.isdir(item_path) and item != "api":
                    cert_file = os.path.join(item_path, "fullchain.pem")
                    if os.path.exists(cert_file):
                        print(f"  {green('●')} {item}: found")
        else:
            print(f"  {red('○')} Certificates directory not found")
            print(f"      Run 'init' to generate certificates")

        print()

    def certs_trust(self):
        """Install mkcert CA for browser-trusted certificates"""
        print(f"\n{bold('Installing mkcert CA')}")
        print("-" * 50)

        # Check if mkcert is installed
        mkcert_installed = run_cmd("which mkcert 2>/dev/null")
        if not mkcert_installed:
            print(red("mkcert is not installed."))
            print("\nInstall mkcert first:")
            print("  Ubuntu/Debian: sudo apt install mkcert")
            print("  macOS:         brew install mkcert")
            print("\nThen run 'certs trust' again.")
            return

        print("Installing mkcert CA (this makes certificates browser-trusted)...\n")
        os.system("mkcert -install")

        print(f"\n{green('✓')} mkcert CA installed!")
        print("\nNext steps:")
        print("  1. Restart your browser")
        print("  2. If certificates were generated before CA install, regenerate them:")
        print("     rm -rf certs/")
        print("     voipbin> init")
        print()

    def cmd_network(self, args):
        """Manage VoIP network interfaces"""
        subcmd = args[0].lower() if args else "status"

        if subcmd == "status":
            self.network_status()
        elif subcmd == "setup":
            # Parse --external-ip if provided
            external_ip = None
            for i, arg in enumerate(args):
                if arg == "--external-ip" and i + 1 < len(args):
                    external_ip = args[i + 1]
                    break
            self.network_setup(external_ip)
        elif subcmd == "teardown":
            self.network_teardown()
        else:
            print("Usage: network [status|setup|teardown]")
            print("       network setup --external-ip X.X.X.X")

    def network_status(self):
        """Show VoIP network configuration status"""
        print(f"\n{bold('VoIP Network Configuration')}")
        print("=" * 60)

        # Get IPs from .env
        host_ip = run_cmd("grep '^HOST_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or "not set"
        kamailio_ip = run_cmd("grep '^KAMAILIO_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or ""
        rtpengine_ip = run_cmd("grep '^RTPENGINE_EXTERNAL_IP=' .env 2>/dev/null | cut -d'=' -f2 | head -1") or ""

        # Check internal interfaces
        print(f"\n{bold('Internal Interfaces')} (Docker bridge → host macvlan)")
        print("-" * 60)

        kamailio_int = run_cmd("ip addr show kamailio-int 2>/dev/null | grep -oP 'inet \\K[\\d./]+' | head -1")
        rtpengine_int = run_cmd("ip addr show rtpengine-int 2>/dev/null | grep -oP 'inet \\K[\\d./]+' | head -1")

        if kamailio_int:
            print(f"  {green('●')} kamailio-int:  {kamailio_int}")
        else:
            print(f"  {red('○')} kamailio-int:  not configured")

        if rtpengine_int:
            print(f"  {green('●')} rtpengine-int: {rtpengine_int}")
        else:
            print(f"  {red('○')} rtpengine-int: not configured")

        # Check Docker network
        print(f"\n{bold('Docker Networks')}")
        print("-" * 60)

        # Check if voip-internal network exists
        voip_internal = run_cmd("docker network inspect sandbox_voip-internal --format '{{.Id}}' 2>/dev/null | head -c 12")
        if voip_internal:
            bridge_if = f"br-{voip_internal}"
            bridge_exists = run_cmd(f"ip link show {bridge_if} 2>/dev/null | head -1")
            if bridge_exists:
                print(f"  {green('●')} voip-internal: {bridge_if} (172.29.0.0/16)")
            else:
                print(f"  {yellow('!')} voip-internal: network exists but bridge not found")
        else:
            print(f"  {gray('○')} voip-internal: not created (run 'docker compose up -d' first)")

        default_network = run_cmd("docker network inspect sandbox_default --format '{{.Id}}' 2>/dev/null | head -c 12")
        if default_network:
            print(f"  {green('●')} default:       br-{default_network} (172.28.0.0/16)")
        else:
            print(f"  {gray('○')} default:       not created")

        # External configuration
        print(f"\n{bold('External Configuration')}")
        print("-" * 60)
        print(f"  HOST_EXTERNAL_IP: {blue(host_ip)}")

        physical_iface = run_cmd("ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \\K\\S+' | head -1") or "eth0"

        if kamailio_ip:
            ip_on_iface = run_cmd(f"ip addr show {physical_iface} 2>/dev/null | grep -oP 'inet \\K{kamailio_ip}'")
            if ip_on_iface:
                print(f"  KAMAILIO_EXTERNAL_IP:   {green(kamailio_ip)} (configured on {physical_iface})")
            else:
                print(f"  KAMAILIO_EXTERNAL_IP:   {yellow(kamailio_ip)} (not yet applied)")
        else:
            print(f"  KAMAILIO_EXTERNAL_IP:   {red('not set')} (required for SIP)")

        if rtpengine_ip:
            ip_on_iface = run_cmd(f"ip addr show {physical_iface} 2>/dev/null | grep -oP 'inet \\K{rtpengine_ip}'")
            if ip_on_iface:
                print(f"  RTPENGINE_EXTERNAL_IP:  {green(rtpengine_ip)} (configured on {physical_iface})")
            else:
                print(f"  RTPENGINE_EXTERNAL_IP:  {yellow(rtpengine_ip)} (not yet applied)")
        else:
            print(f"  RTPENGINE_EXTERNAL_IP:  {red('not set')} (required for RTP media)")

        # Web services info
        print(f"\n{bold('Web Services')} (Docker port mapping)")
        print("-" * 60)
        print(f"  API:   {host_ip}:8443")
        print(f"  Admin: {host_ip}:3003")
        print(f"  Meet:  {host_ip}:3004")
        print(f"  Talk:  {host_ip}:3005")

        # Show physical interface IPs
        print(f"\n{bold('Physical Interface')}")
        print("-" * 60)
        physical_iface = run_cmd("ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \\K\\S+' | head -1") or "unknown"
        iface_ips = run_cmd(f"ip addr show {physical_iface} 2>/dev/null | grep -oP 'inet \\K[\\d./]+'")
        if iface_ips:
            print(f"  {physical_iface}:")
            for ip in iface_ips.split('\n'):
                if ip:
                    print(f"    {ip}")
        else:
            print(f"  Could not detect physical interface")

        print(f"\n{bold('Usage')}")
        print("-" * 60)
        print("  network setup                     Setup internal interfaces")
        print("  network setup --external-ip X.X.X.X  Add secondary IP for VoIP")
        print("  network teardown                  Remove interfaces")
        print()

    def network_setup(self, external_ip=None):
        """Setup VoIP network interfaces"""
        script_dir = self.config.get("project_dir", ".")
        script_path = os.path.join(script_dir, "scripts", "setup-voip-network.sh")

        if not os.path.exists(script_path):
            print(red(f"Setup script not found: {script_path}"))
            return

        print(f"\n{bold('Setting up VoIP network interfaces...')}\n")

        cmd = script_path
        if external_ip:
            cmd += f" --external-ip {external_ip}"

        os.system(cmd)

    def network_teardown(self):
        """Teardown VoIP network interfaces"""
        script_dir = self.config.get("project_dir", ".")
        script_path = os.path.join(script_dir, "scripts", "teardown-voip-network.sh")

        if not os.path.exists(script_path):
            print(red(f"Teardown script not found: {script_path}"))
            return

        print(f"\n{bold('Tearing down VoIP network interfaces...')}\n")
        os.system(script_path)

    def cmd_init(self, args):
        """Initialize sandbox"""
        script_dir = self.config.get("project_dir", ".")
        script_path = os.path.join(script_dir, "scripts", "init.sh")

        if not os.path.exists(script_path):
            print(red(f"Init script not found: {script_path}"))
            return

        print("Running initialization script...")
        print("This will generate .env and certificates.\n")
        os.system(script_path)

    def cmd_clean(self, args):
        """Cleanup sandbox"""
        if not args:
            print("Usage: clean [--volumes] [--images] [--network] [--dns] [--purge] [--all]")
            print("")
            print("Options:")
            print("  --volumes   Remove docker volumes (database, recordings)")
            print("  --images    Remove docker images")
            print("  --network   Teardown VoIP network interfaces")
            print("  --dns       Remove DNS configuration")
            print("  --purge     Remove generated files (.env, certs, configs)")
            print("  --all       All of the above (full reset)")
            return

        # Parse options
        clean_volumes = "--volumes" in args or "--all" in args
        clean_images = "--images" in args or "--all" in args
        teardown_network = "--network" in args or "--all" in args
        teardown_dns = "--dns" in args or "--all" in args
        purge = "--purge" in args or "--all" in args

        project_dir = self.config.get("project_dir", ".")
        scripts_dir = os.path.join(project_dir, "scripts")

        # Stop services first
        print("Stopping services...")
        if clean_volumes:
            run_cmd("docker compose down -v 2>&1")
            print(green("✓ Services stopped and volumes removed"))
        else:
            run_cmd("docker compose down 2>&1")
            print(green("✓ Services stopped"))

        # Remove images
        if clean_images:
            print("\nRemoving docker images...")
            # Get images from docker compose
            compose_images = run_cmd("docker compose config --images 2>/dev/null") or ""
            # Get voipbin images
            voipbin_images = run_cmd("docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^voipbin/' 2>/dev/null") or ""
            # Get other sandbox images
            other_images = run_cmd("docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^(mysql|redis|rabbitmq|coredns/)' 2>/dev/null") or ""

            # Combine and deduplicate
            all_images = set()
            for img_list in [compose_images, voipbin_images, other_images]:
                for img in img_list.strip().split('\n'):
                    if img and '<none>' not in img:
                        all_images.add(img)

            removed = 0
            for image in sorted(all_images):
                result = run_cmd(f"docker rmi -f {image} 2>/dev/null")
                if result is not None:
                    print(f"  Removed: {image}")
                    removed += 1

            # Also try docker compose --rmi
            run_cmd("docker compose down --rmi all 2>/dev/null")
            print(green(f"✓ Removed {removed} docker images"))

        # Teardown network
        if teardown_network:
            print("\nTearing down VoIP network interfaces...")
            script_path = os.path.join(scripts_dir, "teardown-voip-network.sh")
            if os.path.exists(script_path):
                os.system(f"{script_path} 2>/dev/null || true")
                print(green("✓ Network interfaces removed"))
            else:
                print(yellow("! teardown-voip-network.sh not found"))

        # Teardown DNS
        if teardown_dns:
            print("\nRemoving DNS configuration...")
            script_path = os.path.join(scripts_dir, "setup-dns.sh")
            if os.path.exists(script_path):
                os.system(f"{script_path} --uninstall 2>/dev/null || true")
                print(green("✓ DNS configuration removed"))
            else:
                print(yellow("! setup-dns.sh not found"))

        # Purge generated files
        if purge:
            print("\nPurging generated files...")

            files_to_remove = [
                ("certs", "certificates directory"),
                (".env", ".env file"),
                ("config/coredns", "CoreDNS config"),
                ("config/dummy-gcp-credentials.json", "dummy GCP credentials"),
                ("tmp", "tmp directory"),
            ]

            for path, desc in files_to_remove:
                full_path = os.path.join(project_dir, path)
                if os.path.exists(full_path):
                    if os.path.isdir(full_path):
                        import shutil
                        shutil.rmtree(full_path)
                    else:
                        os.remove(full_path)
                    print(f"  Removed {desc}")

            print(green("✓ Generated files purged"))

        print(f"\n{bold('Cleanup complete!')}")
        print("Run 'init' to initialize, then 'start' to begin.")

    def cmd_update(self, args):
        """Update sandbox - pull images and run migrations"""
        pull_images = True
        run_migrations = True

        # Parse options
        if args:
            if "--images" in args:
                pull_images = True
                run_migrations = False
            elif "--migrate" in args:
                pull_images = False
                run_migrations = True

        project_dir = self.config.get("project_dir", ".")

        print(f"\n{bold('VoIPBin Sandbox Update')}")
        print("=" * 50)

        # Step 1: Pull latest Docker images
        if pull_images:
            print(f"\n{blue('==>')} Pulling latest Docker images...")
            result = run_cmd("docker compose pull 2>&1")
            if result:
                # Show summary of pulled images
                lines = result.strip().split('\n')
                for line in lines[-10:]:  # Show last 10 lines
                    print(f"  {line}")
            print(green("✓ Images updated"))

        # Step 2: Run database migrations
        if run_migrations:
            print(f"\n{blue('==>')} Running database migrations...")

            # Check if alembic is available
            alembic_check = run_cmd("which alembic 2>/dev/null")
            if not alembic_check:
                print(yellow("! Alembic not found. Install with: pip3 install alembic mysqlclient PyMySQL"))
                print(yellow("  Skipping database migrations."))
            else:
                # Check if database is running
                db_check = run_cmd("docker exec voipbin-db mysql -u root -proot_password -e 'SELECT 1' 2>/dev/null")
                if not db_check:
                    print(yellow("! Database not running. Start services first with 'start'."))
                    print(yellow("  Skipping database migrations."))
                else:
                    # Run migrations using init_database.sh
                    script_path = os.path.join(project_dir, "scripts", "init_database.sh")
                    if os.path.exists(script_path):
                        print("  Running alembic migrations...")
                        os.system(f"{script_path}")
                        print(green("✓ Database migrations complete"))
                    else:
                        print(yellow("! init_database.sh not found"))

        # Step 3: Restart services if they were running
        running_services = run_cmd("docker compose ps -q 2>/dev/null")
        if running_services and pull_images:
            print(f"\n{blue('==>')} Restarting services with new images...")
            run_cmd("docker compose up -d 2>&1")
            print(green("✓ Services restarted"))

        print(f"\n{bold('Update complete!')}")
        print("Run 'status' to check service status.")

    def cmd_exit(self, args):
        """Exit CLI"""
        self.running = False

    def cmd_clear(self, args):
        """Clear screen"""
        os.system("clear" if os.name != "nt" else "cls")


# =============================================================================
# Tab Completion
# =============================================================================

class Completer:
    def __init__(self, cli):
        self.cli = cli
        self.matches = []

    def complete(self, text, state):
        if state == 0:
            line = readline.get_line_buffer()
            self.matches = self.get_matches(line, text)

        try:
            return self.matches[state]
        except IndexError:
            return None

    def get_matches(self, line, text):
        """Get completion matches"""
        parts = line.split()

        # In context mode
        if self.cli.context:
            return self.context_matches(text)

        # Empty line or first word - complete commands
        if not parts or (len(parts) == 1 and not line.endswith(" ")):
            commands = list(self.cli.commands.keys())
            return [c + " " for c in commands if c.startswith(text)]

        # Second word - context-specific completion
        cmd = parts[0].lower()

        if cmd in ("start", "stop", "restart", "logs"):
            # Complete service names
            services = get_all_services()
            if cmd == "logs" and text == "-":
                return ["-f "]
            return [s + " " for s in services if s.startswith(text)]

        if cmd == "ext":
            subcmds = ["list", "create", "delete"]
            return [s + " " for s in subcmds if s.startswith(text)]

        if cmd == "customer":
            subcmds = ["info", "create"]
            return [s + " " for s in subcmds if s.startswith(text)]

        if cmd == "network":
            subcmds = ["status", "setup", "teardown"]
            return [s + " " for s in subcmds if s.startswith(text)]

        if cmd == "dns":
            subcmds = ["status", "list", "setup", "regenerate", "test"]
            return [s + " " for s in subcmds if s.startswith(text)]

        if cmd == "certs":
            subcmds = ["status", "trust"]
            return [s + " " for s in subcmds if s.startswith(text)]

        if cmd == "config":
            if len(parts) == 1 or (len(parts) == 2 and not line.endswith(" ")):
                keys = list(self.cli.config.data.keys()) + ["reset"]
                return [k + " " for k in keys if k.startswith(text)]

        if cmd in ("ast", "asterisk"):
            # Common Asterisk commands
            ast_cmds = [
                "pjsip show endpoints", "pjsip show contacts", "pjsip show aors",
                "core show channels", "core show calls", "core show version",
                "sip show peers", "sip show registry",
                "dialplan show", "module show",
            ]
            return [c for c in ast_cmds if c.startswith(text)]

        if cmd in ("kam", "kamailio"):
            # Common kamcmd commands
            kam_cmds = [
                "ul.dump", "ul.lookup", "stats.get_statistics",
                "tm.stats", "sl.stats", "core.version",
            ]
            return [c for c in kam_cmds if c.startswith(text)]

        return []

    def context_matches(self, text):
        """Get matches for context mode"""
        if self.cli.context == "asterisk":
            cmds = [
                "pjsip show endpoints", "pjsip show contacts",
                "core show channels", "core show calls",
                "exit", "quit"
            ]
            return [c for c in cmds if c.startswith(text)]

        if self.cli.context == "api":
            cmds = ["login", "get", "post", "put", "delete", "exit", "quit"]
            return [c + " " for c in cmds if c.startswith(text)]

        return ["exit ", "quit "]


# =============================================================================
# Main Loop
# =============================================================================

def setup_readline(cli):
    """Setup readline with history and completion"""
    # History
    if HISTORY_FILE.exists():
        try:
            readline.read_history_file(HISTORY_FILE)
        except (IOError, OSError):
            pass

    readline.set_history_length(cli.config.get("history_size", 1000))
    atexit.register(lambda: readline.write_history_file(HISTORY_FILE))

    # Tab completion
    completer = Completer(cli)
    readline.set_completer(completer.complete)
    readline.parse_and_bind("tab: complete")

    # macOS compatibility
    if "libedit" in readline.__doc__:
        readline.parse_and_bind("bind ^I rl_complete")


def show_cli_usage():
    """Show usage for command-line mode"""
    print(f"""
{bold('VoIPBin Sandbox CLI')}

Usage:
  sudo ./voipbin                # Start interactive mode
  sudo ./voipbin <command>      # Run command and exit

Commands:
  status              Show service status
  start [service]     Start all services (or specific service)
  stop [service]      Stop all services (or specific service)
  restart [service]   Restart services
  logs <service>      View logs
  init                Initialize sandbox (generates .env and certs)
  update [options]    Pull latest images and run DB migrations
  dns [subcommand]    DNS configuration (status, list, setup, regenerate, test)
  certs [subcommand]  Certificate management (status, trust)
  network [subcommand] VoIP network management (status, setup, teardown)
  clean [options]     Cleanup sandbox
    --volumes         Remove docker volumes
    --network         Teardown VoIP network interfaces
    --dns             Remove DNS configuration
    --purge           Remove generated files (.env, certs, configs)
    --all             Full reset (all of the above)

Examples:
  sudo ./voipbin status
  sudo ./voipbin start
  sudo ./voipbin network setup --external-ip 192.168.45.160
  sudo ./voipbin clean --all
  sudo ./voipbin logs api-manager

Note: This CLI requires sudo for network and DNS operations.
""")


def main():
    # Require root/sudo
    check_root()

    cli = VoIPBinCLI()

    # Change to project directory
    project_dir = cli.config.get("project_dir")
    if project_dir and os.path.isdir(project_dir):
        os.chdir(project_dir)

    # Check for command-line arguments (non-interactive mode)
    if len(sys.argv) > 1:
        # Handle help
        if sys.argv[1] in ("-h", "--help", "help"):
            show_cli_usage()
            return

        # Parse command and args
        cmd = sys.argv[1].lower()
        args = sys.argv[2:]

        if cmd in cli.commands:
            cli.commands[cmd](args)
        else:
            print(red(f"Unknown command: {cmd}"))
            print("Run 'sudo ./voipbin --help' for usage.")
            sys.exit(1)
        return

    # Interactive mode
    setup_readline(cli)

    # Show welcome dashboard
    show_welcome_dashboard()

    # Handle Ctrl+C gracefully
    def sigint_handler(sig, frame):
        print()
        if cli.context:
            cli.context = None
        else:
            print("Type 'exit' to quit")

    signal.signal(signal.SIGINT, sigint_handler)

    while cli.running:
        try:
            line = input(cli.get_prompt())

            if cli.context:
                cli.run_in_context(line)
            else:
                cmd, args = cli.parse_input(line)
                if cmd:
                    if cmd in cli.commands:
                        cli.commands[cmd](args)
                    else:
                        print(f"Unknown command: {cmd}. Type 'help' for available commands.")

        except EOFError:
            print()
            break
        except KeyboardInterrupt:
            print()
            continue
        except Exception as e:
            print(red(f"Error: {e}"))

    print("Goodbye!")


if __name__ == "__main__":
    main()
