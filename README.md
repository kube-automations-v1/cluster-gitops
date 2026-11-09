# cluster-gitops

Fonte de verdade (GitOps) do ambiente de testes/automações. O ArgoCD observa este repositório e aplica tudo que está em `apps/*`.

## Visão geral

```
dev push (repo do ms) ─► GitHub Actions (shared-pipelines) ─► imagem no GHCR
                                         │
                                         └─► commit em cluster-gitops (apps/<ms>, newTag = sha)
                                                    │
                                          ArgoCD (ApplicationSet) sincroniza
                                                    │
 cliente na VPN ─► http://automation-v1/<tech>/<ms> ─► Traefik ─► Service ─► 2 pods
```

## 1. Infraestrutura (VM)

| Item | Valor |
|---|---|
| Host | `automation-v1` (Ubuntu 26.04), 10 GB RAM, 12 vCPUs, VM libvirt |
| Acesso | Tailscale (VPN) `100.77.183.32`; `ssh vitor@100.77.183.32` (sudo) |
| Kubernetes | k3s single-node (control-plane), `kubectl` no próprio servidor |
| Ingress | Traefik (embutido no k3s, v3), Service `LoadBalancer` `192.168.122.200` |
| LoadBalancer | MetalLB L2, pool `192.168.122.200-250` (`metallb-system`) |
| GitOps | ArgoCD v3.5.6 (`argocd`), UI em `http://automation-v1/argocd` |
| Rede | `enp1s0`: `192.168.122.150/24` (estático) + `192.168.1.105/24` (DHCP) |

### Rede: atenção
`/etc/netplan/00-installer-config.yaml` define a rota default via `192.168.122.1` com `metric: 600`. Sem a métrica, essa rota (sem saída para a internet) vencia a do DHCP (`192.168.1.1`, metric 100) e causava timeouts em ghcr.io / public.ecr.aws (`ImagePullBackOff`, ArgoCD `Unknown` por redis fora). Backup: `00-installer-config.yaml.bak`.

### Namespaces / componentes
- `kube-system`: coredns, traefik (+ svclb), metrics-server, local-path-provisioner.
- `metallb-system`: controller, speaker (IPAddressPool `default-pool`, L2Advertisement `default-l2`).
- `argocd`: application-controller, applicationset-controller, repo-server, server, redis, dex, notifications.
- `default`: os microsserviços (um Application do ArgoCD por pasta de `apps/`).

### Configuração manual (fora do GitOps)
- `bootstrap/root-app.yaml`: ApplicationSet `cluster-workloads` (aplicar uma vez: `kubectl apply -f`).
- `bootstrap/argocd-cmd-params.yaml`: faz o ArgoCD servir em `/argocd` por trás do Traefik (HTTP). Após aplicar: `kubectl -n argocd rollout restart deploy argocd-server`.
- Secret `ghcr-secret` (namespace `default`) para puxar imagens privadas do GHCR.
- Senha admin do ArgoCD: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d`.
- O ApplicationSet consulta o Git a cada ~3 min; para acelerar: `kubectl -n argocd rollout restart deploy argocd-applicationset-controller`.

## 2. Padrão de rede e DNS

`http://automation-v1/<tech>/<ms>` — `tech` ∈ `java | go | node | graalvm`. Acesso apenas pela VPN.

- Nome padrão: **`automation-v1`**, o MagicDNS do Tailscale (nome da máquina no client Tailscale). Sem configuração extra: `http://automation-v1/argocd`, `http://automation-v1/java/<ms>/`.
- Os Ingress **não definem `host:`**: aceitam qualquer Host, então o IP (`http://100.77.183.32/...`), `automation-v1` e o FQDN `automation-v1.tail25d04f.ts.net` funcionam igualmente. Não use mais o nome `automations`.
- O Middleware Traefik `strip-tech-ms` (`apps/platform`) remove `/<tech>/<ms>` antes de chegar ao pod: `/java/foo/users` → `/users`.
- Balanceamento: Service `ClusterIP` com 2 réplicas; o Traefik distribui entre os pods (round-robin). Service `LoadBalancer` por app não é usado.
- Contrato do app: escutar na porta **8080** (env `PORT`).
- CLI do ArgoCD: `argocd login automation-v1 --plaintext --grpc-web --grpc-web-root-path /argocd --username admin`.

