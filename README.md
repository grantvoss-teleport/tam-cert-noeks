# tam-cert-noeks

Terraform + Ansible automation to deploy a 3-node Kubernetes cluster (1 master, 2 workers) on AWS EC2 using Ubuntu 24.04 LTS. Cluster bootstrapping is handled via cloud-init on the master node, which pulls Ansible roles directly from this repository and runs them to configure all nodes.

---

## Repository Structure

```
tam-cert-noeks/
├── .github/
│   └── workflows/
│       └── terraform.yml          # GitHub Actions CI/CD pipeline
├── terraform/
│   ├── main.tf                    # All AWS infrastructure + cloud-init
│   └── backend.tf                 # S3 remote state (values injected at runtime)
└── ansible/
    ├── ansible.cfg                # Ansible configuration
    ├── hosts                      # Inventory file
    ├── site.yaml                  # Master playbook (runs all roles in order)
    ├── k8s-setup.yaml             # Playbook: common node setup
    ├── k8s-master.yaml            # Playbook: master initialization
    ├── k8s-workers.yaml           # Playbook: worker join
    └── roles/
        ├── k8s-setup/
        │   └── tasks/
        │       └── main.yaml      # Installs containerd, kubeadm, kubelet, kubectl
        ├── k8s-master/
        │   └── tasks/
        │       └── main.yaml      # Runs kubeadm init, installs Calico CNI
        └── k8s-workers/
            └── tasks/
                └── main.yaml      # Joins workers to the cluster
```

---

## Prerequisites

### 1. AWS Resources (created once before first run)

The Terraform S3 backend requires an S3 bucket and DynamoDB table to exist before the pipeline runs. Create them manually or with the AWS CLI:

```bash
# S3 bucket for state
aws s3api create-bucket \
  --bucket <your-tf-state-bucket> \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket <your-tf-state-bucket> \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket <your-tf-state-bucket> \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# DynamoDB table for state locking
aws dynamodb create-table \
  --table-name <your-tf-lock-table> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-west-2
```

### 2. GitHub Repository Secrets

Navigate to **Settings → Secrets and variables → Actions** in your repository and add the following secrets:

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM access key with EC2 and VPC permissions |
| `AWS_SECRET_ACCESS_KEY` | Corresponding IAM secret key |
| `AWS_SESSION_TOKEN` | Session token (required for temporary/STS credentials) |
| `TF_STATE_BUCKET` | Name of the S3 bucket created above |
| `TF_LOCK_TABLE` | Name of the DynamoDB table created above |
| `CUSTOMER_IP` | Your public IP in CIDR notation (e.g. `136.25.0.29/32`) |

### 3. GitHub Environment (optional but recommended)

Create a **`production`** environment under **Settings → Environments** and add required reviewers to gate all `apply` and `destroy` operations behind a manual approval step.

---

## Deploying the Cluster

### Option A: Automatic deploy via push to `main`

Any push to the `main` branch that modifies files under `terraform/` will automatically trigger a `plan` followed by `apply`.

```bash
git checkout main
git push origin main
```

### Option B: Manual trigger via GitHub Actions UI

1. Navigate to **Actions → Terraform - K8s Cluster → Run workflow**
2. Select the desired action:
   - **`plan`** — preview infrastructure changes, no resources created
   - **`apply`** — create or update the cluster
   - **`destroy`** — tear down all resources
3. Click **Run workflow**

### Option C: Pull request plan preview

Open a pull request targeting `main`. The workflow will automatically run a `plan` and post the output as a comment on the PR for review before merging.

---

## How It Works

1. **Terraform** provisions the AWS VPC, subnet, internet gateway, security group, SSH key pair, and three EC2 instances (master + 2 workers).
2. The **master** instance runs a cloud-init script at first boot that:
   - Installs `kubectl`, `kubeadm`, `kubelet`, `ansible`, and dependencies
   - Writes the Terraform-generated SSH private key to `~/.ssh/id_rsa`
   - Downloads all Ansible playbooks and roles from this GitHub repository
   - Runs `k8s-setup.yaml` → `k8s-master.yaml` → `k8s-workers.yaml` in sequence
3. **Workers** run their own cloud-init that installs `kubeadm` and `kubelet`, then wait for the master's Ansible run to join them to the cluster via SSH.
4. **Calico CNI** is installed by the master playbook after `kubeadm init` completes.

---

## Accessing the Cluster

After a successful apply, get the master's public IP from the Terraform outputs:

```bash
cd terraform
terraform output master_public_ip
```

SSH into the master node:

```bash
ssh -i grant-tam-key.pem ubuntu@<master_public_ip>
```

Verify the cluster is healthy:

```bash
kubectl get nodes
kubectl get pods -A
```

---

## Tearing Down

To destroy all AWS resources:

1. Navigate to **Actions → Terraform - K8s Cluster → Run workflow**
2. Select **`destroy`**
3. Click **Run workflow**

Or locally:

```bash
cd terraform
terraform destroy
```

---

## Notes

- The SSH private key (`grant-tam-key.pem`) is written to the `terraform/` directory after the first `apply`. It is listed in `.gitignore` and must never be committed to the repository.
- Terraform state is stored remotely in S3 with DynamoDB locking — do not use local state in shared environments.
- AWS session tokens from STS/SSO expire. Refresh `AWS_SESSION_TOKEN` in repository secrets before running the pipeline if credentials have expired.
- Cloud-init logs on the master can be monitored in real time: `sudo tail -f /var/log/cloud-init-output.log`
