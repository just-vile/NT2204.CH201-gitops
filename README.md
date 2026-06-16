# saga gitops — Phase 1

A minimum-viable GitOps bootstrap for the choreography-saga e-commerce demo:
**kind cluster + Istio (mesh-wide STRICT mTLS) + Argo CD + 5 app services**, all
reconciled from this repo via the app-of-apps pattern.

Phase 1 deliberately leaves out the observability stack, message-broker /
database operators, and sealed-secrets — those land in Phase 2 (see
[Phase 2 backlog](#phase-2-backlog)).

---

## Prerequisites

| Tool | Min version | Notes |
| --- | --- | --- |
| Docker Desktop | recent | kind needs a working Docker daemon |
| `kind` | 0.24 | cluster provisioning |
| `kubectl` | matches cluster | 1.30 ships with kind 0.24 |
| `helm` | 3.x | optional locally — Argo CD renders charts in-cluster |
| `istioctl` | 1.23 | optional locally — diagnostics only; Istio is installed via Argo CD |
| `argocd` CLI | 2.12 | for `argocd app sync`, login, port-forward |

PowerShell 7+ (`pwsh`) on Windows; bash on Linux/macOS. The two bootstrap scripts
do the same thing.

---

## Bootstrap (3 steps)

> The default Argo CD `repoURL` and image repositories use the placeholder
> `REPLACE_ME_OWNER`. Either edit the YAMLs directly **or** pass `-RepoURL` /
> `--repo-url` to the bootstrap script and it will substitute on apply.

```powershell
# 1. cluster + Argo CD + kick off app-of-apps
pwsh ./scripts/bootstrap-kind.ps1 `
  -RepoURL https://github.com/<your-org>/saga-gitops.git

# 2. (optional, the script does this for you) re-apply if you edited apps/
kubectl apply -n argocd -f apps/app-of-apps.yaml

# 3. port-forward Argo CD UI and the Istio ingress gateway
kubectl -n argocd port-forward svc/argocd-server 8080:443
# WebUI is reachable at http://localhost/ once the gateway pod is ready
# (kind maps host :80 -> ingress-ready worker node :30080)
```

Linux/macOS:

```bash
./scripts/bootstrap-kind.sh --repo-url https://github.com/<your-org>/saga-gitops.git
```

Argo CD admin password (initial):

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' |
  ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

---

## Sync waves (provisioning order)

Argo CD applies resources in this order via the
`argocd.argoproj.io/sync-wave` annotation:

| Wave | What | Where |
| --- | --- | --- |
| -20 | `saga` + `istio-system` namespaces | `platform/istio/namespace.yaml` |
| -10 | Istio CRDs (`base` Helm chart) | `platform/istio/istio-base.yaml` |
| -5 | `istiod` control plane | `platform/istio/istiod.yaml` |
| -3 | `istio-ingressgateway` data plane | `platform/istio/istio-gateway.yaml` |
| 0 | Saga services (5 Helm releases) | `apps/<service>.yaml` |
| 5 | Istio CRs + NetworkPolicies | `apps/saga-mesh.yaml` |

The bootstrap script installs Argo CD itself (it cannot self-bootstrap) and
applies `apps/app-of-apps.yaml`. Everything else is reconciled by Argo CD.

---

## CI contract (cross-repo)

The application repo (`app/`) builds and pushes images to GHCR on every push to
`main`, then a workflow opens a PR here that bumps the image tag.

- **Workflow:** `app/.github/workflows/bump-gitops.yml`
- **What it edits:** `environments/local/values-<service>.yaml`
- **YAML key it sets:** `.image.tag` (top-level — yq edits in place)
- **Tag format:** `sha-<full-commit>`

The five files the bumper touches:

```
environments/local/values-order-service.yaml
environments/local/values-payment-service.yaml
environments/local/values-inventory-service.yaml
environments/local/values-shipping-service.yaml
environments/local/values-web-ui.yaml
```

Image repos default to `ghcr.io/REPLACE_ME_OWNER/saga-<service>`; the
`bootstrap-kind.ps1` substitution replaces only the Argo CD `repoURL`, so update
each `values-*.yaml` `image.repository` once you know the GHCR owner (or run
`scripts/set-image-owner.ps1` if you add one in Phase 2).

---

## Decisions (taken without explicit spec input)

1. **`platform/argocd/argocd-install.yaml` → `kustomization.yaml`.** The spec
   asked for `argocd-install.yaml`, but `kustomize` / `kubectl apply -k` only
   recognise `kustomization.yaml` (or `.yml` / `Kustomization`). Renaming
   eliminates a workaround in the bootstrap script.
2. **Istio ingress gateway in `istio-system`, not a separate `saga-system`.**
   The spec comment mentioned `saga-system`; conventional Istio installs put
   the gateway in `istio-system`. Fewer namespaces, fewer NetworkPolicy /
   AuthorizationPolicy rules to maintain. The principal in the
   `AuthorizationPolicy` for `web-ui` reflects this (`cluster.local/ns/istio-system/sa/istio-ingressgateway`).
3. **Bootstrap script does NOT run `istioctl install`.** Argo CD installs
   Istio via the upstream Helm charts (`base`, `istiod`, `gateway`). The
   script only does `kind` + Argo CD + app-of-apps.
4. **Extra Argo CD Application: `apps/saga-mesh.yaml`.** Reconciles
   `environments/local/istio/` and `environments/local/networkpolicies/`.
   Without this there's no manifest path that picks up Gateway,
   VirtualService, DestinationRules, PeerAuthentication, AuthorizationPolicy,
   and the namespace-scoped NetworkPolicies.
5. **One ingress-ready worker node.** Only one kind node can bind host port
   80 (Docker port collision otherwise). The `kind-config.yaml` labels
   exactly one worker with `ingress-ready=true` and exposes 80/443; the
   gateway Helm chart pins via `nodeSelector`.
6. **Plain env vars in `values-*.yaml`, no Secret resources yet.** Spec
   permitted plain Secrets with placeholder values. Going one step further:
   the chart wires `envFromSecrets` (list of `{name, secretName, key}`) for
   Phase 2 sealed-secrets, but Phase 1 puts `ConnectionStrings__Postgres`
   directly in `values.env` with a `# TODO: SealedSecret in Phase 2` comment.
   Less file churn, same final structure.
7. **Chart `networkPolicy.enabled: false` by default.** Namespace-scope
   default-deny + allow-mesh + allow-dns in `environments/local/networkpolicies/`
   already cover Phase 1. The chart template exists for Phase 2 fine-grained
   per-service policies.
8. **Image tag default is `dev`** (placeholder). The `bump-gitops` workflow
   overwrites it on every successful main-branch CI run.

---

## Phase 2 — what landed

Phase 2 makes the cluster operationally self-sufficient. After Phase 2 the
saga runs in-cluster with no `docker-compose` dependency: the data plane
(Postgres, RabbitMQ), the observability plane (OTel Collector → Jaeger +
kube-prometheus-stack), sealed-secrets, ServiceMonitors, PrometheusRules
and a Grafana dashboard ConfigMap are all reconciled from this repo.

Pinned versions:

| Component | Source | Version |
| --- | --- | --- |
| sealed-secrets controller | `bitnami-labs/sealed-secrets` (chart) | `2.16.1` |
| CloudNativePG operator | `cloudnative-pg/cloudnative-pg` (chart) | `0.22.1` |
| RabbitMQ Cluster Operator | `rabbitmq/cluster-operator` (kustomize) | `v2.10.0` |
| Jaeger Operator | `jaegertracing/jaeger-operator` (chart) | `2.57.0` |
| OpenTelemetry Collector | `open-telemetry/opentelemetry-collector` (chart) | `0.108.0` |
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` (chart) | `65.5.0` |

### Updated sync-wave table

| Wave | What | Where |
| --- | --- | --- |
| -20 | Namespaces (existing istio-system, saga, argocd + new sealed-secrets, cnpg-system, rabbitmq-system, monitoring, jaeger) | `platform/{istio,secrets,data-plane,observability}/namespace.yaml` |
| -18 | sealed-secrets controller (chart) | `platform/secrets/sealed-secrets.yaml` |
| -17 | CloudNativePG operator (chart) | `platform/data-plane/cnpg-operator.yaml` |
| -17 | RabbitMQ Cluster Operator (upstream kustomize) | `platform/data-plane/rabbitmq-operator.yaml` |
| -16 | Jaeger operator (chart) | `platform/observability/jaeger-operator.yaml` |
| -15 | platform-istio (Phase 1, unchanged) | `apps/platform.yaml` |
| -10 | saga-credentials (sealed credentials -> k8s Secrets) | `apps/saga-credentials.yaml` |
| -10 / -5 / -3 | istio-base / istiod / istio-ingressgateway (Phase 1) | `platform/istio/` |
| -2 | Postgres `Cluster` CR | `platform/data-plane/postgres-cluster.yaml` |
| -2 | `RabbitmqCluster` CR | `platform/data-plane/rabbitmq-cluster.yaml` |
| -2 | Jaeger CR (allInOne, in-memory, dev) | `platform/observability/jaeger-instance.yaml` |
| -2 | OTel Collector (chart, deployed in `saga` ns) | `platform/observability/otel-collector.yaml` |
| -1 | kube-prometheus-stack (chart) | `platform/observability/kube-prometheus-stack.yaml` |
| 0 | Saga services (Phase 1) | `apps/<service>.yaml` |
| 5 | saga-mesh (Phase 1) | `apps/saga-mesh.yaml` |
| 10 | saga-monitoring (cross-cutting `ServiceMonitor` + `PrometheusRule` + dashboard ConfigMap) | `apps/saga-monitoring.yaml` |

---

## Decisions Phase 2

1. **Cross-cutting `ServiceMonitor` instead of per-chart template.** The spec
   left a choice between adding `templates/servicemonitor.yaml` to the chart
   (one ServiceMonitor per service) or a single cross-cutting one selecting
   `app.kubernetes.io/part-of: saga`. We picked the cross-cutting one
   ([environments/local/service-monitors/saga-services.yaml](environments/local/service-monitors/saga-services.yaml));
   one resource, one place to tune scrape interval / relabel. The
   saga-service chart's `_helpers.tpl` already stamps `part-of: saga` on
   every Service, and the OTel Collector chart values tag it the same, so
   the same ServiceMonitor scrapes app metrics on the `http` port (8080
   `/metrics`), the OTel Collector on `metrics` (8889), and RabbitMQ on
   `prometheus` (15692).
2. **OTel Collector deployed in `saga` ns, not `monitoring`.** App code points
   at `http://otel-collector.saga.svc.cluster.local:4317`; deploying the
   Collector in `saga` with `fullnameOverride: otel-collector` produces a
   Service of exactly that name and avoids an `ExternalName` redirect. The
   Collector exporter targets `jaeger-collector.jaeger.svc.cluster.local:4317`
   (Jaeger Operator's emitted Service for the all-in-one CR).
3. **`automated.selfHeal: false` on every operator Application.** First-sync
   self-heal during partial CRD apply will thrash. Operators (sealed-secrets,
   CNPG, RabbitMQ, Jaeger, kube-prometheus-stack) and their wrapper Apps
   (`platform-secrets`, `platform-data-plane`, `platform-observability`) all
   start with `prune: false, selfHeal: false`. Re-enable per resource once
   steady-state in Phase 3.
4. **Postgres bootstrap via `postInitApplicationSQL`.** CNPG's `bootstrap.initdb`
   only takes a single primary database name, so the 4 logical DBs (orders /
   payments / inventory / shipping) are created via SQL run inside the
   primary `app` database on first init. Mirrors `app/build/postgres/init.sql`
   verbatim. The CNPG Service emitted is `postgres-rw` (writes) /
   `postgres-ro` (reads) — saga services connect to `postgres-rw`.
5. **RabbitmqCluster Service named `rabbitmq`.** The cluster CR's `metadata.name`
   determines the Service name; `rabbitmq` matches what the saga services'
   `RabbitMq__Host` points at (`rabbitmq.saga.svc.cluster.local`). Management
   (15672) and Prometheus (15692) ports added via `spec.override.service`.
6. **Saga ns NOT re-declared in `platform/data-plane/namespace.yaml`.** Already
   declared at wave -20 by `platform/istio/namespace.yaml`. Re-declaring under
   ServerSideApply triggers field-ownership ping-pong on the
   `istio-injection: enabled` label. `platform/data-plane/namespace.yaml`
   creates only `cnpg-system` and `rabbitmq-system`.
7. **Dashboard JSON inlined as a static ConfigMap, not Helm-templated.** The
   dashboard rarely changes; Helm escaping of Grafana template strings
   (`{{job}}`, `${DS_PROMETHEUS}`) is fiddly. The ConfigMap is generated by
   copying [app/build/observability/grafana/provisioning/dashboards/saga-overview.json](../app/build/observability/grafana/provisioning/dashboards/saga-overview.json)
   verbatim; bump `dashboard.version` inside the JSON to force the Grafana
   sidecar to reload.
8. **No `serviceMonitor.enabled` flag added to the chart `values.yaml`.** The
   chart-template approach was rejected (see Decision 1); adding a defaulted
   flag we don't use is dead code.

---

## Phase 2 — bootstrap on an existing cluster

Phase 1 assumes a fresh `kind` cluster created by `scripts/bootstrap-kind.ps1`.
If you already have a cluster (any flavour), you can skip the script and
do the equivalent manually:

```powershell
# 1. Argo CD itself (kustomize over upstream v2.12.6)
kubectl apply -k platform/argocd/

# 2. Wait for the controller
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

# 3. App-of-apps (edit repoURL first, OR use the script's substitution
#    pattern: replace REPLACE_ME_OWNER and apply via stdin)
kubectl apply -n argocd -f apps/app-of-apps.yaml
```

Caveats:

- **Ingress.** The Phase 1 Istio Gateway is a `NodePort` Service pinned to a
  worker node labelled `ingress-ready=true` (kind-specific). On a generic
  cluster, edit `platform/istio/istio-gateway.yaml` to use
  `service.type: LoadBalancer` (cloud) or remove the `nodeSelector` (any
  cluster with reachable node ports). This README does NOT change the YAML
  — adjust to your environment.
- **Storage class.** CNPG's `Cluster` CR and the `RabbitmqCluster` CR both
  request 1Gi PVCs from the cluster default StorageClass. If your cluster
  has no default, add `storageClassName:` to both CRs.
- **Sealed-Secrets seed.** A fresh cluster has no controller key yet. Apply
  the controller (wave -18 will do this), then run the kubeseal commands
  in [platform/secrets/README.md](platform/secrets/README.md) to seal the
  four credential bundles.

This bootstrap path is **Option B** from the "I already have a Kubernetes
cluster" answer in the previous turn — proper operators, no docker-compose
shortcuts.

---

## Sealed-Secrets workflow

The four SealedSecret bundles the cluster needs before everything turns
green:

| File | Target ns | Resulting Secret | Keys |
| --- | --- | --- | --- |
| `postgres-app-creds.sealedsecret.yaml` | saga | `postgres-app-creds` | `username`, `password`, `ConnectionStrings__Postgres__{order,payment,inventory,shipping}` |
| `postgres-superuser-creds.sealedsecret.yaml` | saga | `postgres-superuser-creds` | `username`, `password` |
| `rabbitmq-creds.sealedsecret.yaml` | saga | `rabbitmq-creds` | `RabbitMq__Username`, `RabbitMq__Password` |
| `grafana-admin.sealedsecret.yaml` | monitoring | `grafana-admin` | `admin-user`, `admin-password` |

Quick command sequence (full reference: [platform/secrets/README.md](platform/secrets/README.md)):

```powershell
# 0. install kubeseal locally — version-match the controller (2.16.x)
choco install kubeseal --version=0.27.1

# 1. fetch the controller pubkey (after wave -18 has synced)
kubeseal --controller-namespace sealed-secrets `
         --controller-name sealed-secrets-controller `
         --fetch-cert > pubcert.pem

# 2. seal each bundle. Example for rabbitmq-creds:
@"
apiVersion: v1
kind: Secret
metadata: { name: rabbitmq-creds, namespace: saga }
stringData:
  RabbitMq__Username: saga
  RabbitMq__Password: <your password>
"@ | kubeseal --cert pubcert.pem --format yaml `
   > environments/local/secrets/rabbitmq-creds.sealedsecret.yaml

# 3. commit and push — Argo CD picks them up via apps/saga-credentials.yaml
git add environments/local/secrets/*.sealedsecret.yaml
git commit -m "feat(secrets): seal Phase 2 credentials"
git push
```

The `*.sealedsecret.yaml.example` files in
[environments/local/secrets/](environments/local/secrets/) are placeholders
with non-decryptable `encryptedData` — they document the shape of each
sealed bundle and the keys it must contain. The `saga-credentials` ArgoCD
app matches `*.sealedsecret.yaml` only; `.example` files are ignored.

---

## Operational verification

After all sync waves complete:

```powershell
# Pods in saga ns: 5 services + otel-collector + 1 postgres + 1 rabbitmq
kubectl -n saga get pods
# Expected: order/payment/inventory/shipping/web-ui (each 1) + otel-collector
#           (1) + postgres-1 (1) + rabbitmq-server-0 (1) — 9 pods total.

# Operator pods
kubectl -n cnpg-system get pods                # 1
kubectl -n rabbitmq-system get pods            # 1
kubectl -n jaeger get pods                     # operator (1) + jaeger (1) = 2
kubectl -n monitoring get pods                 # ~10: prometheus, am, grafana,
                                               # node-exporter, kube-state-metrics,
                                               # operator
kubectl -n sealed-secrets get pods             # 1

# Argo CD application states
argocd app list                                # everything Synced + Healthy

# Port-forwards (each in a separate terminal)
kubectl -n monitoring port-forward svc/kps-grafana 3000:80          # http://localhost:3000
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090     # http://localhost:9090
kubectl -n jaeger     port-forward svc/jaeger-query 16686:16686     # http://localhost:16686
kubectl -n saga       port-forward svc/rabbitmq 15672:15672         # http://localhost:15672
kubectl -n argocd     port-forward svc/argocd-server 8080:443       # https://localhost:8080
```

Smoke checks:

- **Grafana** → "Saga" folder → "Saga Overview" dashboard renders with at
  least the request-rate panel populated.
- **Prometheus** → Status → Targets → all `serviceMonitor/monitoring/saga-services/*`
  rows are `UP`.
- **Jaeger UI** → Services → `OrderService` (etc) appear; one trace per
  smoke-test order.
- **RabbitMQ UI** → Queues tab → `*_error` DLQs exist and are empty.

---

## Phase 3 backlog

- Per-service `NetworkPolicy` refinement (chart `networkPolicy.enabled: true`)
  for L3/L4 defence-in-depth on top of Istio `AuthorizationPolicy`. Tighten
  data-plane egress: only `<svc>` -> `postgres-rw:5432`, only
  `<svc>` -> `rabbitmq:5672`, only `<svc>` -> `otel-collector:4317`.
- Argo CD self-management `Application` (so Argo version bumps go through
  GitOps).
- Istio canary-by-weight in a `VirtualService` for one of the saga services
  + a forced-failure `Fault` injection for chaos drills.
- Chaos Mesh / Litmus chaos manifests checked in alongside the
  `Fault` injection.
- Production overlays:
  - AKS Application Gateway / managed nginx for ingress.
  - Azure Key Vault CSI driver replacing sealed-secrets (`SecretProviderClass`,
    same `envFromSecrets` shape).
  - Azure Database for PostgreSQL Flexible Server replacing CNPG (delete
    `Cluster` CR, point `ConnectionStrings__Postgres__*` keys at the AKS-side
    SealedSecret).
- Re-enable `automated.selfHeal: true` on operator Apps once steady-state
  proves stable across two consecutive upgrades.

---

## AKS portability note

Three swaps to take this from kind to AKS:

1. **Ingress.** Drop the kind `extraPortMappings` + NodePort gateway service;
   use AKS application routing (or a separate `Service` of type
   `LoadBalancer` with the AKS load balancer). The Istio Gateway / VS /
   AuthorizationPolicy stay byte-identical.
2. **Secrets.** Replace Sealed-Secrets (Phase 2) with the **Azure Key Vault
   CSI driver** + `SecretProviderClass`. The chart's `envFromSecrets` list
   stays the same shape.
3. **Postgres.** Replace the in-cluster Postgres (or CloudNativePG, Phase 2)
   with **Azure Database for PostgreSQL — Flexible Server**. Update
   `ConnectionStrings__Postgres` in each `values-<service>.yaml` (or, post-Phase 2,
   in the `SealedSecret`). No chart changes.