## 3. Estrutura do repositório

```
bootstrap/
  root-app.yaml              ApplicationSet (um Application por apps/*)
  argocd-cmd-params.yaml     ArgoCD em /argocd (manual)
base/app/                    Deployment (2 réplicas, readiness TCP 8080, requests/limits), Service, Ingress
apps/
  platform/                  Middleware strip-tech-ms
  argocd/                    Ingress da UI do ArgoCD (ns argocd)
  <ms>/kustomization.yaml    namePrefix, labels, path do ingress, imagem/tag
scripts/new-app.sh           cria apps/<ms> no padrão
```

Apps atuais: `java-service` (`/java/java-service`), `swing-trade-v1` (`/java/swing-trade-v1`), mais `platform` e `argocd`.

Cada app usa `namePrefix: <ms>-` (recursos `<ms>-app`), `labels.includeSelectors` com `app: <ms>`, um patch JSON que define o path do ingress e `images` (`imagem-padrao` → imagem real; `newTag` é atualizado pela pipeline).

### Criar um app manualmente
```bash
scripts/new-app.sh <java|go|node|graalvm> <ms> ghcr.io/kube-automations-v1/<ms> [tag]
git add apps/<ms> && git commit && git push
```

## 4. Pipelines (repo `kube-automations-v1/shared-pipelines`)

Workflows reutilizáveis em `.github/workflows/`:

| Workflow | Testes | Observação |
|---|---|---|
| `java-template.yml` | `setup-java` (temurin, input `java-version`=21); `mvn verify` ou `gradlew test` | |
| `node-template.yml` | `setup-node` (input `node-version`=22); `npm ci`, `npm test --if-present` | |
| `go-template.yml` | `setup-go` (input `go-version`=1.23); `go vet`, `go test` | |
| `graalvm-template.yml` | `setup-graalvm`; `mvn verify` ou `gradlew test` | imagem nativa via Dockerfile padrão |
| `_deploy.yml` | — | interno; chamado após os testes |

`_deploy.yml` (input `tech`):
1. Usa o `Dockerfile` do repo, ou o fallback `dockerfiles/<tech>.Dockerfile` (checkout do shared-pipelines com `GITOPS_PAT`).
2. Build + push para `ghcr.io/<org>/<repo>` com tags `latest` e `<sha>`.
3. Clona este repo, roda `scripts/new-app.sh` (cria `apps/<repo>` no primeiro deploy), atualiza `newTag` e faz commit/push (3 tentativas com `pull --rebase`).
4. O ArgoCD sincroniza (`automated`, `prune`, `selfHeal`).

O nome da pasta em `apps/` é o nome do repositório do microsserviço.

### Usar no repo de um microsserviço
```yaml
name: CI/CD
on: { push: { branches: [main] } }
jobs:
  pipeline:
    uses: kube-automations-v1/shared-pipelines/.github/workflows/<tech>-template.yml@main
    secrets: inherit
```
Requisitos: secret `GITOPS_PAT` (acesso de escrita a este repo e leitura ao shared-pipelines) na org; pacote GHCR acessível pelo cluster (`ghcr-secret`).

## 5. Bases de dados (`base-*`)

Padrão de nome: `base-<nome>` (repo = pasta em `apps/` = prefixo dos recursos). Primeira base: `base-bolt-mesh` (PostgreSQL 17).

- `base/postgres`: StatefulSet (1 réplica, probes `pg_isready`), Service `<base>-db` (ClusterIP :5432), `<base>-db-external` (NodePort, VPN `100.77.183.32:<30432+n>`), CronJob de backup.
- **Persistência:** PVC `data-<base>-db-0` (10Gi) na StorageClass `local-path-retain` (`apps/platform`): `Retain` — o dado fica na VM em `/var/lib/rancher/k3s/storage/pvc-*` mesmo se o PVC/StatefulSet for apagado (o `local-path` padrão apaga). Ao recriar, é preciso religar o PV manualmente (remover `claimRef`).
- **Backup:** CronJob diário 03:00, `pg_dump | gzip` em PVC `<base>-backups` (5Gi, últimos 7). Teste: `kubectl create job --from=cronjob/<base>-backup bkp-test`. Os dados estão no mesmo disco da VM: copie os dumps para fora periodicamente.
- **Credenciais:** secret `<base>-credentials` (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) criado manualmente, nunca no Git:
  `kubectl create secret generic base-x-credentials --from-literal=POSTGRES_USER=... --from-literal=POSTGRES_PASSWORD=... --from-literal=POSTGRES_DB=...`
