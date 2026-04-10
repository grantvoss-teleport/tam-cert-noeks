# ─── EFS Filesystem for PostgreSQL Persistent Storage ────────────────────────
# Provides durable storage for the in-cluster PostgreSQL pod that backs
# Teleport's state and audit backends. Using EFS (vs emptyDir) means the
# PostgreSQL data — including the Teleport ACME/Let's Encrypt cert — survives
# pod restarts, node replacements, and cluster rebuilds.

resource "aws_efs_file_system" "postgres" {
  creation_token = "${var.training_prefix}-postgres-data"
  encrypted      = true

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-postgres-efs"
  })
}

# ── Security group for EFS mount targets ─────────────────────────────────────
# Accepts NFS (2049) only from the K8s node security group.

resource "aws_security_group" "efs" {
  name        = "${var.training_prefix}-efs-sg"
  description = "EFS NFS access from K8s nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "NFS from K8s nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.main.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.training_prefix}-efs-sg"
  })
}

# ── Mount target in the cluster subnet ───────────────────────────────────────

resource "aws_efs_mount_target" "postgres" {
  file_system_id  = aws_efs_file_system.postgres.id
  subnet_id       = aws_subnet.main.id
  security_groups = [aws_security_group.efs.id]
}

# ── IAM permissions for EFS CSI driver ───────────────────────────────────────
# The EFS CSI controller (running on EC2) uses the instance profile to
# create/delete EFS Access Points when PVCs are provisioned.

resource "aws_iam_role_policy" "efs_csi" {
  name = "${var.training_prefix}-efs-csi-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "ec2:DescribeAvailabilityZones",
        "elasticfilesystem:CreateAccessPoint",
        "elasticfilesystem:DeleteAccessPoint",
        "elasticfilesystem:TagResource"
      ]
      Resource = "*"
    }]
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "efs_filesystem_id" {
  value       = aws_efs_file_system.postgres.id
  description = "EFS filesystem ID for PostgreSQL persistent storage"
}
