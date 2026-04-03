# tam-cert-noeks

Terraform + Ansible automation to deploy a production-ready Kubernetes cluster on AWS with Teleport Enterprise 18.7.1, PostgreSQL backend, Okta SAML SSO, ArgoCD GitOps, Teleport Access Graph, and AI-powered session summaries. All infrastructure is provisioned via Terraform, cluster bootstrapping runs via cloud-init on the master node, Teleport RBAC is managed via ArgoCD GitOps, and secrets are handled without any static credentials.

---

## Architecture

```
Internet
    │
    ▼
AWS NLB (grant-tam-teleport.gvteleport.com)
    │  port 443 → NodePort 32443
    ▼
Kubernetes Nodes (t3.medium × 3, us-west-2a)
  ├── master  172.49.20.230   control-plane + Ansible runner
  ├── worker1 172.49.20.231   K8s worker
  └── worker2 172.49.20.232   K8s worker
        │
        ├── Namespace: postgres
        │     └── PostgreSQL 17 (wal2json)
        │           ├── mTLS cert auth for teleport user
        │           └── scram-sha-256 for access_graph_user
        │
        ├── Namespace: teleport
        │     ├── teleport-auth     — PostgreSQL backend, S3 sessions
        │     └── teleport-proxy    — NodePort 32443, self-signed cert
        │
        ├── Namespace: teleport-access-graph
        │     └── Access Graph 1.29.6 — connected to PostgreSQL
        │
        └── Namespace: argocd
              └── ArgoCD — GitOps controller for Teleport RBAC
                    └── Application: teleport-rbac
                          └── PostSync Job: tctl apply all RBAC resources

ssh-node-1 (t2.small, private IP varies)
  └── Teleport SSH node, AWS IAM join, BPF enhanced session recording
      team=okta-teleport-users label, cgroup2 mount for BPF
```

---

## Repository Structure

```
tam-cert-noeks/
├── .github/workflows/terraform.yml     # plan + apply (Terraform only) + destroy
├── helm/
│   ├── teleport-values.yaml            # Base Teleport Helm values
│   └── postgres/                       # In-cluster PostgreSQL manifests
├── terraform/
│   ├── main.tf                         # EC2, VPC, IAM, cloud-init, .teleport-env
│   ├── rds.tf                          # S3 sessions bucket + IAM policy
│   ├── nlb.tf                          # AWS NLB → NodePort 32443
│   ├── route53.tf                      # DNS CNAME records
│   ├── teleport-oidc.tf                # AWS OIDC IAM resources
│   ├── ssh-node.tf                     # ssh-node-1 EC2 + IAM
│   └── scripts/
│       └── ssh-node-userdata.sh        # cloud-init: Teleport install + BPF config
├── argocd/
│   └── apps/
│       ├── teleport-rbac-app.yaml      # ArgoCD Application resource
│       └── teleport-rbac/
│           ├── rbac-configmap.yaml     # All RBAC YAMLs as ConfigMap data
│           ├── rbac-sync-job.yaml      # PostSync Job: tctl create -f each file
│           ├── rbac-syncer-rbac.yaml   # ServiceAccount + ClusterRole for job
│           ├── login-rule-okta-team.yaml
│           ├── role-base.yaml
│           ├── role-auto-approver.yaml
│           ├── role-okta-base.yaml
│           ├── role-okta-kube.yaml
│           ├── role-okta-ssh.yaml
│           ├── role-okta-ssh-root.yaml
│           ├── inference-model.yaml    # AI session summary model config
│           ├── inference-policy.yaml   # AI session summary policy (ssh kind)
│           └── cluster-auth-preference.yaml
└── ansible/
    ├── site.yaml                       # Master playbook (steps 1-11)
    └── roles/
        ├── k8s-setup/                  # containerd, kubeadm, kubelet, kubectl
        ├── k8s-master/                 # kubeadm init, Calico CNI
        ├── k8s-workers/                # dynamic kubeadm join
        ├── postgres/                   # cert gen, deployment, pg_hba
        ├── teleport/                   # Helm install, NodePort 32443
        ├── access-graph/               # Access Graph Helm + teleport-cluster patch
        ├── teleport-oidc/              # AWS OIDC via tctl
        ├── teleport-sso/               # Okta SAML connector bootstrap
        ├── teleport-rbac/              # Machine ID bot + rbac-manager join token
        ├── teleport-node/              # IAM join token for ssh-node-1
        └── argocd/                     # ArgoCD Helm + RBAC GitOps + secrets
```

---

## Playbook Sequence (`ansible/site.yaml`)

