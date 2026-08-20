# OpenShell Gateway - Podman Deployment

Rootless Podman deployment of the OpenShell gateway for local single-user development.

## Prerequisites

- **Podman** (rootless mode) - [Setup guide](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)
- **OpenShell CLI** - [Installation guide](https://docs.nvidia.com/openshell/install)
- **OpenSSL** - For JWT key generation
- **UUID tools** - For generating key IDs (`uuidgen`)

**SELinux Users:** This deployment uses `security_opt: label=disable` for Podman socket access.

## Quick Start

### 1. Generate JWT Keys and Configuration

Run the setup script to create JWT signing keys and generate `gateway.toml`:

```bash
./setup.sh
```

This script:
- Creates Ed25519 JWT signing keys in `~/.config/openshell/jwt/`
- Generates `gateway.toml` from the template with your paths
- Sets proper file permissions

**Note:** `gateway.toml` is git-ignored and specific to your user account.

<details>
<summary>Manual key generation (click to expand)</summary>

```bash
mkdir -p ~/.config/openshell/jwt
cd ~/.config/openshell/jwt
openssl genpkey -algorithm ed25519 -out signing.pem
openssl pkey -in signing.pem -pubout -out public.pem
uuidgen | tr -d '\n' > kid
chmod 600 signing.pem

# Then generate gateway.toml from template
cd /path/to/openshell-podman-compose
sed "s|__HOME__|${HOME}|g" gateway.toml.template > gateway.toml
```
</details>

### 2. Start the Gateway

```bash
podman compose up -d
```

**Verify it's running:**
```bash
podman compose logs gateway --tail=20
```

Expected output includes:
- `Gateway listener bound address=0.0.0.0:8080`
- `Unauthenticated user access enabled`

### 3. Register the Gateway

```bash
openshell gateway add http://localhost:8080 --local --name openshell-podman
```

### 4. Create Your First Sandbox

```bash
openshell sandbox create --name test
```

**Check status:**
```bash
openshell sandbox list
```

When `Phase: Ready` appears, your sandbox is working! 🎉

## Architecture

### Security Model

| Component | Authentication |
|-----------|---------------|
| **CLI → Gateway** | None (localhost-only, single-user) |
| **Sandbox → Gateway** | JWT tokens (gateway-minted) |
| **External Access** | Blocked (127.0.0.1 host binding) |

### Network Layout

```
Host (127.0.0.1:8080)
  │
  └─→ Gateway Container (0.0.0.0:8080)
        │
        └─→ Podman Bridge Network (10.89.0.0/24)
              │
              └─→ Sandbox Containers
                    └─→ Connect to gateway via DNS: openshell-gateway:8080
```

### Authentication Flow

1. **Sandbox Creation:**
   - Gateway mints JWT token with Ed25519 key
   - Podman driver writes token to `~/.local/share/openshell/state/openshell/podman-sandbox-tokens/<id>/sandbox.jwt`
   - Token bind-mounted read-only into sandbox at `/etc/openshell/auth/sandbox.jwt`

2. **Sandbox Runtime:**
   - Supervisor reads `$OPENSHELL_SANDBOX_TOKEN_FILE`
   - Uses JWT to authenticate all callbacks to gateway
   - Token refreshed periodically (ttl=0 means no expiration for local dev)

## Configuration

### Files

- **`gateway.toml.template`** - Template for gateway configuration (committed to git)
- **`gateway.toml`** - Generated user-specific configuration (git-ignored)
- **`compose.yaml`** - Podman Compose service definition
- **`setup.sh`** - JWT key generation and config setup script

### Key Settings

**gateway.toml (generated):**
```toml
disable_tls = true                        # Plaintext HTTP (localhost only)
[openshell.gateway.auth]
allow_unauthenticated_users = true        # No CLI authentication
[openshell.gateway.gateway_jwt]
signing_key_path = "~/.config/openshell/jwt/signing.pem"
ttl_secs = 0                             # No token expiration
```

**compose.yaml:**
```yaml
volumes:
  - ${HOME}/.config/openshell/jwt:${HOME}/.config/openshell/jwt:ro,z
```

### Port Configuration

Customize ports via environment variables:

```bash
export OPENSHELL_PORT=8080           # Gateway API (default: 8080)
export OPENSHELL_HEALTH_PORT=8081    # Health endpoint (default: 8081)
podman compose up -d
```

## Troubleshooting

### Sandbox fails with "no sandbox token source available"

**Symptoms:**
```bash
openshell sandbox list
# Shows: Phase: Error

podman logs openshell-default--<name>-<id>
# Shows: Error: no sandbox token source available
```

**Cause:** JWT keys missing or not mounted

**Solution:**
```bash
# Check if keys exist
ls -la ~/.config/openshell/jwt/
# Should show: signing.pem, public.pem, kid

# If missing, run setup
./setup.sh

# Restart gateway to reload configuration
podman compose restart gateway

# Create new sandbox (old ones won't recover)
openshell sandbox create --name working-test
```

---

### Gateway won't start - "Permission denied" on Podman socket

**Symptoms:**
```bash
podman compose logs gateway
# Shows: Permission denied (os error 13)
```

**Cause:** SELinux blocking socket access or wrong UID mapping

**Solution:**
```bash
# Verify compose.yaml has:
#   security_opt: label=disable
#   user: "0:0"

# Check Podman socket exists and is accessible
ls -la $XDG_RUNTIME_DIR/podman/podman.sock

# Restart gateway
podman compose restart gateway
```

---

### Gateway fails with "failed to read sandbox JWT signing key"

**Symptoms:**
```bash
podman compose logs gateway
# Shows: failed to read sandbox JWT signing key from /var/home/.../signing.pem
```

**Cause:** `gateway.toml` not generated or has wrong paths

**Solution:**
```bash
# Regenerate gateway.toml from template
./setup.sh

# Verify gateway.toml has your actual home path (not __HOME__)
grep signing_key_path gateway.toml
# Should show: signing_key_path = "/var/home/youruser/.config/..."

# Restart gateway
podman compose restart gateway
```

---

### Sandbox starts but stays in "Provisioning" phase

**Check network connectivity:**
```bash
# Verify gateway is reachable from bridge network
podman network inspect openshell | grep -A 5 gateway

# Check gateway logs for incoming connections
podman compose logs gateway -f
```

**Check sandbox logs:**
```bash
# Get sandbox ID
SANDBOX_ID=$(openshell sandbox list --output json | jq -r '.[0].id')

# View logs
podman logs openshell-default--*${SANDBOX_ID}*
```

**Common causes:**
- Network routing issues (should use bridge DNS, not host.containers.internal)
- JWT token mount failed
- Policy evaluation denials

---

### View detailed logs

**Gateway:**
```bash
podman compose logs gateway -f
```

**Specific sandbox:**
```bash
podman ps | grep sandbox  # Find container name
podman logs <container-name> -f
```

**All sandbox containers:**
```bash
podman ps -a --filter "name=openshell-default"
```

---

### Clean up failed sandboxes

```bash
# List all sandboxes
openshell sandbox list

# Delete failed sandboxes
openshell sandbox delete <name>

# Force remove stuck containers
podman rm -f $(podman ps -aq --filter "name=openshell-default")
```

## Security Considerations

⚠️ **For local single-user development only**

**What's NOT secured:**
- CLI access (no authentication required)
- Network traffic (no TLS encryption)  
- Multi-user isolation (shared gateway database)

**What IS secured:**
- Sandbox-to-gateway authentication (JWT tokens)
- External network access (localhost-only binding)
- Sandbox isolation (containers + OpenShell policy)

**For production or multi-user environments:**
- Enable TLS (`disable_tls = false`)
- Configure OIDC or mTLS authentication
- Use Kubernetes deployment with proper RBAC
- See: [OpenShell Production Deployment Guide](https://docs.nvidia.com/openshell/)

## Advanced

### Regenerate JWT Keys

If you need to rotate keys (invalidates all running sandboxes):

```bash
./setup.sh  # Accepts 'y' to overwrite
podman compose restart gateway
```

Old keys are automatically backed up to timestamped directories.

### Update Configuration

If `gateway.toml.template` is updated:

```bash
./setup.sh  # Regenerates gateway.toml from template
podman compose restart gateway
```

### Custom Configuration

Edit `gateway.toml.template` for configuration changes, then regenerate:
- Log levels
- Image pull policies
- Network configuration
- Driver-specific options

**Do not edit `gateway.toml` directly** - it's regenerated from the template.

See: [Gateway Configuration Reference](https://docs.nvidia.com/openshell/reference/gateway-config)

### Inspect JWT Tokens

```bash
# View token file location for a sandbox
SANDBOX_ID="<your-sandbox-id>"
cat ~/.local/share/openshell/state/openshell/podman-sandbox-tokens/default/${SANDBOX_ID}/sandbox.jwt

# Decode JWT (requires jq)
cat <token-file> | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .
```

## References

- [OpenShell Documentation](https://docs.nvidia.com/openshell/)
- [Upstream Docker Deployment](https://github.com/NVIDIA/OpenShell/tree/main/deploy/docker)
- [Gateway Configuration Reference](https://docs.nvidia.com/openshell/reference/gateway-config)
- [Gateway Authentication](https://docs.nvidia.com/openshell/reference/gateway-auth)
- [Podman Rootless Tutorial](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)

## License

This deployment configuration follows the OpenShell project license. See the [OpenShell repository](https://github.com/NVIDIA/OpenShell) for details.
