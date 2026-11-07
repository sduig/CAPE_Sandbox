#!/bin/bash
set -e

# ============================================================
# CAPEv2 Host Setup — Linux Mint (Ubuntu 22.04 base)
# Run as: sudo bash cape-host-setup.sh
# ============================================================

# --- Configurable variables (edit these) ---
CAPE_USER="cape"
CAPE_PASSWD="CHANGE_ME"
CAPE_DIR="/opt/CAPEv2"
VMNET_IP="172.16.204.1"
VMNET_IFACE="vmnet1"
MONGO_REPO_CODENAME="jammy"  # jammy=Mint 21.x, noble=Mint 22.x

# Guest VMs
WIN10_VMX="/media/user/VMWare/Cape-Windows-10-x64/Cape-Windows-10-x64.vmx"
WIN10_IP="172.16.204.100"
WIN11_VMX="/media/user/VMWare/Cape-Windows-11-x64/Cape-Windows-11-x64.vmx"
WIN11_IP="172.16.204.101"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Check root ---
[[ $EUID -ne 0 ]] && error "Run as root: sudo bash $0"

# ============================================================
# STEP 1: Prerequisites
# ============================================================
info "Installing prerequisites..."
apt update -qq
apt install -y -qq git build-essential cmake ninja-build \
    python3-dev cython3 pybind11-dev python3-pip \
    libre2-dev acpica-tools net-tools gperf \
    openssh-server vim wget gpg curl

info "Prerequisites installed."

# ============================================================
# STEP 2: MongoDB
# ============================================================
info "Setting up MongoDB..."

# Create user and dirs
id -u mongodb &>/dev/null || useradd -r -s /bin/false mongodb
mkdir -p /data/db /var/log/mongodb /var/run/mongodb
chown -R mongodb:mongodb /data/db /var/log/mongodb /var/run/mongodb

# Add repo (skip if already present)
if [[ ! -f /etc/apt/sources.list.d/mongodb-org-7.0.list ]]; then
    wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc | \
        gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
    echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] http://repo.mongodb.org/apt/ubuntu ${MONGO_REPO_CODENAME}/mongodb-org/7.0 multiverse" \
        > /etc/apt/sources.list.d/mongodb-org-7.0.list
    apt update -qq
fi

# Install mongod if not present
if [[ ! -f /usr/bin/mongod ]]; then
    apt install -y -qq mongodb-org
fi

# Start and enable
systemctl enable mongodb
systemctl start mongodb

# Wait for it to be ready
for i in {1..10}; do
    if ss -tlnp | grep -q 27017; then
        info "MongoDB is listening on port 27017."
        break
    fi
    sleep 1
done
ss -tlnp | grep -q 27017 || error "MongoDB failed to start. Check: journalctl -u mongodb"

# ============================================================
# STEP 3: CAPEv2
# ============================================================
if [[ -d "$CAPE_DIR" ]]; then
    warn "CAPEv2 already exists at $CAPE_DIR — skipping clone/install."
else
    info "Cloning CAPEv2..."
    cd /tmp
    git clone --depth 1 https://github.com/kevoreilly/CAPEv2.git

    info "Running CAPEv2 installer (this takes a while)..."
    cd CAPEv2/installer

    # Edit cape2.sh
    sed -i "s|^NETWORK_IFACE=.*|NETWORK_IFACE=${VMNET_IFACE}|" cape2.sh
    sed -i "s|^IFACE_IP=.*|IFACE_IP=\"${VMNET_IP}\"|" cape2.sh
    sed -i "s|^PASSWD=.*|PASSWD=\"${CAPE_PASSWD}\"|" cape2.sh
    sed -i "s|^USER=.*|USER=${CAPE_USER}|" cape2.sh

    chmod +x cape2.sh
    ./cape2.sh base "$CAPE_USER" 2>&1 | tee /tmp/cape-install.log

    info "CAPEv2 installed."
fi

# ============================================================
# STEP 4: Generate config files
# ============================================================
info "Writing CAPE configuration..."

