#!/usr/bin/env bash
# Uso: scripts/new-app.sh <java|go|node|graalvm> <ms> <image> [tag]
# Cria apps/<ms>/ no padrão http://automations/<tecnologia>/<ms>
set -euo pipefail
tech="${1:?tecnologia (java|go|node|graalvm)}"; ms="${2:?nome do ms}"; image="${3:?imagem}"; tag="${4:-latest}"
case "$tech" in java|go|node|graalvm) ;; *) echo "tecnologia inválida: $tech" >&2; exit 1;; esac
dir="$(dirname "$0")/../apps/$ms"
[ -e "$dir/kustomization.yaml" ] && { echo "apps/$ms já existe"; exit 0; }
mkdir -p "$dir"
cat > "$dir/kustomization.yaml" <<EOF
resources:
  - ../../base/app

namePrefix: $ms-

labels:
  - includeSelectors: true
    pairs:
      app: $ms

patches:
  - target:
      kind: Ingress
    patch: |-
      - op: replace
        path: /spec/rules/0/http/paths/0/path
        value: /$tech/$ms

images:
  - name: imagem-padrao
    newName: $image
    newTag: $tag
EOF
echo "criado apps/$ms -> http://automations/$tech/$ms"
