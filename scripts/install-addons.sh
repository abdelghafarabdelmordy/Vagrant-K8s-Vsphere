#!/usr/bin/env bash
#
# ==============================================================================
# Deploys MetalLB and Traefik once the whole cluster is up. Run automatically
# by the Vagrantfile trigger after `vagrant up` finishes (see the
# `config.trigger.after :up` block near the bottom of ../Vagrantfile) - or run
# by hand any time afterward to re-apply/retry just this part:
#
#   $ bash scripts/install-addons.sh
#
# Skip the automatic run with SKIP_ADDONS=1 (see ../README.md).
#
# Requires on the machine you run this from: vagrant, kubectl, helm.
# Deliberately does NOT need sshpass/scp - it pulls the kubeconfig through
# `vagrant ssh`, which already knows how to reach kmaster (same insecure key
# the template's `vagrant` user trusts), so there's no root password or extra
# SSH plumbing on the host side at all.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/.kubeconfig}"

for bin in vagrant kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH" >&2; exit 1; }
done

cd "$REPO_ROOT"

echo "Fetching kubeconfig from kmaster via 'vagrant ssh'..."
vagrant ssh kmaster -c "sudo cat /etc/kubernetes/admin.conf" > "$KUBECONFIG_PATH"
export KUBECONFIG="$KUBECONFIG_PATH"

echo "Waiting for all nodes to be Ready (up to 5 minutes)..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo "Applying MetalLB..."
kubectl apply --server-side --force-conflicts -f misc/metallb/01_metallb.yaml
kubectl -n metallb-system wait --for=condition=Available deployment/controller --timeout=180s
kubectl apply --server-side --force-conflicts -f misc/metallb/02_metallb-config.yaml

echo "Installing Traefik via Helm..."
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create namespace traefik-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install traefik traefik/traefik \
  --namespace traefik-system \
  --values misc/traefik/values.yaml \
  --wait

echo "Applying Traefik dashboard route..."
kubectl apply -f misc/traefik/02-dashboard.yaml

cat <<EOF

Done. MetalLB and Traefik are installed.

kubeconfig saved to: ${KUBECONFIG_PATH}
  export KUBECONFIG=${KUBECONFIG_PATH}
(this is a separate copy - your default ~/.kube/config, if you set one up
per the README's step 3, is untouched)

EOF
kubectl get svc -n traefik-system
echo ""
echo "Traefik dashboard: http://<EXTERNAL-IP above>/dashboard/  (admin / traefik-admin -"
echo "change this - see misc/traefik/02-dashboard.yaml's header comment)"
