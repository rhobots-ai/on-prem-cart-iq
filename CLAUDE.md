# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **deployment-only**: Terraform + a Helm chart + operator scripts to run the cart-iq application stack on a customer-managed AWS account. The application source code (backend Django, web Nuxt, auth, celery workers) lives in **separate repos** — this repo only ships its container images and the infrastructure they run on. Do not look here for app code.

**Two deployment paths** ship the same images:
- **EKS (default)** — `infra/terraform/` + `helm/cart-iq/`; runbook [docs/eks-deployment-guide.md](docs/eks-deployment-guide.md). Most of this file describes this path.
- **EC2 / Docker Compose** — `infra/terraform-ec2/` (ALB + app EC2 + RDS + S3) + `deploy/ec2/` (compose, nginx, `.env` templates); runbook [docs/ec2-deployment-guide.md](docs/ec2-deployment-guide.md). Simpler topology: nginx routes on the app box (not the ALB), Redis is a container (not ElastiCache), DB is direct (no Proxy), secrets are `.env` files (no ESO), identity is one EC2 instance profile (not Pod Identity). Single box — no GPU (cart-iq is API-based; the Playwright scraper runs on the app box CPU). See [docs/decision-log.md](docs/decision-log.md#ec2-path) for the why.

The canonical end-to-end runbook is [docs/eks-deployment-guide.md](docs/eks-deployment-guide.md). When in doubt about a deployment step, check there before reasoning from first principles — it documents the chosen sequence; the why behind non-obvious decisions lives in [docs/decision-log.md](docs/decision-log.md).

## Common commands

Operator workflow runs in this fixed order:

```bash
# 1. Pre-Terraform: verify local tools + AWS creds
AWS_REGION=ap-south-1 ./scripts/preflight.sh

# 2. Provision AWS infra
cd infra/terraform && terraform init && terraform plan -var "domain=$DOMAIN" -var "region=$AWS_REGION" -out tfplan && terraform apply tfplan

# 3. Generate Helm overrides from Terraform outputs (run from repo root)
terraform -chdir=infra/terraform output -raw helm_values_snippet > helm/cart-iq/my-values.yaml

# 4. Seed AWS Secrets Manager (5 SM entries, JSON-shaped, consumed by ESO)
cp scripts/seed-secrets.example.env scripts/seed-secrets.env
$EDITOR scripts/seed-secrets.env          # fill OAuth/LLM keys; DB/Redis are auto-fetched from TF
ENV=prod ./scripts/seed-secrets.sh

# 5. Post-Terraform: verify cloud resources before installing the chart
ENV=prod AWS_REGION=ap-south-1 CLUSTER_NAME=cart-iq-prod \
  DOMAIN=... ACM_CERT_ARN=... RDS_PROXY_ENDPOINT=... REDIS_ENDPOINT=... S3_BUCKET=... \
  ./scripts/verify-infra.sh

# 6. Install the chart
helm install cart-iq ./helm/cart-iq -n cart-iq \
  --values helm/cart-iq/my-values.yaml --atomic --timeout 10m

# Local dev cluster (kind) — for chart iteration only, not a prod analogue
./scripts/create-kind-cluster.sh
```

Helm template debugging: `helm template cart-iq ./helm/cart-iq -f helm/cart-iq/my-values.yaml` (renders without applying). Lint: `helm lint ./helm/cart-iq -f helm/cart-iq/my-values.yaml`.

There is no test suite in this repo — the chart's "tests" are running `verify-infra.sh` then a smoke curl against `/service-api/api/health/`, `/auth/api/auth/ok`, and `/`.

## Architecture in one breath

Single ALB, path-based routing into one namespace (`cart-iq`):

- `/` → **web** (Nuxt SSR, port 3000)
- `/service-api/` → **backend** (Django + gunicorn, port 8000)
- `/auth/` → **auth** (Better Auth, port 10000, image `rhobotsai/auth`)
- **celery** (3 deployments: `default` [queue `celery`], `scraper` [Playwright/Chromium, queues `scraper_listing,scraper`, prefork], `beat` singleton) — workers consume Redis broker, write to Django ORM
- Data plane: **RDS Postgres 16** (via **RDS Proxy**, two logical DBs: `cart_iq` + `auth`), **ElastiCache Redis 7** (broker only), **S3** (uploads)

Identity: **EKS Pod Identity** (not IRSA). Three pod-level roles (`backend`, `celery`, `external-secrets`) plus controller roles (`cluster-autoscaler`, `aws-load-balancer-controller`). All wired in [infra/terraform/main.tf](infra/terraform/main.tf).

Secrets: **External Secrets Operator** projects 5 AWS Secrets Manager paths (`cart-iq/<env>/{backend,db,redis,auth,llm}`) into K8s Secrets. The chart's `secrets.*` map is a *fallback* for kind/dev only — production must use `externalSecrets.enabled: true`.

## Conventions and load-bearing details

- **`my-values.yaml` is the only file an operator edits** — and it is gitignored. Never commit it. The chart's [values.yaml](helm/cart-iq/values.yaml) is the contract; `my-values-yaml.example` shows the minimal override shape.
- **Auto-derivation from `global.domain`**: many `web.public*BaseUrl`, `ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS`, `auth.trustedOrigins`, etc. default to blank and are computed in [_helpers.tpl](helm/cart-iq/templates/_helpers.tpl). Don't hand-set them unless you need a non-derived value — leave blank to let the helper fill it.
- **Image repos auto-derive to ECR** when blank: `<awsAccountId>.dkr.ecr.<awsRegion>.amazonaws.com/cart-iq/{backend,web,scraper}`.
- **The `auth` database is a separate logical DB on the same RDS instance**, created by the `authDbInit` job (postgres:16-alpine). Better Auth then runs its own schema migrations on boot. Django migrations run via the `migrate` pre-install/pre-upgrade Job on the `cart_iq` DB.
- **ECR repos are managed outside Terraform** by design — they outlive any single environment, so `terraform destroy` must not touch them. Comment in [main.tf](infra/terraform/main.tf) is explicit about this.
- **EBS CSI driver is intentionally omitted** from the EKS module: prod has no PVCs (state lives in RDS/ElastiCache/S3). If you ever add a PVC, you must re-enable the addon AND add a Pod Identity association with `AmazonEBSCSIDriverPolicy`.
- **Cluster Autoscaler** discovers ASGs by the `k8s.io/cluster-autoscaler/<cluster>=owned` tags set on the managed node groups. If you rename the cluster, update the discovery tag too or autoscaling silently stops.
- **`require_tls = true`** on the RDS Proxy — clients must connect with SSL. The DB params also enforce `rds.force_ssl=1`.
- **Celery workers run at fixed `replicas`** (no HPA). Resize via `celery.<queue>.replicas`. HPA is enabled only for `backend`/`web`/`auth` (CPU-bound).
- **`celery.beat` is a singleton** — never autoscale, never run >1 replica (would duplicate scheduled tasks).
- **NetworkPolicy is default-deny**. `networkPolicy.allowedEgress.{rdsCidrs,redisCidrs}` must be filled from Terraform outputs (`rds_subnet_cidrs`, `elasticache_subnet_cidrs`) or pods can't reach the data plane.
- **`adminCidrAllowlist`** on the ingress gates `/service-api/admin/*`. Default is deny-all — set it explicitly when granting Django admin access.
- **PodSecurity is `restricted`** on the namespace and the chart's `podSecurity` defaults match (non-root, read-only rootfs, drop ALL caps). New workloads added to the chart must keep these defaults compatible (no privileged init containers, etc.).

## Files / paths to know

- [infra/terraform/main.tf](infra/terraform/main.tf) — all infra in one file (VPC, EKS, RDS+Proxy, ElastiCache, S3, Pod Identity, ESO/LBC/CA roles, ACM). Module wiring lives here, not in `modules/`.
- [infra/terraform/outputs.tf](infra/terraform/outputs.tf) — emits `helm_values_snippet`, the rendered partial that becomes `my-values.yaml`.
- [helm/cart-iq/values.yaml](helm/cart-iq/values.yaml) — canonical configuration contract; read this before editing any template.
- [helm/cart-iq/templates/_helpers.tpl](helm/cart-iq/templates/_helpers.tpl) — domain auto-derivation logic and shared labels.
- [scripts/seed-secrets.sh](scripts/seed-secrets.sh) — refuses to run if `seed-secrets.env` is git-tracked (a real-leak guard); auto-fetches RDS/Redis values from `terraform output`.
- [eks-deployment-guide.md](eks-deployment-guide.md) — the runbook. Appendix A is the env var reference. The decision log explaining *why* choices were made lives in [docs/decision-log.md](docs/decision-log.md).
