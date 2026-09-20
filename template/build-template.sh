#!/usr/bin/env bash
#
# ==============================================================================
# Automated Ubuntu 22.04 vSphere template builder for the K8s Vagrant cluster.
#
# What it does, end to end, with no ISO and no manual VM console work:
#   1. Downloads Canonical's official Ubuntu 22.04 cloud image OVA to a local
#      folder (verified against Ubuntu's published SHA256SUMS).
#   2. Imports it into vCenter with govc, using the OVA's built-in OVF/cloud-init
#      properties to inject an SSH key, create a `vagrant` user, and install
#      open-vm-tools - the same prep Vagrant boxes normally ship with.
#   3. Grows the disk, boots it once so cloud-init can do that prep, waits for
#      it to shut itself down, then converts it to a vSphere template.
#
# Result: a template ready for VSPHERE_TEMPLATE in ../Vagrantfile.
#
# Requires on the machine you run this from: govc, jq, curl, sha256sum
#   govc:  https://github.com/vmware/govmomi/releases  (or `brew install govc`)
#   jq:    apt/brew install jq
#
# Usage:
#   ./build-template.sh
#   DOWNLOAD_DIR=/mnt/isos ./build-template.sh      # download OVA elsewhere
#   GOVC_PASSWORD='...' ./build-template.sh          # override any setting below
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# vCenter connection + inventory - matches ../Vagrantfile. Override any of
# these with an environment variable of the same name instead of editing here.
# ------------------------------------------------------------------------------
export GOVC_URL="${GOVC_URL:-10.10.10.250}"
export GOVC_USERNAME="${GOVC_USERNAME:-administrator@vsphere.local}"
export GOVC_PASSWORD="${GOVC_PASSWORD:-URn0t+hE1.}"
export GOVC_INSECURE="${GOVC_INSECURE:-1}"
export GOVC_DATACENTER="${GOVC_DATACENTER:-intl-site}"

VSPHERE_COMPUTE_RESOURCE="${VSPHERE_COMPUTE_RESOURCE:-Cluster}"    # CHANGE ME - cluster or ESXi host
VSPHERE_RESOURCE_POOL="${VSPHERE_RESOURCE_POOL:-Resources}"       # CHANGE ME
VSPHERE_DATASTORE="${VSPHERE_DATASTORE:-datastore1}"              # CHANGE ME
VSPHERE_NETWORK="${VSPHERE_NETWORK:-VM Network}"                  # CHANGE ME - port group/VLAN
VSPHERE_FOLDER="${VSPHERE_FOLDER:-k8s-demo}"                      # holds both the template and the cluster VMs

export GOVC_DATASTORE="$VSPHERE_DATASTORE"
export GOVC_RESOURCE_POOL="${VSPHERE_COMPUTE_RESOURCE}/${VSPHERE_RESOURCE_POOL}"

# ------------------------------------------------------------------------------
# Template / build settings
# ------------------------------------------------------------------------------
TEMPLATE_NAME="${TEMPLATE_NAME:-ubuntu-2204-k8s-template}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-22.04}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$(pwd)/downloads}"    # <-- "any folder": override freely
TEMPLATE_CPU="${TEMPLATE_CPU:-2}"
TEMPLATE_MEM_MB="${TEMPLATE_MEM_MB:-2048}"
TEMPLATE_DISK_GB="${TEMPLATE_DISK_GB:-40}"
ROOT_PASSWORD="${ROOT_PASSWORD:-kubeadmin}"
VAGRANT_PUBKEY_URL="${VAGRANT_PUBKEY_URL:-https://raw.githubusercontent.com/hashicorp/vagrant/master/keys/vagrant.pub}"

OVA_FILE="ubuntu-${UBUNTU_RELEASE}-server-cloudimg-amd64.ova"
OVA_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release/${OVA_FILE}"
SHA_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release/SHA256SUMS"

for bin in govc jq curl sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH" >&2; exit 1; }
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[1/8] Downloading ${OVA_FILE} to ${DOWNLOAD_DIR} (skips if already present and valid)"
mkdir -p "$DOWNLOAD_DIR"
OVA_PATH="${DOWNLOAD_DIR}/${OVA_FILE}"
curl -fsSL "$SHA_URL" -o "${WORKDIR}/SHA256SUMS"
EXPECTED_SHA="$(grep " \*${OVA_FILE}\$" "${WORKDIR}/SHA256SUMS" | awk '{print $1}')"
if [ -z "$EXPECTED_SHA" ]; then
  echo "ERROR: couldn't find ${OVA_FILE} in Ubuntu's SHA256SUMS - check UBUNTU_RELEASE" >&2
  exit 1
