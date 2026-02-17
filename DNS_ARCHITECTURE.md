# DNS Architecture

## Overview

Talc uses a two-tier DNS architecture to provide wildcard domain resolution for local development:

```
Client → systemd-resolved (port 53) → dnsmasq (port 5335)
         ↓ (forwards .internal)
```

- **systemd-resolved**: System DNS resolver running on port 53
  - Handles all DNS queries from applications
  - Configured to forward queries for `.internal` domains to dnsmasq on localhost:5335
  - Handles all other DNS queries normally (using system's upstream DNS servers)

- **dnsmasq**: Wildcard DNS resolver running on port 5335
  - Receives only `.internal` domain queries from systemd-resolved
  - Provides wildcard resolution (e.g., `*.myapp.internal` → `127.0.0.1`)
  - No upstream DNS needed (only handles `.internal` queries)

## Benefits of This Architecture

1. **Non-invasive**: systemd-resolved remains the primary DNS resolver
2. **Selective forwarding**: Only `.internal` domains go to dnsmasq
3. **System compatibility**: Works with existing system DNS configuration
4. **Easy rollback**: Removing `/etc/systemd/resolved.conf.d/talc.conf` restores normal operation

## Configuration Files

### systemd-resolved Configuration
**Location**: `/etc/systemd/resolved.conf.d/talc.conf`

```ini
# Managed by Talc
# Forward all .internal DNS queries to dnsmasq on localhost:5335
[Resolve]
DNS=127.0.0.1:5335
Domains=~internal
```

The `~internal` syntax tells systemd-resolved to route only `.internal` queries to the specified DNS server.

### dnsmasq Configuration
**Location**: `/etc/dnsmasq.d/talc.conf`

```
# Managed by Talc
# Architecture: systemd-resolved (port 53) forwards .internal → dnsmasq (port 5335)
port=5335
listen-address=127.0.0.1
bind-interfaces

# Don't read /etc/resolv.conf (systemd-resolved handles forwarding)
no-resolv

# We only handle .internal queries (no upstream needed)
# All other queries are handled by systemd-resolved

# Wildcard DNS resolution for *.internal domains
address=/.internal/127.0.0.1
```

## Critical Configuration Issue & Solution

### The Problem

**Symptom**: Wildcard domain resolution doesn't work even though `/etc/dnsmasq.d/talc.conf` exists and looks correct.

**Root Cause**: dnsmasq doesn't load configuration files from `/etc/dnsmasq.d/` by default. The `conf-dir` directive in `/etc/dnsmasq.conf` is typically commented out:

```
# Configuration file location
#conf-dir=/etc/dnsmasq.d/,*.conf
```

Even though the file exists in `/etc/dnsmasq.d/`, dnsmasq ignores it!

### The Solution

Talc automatically enables the `conf-dir` directive during setup:

1. **Check** if `conf-dir=/etc/dnsmasq.d/` is already enabled in `/etc/dnsmasq.conf`
2. **Uncomment** the line if it exists but is commented out
3. **Add** the directive if it doesn't exist

This is implemented in the `enable_dnsmasq_conf_dir` method in `lib/talc/dns/dnsmasq.rb`.

### Manual Fix

If you encounter this issue manually, run:

```bash
# Edit /etc/dnsmasq.conf
sudo $EDITOR /etc/dnsmasq.conf

# Find and uncomment this line (or add it):
conf-dir=/etc/dnsmasq.d/,*.conf

# Restart dnsmasq
sudo systemctl restart dnsmasq
```

## Verification

### Check systemd-resolved Configuration

```bash
# Verify config file exists
cat /etc/systemd/resolved.conf.d/talc.conf

# Check systemd-resolved status
resolvectl status

# Should show:
# Link ... (...)
#   ...
#   DNS Servers: 127.0.0.1:5335
#   DNS Domain: ~internal
```

### Check dnsmasq Configuration

```bash
# Verify config file exists
cat /etc/dnsmasq.d/talc.conf

# Verify conf-dir is enabled
grep "^conf-dir=/etc/dnsmasq.d/" /etc/dnsmasq.conf

# Check dnsmasq is listening on port 5335
sudo ss -tulpn | grep ':5335.*dnsmasq'
# Should show: 127.0.0.1:5335 ... dnsmasq
```

### Test DNS Resolution

```bash
# Test wildcard subdomain resolution
dig myapp.internal @127.0.0.1
dig api.myapp.internal @127.0.0.1
dig anything.myapp.internal @127.0.0.1

# All should resolve to 127.0.0.1 (or your configured local IP)

# Test through systemd-resolved
resolvectl query myapp.internal
# Should show the correct IP
```

## Troubleshooting

### DNS queries not resolving

1. Check systemd-resolved is running:
   ```bash
   systemctl status systemd-resolved
   ```

2. Check dnsmasq is running on port 5335:
   ```bash
   sudo ss -tulpn | grep ':5335.*dnsmasq'
   ```

3. Verify conf-dir is enabled in `/etc/dnsmasq.conf`:
   ```bash
   grep "^conf-dir=/etc/dnsmasq.d/" /etc/dnsmasq.conf
   ```

4. Check systemd-resolved configuration:
   ```bash
   resolvectl status
   ```

### Port 5335 already in use

If another service is using port 5335:

```bash
# Find what's using the port
sudo ss -tulpn | grep ':5335'

# Stop the conflicting service
sudo systemctl stop <service-name>
```

### Changes not taking effect

After modifying configuration:

```bash
# Reload systemd-resolved
sudo systemctl restart systemd-resolved

# Reload dnsmasq
sudo systemctl restart dnsmasq

# Verify with talc status
talc status
```

## Reverting Configuration

To remove Talc's DNS configuration:

```bash
talc teardown
```

This will:
1. Remove `/etc/dnsmasq.d/talc.conf`
2. Remove `/etc/systemd/resolved.conf.d/talc.conf`
3. Stop and disable dnsmasq (without Talc's config it would conflict with systemd-resolved on port 53)
4. Restart systemd-resolved to remove `.internal` forwarding
