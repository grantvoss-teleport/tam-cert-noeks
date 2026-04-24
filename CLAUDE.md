# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-Code for a Teleport Enterprise demo/certification cluster on AWS. It provisions a 3-node kubeadm Kubernetes cluster with Teleport Enterprise, PostgreSQL backend, ArgoCD GitOps, Access Graph, and Auth0 OIDC SSO — using Terraform → Ansible → Helm → ArgoCD as a 4-layer stack.

## Deployment

**Full deploy:** Bump the comment in `terraform/backend.tf` and merge to `main`. The GitHub Actions workflow runs `terraform plan` on PR, then `terraform apply` (gated by `production` environment approval) on merge. Cloud-init on the master node automatically runs the full Ansible playbook.

**Destroy:** `workflow_dispatch` with `action: destroy` (requires environment approval).

No local `terraform` or `ansible` commands are needed — all execution happens in GitHub Actions via the master EC2 node.

## Re-running specific Ansible steps

Each of the 11 playbook steps has a standalone playbook in `ansible/`. SSH to the master node and run:

```
ansible-playbook -i /home/ubuntu/ansible/hosts /home/ubuntu/ansible/<playbook>.yaml
```

Standalone playbooks: `argocd.yaml`, `teleport-sso.yaml`, `teleport-rbac.yaml`, `teleport-node.yaml`, `access-graph.yaml`, `postgres.yaml`.

The full 11-step sequence is `site.yaml` — prefer individual playbooks for targeted fixes.

## Teleport RBAC (ArgoCD GitOps)

RBAC resources live in `argocd/apps/teleport-rbac/`. The flow:

1. ArgoCD watches `argocd/apps/teleport-rbac/` on `main` (excludes `resources/*`)
2. On sync, it applies `rbac-configmap.yaml` (contains all Teleport YAML files inline as ConfigMap data)
3. A PostSync Job (`rbac-sync-job.yaml`) mounts the ConfigMap onto the `teleport-auth` pod and runs `tctl create -f` for each file

**Critical:** The `rbac-configmap.yaml` is the source of truth for what gets applied. The `argocd/apps/teleport-rbac/resources/` directory is documentation/history only — ArgoCD excludes it. Edits to RBAC resources must go in the ConfigMap data keys.

To add a new Teleport resource: add a new key to `rbac-configmap.yaml` data, and add the filename to the apply loop in `rbac-sync-job.yaml`.

To apply immediately without waiting for ArgoCD auto-sync:
```
argocd app sync teleport-rbac --force
```

To manually apply a single resource via tctl:
```
kubectl exec -n teleport <auth-pod> -- tctl create -f /tmp/rbac-sync/<file>.yaml
```

## SSO: two-phase design

The OIDC connector is applied in two separate stages:
- **Step 8 (`teleport-sso`):** Bootstrap connector with built-in roles only (`editor`, `access`, `auditor`) — because custom roles don't exist yet
- **Step 11 (`argocd`):** Full connector applied after custom roles exist, replacing the bootstrap version

If SSO breaks after a re-deploy, re-running only `teleport-sso.yaml` applies the bootstrap version. Re-running `argocd.yaml` applies the full version. Running both in order is safe.

Auth0 OIDC connector (`auth0`) uses a custom claim namespace: `https://teleport.gvteleport.com/groups`. The `claims_to_roles` mapping in `ansible/roles/teleport-rbac/templates/oidc-auth0-patch.yaml.j2` must match what Auth0 sends.

## Cluster topology

| Host | IP | Role |
|------|----|------|
| master | `172.49.20.230` | K8s control-plane, Ansible runner |
| worker1 | `172.49.20.231` | K8s worker |
| worker2 | `172.49.20.232` | K8s worker |
| ssh-node-1 | dynamic | Standalone SSH node (AWS IAM join) |

Teleport Enterprise: `v18.7.1` (Helm). SSH node: `v18.7.3` (cloud-init). Access Graph: `v1.29.6`.

Public endpoint: `grant-tam-teleport.gvteleport.com` → AWS NLB → NodePort `32443`.

## Storage

The only available `StorageClass` is `efs-sc` (EFS CSI driver with dynamic provisioning via `efs-ap` access points). Any PVC must explicitly set `storageClassName: efs-sc` — there is no default StorageClass.

## Secrets

All sensitive values are GitHub Secrets injected at apply time. Terraform writes a `.teleport-env` file passed to cloud-init with license, DB passwords, OIDC credentials, and API keys. Nothing sensitive is ever committed to the repo.
