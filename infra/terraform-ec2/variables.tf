variable "name" { default = "cart-iq" }
variable "env" { default = "prod" }
variable "region" { default = "ap-south-1" }

variable "domain" {
  type        = string
  description = "Public hostname for the app (e.g. cartiq.acmecorp.com)"
}

variable "route53_zone_id" {
  type        = string
  default     = ""
  description = <<-EOT
    Existing Route53 hosted zone ID for var.domain. If set, Terraform creates an
    ALIAS A-record pointing the domain at the ALB. Leave blank if DNS lives
    elsewhere (Cloudflare, a separate account) — then create the record manually
    against the `alb_dns_name` output.
  EOT
}

variable "acm_certificate_arn" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional ARN of an existing ACM certificate (regional, in var.region) that
    covers var.domain. If set, Terraform uses it as-is. If blank, Terraform
    requests a new DNS-validated cert (you then create the validation CNAME —
    see the EC2 deployment guide).
  EOT
}

variable "vpc_cidr" { default = "10.30.0.0/16" }
variable "azs" { default = ["ap-south-1a", "ap-south-1b", "ap-south-1c"] }

# --- Compute ---------------------------------------------------------------
# App box runs the full Docker Compose stack (nginx, web, backend, auth, celery
# default/scraper/beat, redis). The scraper worker drives Playwright/Chromium on
# the CPU — cart-iq uses API-based inference, so there is no GPU box.
variable "app_instance_type" { default = "m6i.xlarge" } # 4 vCPU / 16 GB
variable "app_root_gb" { default = 100 }

# Optional SSH keypair name for break-glass access. The instance lives in a
# private subnet — prefer SSM Session Manager (enabled via instance profile)
# over opening port 22. Leave blank to omit a key entirely.
variable "ssh_key_name" { default = "" }

# --- Data plane ------------------------------------------------------------
variable "rds_instance_class" { default = "db.t4g.medium" }
variable "rds_storage_gb" { default = 100 }
variable "rds_multi_az" { default = false }

variable "tags" {
  type    = map(string)
  default = { Project = "cart-iq" }
}