- **Pipeline:** repo `base-<nome>` com `Dockerfile` + `initdb/*.sql` chama `postgres-template.yml` (build, smoke test com container, deploy via `scripts/new-base.sh`). `initdb/` só roda com volume vazio.
- Criar manualmente: `scripts/new-base.sh postgres base-<nome> ghcr.io/kube-automations-v1/base-<nome> [tag] [nodePort]`.
- Imagens no GHCR são privadas por padrão; `ghcr-secret` é usado pelos pods.
- Workflows reutilizáveis aninhados exigem `permissions: {contents: read, packages: write}` no job chamador (sem isso: `startup_failure`).

## 6. Operação

```bash
kubectl get applications -n argocd          # estado dos apps
kubectl get pods,ingress -A                 # pods e rotas
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite
```

Problemas comuns:
- `ImagePullBackOff` com timeout → ver rota default (seção 1); imagem privada → `ghcr-secret`.
- Aplicação `Unknown` → repo-server sem redis ou sem acesso ao GitHub.
- 404 do Traefik (`404 page not found`) → host/path errado; 404 JSON/HTML do app → rota ok, endpoint inexistente.
- Na UI do ArgoCD, o HTML só é servido com header `Accept: text/html` (o `curl` puro devolve o `index.html` bruto).

## 7. Pendências
- Backup externo (fora da VM) das bases.
- TLS (hoje HTTP puro dentro da VPN).
- Gerenciar `argocd-cmd-params-cm` via GitOps.
- Rotacionar credenciais SSH expostas anteriormente e migrar para chave.

## 8. OCS Inventory (serviço especial)
Repo `ocs-inventory` (Alpine multi-stage, OCS 2.12.6, ~194 MB) + MariaDB 11 (StatefulSet, PVC `local-path-retain`) em `apps/ocs-inventory`, mantido à mão (o pipeline só atualiza `newTag`).
- Console: `http://automation-v1/ocsreports/` (admin/admin — trocar no 1º acesso)
- Agentes: `http://automation-v1/ocsinventory` · API: `/ocsapi/v1/computers`
- Exceção ao padrão `/<tech>/<ms>`: o console usa links absolutos, então não há strip-prefix.
- Secret manual `ocs-inventory-credentials` (MARIADB_ROOT_PASSWORD/USER/PASSWORD/DATABASE).

## 9. GLPI (serviço especial)
Repo `glpi` (Alpine + Apache/PHP 8.4, GLPI 12.0.1, ~640 MB) + manifests em `apps/glpi` (PVC `glpi-data` em `/var/glpi`, mantido à mão; o pipeline só atualiza `newTag`).
- URL: `http://automation-v1/glpi/` (glpi/glpi, tech/tech, normal/normal, post-only/postonly — trocar senhas)
- Sem strip-prefix (path nativo `/glpi`).
- Banco: **compartilhado com o MariaDB do OCS** (`ocs-inventory-db`, database/usuário `glpi`), pois a inicialização de um MariaDB novo trava no kernel atual da VM. Database e usuário criados à mão.
- Secret manual `glpi-credentials`. A 1ª subida instala o schema (~30 min com o disco lento).

## 10. fe-bolt-mesh (frontend, exceção ao padrão)
Repo `fe-bolt-mesh` (Vite/React → nginx:alpine, porta 8080, ~95 MB, fallback SPA). Servido na **raiz** `http://automation-v1/` sem strip-prefix, pois chama a API por caminho absoluto `/java/engine-bolt-mesh/api/v1` (mesma origem, sem CORS). Rotas mais específicas (`/java/...`, `/argocd`, `/glpi`...) têm prioridade no Traefik.
