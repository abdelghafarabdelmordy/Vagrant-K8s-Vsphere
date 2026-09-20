#!/bin/bash

## Worker provisioner. MASTER_IP and ROOT_PASSWORD are injected by the
## Vagrantfile via the shell provisioner's `env` option and must match the
## values bootstrap.sh set on kmaster.

set -euo pipefail

MASTER_IP="${MASTER_IP:-10.10.10.240}"
ROOT_PASSWORD="${ROOT_PASSWORD:-kubeadmin}"

echo "[TASK 1] Join node to Kubernetes Cluster"
export DEBIAN_FRONTEND=noninteractive
apt-get install -qq -y sshpass

# kmaster.example.com resolves via the /etc/hosts entries bootstrap.sh wrote
# on every node, pointing at MASTER_IP.
sshpass -p "$ROOT_PASSWORD" scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
  root@kmaster.example.com:/joincluster.sh /joincluster.sh
bash /joincluster.sh
