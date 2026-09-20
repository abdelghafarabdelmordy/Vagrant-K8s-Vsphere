#!/bin/bash

## Control-plane provisioner. MASTER_IP and CALICO_VERSION are injected by
## the Vagrantfile via the shell provisioner's `env` option.

set -euo pipefail

MASTER_IP="${MASTER_IP:-10.10.10.240}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.1}"

echo "[TASK 1] Pull required containers"
kubeadm config images pull

echo "[TASK 2] Initialize Kubernetes Cluster (advertise-address=${MASTER_IP})"
kubeadm init \
  --apiserver-advertise-address="${MASTER_IP}" \
  --pod-network-cidr=192.168.0.0/16

echo "[TASK 3] Configure kubectl for root"
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

echo "[TASK 4] Deploy Calico network (${CALICO_VERSION})"
kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

# tigera-operator.yaml above does NOT ship the operator.tigera.io CRDs
# (Installation, APIServer, Goldmane, Whisker, ...) as static manifest
# objects - its own `kubectl create` output above never prints a
# "customresourcedefinition.../... created" line. The tigera-operator binary
# installs those CRDs itself, from its own embedded manifests, only once its
# pod is actually running - which takes longer than "the Deployment object
# exists" (image pull + container start + the operator's own startup
# routine). A prior version of this script tried to `kubectl wait` on
# whatever operator.tigera.io CRDs already existed right after `create`
# returned - which is none of them yet, so the wait loop found nothing to
# wait on and fell straight through into the same race.
#
# Fix: wait for the operator pod itself to be ready, then retry the
# custom-resources.yaml apply (kubectl apply, not create, so a retry is
# safe even if an earlier attempt partially succeeded) until the operator
# has had time to install its CRDs.
echo "      waiting for the tigera-operator pod to be ready"
kubectl --kubeconfig=/etc/kubernetes/admin.conf -n tigera-operator rollout status deployment/tigera-operator --timeout=180s

echo "      applying custom-resources.yaml (retrying until the operator's CRDs are ready)"
attempt=1
until kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"; do
  if [ "${attempt}" -ge 24 ]; then
    echo "custom-resources.yaml still failing after ${attempt} attempts - giving up" >&2
    exit 1
  fi
  echo "      not ready yet (attempt ${attempt}/24) - retrying in 10s"
  attempt=$((attempt + 1))
  sleep 10
done

echo "[TASK 5] Generate and save cluster join command to /joincluster.sh"
kubeadm token create --print-join-command > /joincluster.sh
chmod 644 /joincluster.sh
