# cart-iq — AWS EC2 + Load Balancer Deployment Guide

This guide covers the **EC2 / Docker Compose** deployment path — a simpler
alternative to the [EKS path](eks-deployment-guide.md) for customers who do not
run Kubernetes. It is both an **architecture reference** and an **operator
runbook**: read §1–§4 to understand what gets built and why, then follow §5–§12
to stand it up.

The whole stack runs on a **single app box** behind an ALB. cart-iq uses
API-based inference (no self-hosted models), so there is no GPU box — the
Playwright scraper worker runs on the app box CPU alongside the other services.

---

## Table of Contents

1. [Overview — EC2 vs EKS](#1-overview-ec2-vs-eks)
2. [Architecture](#2-architecture)
3. [Resource Configuration](#3-resource-configuration)
4. [Security Architecture](#4-security-architecture)
5. [Pre-requisite Checklist](#5-pre-requisite-checklist)
6. [Provision Infra (Terraform)](#6-provision-infra-terraform)
7. [DNS & ACM](#7-dns-acm)
8. [Configure the Instance](#8-configure-the-instance)
9. [Bring Up the Stack](#9-bring-up-the-stack)
10. [Verification](#10-verification)
11. [Upgrades & Rollback](#11-upgrades-rollback)
12. [Failover, Availability & Day-2](#12-failover-availability-day-2)
13. [Cost Reference](#13-cost-reference)
14. [Appendix A — Environment Variables](#appendix-a-environment-variables)
15. [Appendix B — Security Group Rules](#appendix-b-security-group-rules)

---

## 1. Overview — EC2 vs EKS

Both paths run the identical container images (`backend`, `web`, `scraper`,
`auth`) and the same data plane shape (Postgres + Redis + S3). They differ only
in the runtime.

| | **EC2 (this guide)** | **EKS** ([guide](eks-deployment-guide.md)) |
| --- | --- | --- |
| Orchestration | Docker Compose on 1 EC2 box | Kubernetes (Helm chart) |
| Routing | nginx on the app box, behind an ALB | ALB Ingress (LBC) |
| Redis | container on the app box | ElastiCache |
| DB access | direct to RDS (TLS) | RDS Proxy |
| Secrets | `.env` files on the instance | External Secrets Operator + Secrets Manager |
| Identity | one EC2 instance profile | EKS Pod Identity (per-workload roles) |
| Scaling | vertical (resize the box) | HPA + Cluster Autoscaler |
| Best for | single-tenant, low-ops, "looks like on-prem" | multi-tenant, elastic, HA |

Choose EC2 when the customer wants the smallest possible operational surface and
does not need horizontal autoscaling or multi-AZ compute. Choose EKS for
elasticity and high availability.

---

## 2. Architecture

```
                         Internet
                            │
                            ▼
                 ┌──────────────────────┐
                 │   Route 53 ALIAS      │
                 │ cartiq.acmecorp.com   │
                 └──────────┬───────────┘
                            ▼
                 ┌──────────────────────┐
                 │    ALB + ACM cert    │  TLS terminates here; idle_timeout=300s
                 │   :443 → app box :80 │
                 └──────────┬───────────┘
                            ▼  HTTP :80
   ┌──── App EC2 (private subnet) — Docker Compose ──────────────────┐
   │  nginx  /→web  /service-api→backend  /auth→auth                 │
   │  ┌──────┐   ┌──────────┐   ┌──────┐                             │
   │  │ web  │   │ backend  │   │ auth │                             │
   │  │ Nuxt │   │ Django   │   │Better│                             │
   │  │ :3000│   │ :8000    │   │ :10000                             │
   │  └──────┘   └────┬─────┘   └──────┘                             │
   │  celery: default · scraper (Playwright/Chromium) · beat         │
   │  redis (broker, container)                                      │
   └────────┬────────────────────────────────────────────────┬──────┘
            │ :5432 (TLS)                                      │
            ▼                                                  ▼
   ┌──────────────────┐                              ┌────────────┐
   │ RDS Postgres 16  │                              │ S3 bucket  │
   │  cart_iq         │                              │ uploads    │
   │  auth            │                              └────────────┘
   └──────────────────┘
```

**Request flow:** ALB terminates TLS and forwards HTTP to nginx on the app box.
nginx routes by path. The **scraper** celery worker drives Playwright/Chromium to
collect listings/products and writes to RDS; the **default** worker handles
parity/catalogue tasks and the parity-chat pipeline, calling the **LLM** (Gemini
by default) via API. Uploads and artefacts live in S3, reached via the instance
profile.

**Services on the app box (`docker-compose.app.yml`):**

| Service | Purpose |
| --- | --- |
| nginx | Reverse proxy / path routing |
| web | Nuxt SSR dashboard (:3000) |
| backend | Django + gunicorn REST API (:8000) |
| auth | Better Auth — JWT issuance & sessions (:10000) |
| celery_default | General background tasks (queue `celery`) |
| celery_scraper | Playwright/Chromium scraper (queues `scraper_listing,scraper`) |
| beat | Scheduled task runner (singleton) |
| redis | Celery broker (container) |

---

## 3. Resource Configuration

### 3.1 App EC2

| Parameter | Value |
| --- | --- |
| Instance type | `m6i.xlarge` (4 vCPU / 16 GB) — no GPU |
| Root volume | 100 GB gp3, encrypted |
| OS | Ubuntu 24.04 LTS (Noble) |
| Runs | nginx, web, backend, auth, celery (default/scraper/beat), redis |

The scraper worker runs headless Chromium via Playwright. It needs writable
`HOME`/cache dirs (pointed at `/tmp`) and a larger `/dev/shm` (`shm_size: 1gb`)
so Chromium tabs don't crash — both are configured in `docker-compose.app.yml`.
If listing volume grows, raise the scraper `--concurrency` (keep it in sync with
`SCRAPER_MAX_CONCURRENCY`) or resize the box.

### 3.2 RDS — PostgreSQL 16

| Parameter | Value |
| --- | --- |
| Engine | PostgreSQL **16** (the repo standard) |
| Instance | `db.t4g.medium` (configurable), 100 GB gp3, encrypted |
| Availability | Single-AZ (set `rds_multi_az=true` for HA) |
| Backups | Daily, 7-day retention; PITR enabled |
| TLS | Enforced (`rds.force_ssl=1`) |
| Logical DBs | `cart_iq` (app) · `auth` (Better Auth) |
| Extensions | `pgvector` on `cart_iq` (embeddings) — created by the `authdb` bootstrap |

No RDS Proxy — the fixed set of services opens few connections and connects
directly over TLS.

### 3.3 S3 & Redis

- **S3**: one bucket `cart-iq-<env>-ec2-uploads`, SSE-S3, reached via the VPC
  gateway endpoint (no NAT egress cost).
- **Redis**: a container on the app box, broker only — task results persist in
  Postgres (`CELERY_RESULT_BACKEND=django-db`). No ElastiCache.

---

## 4. Security Architecture

- **Identity & access** — Users authenticate via Better Auth (email/password,
  JWT, short-lived tokens). One **EC2 instance profile** grants the box S3
  access, ECR pull, and SSM Session Manager. No long-lived AWS keys on disk —
  `AWS_ACCESS_KEY_ID`/`SECRET` are intentionally unset so boto3 uses the
  instance-profile credentials.
- **Network isolation** — The EC2 box lives in a **private subnet**. Only the
  ALB is public. Security groups are least-privilege:
  - ALB ← internet on 80/443
  - app ← ALB on 80 only
  - RDS ← app on 5432 only
- **TLS coverage**

  | Connection | Protocol |
  | --- | --- |
  | User → ALB | HTTPS / TLS 1.2+ (TLS13 policy) |
  | ALB → nginx (app box) | HTTP, inside the VPC |
  | app box → RDS | TLS (enforced) |
  | app box → LLM API / scraper targets | HTTPS (outbound only) |

- **Secrets** — config lives in `app.env` on the instance (gitignored), not in
  source. For tighter governance you can store the same values in **SSM
  Parameter Store** (SecureString) and render `app.env` at boot — optional, not
  required.

Full SG matrix in [Appendix B](#appendix-b-security-group-rules).

---

## 5. Pre-requisite Checklist

| # | Requirement |
| --- | --- |
| 1 | AWS account + credentials (`aws sts get-caller-identity` works) |
| 2 | Terraform ≥ 1.6, AWS CLI v2 installed locally |
| 3 | A registered domain + Route53 hosted zone (or external DNS you control) |
| 4 | ECR repos exist: `cart-iq/backend`, `cart-iq/web`, `cart-iq/scraper` (managed outside Terraform — they outlive any environment) |
| 5 | Image tags pushed to ECR by CI |
| 6 | OAuth / LLM (Gemini) API keys on hand for the `.env` file |

Set shell vars once per terminal:

```bash
export AWS_REGION=ap-south-1
export DOMAIN=cartiq.acmecorp.com
```

---

## 6. Provision Infra (Terraform)

The EC2 path has its **own Terraform root**: `infra/terraform-ec2/` (separate
from the EKS `infra/terraform/`). Use one or the other per environment.

```bash
cd infra/terraform-ec2
terraform init
terraform plan \
  -var "domain=$DOMAIN" \
  -var "region=$AWS_REGION" \
  -out tfplan
terraform apply tfplan
```

This provisions: VPC (3 AZ, public/private/db subnets, single NAT, S3 gateway
endpoint), the ALB + target group + listeners, the app EC2 instance (with Docker
bootstrapped via cloud-init), the instance profile, RDS Postgres 16, the S3
bucket, and the ACM cert.

Key outputs:

```bash
terraform output alb_dns_name        # point DNS here if not using Route53
terraform output app_private_ip
terraform output rds_master_secret_arn
terraform output -raw app_env_snippet > ../../deploy/ec2/app.env
```

---

## 7. DNS & ACM

- **ACM**: if you did not pass `acm_certificate_arn`, Terraform requested a new
  DNS-validated cert. Create the validation CNAME shown in the ACM console (or
  via `aws acm describe-certificate`) and wait for status **ISSUED**.
- **DNS**: if you passed `route53_zone_id`, Terraform already created the ALIAS
  A-record. Otherwise create a CNAME/ALIAS for `$DOMAIN` → `alb_dns_name` in
  your provider.

---

## 8. Configure the Instance

Connect to the app box via SSM Session Manager (no SSH, no bastion):

```bash
aws ssm start-session --target "$(terraform output -raw app_instance_id)"
```

On the app box:

```bash
# Copy deploy/ec2/ to the box (scp via SSM tunnel, git clone, or S3).
cd /opt/cart-iq/deploy/ec2

# Fill app.env (start from the Terraform snippet, then add secrets).
cp app.env.example app.env   # or use the app_env_snippet output
$EDITOR app.env              # fill DB_PASSWORD (from rds_master_secret_arn), SECRET_KEY,
                             # WEBHOOK_SECRET_KEY, BETTER_AUTH_SECRET, GOOGLE_API_KEY

# Log Docker in to ECR.
source app.env
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
```

Fetch the DB password from the RDS master secret:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw rds_master_secret_arn)" \
  --query SecretString --output text | jq -r .password
```

---

## 9. Bring Up the Stack

First confirm RDS is reachable — a fresh instance can take 5–10 minutes to leave
`creating` after `terraform apply` returns. Wait for status `available`:

```bash
aws rds describe-db-instances --db-instance-identifier cart-iq-${ENV:-prod}-ec2 \
  --query 'DBInstances[0].DBInstanceStatus' --output text
```

Run the two one-shot bootstrap tools once (they live behind the `tools` compose
profile, so they are not part of `up -d`), then start the long-running services:

```bash
# 1. Ensure the `auth` logical DB exists and pgvector is enabled on cart_iq.
docker compose -f docker-compose.app.yml --env-file app.env run --rm authdb

# 2. Run Django migrations against the app DB.
docker compose -f docker-compose.app.yml --env-file app.env run --rm migrate

# 3. Start the stack.
docker compose -f docker-compose.app.yml --env-file app.env up -d
```

`pgvector` must exist before migrations — cart-iq stores embeddings in `vector`
columns (the `authdb` tool enables it, mirroring the EKS auth-db-init Job).
Better Auth runs its own schema migrations on first boot against the `auth` DB.

> **Web `NUXT_PUBLIC_*` URLs are passed at runtime** in `docker-compose.app.yml`
> (derived from `DOMAIN`): `NUXT_PUBLIC_API_BASE_URL=<domain>/service-api`,
> `NUXT_PUBLIC_AUTH_BASE_URL=https://<domain>/auth/api/auth`,
> `NUXT_PUBLIC_APP_BASE_URL=https://<domain>`, `NUXT_PUBLIC_API_SCHEME=https`.

> **No `SCRIPT_NAME`.** The app-box nginx strips the `/service-api` and `/auth`
> prefixes (trailing-slash `proxy_pass`), so the backend serves bare `/api/...`
> paths. The EKS chart sets `SCRIPT_NAME=/service-api` because its ALB does not
> strip; do not set it here. This is also why the EKS auth nginx-sidecar is
> unnecessary on EC2 — the app-box nginx already does the prefix strip.

---

## 10. Verification

```bash
curl -fsS https://$DOMAIN/service-api/api/health/
curl -fsS https://$DOMAIN/auth/api/auth/ok
curl -fsS https://$DOMAIN/ -o /dev/null
```

All three returning 2xx means the deploy is live. Also confirm the ALB target is
healthy:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$(aws elbv2 describe-target-groups \
      --names cart-iq-${ENV:-prod}-app --query 'TargetGroups[0].TargetGroupArn' --output text)"
```

The target-group health check hits `/healthz` (answered directly by nginx).

---

## 11. Upgrades & Rollback

Roll a new image tag:

```bash
# On the app box — bump the tag in app.env, then:
source app.env
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
docker compose -f docker-compose.app.yml --env-file app.env run --rm migrate   # if the release has migrations
docker compose -f docker-compose.app.yml --env-file app.env pull
docker compose -f docker-compose.app.yml --env-file app.env up -d
```

**Rollback**: set the previous tag in `app.env` and re-run `pull` + `up -d`.
Compose recreates only the changed services. For a full-box failure, replace the
instance from its AMI — no DNS, IAM, or SG changes are needed (the ALB
re-registers the new instance once it is healthy).

---

## 12. Failover, Availability & Day-2

| Area | Mechanism |
| --- | --- |
| App health | ALB health check on `/healthz`; unhealthy targets are drained |
| Compute recovery | Replace EC2 from an AMI; re-attach to the target group |
| Database recovery | Daily RDS snapshots + PITR (`rds_multi_az=true` for AZ failover) |
| In-flight tasks | Fail safely; completed results persist in RDS + S3 |

**Day-2 runbooks:**

```bash
# Logs
docker compose -f docker-compose.app.yml logs -f backend
docker compose -f docker-compose.app.yml logs -f celery_scraper

# Restart a service
docker compose -f docker-compose.app.yml --env-file app.env restart backend

# Scale scraper throughput — raise celery_scraper --concurrency (keep
# SCRAPER_MAX_CONCURRENCY in sync) or resize the app box (vertical). No HPA here.
```

---

## 13. Cost Reference

Indicative on-demand monthly cost (ap-south-1, 730 h; excludes data transfer &
LLM API usage):

| Resource | Spec | Notes |
| --- | --- | --- |
| App EC2 | m6i.xlarge | Always-on |
| RDS | db.t4g.medium, 100 GB gp3 | Single-AZ; ~2× for Multi-AZ |
| ALB | 1 ALB | + LCU usage |
| S3 | Standard | Usage-based |
| NAT Gateway | single | Hourly + per-GB |

The single always-on app box plus RDS dominate. LLM usage is billed per-call by
the provider (Gemini/OpenAI/Anthropic) and is not an infra line item.

---

## Appendix A — Environment Variables

Authoritative template: [`deploy/ec2/app.env.example`](../deploy/ec2/app.env.example).

| Variable | Meaning |
| --- | --- |
| `ECR_REGISTRY`, `*_TAG` | Image registry + per-image tags (`BACKEND_TAG`, `WEB_TAG`, `SCRAPER_TAG`, `AUTH_TAG`) |
| `DOMAIN` | Public FQDN; drives derived URLs |
| `ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS`, `HOST_NAME` | Django host/origin allow-lists (include `localhost,127.0.0.1,backend` for the healthcheck) |
| `SECRET_KEY`, `WEBHOOK_SECRET_KEY` | Django secrets |
| `DB_HOST/PORT/USER/PASSWORD/NAME` | RDS connection (`DB_NAME_AUTH` = `auth`); `PARITY_CHAT_DB_*` for the parity-chat read connection |
| `CELERY_BROKER_URL` | `redis://redis:6379/0` (local container); results in Postgres |
| `AWS_REGION`, `AWS_STORAGE_BUCKET_NAME` | S3 uploads (credentials come from the instance profile) |
| `EMBED_MODEL`, `EMBED_DIMENSIONS`, `GEMINI_USE_VERTEX_AI`, `PARITY_CHAT_*` | Embedding + parity-chat tuning |
| `SCRAPER_DEFAULT_PINCODE`, `SCRAPER_MAX_CONCURRENCY`, `SCRAPER_RATE_LIMIT_ENABLED`, `SCRAPER_LISTING_PARTITION` | Scraper tunables |
| `BETTER_AUTH_SECRET` | Better Auth signing secret; auth's `DATABASE_STRING` is composed from `DB_*` + `DB_NAME_AUTH` |
| `REQUIRE_EMAIL_VERIFICATION`, `*_CLIENT_ID/SECRET`, `AWS_SENDER_EMAIL` | Auth OAuth providers + transactional email |
| `NUXT_PUBLIC_ENABLED_SOCIAL_PROVIDERS` | Comma-separated providers surfaced in the web UI |
| `AI_PROVIDER`, `GOOGLE_API_KEY`, `EMBED_GOOGLE_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GROQ_API_KEY`, `TOGETHER_API_KEY`, `OLLAMA_API_BASE` | AI provider selection + keys (only the selected provider's key is read) |

> The Nuxt `NUXT_PUBLIC_*` URLs are passed to the `web` container at runtime in
> `docker-compose.app.yml` (see §9), derived from `DOMAIN`.

---

## Appendix B — Security Group Rules

**ALB SG**

| Dir | Port | Source / Dest |
| --- | --- | --- |
| In | 80, 443 | `0.0.0.0/0` |
| Out | all | `0.0.0.0/0` |

**App SG**

| Dir | Port | Source / Dest |
| --- | --- | --- |
| In | 80 | ALB SG only |
| Out | all | `0.0.0.0/0` (LLM API, ECR, S3, scraper targets, RDS) |

**RDS SG**

| Dir | Port | Source / Dest |
| --- | --- | --- |
| In | 5432 | App SG only |
| Out | all | `0.0.0.0/0` |
