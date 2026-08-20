#!/bin/bash
# OpenShell Podman Gateway Setup Script
# Generates JWT signing keys and user-specific gateway.toml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JWT_DIR="${HOME}/.config/openshell/jwt"
GATEWAY_TOML="${SCRIPT_DIR}/gateway.toml"
GATEWAY_TEMPLATE="${SCRIPT_DIR}/gateway.toml.template"

echo "OpenShell Gateway Setup"
echo "======================="
echo

# Check prerequisites
if ! command -v openssl &> /dev/null; then
    echo "❌ Error: openssl is required but not installed."
    echo "   Install: sudo dnf install openssl     (Fedora/RHEL)"
    echo "        or: sudo apt install openssl     (Debian/Ubuntu)"
    exit 1
fi

if ! command -v uuidgen &> /dev/null; then
    echo "❌ Error: uuidgen is required but not installed."
    echo "   Install: sudo dnf install util-linux     (Fedora/RHEL)"
    echo "        or: sudo apt install uuid-runtime    (Debian/Ubuntu)"
    exit 1
fi

if [ ! -f "${GATEWAY_TEMPLATE}" ]; then
    echo "❌ Error: gateway.toml.template not found in ${SCRIPT_DIR}"
    exit 1
fi

# Step 1: Check if keys already exist
if [ -f "${JWT_DIR}/signing.pem" ]; then
    echo "⚠️  JWT keys already exist at ${JWT_DIR}"
    echo
    read -p "Regenerate keys? This invalidates running sandboxes. (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Keeping existing keys..."
    else
        echo "Backing up existing keys..."
        BACKUP_DIR="${JWT_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "${BACKUP_DIR}"
        cp -a "${JWT_DIR}"/*.pem "${JWT_DIR}/kid" "${BACKUP_DIR}/" 2>/dev/null || true
        echo "✓ Backup saved to ${BACKUP_DIR}"
        
        # Generate new keys
        echo "Generating new Ed25519 signing key..."
        openssl genpkey -algorithm ed25519 -out "${JWT_DIR}/signing.pem"
        chmod 600 "${JWT_DIR}/signing.pem"
        
        echo "Extracting public key..."
        openssl pkey -in "${JWT_DIR}/signing.pem" -pubout -out "${JWT_DIR}/public.pem"
        chmod 644 "${JWT_DIR}/public.pem"
        
        echo "Generating key ID..."
        uuidgen | tr -d '\n' > "${JWT_DIR}/kid"
        chmod 644 "${JWT_DIR}/kid"
        
        echo "✓ New JWT keys generated"
    fi
else
    # First-time setup
    echo "Creating JWT directory: ${JWT_DIR}"
    mkdir -p "${JWT_DIR}"
    
    echo "Generating Ed25519 signing key..."
    openssl genpkey -algorithm ed25519 -out "${JWT_DIR}/signing.pem"
    chmod 600 "${JWT_DIR}/signing.pem"
    
    echo "Extracting public key..."
    openssl pkey -in "${JWT_DIR}/signing.pem" -pubout -out "${JWT_DIR}/public.pem"
    chmod 644 "${JWT_DIR}/public.pem"
    
    echo "Generating key ID..."
    uuidgen | tr -d '\n' > "${JWT_DIR}/kid"
    chmod 644 "${JWT_DIR}/kid"
    
    echo "✓ JWT keys generated successfully"
fi

# Step 2: Backup existing gateway.toml if present
if [ -f "${GATEWAY_TOML}" ]; then
    echo
    echo "Backing up existing gateway.toml..."
    BACKUP_FILE="${GATEWAY_TOML}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "${GATEWAY_TOML}" "${BACKUP_FILE}"
    echo "✓ Backup saved to ${BACKUP_FILE}"
fi

# Step 3: Generate gateway.toml from template
echo
echo "Generating gateway.toml from template..."

# Replace __HOME__ placeholder with actual HOME path
sed "s|__HOME__|${HOME}|g" "${GATEWAY_TEMPLATE}" > "${GATEWAY_TOML}"

echo "✓ gateway.toml generated at ${GATEWAY_TOML}"

# Step 4: Summary
echo
echo "✅ Setup complete!"
echo
echo "Generated files:"
echo "  JWT keys:      ${JWT_DIR}/"
echo "    - signing.pem  (private key, mode 600)"
echo "    - public.pem   (public key)"
echo "    - kid          (key identifier)"
echo "  Configuration: ${GATEWAY_TOML}"
echo
echo "Next steps:"
echo "  1. Start the gateway:    podman compose up -d"
echo "  2. Check gateway logs:   podman compose logs gateway --tail=20"
echo "  3. Register the gateway: openshell gateway add http://localhost:8080 --local"
echo "  4. Create a sandbox:     openshell sandbox create --name test"
echo
