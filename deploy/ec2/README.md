# deploy/ec2 — Docker Compose deployment artifacts

These files run cart-iq on plain EC2 (no Kubernetes), behind an ALB. Full
runbook: [`../../docs/ec2-deployment-guide.md`](../../docs/ec2-deployment-guide.md).

| File | Runs on | Purpose |
| ---- | ------- | ------- |
| `docker-compose.app.yml` | app box | nginx, web, backend, auth, celery (default/scraper/beat), redis |
| `nginx/cart-iq.conf` | app box | path routing `/`→web, `/service-api`→backend, `/auth`→auth |
| `app.env.example` | app box | copy → `app.env`, fill secrets |

> **Never commit `app.env`** — it holds DB passwords, auth secrets, and LLM
> keys. It is gitignored (`deploy/ec2/*.env`).

Quick start (on the app box, after Terraform has provisioned infra):

```bash
terraform -chdir=infra/terraform-ec2 output -raw app_env_snippet > deploy/ec2/app.env
# fill the __FILL__ placeholders, then load the env so $AWS_REGION / $ECR_REGISTRY resolve:
source app.env
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
# one-shot bootstrap: create the auth DB + pgvector, run Django migrations
docker compose -f docker-compose.app.yml --env-file app.env run --rm authdb
docker compose -f docker-compose.app.yml --env-file app.env run --rm migrate
docker compose -f docker-compose.app.yml --env-file app.env up -d
```
