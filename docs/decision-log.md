# Decision Log

Architectural rationale for the cart-iq deployment stack. The runbooks cover the *how*; this file covers the *why*.

- EKS path: [eks-deployment-guide.md](eks-deployment-guide.md)
- EC2 / Docker Compose path: [ec2-deployment-guide.md](ec2-deployment-guide.md)

## EKS path

| Decision | Choice | Rationale |
|---|---|---|
| Ingress | AWS LBC + ALB (single) | ACM-native, WAF/Shield ready, no client body limit, idle timeout up to 4000s |
| TLS | ACM regional cert | Free, auto-renewed, attached to ALB |
| Host topology | Single host, path-based | Preserves Better-Auth same-origin cookies; matches app contract |
| Backend probe path | `/api/health/` | Container-native; `/service-api` prefix only exists at ALB |
| Static files | `collectstatic` baked into image (WhiteNoise) | No S3 writes at build; simplest |
| Migrations | Helm pre-install/pre-upgrade Job | Runs once per release; failure aborts rollout |
| Auth DB | Separate `auth` DB on same RDS instance | Cheaper than two instances; isolation via DB grants |
| DB pooling | RDS Proxy in front of single instance | Multiplexes Django + celery; smooths failover |
| Celery autoscaling | None — fixed `replicas` per queue | Simplest possible; I/O-bound workers make CPU HPA ineffective. Resize via `helm upgrade` when a queue is consistently backlogged |
| Backend autoscaling | HPA on CPU @70% | CPU-bound for synchronous request handling |
| Beat | Deployment replicas=1, Recreate | Singleton enforced by strategy + alert |
| Identity | EKS Pod Identity (not IRSA) | Simpler than OIDC trust dance; AWS recommended for new clusters |
| Secrets | AWS Secrets Manager + ESO | Centralized rotation + audit; no plaintext in Git |
| Cluster auth | EKS access entries | Replaces aws-auth ConfigMap |
| CNI | VPC CNI prefix delegation | Avoids pod IP exhaustion on dense nodes |
| Nodes | Fixed-size managed node groups (system + app) | Simpler ops; predictable cost; resize manually when capacity-bound |
| GitOps | Argo CD pull-based | No long-lived kubeconfig in CI; rollback via git revert |
| Image registry | ECR + pull-through cache | No Docker Hub rate limits; immutable tags |
| Logs | AWS for Fluent Bit → CloudWatch | Single add-on, 30d retention prod |
| Metrics | CloudWatch Container Insights (EKS addon) | Zero pods on cluster, AWS-native; AMP/AMG or self-hosted Prometheus is future work when custom app metrics are needed |
| Backups | RDS automated 7d + manual pre-upgrade | Plus Helm history for app rollback |
| Security baseline | PSA `restricted`, NetworkPolicy default-deny | Defense in depth with minimum operational drag |
| Celery queues (cart-iq retarget) | `default` (queue `celery`) + `scraper` (`scraper_listing,scraper`) + `beat` | Mirrors the app's `CELERY_TASK_ROUTES`; replaced the old insurance queues (`policy_extract`, `commission_intake`) |
| Scraper worker | Separate `cart-iq/scraper` image (Playwright/Chromium), **prefork** pool, `--max-tasks-per-child=20`, `--prefetch-multiplier=1`, writable `/dev/shm` | A hung browser task must be killable by `--time-limit` (threads can't); recycle caps Chromium memory; `/dev/shm` emptyDir keeps `readOnlyRootFilesystem` intact |
| pgvector | Enabled on `cart_iq` by the db-init Job (before migrate) | cart-iq stores embeddings in `vector` columns; the extension must exist before Django migrations |
| Parity-chat DB role | v1 reuses the main `cart_iq` user (`PARITY_CHAT_DB_USER=cart_iq`) | Avoids provisioning a separate read-only role for the first cut; harden later by creating `chat_readonly` |
| GPU node group | Removed | cart-iq uses API-based embeddings/inference; no self-hosted local models. Re-add only for ollama/local inference |
| AWS credentials | Pod Identity only; AWS keys NOT set | `settings.py` declares `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` as required — the app must default them blank, else setting them would break boto3's Pod Identity credential chain |

## EC2 path

- **Single app box, no GPU** — cart-iq uses API-based inference (Gemini/OpenAI/
  Anthropic), not self-hosted models, so there is no GPU box. The heavy worker is
  the Playwright/Chromium scraper, which is CPU-bound and runs on the app box.
  This matches the EKS path, which deliberately omits a GPU node group.
- **pgvector enabled in the bootstrap** — cart-iq stores embeddings in `vector`
  columns; the `authdb` one-shot creates the `auth` DB *and* runs
  `CREATE EXTENSION IF NOT EXISTS vector` on `cart_iq` before migrations, mirroring
  the EKS auth-db-init Job.
- **Auth nginx-sidecar collapsed** — the EKS chart fronts the auth app with an
  nginx sidecar only because its ALB forwards unstripped `/auth/` paths. On EC2
  the app-box nginx already strips `/auth/`, so the auth app is reached directly
  on `:10000` (`PORT=10000`); no sidecar is needed.
- **gunicorn + discrete migrate/authdb steps** — the compose runs gunicorn as the
  backend command and Django migrations as a one-shot `migrate` tool, mirroring
  the EKS chart (gunicorn workload + migrate pre-install Job) rather than an
  image entrypoint that migrates on boot.
- **Redis as a container, not ElastiCache** — the broker holds transient queue
  state only (results live in Postgres); a local container removes a managed
  service and its cost.
- **Direct RDS, no Proxy** — a fixed, small set of services opens few
  connections; RDS Proxy's pooling/failover-muxing buys little here and adds a
  hop. TLS is still enforced.
- **`.env` files, not ESO/Secrets Manager projection** — without Kubernetes
  there is no ESO; instance-local env files are the simplest secure option, with
  SSM Parameter Store available for stricter governance.
- **Instance profile, not Pod Identity** — one IAM role on the box (S3 + ECR +
  SSM) replaces the per-workload Pod Identity roles of the EKS path.
- **nginx does path routing, not the ALB** — keeps ALB config trivial (one TLS
  listener → one target group) and mirrors the `/`, `/service-api`, `/auth`
  split the EKS ingress performs.