fi
if [ -f "$OVA_PATH" ] && echo "${EXPECTED_SHA}  ${OVA_PATH}" | sha256sum -c - >/dev/null 2>&1; then
  echo "      already downloaded and checksum matches, skipping"
else
  curl -fL --progress-bar "$OVA_URL" -o "$OVA_PATH"
  echo "${EXPECTED_SHA}  ${OVA_PATH}" | sha256sum -c -
fi

echo "[2/8] Fetching the Vagrant insecure public key for template SSH access"
curl -fsSL "$VAGRANT_PUBKEY_URL" -o "${WORKDIR}/vagrant.pub"

echo "[3/8] Rendering cloud-init user-data"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sed \
  -e "s|__VAGRANT_PUBLIC_KEY__|$(cat "${WORKDIR}/vagrant.pub")|" \
  -e "s|__ROOT_PASSWORD__|${ROOT_PASSWORD}|g" \
  "${SCRIPT_DIR}/cloud-init-user-data.yaml.tmpl" > "${WORKDIR}/user-data.yaml"
USER_DATA_B64="$(base64 -w0 "${WORKDIR}/user-data.yaml" 2>/dev/null || base64 "${WORKDIR}/user-data.yaml" | tr -d '\n')"

echo "[4/8] Ensuring the vCenter VM folder \"${VSPHERE_FOLDER}\" exists"
govc folder.create "/${GOVC_DATACENTER}/vm/${VSPHERE_FOLDER}" 2>/dev/null || true

echo "[5/8] Building the OVF import spec"
govc import.spec "$OVA_PATH" | jq \
  --arg name "$TEMPLATE_NAME" \
  --arg net "$VSPHERE_NETWORK" \
  --arg userdata "$USER_DATA_B64" \
  '.Name = $name
   | .PowerOn = false
   | .WaitForIP = false
   | .MarkAsTemplate = false
   | .InjectOvfEnv = true
   | .NetworkMapping = [{"Name": .NetworkMapping[0].Name, "Network": $net}]
   | .PropertyMapping = [
       {"Key": "instance-id", "Value": "id-ovf"},
       {"Key": "hostname", "Value": $name},
       {"Key": "seedfrom", "Value": ""},
       {"Key": "public-keys", "Value": ""},
       {"Key": "user-data", "Value": $userdata},
       {"Key": "password", "Value": ""}
     ]' > "${WORKDIR}/spec.json"

echo "[6/8] Importing OVA into vCenter as \"${VSPHERE_FOLDER}/${TEMPLATE_NAME}\" (this can take a few minutes)"
govc import.ova -options="${WORKDIR}/spec.json" -folder="/${GOVC_DATACENTER}/vm/${VSPHERE_FOLDER}" "$OVA_PATH"

VM_PATH="/${GOVC_DATACENTER}/vm/${VSPHERE_FOLDER}/${TEMPLATE_NAME}"

echo "[7/8] Sizing the VM (${TEMPLATE_CPU} vCPU, ${TEMPLATE_MEM_MB}MB RAM, ${TEMPLATE_DISK_GB}GB disk) and booting it once for cloud-init to run"
govc vm.change -vm "$VM_PATH" -c "$TEMPLATE_CPU" -m "$TEMPLATE_MEM_MB" -e="disk.enableUUID=1"
govc vm.disk.change -vm "$VM_PATH" -disk.label "Hard disk 1" -size "${TEMPLATE_DISK_GB}G"
govc vm.power -on=true "$VM_PATH"

echo "      waiting for cloud-init to finish and the VM to power itself off (usually 2-5 minutes)"
until [ "$(govc vm.info -json "$VM_PATH" | jq -r '.virtualMachines[0].runtime.powerState // .VirtualMachines[0].Runtime.PowerState')" = "poweredOff" ]; do
  sleep 10
done

echo "[8/8] Converting to a template"
govc vm.markastemplate "$VM_PATH"

cat <<EOF

Done. Template ready at: ${VSPHERE_FOLDER}/${TEMPLATE_NAME}

Set this in ../Vagrantfile (or leave it - it's already the default there):
  VSPHERE_TEMPLATE = "${VSPHERE_FOLDER}/${TEMPLATE_NAME}"

Remember this template still needs a vSphere Customization Specification per
node (kmaster/kworker1/kworker2) for static IP assignment on clone - see
../README.md.
EOF