# --- vmware.conf ---
cat > "${CAPE_DIR}/conf/vmware.conf" <<EOF
[vmware]
mode = nogui
interface = ${VMNET_IFACE}
path = /usr/bin/vmrun
machines = win10,win11

[win10]
vmx_path = ${WIN10_VMX}
snapshot = clean
platform = windows
ip = ${WIN10_IP}
arch = x64
tags = win10,x64

[win11]
vmx_path = ${WIN11_VMX}
snapshot = clean
platform = windows
ip = ${WIN11_IP}
arch = x64
tags = win11,x64
EOF

# --- cuckoo.conf (only set the sections we need) ---
# Check if machinery is already set, if not, append
if ! grep -q "^\[cuckoo\]" "${CAPE_DIR}/conf/cuckoo.conf" 2>/dev/null; then
    cat > "${CAPE_DIR}/conf/cuckoo.conf" <<EOF
[cuckoo]
machinery = vmware
max_analysis_count = 1
max_machines_count = 2
reschedule = on

[resultserver]
ip = ${VMNET_IP}
EOF
else
    # Update existing values
    sed -i 's/^machinery = .*/machinery = vmware/' "${CAPE_DIR}/conf/cuckoo.conf"
    sed -i 's/^max_machines_count = .*/max_machines_count = 2/' "${CAPE_DIR}/conf/cuckoo.conf"
    # Set resultserver ip
    if grep -q "^\[resultserver\]" "${CAPE_DIR}/conf/cuckoo.conf"; then
        sed -i '/^\[resultserver\]/,/^\[/ s/^ip = .*/ip = '"${VMNET_IP}"'/' "${CAPE_DIR}/conf/cuckoo.conf"
    else
        echo "" >> "${CAPE_DIR}/conf/cuckoo.conf"
        echo "[resultserver]" >> "${CAPE_DIR}/conf/cuckoo.conf"
        echo "ip = ${VMNET_IP}" >> "${CAPE_DIR}/conf/cuckoo.conf"
    fi
fi

# --- reporting.conf (ensure mongodb section) ---
if ! grep -q "^\[mongodb\]" "${CAPE_DIR}/conf/reporting.conf" 2>/dev/null; then
    cat >> "${CAPE_DIR}/conf/reporting.conf" <<EOF

[mongodb]
enabled = yes
host = 127.0.0.1
port = 27017
db = cuckoo
EOF
else
    sed -i '/^\[mongodb\]/,/^\[/ s/^host = .*/host = 127.0.0.1/' "${CAPE_DIR}/conf/reporting.conf"
    sed -i '/^\[mongodb\]/,/^\[/ s/^port = .*/port = 27017/' "${CAPE_DIR}/conf/reporting.conf"
fi

info "Configuration written."

# ============================================================
# STEP 5: Start services
# ============================================================
info "Starting CAPE services..."
systemctl enable cape cape-processor cape-web 2>/dev/null || true
systemctl start cape
systemctl start cape-processor
systemctl start cape-web

# Wait and verify
sleep 5
if curl -s -o /dev/null -w "%{http_code}" http://localhost:8000 | grep -q "200\|302"; then
    info "CAPE web UI is responding at http://localhost:8000"
else
    warn "CAPE web UI may not be ready yet. Check: journalctl -u cape-web -n 20"
fi

# ============================================================
# DONE
# ============================================================
echo ""
info "============================================"
info " Host setup complete!"
info "============================================"
echo ""
echo "  Next steps (manual):"
echo "    1. Build Win10/Win11 guest VMs in VMware Workstation"
echo "    2. Run cape-guest-setup.ps1 inside each guest"
echo "    3. Take 'clean' snapshots in VMware"
echo "    4. Submit a test sample at http://localhost:8000"
echo ""
echo "  Useful commands:"
echo "    journalctl -u cape -f"
echo "    journalctl -u cape-web -f"
echo "    vmrun list"
echo ""   
