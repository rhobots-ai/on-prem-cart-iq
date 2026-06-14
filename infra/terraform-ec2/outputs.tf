output "vpc_id" { value = module.vpc.vpc_id }
output "alb_dns_name" { value = aws_lb.this.dns_name }
output "app_instance_id" { value = aws_instance.app.id }
output "app_private_ip" { value = aws_instance.app.private_ip }

output "rds_endpoint" { value = module.rds.db_instance_endpoint }
output "rds_master_secret_arn" { value = module.rds.db_instance_master_user_secret_arn }

output "s3_bucket_name" { value = aws_s3_bucket.uploads.id }
output "acm_certificate_arn" { value = local.acm_certificate_arn }
output "instance_profile" { value = aws_iam_instance_profile.instance.name }

output "ecr_registry" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

# app.env-ready snippet — fill the remaining secrets (auth, LLM) by hand.
# Run: terraform -chdir=infra/terraform-ec2 output -raw app_env_snippet > deploy/ec2/app.env
output "app_env_snippet" {
  value = <<-EOT
    # ---- Generated from `terraform output app_env_snippet` --------------------
    # Image registry + tags
    ECR_REGISTRY=${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com
    BACKEND_TAG=1.0.0
    WEB_TAG=1.0.0
    SCRAPER_TAG=1.0.0
    AUTH_TAG=latest

    # Public host
    DOMAIN=${var.domain}

    # Django host/origin allow-lists. localhost/127.0.0.1/backend are needed for
    # the container healthcheck (curls localhost) and intra-stack calls.
    ALLOWED_HOSTS=${var.domain},localhost,127.0.0.1,backend
    CSRF_TRUSTED_ORIGINS=https://${var.domain}
    HOST_NAME=https://${var.domain}

    # Database — direct to RDS (no Proxy). Fetch DB_PASSWORD from the master
    # secret: aws secretsmanager get-secret-value --secret-id ${module.rds.db_instance_master_user_secret_arn}
    DB_HOST=${split(":", module.rds.db_instance_endpoint)[0]}
    DB_PORT=5432
    DB_USER=cart_iq
    DB_PASSWORD=__FILL_FROM_SECRETS_MANAGER__
    DB_NAME=cart_iq
    DB_NAME_AUTH=auth
    # Parity-chat read connection. v1 reuses the main user (no read-only role);
    # blank password inherits DB_PASSWORD in the app.
    PARITY_CHAT_DB_USER=cart_iq
    PARITY_CHAT_DB_PASSWORD=

    # Redis runs as a container on this box (broker only).
    CELERY_BROKER_URL=redis://redis:6379/0
    CELERY_RESULT_BACKEND=django-db
    CELERY_CACHE_BACKEND=django-cache

    # S3 (the EC2 instance profile provides credentials — do NOT set AWS keys).
    AWS_REGION=${var.region}
    AWS_STORAGE_BUCKET_NAME=${aws_s3_bucket.uploads.id}

    # Embedding + parity-chat tuning.
    EMBED_MODEL=gemini-embedding-2
    EMBED_DIMENSIONS=1536
    GEMINI_USE_VERTEX_AI=False
    EMBED_USE_VERTEX_AI=
    PARITY_CHAT_CACHE_ENABLED=False
    ANTHROPIC_RATIONALES_ENABLED=False

    # Scraper tunables (keep SCRAPER_MAX_CONCURRENCY in sync with the scraper
    # worker's --concurrency in docker-compose.app.yml).
    SCRAPER_DEFAULT_PINCODE=110001
    SCRAPER_MAX_CONCURRENCY=3
    SCRAPER_RATE_LIMIT_ENABLED=True
    SCRAPER_LISTING_PARTITION=True

    # ---- Fill these by hand (auth + LLM) -------------------------------------
    SECRET_KEY=__FILL__
    WEBHOOK_SECRET_KEY=__FILL__
    BETTER_AUTH_SECRET=__FILL__
    REQUIRE_EMAIL_VERIFICATION=false
    # AI provider: google | openai | anthropic | groq | together | ollama
    AI_PROVIDER=google
    GOOGLE_API_KEY=__FILL__
    EMBED_GOOGLE_API_KEY=
    PARITY_CHAT_MODEL=anthropic/claude-opus-4-7
  EOT
}
