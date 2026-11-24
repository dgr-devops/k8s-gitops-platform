#!/usr/bin/env bash
# Crea el cluster kind, instala Argo CD y aplica la aplicación raíz (app-of-apps).
# Uso: bootstrap/bootstrap.sh
# Variables: CLUSTER_NAME (gitops), ARGOCD_CHART_VERSION, APP_IMAGE (imagen local a cargar en kind).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gitops}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.19.0}"
APP_IMAGE="${APP_IMAGE:-ghcr.io/dgr-devops/k8s-gitops-app:v1.0.0}"
SEALED_KEY="${ROOT}/.secrets/sealed-secrets-key.yaml"

for tool in kind kubectl helm docker; do
  command -v "$tool" >/dev/null || { echo "Falta la herramienta: $tool" >&2; exit 1; }
done

if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo ">> El cluster '$CLUSTER_NAME' ya existe, se reutiliza"
else
  echo ">> Creando cluster kind '$CLUSTER_NAME' (1 control-plane + 2 workers)"
  kind create cluster --config "${ROOT}/bootstrap/kind-config.yaml"
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# La imagen se construye en local (o se descarga) y se carga en los nodos de kind:
# así el ejemplo no depende de que el paquete de GHCR sea público.
if docker image inspect "$APP_IMAGE" >/dev/null 2>&1; then
  echo ">> Cargando $APP_IMAGE en kind"
  kind load docker-image "$APP_IMAGE" --name "$CLUSTER_NAME"
fi

# Restaura la clave de Sealed Secrets si existe una copia local (nunca va a git),
# para que los SealedSecret ya commiteados se puedan descifrar en un cluster nuevo.
if [ -f "$SEALED_KEY" ]; then
  echo ">> Restaurando clave de Sealed Secrets desde .secrets/"
  kubectl apply -f "$SEALED_KEY"
fi

echo ">> Instalando Argo CD ${ARGOCD_CHART_VERSION}"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values "${ROOT}/bootstrap/argocd-values.yaml" \
  --wait --timeout 5m

echo ">> Aplicando la aplicación raíz (app-of-apps)"
kubectl apply -f "${ROOT}/bootstrap/root-app.yaml"

cat <<'EOF'

Listo. Siguiente:
  kubectl -n argocd get applications -w
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  kubectl -n argocd port-forward svc/argocd-server 8088:80
EOF
