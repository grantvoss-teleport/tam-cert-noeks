# ─── Teleport AWS OIDC Integration ───────────────────────────────────────────
# References existing AWS IAM OIDC provider and role via variables.
# Both resources are pre-created and managed outside of this Terraform config.
# Variable aws_oidc_role_arn is declared in main.tf

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "teleport_oidc_role_arn" {
  value       = var.aws_oidc_role_arn
  description = "ARN of the IAM role used by the Teleport AWS OIDC integration"
}
