#!/usr/bin/env bash
# Phase 1 bootstrap: kind cluster + Argo CD + app-of-apps. Argo CD then
# installs Istio (via Helm) and reconciles the saga services.
#
# Usage:
#   ./scripts/bootstrap-kind.sh [--cluster saga] [--repo-url URL] [--skip-cluster]

set -euo pipefail

CLUSTER_NAME="saga"
REPO_URL=""
SKIP_CLUSTER=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster)        CLUSTER_NAME="$2"; shift 2 ;;
        --repo-url)       REPO_URL="$2";     shift 2 ;;
        --skip-cluster)   SKIP_CLUSTER=1;    shift   ;;
        -h|--help)
            sed -n '2,9p' "$0"; exit 0 ;;
        *)
            echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "==> repo root: $ROOT"

for cmd in kind kubectl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd not found on PATH" >&2; exit 1; }
done

if [[ "$SKIP_CLUSTER" -eq 0 ]]; then
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
        echo "==> kind cluster '$CLUSTER_NAME' already exists; skipping create"
    else
        echo "==> creating kind cluster '$CLUSTER_NAME'"
        kind create cluster --name "$CLUSTER_NAME" --config scripts/kind-config.yaml
    fi
fi

kubectl cluster-info --context "kind-$CLUSTER_NAME" >/dev/null

echo "==> installing Argo CD (kustomize over upstream v2.12.6)"
kubectl apply -k platform/argocd/

echo "==> waiting for argocd-server to become Available"
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
if [[ -n "$REPO_URL" ]]; then
    echo "==> substituting repoURL: $REPO_URL"
    sed "s|https://github.com/REPLACE_ME_OWNER/saga-gitops.git|${REPO_URL}|g" \
        apps/app-of-apps.yaml > "$TMP"
else
    cp apps/app-of-apps.yaml "$TMP"
fi
kubectl apply -n argocd -f "$TMP"

cat <<EOF

==> bootstrap complete.

Next steps:
  1. argocd UI:    kubectl -n argocd port-forward svc/argocd-server 8080:443
                   browse https://localhost:8080 (admin / pwd below)
  2. admin pwd:    kubectl -n argocd get secret argocd-initial-admin-secret \\
                     -o jsonpath='{.data.password}' | base64 -d
  3. webui:        http://localhost/   (host:80 -> kind worker NodePort 30080 -> istio-ingressgateway -> web-ui)
  4. watch sync:   kubectl -n argocd get applications -w
EOF

if [[ -z "$REPO_URL" ]]; then
    cat <<EOF

WARNING: --repo-url was not provided. Argo CD will fail to fetch from REPLACE_ME_OWNER/saga-gitops.
         Edit apps/app-of-apps.yaml + apps/*.yaml + apps/saga-mesh.yaml to point at your fork, commit, then re-apply.
EOF
fi
