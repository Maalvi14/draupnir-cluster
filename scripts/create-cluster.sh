#!/usr/bin/env bash
# create-cluster.sh: Bootstraps draupnir k3d cluster, installs Cilium, and bootstraps namespaces
# Usage: ./scripts/create-cluster.sh
set -euo pipefail

# Ensure running from repo root
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
cd "$REPO_ROOT"

echo "==> Checking dependencies..."
for cmd in k3d kubectl helm cilium; do
  if ! command -v $cmd &> /dev/null; then
    echo "ERROR: $cmd not found. Please install it before running this script."
    exit 1
  fi
done

echo "==> Creating k3d cluster 'draupnir'..."
k3d cluster delete draupnir --no-wait || true
k3d cluster create draupnir \
  --servers 1 \
  --agents 2 \
  -p "8080:80@loadbalancer" \
  -p "8443:443@loadbalancer" \
  -p "4244:4244@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0"

export KUBECONFIG=$(k3d kubeconfig write draupnir)

echo "==> Installing Cilium..."
helm repo add cilium https://helm.cilium.io/ && helm repo update
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system --create-namespace \
  --set global.kubeProxyReplacement=strict \
  --set global.tunnel=disabled \
  --set global.hostNetwork=true \
  --set global.healthEndpointAddress="0.0.0.0" \
  --set global.healthEndpointPort=4244 \
  --set global.healthEndpointPath="/healthz"

echo "==> Waiting for Cilium DaemonSet rollout..."
kubectl -n kube-system rollout status daemonset cilium --timeout=2m

echo "==> Checking Cilium status..."
cilium status --wait

echo "==> Applying namespaces..."
kubectl apply -f bootstrap/00-namespaces.yaml

echo "==> Labeling namespaces for Cilium sidecar injection..."
for ns in \
  platform-system infra-ops security-gatekeeper ci-cd \
  data-engineering feature-store training-gpu model-registry \
  inference-online inference-batch runtimes-sandbox dev staging prod; do
  kubectl label namespace "$ns" k8s.cilium.io/sidecar-injection=enabled --overwrite
  echo "  - Labeled $ns"
done

echo "==> Cluster bootstrap complete!"

kubectl get namespaces -L k8s.cilium.io/sidecar-injection

