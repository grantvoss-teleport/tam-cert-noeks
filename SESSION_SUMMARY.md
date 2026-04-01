# Session Summary — tam-cert-noeks
## Repo: `grantvoss-teleport/tam-cert-noeks`
## Local path: `/Users/grantvoss/Documents/tam-cert-ans/tam-cert-noeks`

---

## Stack

- **Terraform** (AWS: VPC, EC2, S3, Secrets Manager, IAM, Route53)
- **Ansible** — 10-step playbook sequence run via cloud-init on master `172.49.20.230`
- **Kubernetes** — kubeadm, Calico CNI, 1 master + 2 workers (`.231`/`.232`)
- **Teleport Enterprise 18.7.1** — Helm chart `teleport-cluster`
- **Teleport Access Graph** — Helm chart `teleport-access-graph` v1.29.6
- **In-cluster PostgreSQL** (`ateleport/test:postgres-wal2json-17-1`) with mTLS cert auth
- **Okta SAML SSO**, **AWS OIDC**, **Machine ID RBAC**
- **ArgoCD** — newly added, NodePort 32080, registered as Teleport app

## Infrastructure

| Node | Private IP | Role |
|---|---|---|
| master | 172.49.20.230 | K8s control plane, Ansible runner |
| worker-1 | 172.49.20.231 | K8s worker |
| worker-2 | 172.49.20.232 | K8s worker |
| ssh-node-1 | 172.49.20.137 (private) | Standalone Teleport SSH node, IAM join |

**Teleport proxy**: `grant-tam-teleport.gvteleport.com:443` (NodePort 32443)
**ArgoCD**: `argocd.grant-tam-teleport.gvteleport.com` (NodePort 32080)

---

## Ansible Playbook Sequence (`ansible/site.yaml`)

1. `k8s-setup.yaml` — containerd, kubeadm, kubelet, kubectl
2. `k8s-master.yaml` — kubeadm init, Calico CNI, kubeconfig
3. `k8s-workers.yaml` — dynamic kubeadm join
4. `postgres.yaml` — in-cluster postgres pod, certs, `teleport-pg-client-certs` secret
5. `teleport.yaml` — Teleport Enterprise Helm install
6. `access-graph.yaml` — Access Graph TLS cert, postgres DB, Helm install, teleport-cluster upgrade
7. `teleport-oidc.yaml` — AWS OIDC integration
8. `teleport-sso.yaml` — Okta SAML connector
9. `teleport-rbac.yaml` — Machine ID bot, rbac-manager role, join token
10. `teleport-node.yaml` — AWS IAM join token for ssh-node-1

**Standalone playbooks** (not in site.yaml):
- `ansible/metallb.yaml` — MetalLB load balancer
- `ansible/argocd.yaml` — ArgoCD + Teleport app registration


---

## PRs Merged This Session

| PR | Branch | Fix |
|---|---|---|
| #28 | `fix/ag-debug-user-creation` | `access_graph_user` created via SQL file (`kubectl cp` + `psql -f`) — fixes special char interpolation |
| #29 | `deploy/apply-20260324` | Fresh deploy trigger |
| #30 | `fix/force-unlock-and-destroy` | Force-unlock stale TF state lock (DynamoDB `ConditionalCheckFailedException`) |
| #31 | `deploy/apply-20260324b` | Fresh deploy after clean destroy |
| #32 | `fix/ag-create-db-sql-file` | `access_graph_db` created via SQL file — fixes `\gexec` failure with `psql -c` |
| #33 | `deploy/apply-20260324c` | Fresh deploy |
| #34 | `fix/disable-acme-self-signed` | Disable ACME (`acme: false`) — Let's Encrypt rate limit reached, use self-signed cert |
| #35 | `fix/ag-helm-repo-add-as-ubuntu` | Add Teleport Helm repo in `access-graph` role — `teleport` role runs as root, `access-graph` runs as ubuntu |
| #36 | `deploy/apply-20260324d` | Fresh deploy |
| #37 | `fix/ag-chart-version-1-29-6` | Pin `teleport-access-graph` chart to `1.29.6` — has independent versioning from `teleport-cluster` |
| #38 | `deploy/apply-20260324e` | Fresh deploy |
| #39 | `fix/ag-replica-count-1` | Set `replicaCount: 1` in tag-values — chart default of 2 causes `--wait` timeout on lab cluster |
| #40 | `fix/pg-hba-access-graph-user` | Add `hostssl scram-sha-256` rule for `access_graph_user` on pod CIDR `192.168.0.0/16` |
| #41 | `deploy/apply-20260325` | Fresh deploy |
| #42 | `fix/rbac-stdin-instead-of-kubectl-cp` | Apply RBAC manifests via `kubectl exec -i` stdin — `kubectl cp` requires `tar` (distroless container) |
| #44 | `fix/ssh-node-iam-token-configmap-mount` | IAM token via ConfigMap mount + correct `spec.allow` field + `--insecure` systemd drop-in for ssh-node |
| #45 | `feat/argocd` | ArgoCD Helm install + Teleport app registration |
| #46 | `fix/saml-editor-add-access-role` | Add `access` role to `okta_groups_editor` SAML mapping |

**Closed/superseded**: PR #43 (superseded by #44)

---

## Key Design Decisions & Lessons Learned

### kubectl exec -i stdin truncation (distroless containers)
The Teleport auth container is distroless — no `sh`, `tar`, `cat`, nothing except Teleport binaries. `kubectl cp` requires `tar` and fails. `kubectl exec -i` stdin piping truncates multi-line YAML before the full content arrives.