| Step | Role | Description |
|---|---|---|
| 1 | `k8s-setup` | containerd, kubeadm, kubelet, kubectl |
| 2 | `k8s-master` | kubeadm init, Calico CNI, kubeconfig |
| 3 | `k8s-workers` | dynamic kubeadm join |
| 4 | `postgres` | cert gen (openssl), PostgreSQL deployment, pg_hba |
| 5 | `teleport` | Teleport Enterprise Helm install, NodePort 32443 |
| 6 | `access-graph` | Access Graph TLS, postgres DB, Helm install, teleport-cluster upgrade |
| 7 | `teleport-oidc` | AWS OIDC integration resource |
| 8 | `teleport-sso` | Okta SAML connector bootstrap (built-in roles only) |
| 9 | `teleport-rbac` | Machine ID bot, rbac-manager role, GitHub OIDC join token |
| 10 | `teleport-node` | AWS IAM join token for ssh-node-1 |
| 11 | `argocd` | ArgoCD Helm, RBAC GitOps app, full SAML connector, inference_secret |


---

## CI/CD Pipeline

Single GitHub Actions workflow (`.github/workflows/terraform.yml`):

### `plan` — runs on every PR and every push to `main`
- Terraform init, validate, plan
- Uploads plan artifact keyed by git SHA (5-day retention)
- Posts formatted plan output as a PR comment

### `apply` — runs on merge to `main`, gated by `production` environment approval
- Downloads plan artifact, runs `terraform apply`
- Uploads SSH key artifact (`grant-tam-key`, 1-day retention)
- RBAC is handled by ArgoCD automatically — no tbot/tctl in CI

### `destroy` — `workflow_dispatch` only, gated by `production` environment

> **Note:** Deploy PRs use empty commits. The `push` trigger has no `paths` filter so merging any PR to `main` fires the apply job regardless of which files changed.

---

## RBAC — ArgoCD GitOps

All Teleport RBAC resources are managed via ArgoCD. On every merge to `main`, ArgoCD detects the diff in `argocd/apps/teleport-rbac/` and runs a PostSync Job that applies resources to the live cluster via `tctl`.

### How it works

```
Git push to main
    └── ArgoCD detects diff in argocd/apps/teleport-rbac/
          └── Sync: applies rbac-configmap.yaml to teleport namespace
                └── PostSync Job (teleport-rbac-apply)
                      ├── Patches rbac-sync volume onto teleport-auth pod
                      ├── kubectl exec -- tctl create -f <each file>
                      └── Cleanup via trap EXIT (always removes volume)
```

### Role model

| Role | Granted to | Description |
|---|---|---|
| `base` | All authenticated users (`*` wildcard) | No standing privileges, can request `okta_*` roles |
| `okta_base` | `okta-teleport-users` Okta group | No standing privileges, can request `okta_kube/ssh/ssh_root` |
| `okta_kube` | Via access request | K8s namespace access scoped to `{{internal.team}}` |
| `okta_ssh` | Via access request (auto-approved) | SSH to team-labeled nodes, no root |
| `okta_ssh_root` | Via access request (manual approval) | SSH + sudo, 4h TTL |
| `auto-approver` | Machine ID bot | Auto-approves pure `okta_ssh` requests |
| `editor` + `access` + `auditor` | `okta-teleport-admins` Okta group | Full admin + session recording visibility |

### SAML connector mappings

| Okta group | Teleport roles |
|---|---|
| `*` (everyone) | `base` |
| `okta-teleport-admins` | `editor`, `access`, `auditor` |
| `okta-teleport-users` | `okta_base` |

### Login rule (`okta-team-trait`)

Maps Okta SSO attributes to Teleport internal traits. `traits_map` replaces ALL traits so every needed trait must be explicitly listed:

```yaml
traits_map:
  logins:   [external.logins]   # SSH logins
  groups:   [external.groups]   # Preserved for SAML attributes_to_roles matching
  team:     [external.groups]   # Maps Okta group → internal.team for node/K8s scoping
```

### Secrets ownership

| Resource | Applied by | Why |
|---|---|---|
| `inference_model` + `inference_policy` | ArgoCD PostSync Job | No secrets — safe in repo |
| `inference_secret` (Skynet API key) | Ansible step 11 (argocd role) | Contains API key — sourced from `SKYNET_API_KEY` GH secret |
| SAML connector | Ansible step 11 (argocd role) | Contains Okta metadata URL — sourced from `.teleport-env` |

---

## PostgreSQL — In-Cluster with mTLS

PostgreSQL 17 runs in the `postgres` namespace using `ateleport/test:postgres-wal2json-17-1`.

### Users and auth

| User | Auth method | Used by |
|---|---|---|
| `teleport` | Client certificate (CN=teleport) | Teleport auth service — backend + audit |
| `access_graph_user` | scram-sha-256 password | Access Graph service |
| `postgres` | md5 (localhost only) | Admin/bootstrap only |

### Connection strings

