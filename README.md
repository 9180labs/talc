# Talc

**Manage `.internal` domains with DNS and reverse proxy on Arch Linux**

Talc is a CLI tool that makes it easy to access your local development services via memorable domain names across your entire local network. Instead of remembering `localhost:3000`, `192.168.1.155:8080`, etc., you can use clean URLs like `myapp.internal` and `api.internal`.

## The Problem It Solves

When running multiple local services (web apps, APIs, databases), developers face these challenges:

- Remembering IP addresses and port numbers
- Configuring each device to access services
- Setting up DNS and reverse proxy manually
- Managing configuration files across services

Talc automates all of this with simple commands.

## Features

- **Simple CLI**: Add domains with `talc add myapp --port 3000`
- **Network-wide**: Access from any device on your LAN (with [DNS configuration](#network-setup))
- **Automatic DNS**: Wildcard DNS resolution via dnsmasq
- **Reverse Proxy**: Automatic routing via Caddy
- **Persistent**: Domains survive reboots
- **Arch Linux**: Designed for Arch Linux with systemd

## Requirements

- **OS**: Arch Linux
- **Ruby**: 4.0.1 or higher
- **Dependencies**:
  - systemd-resolved (system DNS resolver)
  - dnsmasq (DNS server for `.internal` domains)
  - Caddy (reverse proxy)
  - sudo (for system configuration)

## Installation

### 1. Install System Dependencies

```bash
sudo pacman -S dnsmasq caddy
```

### 2. Install Talc

From source:

```bash
git clone https://github.com/matrix9180/talc.git
cd talc
bundle install
bundle exec rake install
```

From RubyGems (once published):

```bash
gem install talc
```

### 3. Run Setup

```bash
talc setup
```

This will:
- Create configuration directory (`~/.config/talc/`)
- Initialize storage (`~/.config/talc/domains.json`)
- Configure systemd-resolved to forward `.internal` queries to dnsmasq
- Configure dnsmasq on port 5335 with wildcard DNS for `.internal` domains
- Enable and start required services

## Quick Start

### Add a domain

```bash
talc add myapp --port 3000
```

Now you can access your service at `http://myapp.internal`! For access from other devices on your LAN, see [Network Setup](#network-setup).

### List domains

```bash
talc list
```

Output:
```
Configured Domains:

  NAME     FULL DOMAIN        PROXY            UPDATED
  ---------------------------------------------------------------
  myapp    myapp.internal     127.0.0.1:3000   2025-01-15 10:30
  api      api.internal       127.0.0.1:8080   2025-01-15 11:45
```

### Update a domain

```bash
talc update myapp --port 3001
```

### Remove a domain

```bash
talc remove myapp
```

### Check status

```bash
talc status
```

Output:
```
Talc Status
==================================================

DNS (dnsmasq):
  Installed:    ✓
  Running:      ✓
  Enabled:      ✓
  Configured:   ✓
  Port 5335:    ✓

System DNS (systemd-resolved):
  Running:      ✓
  Enabled:      ✓
  Configured:   ✓

Proxy (Caddy):
  Installed: ✓
  Running:   ✓
  Enabled:   ✓
  API:       ✓

Configuration:
  Local IP:      192.168.1.155
  Domain suffix: .internal
  Domains:       2
```

## Usage

### Commands

#### `talc add DOMAIN --port PORT [--ip IP]`

Add a new domain.

```bash
# Basic usage
talc add myapp --port 3000

# Specify custom IP (default: 127.0.0.1)
talc add remote --port 5000 --ip 192.168.1.200
```

#### `talc remove DOMAIN`

Remove a domain.

```bash
talc remove myapp
```

#### `talc list [--format json|table]`

List all configured domains.

```bash
# Table format (default)
talc list

# JSON format
talc list --format json
```

#### `talc update DOMAIN [--port PORT] [--ip IP]`

Update an existing domain.

```bash
# Update port
talc update myapp --port 3001

# Update IP
talc update myapp --ip 192.168.1.200

# Update both
talc update myapp --port 3001 --ip 192.168.1.200
```

#### `talc setup`

Initial setup. Checks dependencies, creates configuration, and starts services.

```bash
talc setup
```

#### `talc status`

Show status of DNS and proxy services.

```bash
talc status
```

#### `talc teardown [--confirm]`

Remove all Talc configuration and domains, including dnsmasq and systemd-resolved configs.

```bash
# Interactive confirmation
talc teardown

# Skip confirmation
talc teardown --confirm
```

#### `talc version`

Show version information.

```bash
talc version
```

### Global Options

- `--verbose, -v`: Enable verbose output
- `--config PATH`: Use custom config file
- `--help, -h`: Show help

```bash
talc add myapp --port 3000 --verbose
talc list --config ~/my-config.yml
```

## Configuration

Talc uses `~/.config/talc/config.yml` for configuration.

### Default Configuration

```yaml
# Domain suffix for all domains (e.g., myapp.internal)
domain_suffix: internal

# Local IP address (auto-detect if set to 'auto')
local_ip: auto

# DNS provider (currently only dnsmasq supported)
dns_provider: dnsmasq

# Caddy API URL
caddy_api_url: http://localhost:2019
```

### Manual Configuration

Edit the config file:

```bash
nano ~/.config/talc/config.yml
```

Then restart services:

```bash
sudo systemctl restart dnsmasq
sudo systemctl restart caddy
```

## How It Works

### Architecture

```
                Your LAN
 ┌──────────┐                ┌───────────────────────────┐
 │  Laptop  │                │   Development Machine     │
 │          │                │                           │
 │  Browser │──┐             │  ┌─────────────────────┐  │
 └──────────┘  │             │  │  systemd-resolved   │  │
               │             │  │  (port 53)          │  │
 ┌──────────┐  │             │  └──────────┬──────────┘  │
 │  Phone   │──┼── myapp. ─▶│             │ .internal   │
 │          │  │   internal  │             ▼ queries     │
 └──────────┘  │             │  ┌─────────────────────┐  │
               │             │  │  dnsmasq            │  │
 ┌──────────┐  │             │  │  (port 5335)        │  │
 │  Tablet  │──┘             │  │  *.internal →       │  │
 │          │                │  │  192.168.1.155      │  │
 └──────────┘                │  └──────────┬──────────┘  │
                             │             │             │
                             │  ┌──────────▼──────────┐  │
                             │  │  Caddy (Proxy)      │  │
                             │  └──────────┬──────────┘  │
                             │             │             │
                             │  ┌──────────▼──────────┐  │
                             │  │  Your Services      │  │
                             │  │  :3000, :8080...    │  │
                             │  └─────────────────────┘  │
                             └───────────────────────────┘
```

1. **System DNS (systemd-resolved)**: Listens on port 53 and forwards `.internal` queries to dnsmasq
2. **DNS (dnsmasq)**: Listens on port 5335 and resolves `*.internal` to your machine's LAN IP
3. **Proxy (Caddy)**: Routes requests from domains to local ports
4. **Storage**: Persists domain configurations in JSON
5. **CLI**: Manages everything with simple commands

### Files and Locations

- **Config**: `~/.config/talc/config.yml`
- **Storage**: `~/.config/talc/domains.json`
- **DNS Config**: `/etc/dnsmasq.d/talc.conf`
- **Resolved Config**: `/etc/systemd/resolved.conf.d/talc.conf`
- **Caddy Routes**: Managed via Caddy API (port 2019)

## Network Setup

For LAN-wide access, configure other devices to use your machine as DNS server.

### Option 1: Router Configuration (Recommended)

Configure your router to use your machine's IP as a DNS server. This applies to all devices automatically.

1. Access router admin panel
2. Find DNS settings (usually under DHCP/LAN settings)
3. Add your machine's IP (e.g., `192.168.1.155`) as primary DNS
4. Keep your ISP's DNS as secondary

### Option 2: Per-Device Configuration

Configure each device manually:

#### Linux/macOS
Edit `/etc/resolv.conf`:
```
nameserver 192.168.1.155
nameserver 8.8.8.8
```

#### Windows
1. Network settings → Adapter settings
2. Properties → IPv4 → Properties
3. Use following DNS servers: `192.168.1.155`, `8.8.8.8`

#### Android/iOS
Wi-Fi settings → DNS → Manual → Add `192.168.1.155`

## Troubleshooting

### Domains don't resolve

**Check dnsmasq status:**
```bash
talc status
sudo systemctl status dnsmasq
```

**Check dnsmasq config:**
```bash
cat /etc/dnsmasq.d/talc.conf
```

Should show:
```
# Managed by Talc
port=5335
listen-address=127.0.0.1
bind-interfaces
no-resolv
address=/.internal/192.168.1.155
```

**Check systemd-resolved config:**
```bash
cat /etc/systemd/resolved.conf.d/talc.conf
```

Should show:
```
# Managed by Talc
[Resolve]
DNS=127.0.0.1:5335
Domains=~internal
```

**Restart services:**
```bash
sudo systemctl restart dnsmasq
sudo systemctl restart systemd-resolved
```

**Test DNS resolution:**
```bash
dig myapp.internal
nslookup myapp.internal
```

### Can't access domain from browser

**Check Caddy status:**
```bash
talc status
sudo systemctl status caddy
```

**Check Caddy routes:**
```bash
talc list
curl http://localhost:2019/config/apps/http/servers/talc/routes
```

**Check if service is running:**
```bash
curl http://localhost:3000  # Replace with your port
```

**Test domain locally:**
```bash
curl http://myapp.internal
```

### Permission denied errors

Most Talc operations require sudo to modify system files.

**Check sudo availability:**
```bash
which sudo
```

**Run with sudo when needed:**
```bash
sudo talc setup
```

### Can't access from other devices

**Check firewall:**
```bash
# Allow DNS (port 53)
sudo ufw allow 53

# Allow HTTP (port 80)
sudo ufw allow 80

# Check status
sudo ufw status
```

**Check device DNS settings:**

Ensure other devices are configured to use your machine as DNS (see Network Setup).

**Verify local IP:**
```bash
ip addr show
# or
talc status
```

### Services don't start on boot

**Enable services:**
```bash
sudo systemctl enable dnsmasq
sudo systemctl enable caddy
```

**Check service status:**
```bash
systemctl is-enabled dnsmasq
systemctl is-enabled caddy
```

## Development

### Setup

```bash
git clone https://github.com/matrix9180/talc.git
cd talc
bundle install
```

### Run Tests

```bash
bundle exec rake test
```

### Run Locally

```bash
./exe/talc --help
```

### Install Locally

```bash
bundle exec rake install
```

## Architecture Details

### Module Structure

```
Talc::
├── CLI                    # Thor-based command interface
├── Config                 # YAML configuration management
├── DomainManager          # Core orchestration logic
├── DNS::
│   ├── Base              # DNS provider interface
│   └── Dnsmasq           # dnsmasq implementation
├── Proxy::
│   ├── Base              # Proxy provider interface
│   ├── CaddyAPI          # Caddy API client
│   └── CaddyFile         # Caddy file-based fallback
├── Storage                # JSON file persistence
├── Network                # LAN IP detection
├── System                 # Systemd/sudo helpers
└── Errors                 # Custom exceptions
```

### Storage Schema

`~/.config/talc/domains.json`:

```json
{
  "domains": [
    {
      "name": "myapp",
      "port": 3000,
      "ip": "127.0.0.1",
      "created_at": "2025-01-15T10:30:00Z",
      "updated_at": "2025-01-15T10:30:00Z"
    }
  ]
}
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/matrix9180/talc.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a Pull Request

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Acknowledgments

- Built with [Thor](https://github.com/rails/thor) for CLI
- Uses [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) for DNS
- Uses [Caddy](https://caddyserver.com/) for reverse proxy
- Designed for [Arch Linux](https://archlinux.org/)
