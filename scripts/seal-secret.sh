#!/usr/bin/env bash
# Cifra un valor con la clave pública del controlador Sealed Secrets del cluster activo.
# El valor se lee de la entrada estándar (no queda en el historial ni en la lista de procesos).
#
# Uso:  printf '%s' 'valor' | scripts/seal-secret.sh <namespace> <nombre-secret> <clave> <fichero-salida>
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Uso: printf '%s' 'valor' | $0 <namespace> <secret> <clave> <salida.yaml>" >&2
  exit 2
fi

NAMESPACE="$1"
SECRET_NAME="$2"
KEY="$3"
OUT="$4"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBESEAL="${KUBESEAL:-${ROOT}/.bin/kubeseal}"
[ -x "$KUBESEAL" ] || KUBESEAL="$(command -v kubeseal)"

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-file="${KEY}=/dev/stdin" \
  --dry-run=client -o yaml |
  "$KUBESEAL" \
    --controller-name sealed-secrets-controller \
    --controller-namespace kube-system \
    --format yaml >"$OUT"

echo "SealedSecret escrito en $OUT (solo el controlador de este cluster puede descifrarlo)"