```
# Backend + audit (Teleport auth pod)
postgresql://teleport@postgres-service.postgres.svc.cluster.local:5432/teleport_backend
  ?sslmode=verify-full&sslcert=/pg-certs/client.crt
  &sslkey=/pg-certs/client.key&sslrootcert=/pg-certs/ca.crt

# Access Graph
postgresql://access_graph_user:<password>@postgres-service.postgres.svc.cluster.local:5432/access_graph_db
  ?sslmode=require
```

---

## Teleport Access Graph

Access Graph v1.29.6 runs in the `teleport-access-graph` namespace. It connects to the same in-cluster PostgreSQL instance using password auth over TLS.

The `teleport-cluster` Helm chart is upgraded by Ansible step 6 with an `access_graph` patch:

```yaml
auth:
  teleportConfig:
    access_graph:
      enabled: true
      endpoint: teleport-access-graph.teleport-access-graph.svc.cluster.local:443
      ca: /var/run/access-graph/ca.pem
```

**Recovery:** If Access Graph shows "Failed to fetch" in the UI, re-run the Helm upgrade on master:
```bash
helm upgrade teleport teleport/teleport-cluster \
  --namespace teleport --version 18.7.1 \
  --values /home/ubuntu/teleport-values.yaml \
  --values /home/ubuntu/teleport-access-graph-patch.yaml \
  --wait --timeout 10m
```

---

## AI Session Summary

Session summaries are generated using a Skynet-hosted Gemma 3 model via an OpenAI-compatible API.

| Resource | Value |
|---|---|
| `inference_model` | `skynet-gemma` — endpoint `skynet.gvteleport.com:443`, model `gemma3:4b` |
| `inference_policy` | `skynet-gemma-policy` — applies to `ssh` session kind |
| `inference_secret` | `grant-skynet-secret` — API key injected from `SKYNET_API_KEY` GH secret |

The `inference_model` and `inference_policy` are applied by ArgoCD. The `inference_secret` is applied by Ansible step 11 using the ConfigMap mount pattern (same as the SAML connector) so the API key never touches the repo.

---

## ssh-node-1

Standalone `t2.small` Ubuntu node. Auto-enrolls via AWS IAM join — no static tokens.

**Labels:** `team=okta-teleport-users`, `env=demo`, `node=ssh-node-1`

**BPF enhanced session recording** — captures individual commands and network activity:
```yaml
ssh_service:
  enhanced_recording:
    enabled: true
    cgroup_path: /cgroup2   # separate mount, not /sys/fs/cgroup (conflicts with systemd)
```
Cloud-init mounts `/cgroup2` and runs `systemctl daemon-reexec` before starting Teleport to avoid `status=219/CGROUP` failures.


---

## Prerequisites

### 1. AWS Bootstrap Resources

```bash
# S3 bucket for Terraform state
aws s3api create-bucket \
  --bucket <tf-state-bucket> --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2
aws s3api put-bucket-versioning \
  --bucket <tf-state-bucket> \
  --versioning-configuration Status=Enabled

# DynamoDB table for state locking
aws dynamodb create-table \
  --table-name <tf-lock-table> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-west-2
```

### 2. GitHub Repository Secrets

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `AWS_SESSION_TOKEN` | Session token (required for STS/SSO credentials) |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform remote state |
| `TF_LOCK_TABLE` | DynamoDB table name for state locking |
| `CUSTOMER_IP` | Your public IP in CIDR notation (e.g. `1.2.3.4/32`) |
| `TELEPORT_LICENSE` | Teleport Enterprise license file contents |
| `AWS_OIDC_ARN` | ARN of the IAM role for Teleport AWS OIDC integration |
| `OKTA_METADATA_URL` | SAML metadata URL from Okta app Sign On tab |
| `OKTA_GROUPS_EDITOR` | Okta group name for the admin/editor group |
| `OKTA_GROUPS_ACCESS` | Okta group name for the standard access group |
| `SKYNET_API_KEY` | API key for the Skynet AI inference endpoint |

### 3. GitHub Environment

Create a **`production`** environment under **Settings → Environments** with required reviewers to gate all `apply` and `destroy` operations.

### 4. Okta SAML App

Create a SAML 2.0 application in Okta:
- **SSO URL**: `https://grant-tam-teleport.gvteleport.com/v1/webapi/saml/acs/okta`
- **Audience URI**: `https://grant-tam-teleport.gvteleport.com/v1/webapi/saml/acs/okta`
- **Name ID format**: `EmailAddress`
- **Attribute**: `username` → `user.login`
- **Group attribute**: `groups`, filter `Matches regex: .*`
- Copy the **Metadata URL** from Sign On tab → `OKTA_METADATA_URL` secret

Create two Okta groups and assign users:
- Admin group → `OKTA_GROUPS_EDITOR` (gets `editor`, `access`, `auditor` roles)
- Access group → `OKTA_GROUPS_ACCESS` (gets `okta_base` — must request all access)

---

