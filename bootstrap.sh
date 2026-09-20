#!/bin/bash

## !IMPORTANT ##
#
## Tested against the generic Ubuntu 22.04 template described in packer/.
## If you use a different guest OS/template, re-test this script.
#
## Common provisioner - runs on kmaster and every kworker node.
## K8S_VERSION, ROOT_PASSWORD, MASTER_IP, WORKER_IPS and WORKER_COUNT are
## injected by the Vagrantfile via the shell provisioner's `env` option.
#

set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.37}"
ROOT_PASSWORD="${ROOT_PASSWORD:-kubeadmin}"
MASTER_IP="${MASTER_IP:-10.10.10.240}"
WORKER_IPS="${WORKER_IPS:-10.10.10.241,10.10.10.242}"

echo "[TASK 1] Disable and turn off SWAP"
sed -i '/swap/d' /etc/fstab
swapoff -a

echo "[TASK 2] Stop and Disable firewall"
systemctl disable --now ufw || true

echo "[TASK 3] Enable and Load Kernel modules"
cat >/etc/modules-load.d/containerd.conf<<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "[TASK 4] Add Kernel settings"
cat >/etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null 2>&1

echo "[TASK 5] Install open-vm-tools (required on vSphere for guest IP/heartbeat reporting)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -qq -y open-vm-tools
systemctl enable --now open-vm-tools 2>/dev/null || true

echo "[TASK 6] Install containerd runtime"
apt-get install -qq -y apt-transport-https ca-certificates curl gnupg lsb-release socat
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -qq -y containerd.io
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "[TASK 7] Set up kubernetes repo (v${K8S_VERSION})"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

echo "[TASK 8] Install Kubernetes components (kubeadm, kubelet and kubectl)"
apt-get update -qq
apt-get install -qq -y kubeadm kubelet kubectl
apt-mark hold kubeadm kubelet kubectl >/dev/null

echo "[TASK 9] Pin kubelet's node IP (avoids ambiguity when the VM has more than one NIC)"
NODE_IP="$(hostname -I | awk '{print $1}')"
mkdir -p /etc/systemd/system/kubelet.service.d
cat >/etc/default/kubelet<<EOF
KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}
EOF

echo "[TASK 10] Enable ssh password authentication"
# Ubuntu's official cloud images ship /etc/ssh/sshd_config.d/50-cloud-init.conf
# with "PasswordAuthentication no" baked in. sshd_config keeps the FIRST
# value it sees per keyword, and Include (at the very top of the stock
# sshd_config) reads sshd_config.d/*.conf in alphabetical order - so editing
# the MAIN sshd_config file below that Include is a no-op for any keyword a
# drop-in already set, and a same-purpose drop-in has to sort before "50-" to
# actually win. Write our own low-numbered drop-in instead of sed'ing the
# main file, so this also works against a template we didn't build ourselves
# (the template's own cloud-init-user-data.yaml.tmpl already ships one named
# 10-vagrant.conf for the same reason - this is the runtime-side belt-and-
# braces copy).
cat >/etc/ssh/sshd_config.d/10-vagrant.conf<<EOF
PermitRootLogin yes
PasswordAuthentication yes
EOF
systemctl reload ssh

echo "[TASK 11] Set root password"
echo -e "$ROOT_PASSWORD\n$ROOT_PASSWORD" | passwd root
echo "export TERM=xterm" >> /etc/bash.bashrc

echo "[TASK 12] Update /etc/hosts file"
{
  echo "${MASTER_IP}   kmaster.example.com    kmaster"
  i=1
  IFS=',' read -ra IPS <<< "$WORKER_IPS"
  for ip in "${IPS[@]}"; do
    echo "${ip}   kworker${i}.example.com    kworker${i}"
    i=$((i + 1))
  done
} >> /etc/hosts

echo "[TASK 13] Note this node's actual IP for troubleshooting"
echo "This node's detected IP is ${NODE_IP} (expected to match the address assigned by the vSphere Customization Specification)"