**Solution (established pattern)**: Render YAML to a file on master → stage as a ConfigMap in `teleport` namespace → JSON-patch volume + volumeMount onto auth deployment → `kubectl exec -- tctl create -f /tmp/bootstrap/file.yaml` (no stdin) → cleanup patch + delete ConfigMap.

This pattern is used in:
- `ansible/roles/teleport-node/tasks/main.yaml`
- `ansible/roles/argocd/tasks/main.yaml`

### IAM join token YAML schema
IAM join tokens use `spec.allow` (top-level under spec), **NOT** `spec.iam.allow` (which is the EC2 join method). Every `tctl create` failure with `requires defined token allow rules` was caused by this wrong field name.

### `--insecure` for self-signed cert
After disabling ACME (PR #34), nodes connecting to the Teleport proxy must use `--insecure`. This is a **CLI flag only** — `insecure: true` is not a valid `teleport.yaml` v3 field and causes a parse error. Use a systemd drop-in:
```
[Service]
ExecStart=
ExecStart=/usr/local/bin/teleport start --config /etc/teleport.yaml --pid-file=/run/teleport.pid --insecure
```

### teleport-access-graph chart versioning
`teleport-access-graph` uses **independent versioning** (`1.x`) from `teleport-cluster` (`18.x`). Latest as of 2026-03-25 is `1.29.6`.

### Helm repo user context
The `teleport` Ansible role runs with `become: yes` (root) — `helm repo add` writes to `/root/.config/helm/`. The `access-graph` role runs with `become: false` (ubuntu) and needs its own `helm repo add` at the top of its tasks.

### pg_hba.conf for access_graph_user
Access Graph connects from Calico pod CIDR `192.168.x.x` using password auth (URI secret). Requires explicit `hostssl` rule — it does NOT use client certs like the `teleport` user.


---

## Current Cluster State (as of session end)

### Running services
- Teleport Enterprise 18.7.1 — proxy NodePort 32443, self-signed cert (ACME disabled)
- Teleport Access Graph 1.29.6 — healthy, connected to postgres
- PostgreSQL — mTLS cert auth for `teleport` user, scram-sha-256 for `access_graph_user`
- ssh-node-1 — registered in Teleport via AWS IAM join (`tctl nodes ls` confirms)
- ArgoCD — installed, NodePort 32080, registered as Teleport app resource

### Manually applied on live cluster (not via fresh deploy)
These were applied manually and are in the repo but would run automatically on next fresh deploy:
- PR #42: RBAC bootstrap (rbac-manager role, bot, join token) — applied via `ansible-playbook teleport-rbac.yaml`
- PR #44: ssh-node IAM join token — applied via `ansible-playbook teleport-node.yaml`
- PR #45: ArgoCD — applied via `ansible-playbook argocd.yaml` (files curled to master)
- PR #46: SAML connector update — applied manually via ConfigMap mount + `tctl create`
- RBAC roles (base, kube-access, ssh-access, ssh-root-access, auto-approver, login-rule) — applied manually via ConfigMap mount loop (GH Actions workflow blocked, no active PR)

### Pending / in-progress
- PR #46 merged but SAML connector + all RBAC roles applied manually
- `okta_groups_editor` SAML mapping now includes both `editor` and `access` roles

---

## GitHub Actions Workflow

**File**: `.github/workflows/terraform.yml`

- **Plan**: runs on PR open (touches `terraform/**` or `ansible/**`)
- **Apply**: runs on merge to `main`, gated by `production` environment approval
- **Destroy**: `workflow_dispatch` only, gated by `production` environment
- **RBAC apply**: Phase 2 of apply job — uses Machine ID (`tbot`) + `tctl` to apply all RBAC templates. Requires Teleport cluster to be reachable. **Currently blocked** — `workflow_dispatch apply` requires a PR.

**SSH key**: Uploaded as artifact `grant-tam-key` with 1-day retention. Retrieve with:
```bash
gh run download <run-id> --repo grantvoss-teleport/tam-cert-noeks --name grant-tam-key --dir /tmp/grant-tam-key
```
If expired, get from Terraform state:
```bash
cd terraform && terraform init -backend-config=... && terraform output -raw private_key_pem > /tmp/key.pem
```

**Master public IP**: `54.245.49.201` (from last apply run #23526661313)
**ssh-node-1 public IP**: `35.90.50.186` (from last apply run)

---

## Fresh Deploy Procedure

```bash
cd /Users/grantvoss/Documents/tam-cert-ans/tam-cert-noeks
git checkout main && git pull origin main
git checkout -b deploy/apply-YYYYMMDD
sed -i '' 's/# deploy trigger:.*/# deploy trigger: YYYYMMDD/' terraform/backend.tf
git add terraform/backend.tf && git commit -m "chore: fresh apply after environment destroy (YYYY-MM-DD)"
git push origin deploy/apply-YYYYMMDD
gh pr create --title "chore: fresh apply..." --body "..." --base main
```
Then merge PR → approve `production` gate → apply runs.

## Destroy Procedure

```bash
gh workflow run terraform.yml --repo grantvoss-teleport/tam-cert-noeks --field action=destroy
# Then approve production gate in GitHub Actions UI
```
If state lock exists first:
1. Add `terraform force-unlock -force <lock-id>` step before destroy in workflow (see PR #30 pattern)
2. Merge, then trigger destroy