## Deploying

### Via Pull Request (recommended)

```bash
git checkout -b deploy/apply-$(date +%Y%m%d)
git commit --allow-empty -m "chore: fresh deploy $(date +%Y-%m-%d)"
git push origin deploy/apply-$(date +%Y%m%d)
gh pr create --title "chore: fresh deploy" --base main
# Merge PR → apply job starts → approve production gate → infrastructure deploys
# ArgoCD syncs automatically and applies all RBAC resources via PostSync Job
```

### Manual trigger

**Actions → Deploy - K8s Cluster + Teleport RBAC → Run workflow**
- `plan` — preview only
- `apply` — full deploy (gated by production approval)
- `destroy` — tear down (gated by production approval)

---

## Accessing the Cluster

```bash
# Get SSH key from the apply run artifacts (1-day retention)
gh run download <run-id> --repo grantvoss-teleport/tam-cert-noeks \
  --name grant-tam-key --dir /tmp/grant-tam-key
chmod 600 /tmp/grant-tam-key/grant-tam-key.pem

# Get master public IP from apply run logs
gh run view <run-id> --log | grep master_public_ip

# SSH to master
ssh -i /tmp/grant-tam-key/grant-tam-key.pem ubuntu@<master_public_ip>

# Check cluster
kubectl get nodes && kubectl get pods -A

# Check Teleport
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') -- tctl status

# Check ArgoCD sync status
kubectl get application teleport-rbac -n argocd \
  -o jsonpath='{.status.sync.status} {.status.health.status}'
```

---

## Common Operations

### Re-apply RBAC after manual changes

ArgoCD auto-syncs on every commit to `main`. For immediate re-apply without a code change, trigger via the ArgoCD API from master:

```bash
PASS=$(kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sk -X POST http://localhost:32080/api/v1/session \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${PASS}\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
curl -sk -X POST http://localhost:32080/api/v1/applications/teleport-rbac/sync \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"revision":"HEAD","strategy":{"hook":{"force":true}}}'
```

### Fix stale ArgoCD volume on teleport-auth

If the ArgoCD PostSync Job crashes mid-run, it leaves a stale `rbac-sync` volume on `teleport-auth`. Remove it:

```bash
MOUNT_IDX=$(kubectl get deployment teleport-auth -n teleport -o json | \
  python3 -c "import json,sys; d=json.load(sys.stdin); mounts=d['spec']['template']['spec']['containers'][0].get('volumeMounts',[]); idxs=[str(i) for i,m in enumerate(mounts) if m['name']=='rbac-sync']; print(idxs[0] if idxs else '')")
VOL_IDX=$(kubectl get deployment teleport-auth -n teleport -o json | \
  python3 -c "import json,sys; d=json.load(sys.stdin); vols=d['spec']['template']['spec'].get('volumes',[]); idxs=[str(i) for i,v in enumerate(vols) if v['name']=='rbac-sync']; print(idxs[0] if idxs else '')")
kubectl patch deployment teleport-auth -n teleport --type=json \
  -p="[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/${MOUNT_IDX}\"},{\"op\":\"remove\",\"path\":\"/spec/template/spec/volumes/${VOL_IDX}\"}]"
kubectl rollout status deployment/teleport-auth -n teleport --timeout=120s
```

### Fix Access Graph "Failed to fetch"

```bash
helm upgrade teleport teleport/teleport-cluster \
  --namespace teleport --version 18.7.1 \
  --values /home/ubuntu/teleport-values.yaml \
  --values /home/ubuntu/teleport-access-graph-patch.yaml \
  --wait --timeout 10m
```

### Emergency break-glass admin user

```bash
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') \
  -- tctl users add admin --roles=editor,access,auditor --logins=ubuntu
```

---

## Notes

- AWS session tokens expire — refresh `AWS_SESSION_TOKEN` in GitHub Secrets before running
- Monitor cloud-init: `sudo tail -f /var/log/cloud-init-teleport.log` (on master)
- The Teleport proxy uses a **self-signed cert** (ACME disabled due to Let's Encrypt rate limits) — use `--insecure` flag for `tsh` and set `insecure: true` in `~/.tsh/config.yaml`
- NodePort `32443` is pinned via `kubectl patch` — the Teleport Helm chart does not support `nodePort` in values
- `traits_map` in a login rule **replaces** all traits — every trait needed downstream must be explicitly listed
- `{{internal.team}}` template variables in `node_labels` do **not** work when the trait is a list. Use `team: '*'` and rely on role access control instead
- BPF enhanced recording requires `cgroup_path: /cgroup2` (not `/sys/fs/cgroup`) and `systemctl daemon-reexec` after mounting
- `tctl create` for `cluster_auth_preference` requires `--confirm` when the resource is managed by static config
- The `auditor` role is required for session recording visibility in the UI — `editor` alone is not sufficient
