# Sealed-Secrets workflow

The cluster-side **sealed-secrets** controller (installed via
`platform/secrets/sealed-secrets.yaml`) is the only thing that can decrypt the
`SealedSecret` CRs we commit to git. It owns a private key it never exposes;
your local `kubeseal` CLI uses the matching **public** key to encrypt new
secrets before commit.

The four credential bundles the cluster operator must seal before everything
else turns green:

| SealedSecret file | Target ns | Resulting Secret | Keys |
| --- | --- | --- | --- |
| `postgres-app-creds.sealedsecret.yaml` | `saga` | `postgres-app-creds` | `username`, `password`, `ConnectionStrings__Postgres__order`, `ConnectionStrings__Postgres__payment`, `ConnectionStrings__Postgres__inventory`, `ConnectionStrings__Postgres__shipping` |
| `postgres-superuser-creds.sealedsecret.yaml` | `saga` | `postgres-superuser-creds` | `username`, `password` |
| `rabbitmq-creds.sealedsecret.yaml` | `saga` | `rabbitmq-creds` | `RabbitMq__Username`, `RabbitMq__Password` |
| `grafana-admin.sealedsecret.yaml` | `monitoring` | `grafana-admin` | `admin-user`, `admin-password` |

(The CNPG operator only needs the first two; CNPG creates the per-DB
connection strings as a convenience for the .NET services that read them
via `envFromSecrets`.)

## 1. Install `kubeseal`

```powershell
# Windows: pick the matching version from the controller chart (2.16.x)
choco install kubeseal --version=0.27.1   # or scoop, or download from GitHub releases
```

```bash
# macOS
brew install kubeseal
```

The CLI version must match the controller's serialisation format (anything
0.27.x against controller 2.16.x is fine).

## 2. Fetch the controller's public key

```powershell
kubeseal --controller-namespace sealed-secrets `
         --controller-name sealed-secrets-controller `
         --fetch-cert > pubcert.pem
```

Save `pubcert.pem` somewhere convenient (it can be committed to git — it's
the public key). Subsequent `kubeseal` commands can pass `--cert pubcert.pem`
for offline use.

## 3. Seal the four secrets

Each command writes a plain `Secret` to a temp file, pipes it through
`kubeseal`, and produces the SealedSecret YAML you commit. **Do NOT commit
the temp Secret file.**

### Postgres app credentials

```powershell
@"
apiVersion: v1
kind: Secret
metadata:
  name: postgres-app-creds
  namespace: saga
type: kubernetes.io/basic-auth
stringData:
  username: saga
  password: <pick a strong password>
  ConnectionStrings__Postgres__order:     "Host=postgres-rw.saga.svc.cluster.local;Port=5432;Database=orders;Username=saga;Password=<same password>"
  ConnectionStrings__Postgres__payment:   "Host=postgres-rw.saga.svc.cluster.local;Port=5432;Database=payments;Username=saga;Password=<same password>"
  ConnectionStrings__Postgres__inventory: "Host=postgres-rw.saga.svc.cluster.local;Port=5432;Database=inventory;Username=saga;Password=<same password>"
  ConnectionStrings__Postgres__shipping:  "Host=postgres-rw.saga.svc.cluster.local;Port=5432;Database=shipping;Username=saga;Password=<same password>"
"@ | kubeseal --cert pubcert.pem --format yaml `
   > environments/local/secrets/postgres-app-creds.sealedsecret.yaml
```

Note: the host is `postgres-rw.saga.svc.cluster.local`. CloudNativePG creates
two Services per cluster: `postgres-rw` (writes / current primary) and
`postgres-ro` (read-only replicas). Saga services connect to `-rw`.

### Postgres superuser credentials

```powershell
@"
apiVersion: v1
kind: Secret
metadata:
  name: postgres-superuser-creds
  namespace: saga
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: <pick a strong superuser password>
"@ | kubeseal --cert pubcert.pem --format yaml `
   > environments/local/secrets/postgres-superuser-creds.sealedsecret.yaml
```

### RabbitMQ credentials

```powershell
@"
apiVersion: v1
kind: Secret
metadata:
  name: rabbitmq-creds
  namespace: saga
type: Opaque
stringData:
  RabbitMq__Username: saga
  RabbitMq__Password: <pick a strong password>
"@ | kubeseal --cert pubcert.pem --format yaml `
   > environments/local/secrets/rabbitmq-creds.sealedsecret.yaml
```

### Grafana admin

```powershell
@"
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: <pick a strong password>
"@ | kubeseal --cert pubcert.pem --format yaml `
   > environments/local/secrets/grafana-admin.sealedsecret.yaml
```

## 4. Commit

```powershell
git add environments/local/secrets/*.sealedsecret.yaml
git commit -m "feat(secrets): seal Phase 2 credentials"
git push
```

ArgoCD picks them up via the `saga-monitoring`/`platform-data-plane` apps
(both watch the directory). The sealed-secrets controller decrypts each
`SealedSecret` into a regular `Secret` in the target namespace, after which
the app deployments' `envFromSecrets` references resolve and the pods come
up green.

## What happens if a SealedSecret file is missing?

ArgoCD will still apply the rest of the platform; the resources that depend
on the missing Secret (the saga Deployments and the Postgres Cluster) will
sit in `CrashLoopBackOff` / `ImagePullBackOff`-equivalent states until the
Secret materialises. This is the expected behaviour — Argo CD never
automatically applies secret material it doesn't have.
