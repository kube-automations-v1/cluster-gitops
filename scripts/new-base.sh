#!/usr/bin/env bash
# Uso: scripts/new-base.sh <postgres> <base-nome> <imagem> [tag] [nodePort]
# Cria apps/<base-nome>/ (banco com PVC persistente + backup diário).
# Pré-requisito manual: kubectl create secret generic <base-nome>-credentials \
#   --from-literal=POSTGRES_USER=... --from-literal=POSTGRES_PASSWORD=... --from-literal=POSTGRES_DB=...
set -euo pipefail
engine="${1:?engine (postgres)}"; name="${2:?nome da base (base-*)}"; image="${3:?imagem}"; tag="${4:-latest}"
root="$(dirname "$0")/.."
[ "$engine" = postgres ] || { echo "engine inválida: $engine" >&2; exit 1; }
case "$name" in base-*) ;; *) echo "nome deve começar com base-" >&2; exit 1;; esac
dir="$root/apps/$name"
[ -e "$dir/kustomization.yaml" ] && { echo "apps/$name já existe"; exit 0; }
used=$( (grep -l 'base/postgres' "$root"/apps/*/kustomization.yaml 2>/dev/null || true) | wc -l)
port="${5:-$((30432 + used))}"
mkdir -p "$dir"
cat > "$dir/kustomization.yaml" <<EOF
resources:
  - ../../base/$engine

namePrefix: $name-

labels:
  - includeSelectors: true
    pairs:
      app: $name

patches:
  - target:
      kind: StatefulSet
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/envFrom/0/secretRef/name
        value: $name-credentials
  - target:
      kind: CronJob
    patch: |-
      - op: replace
        path: /spec/jobTemplate/spec/template/spec/containers/0/envFrom/0/secretRef/name
        value: $name-credentials
      - op: replace
        path: /spec/jobTemplate/spec/template/spec/containers/0/env/0/value
        value: $name-db
  - target:
      kind: Service
      name: db-external
    patch: |-
      - op: replace
        path: /spec/ports/0/nodePort
        value: $port

images:
  - name: imagem-padrao
    newName: $image
    newTag: $tag
EOF
echo "criado apps/$name -> interno $name-db:5432, VPN 100.77.183.32:$port"
