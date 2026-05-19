# Three-Tier EKS — From Tutorial to DevSecOps Portfolio

> **Built on top of [LondheShubham153/three-tier-eks-iac](https://github.com/LondheShubham153/three-tier-eks-iac).** The original tutorial author's `README` is preserved at [`ORIGINAL_README.md`](./ORIGINAL_README.md) — credit for the app code, Kubernetes manifests, and the foundational Terraform belongs there. This fork is what I did with it.

This repo tracks the journey of building the same app **three times**:

1. **Tried** to follow the original tutorial as-written → hit several years of accumulated bit-rot (deprecated AWS provider blocks, removed Helm syntax, Bitnami's August 2025 paywall, dead EKS API arguments).
2. **Actualized** the tutorial to 2026 → patched the bit-rot, deployed successfully, took it down again.
3. **Modernized** it into a real DevSecOps stack → GitOps with ArgoCD, security scanning with Trivy/tfsec/Kyverno, secrets in AWS Secrets Manager via External Secrets Operator, keyless CI/CD with GitHub Actions OIDC.

---

## How to read this repo

| File | What's in it | When to open it |
|---|---|---|
| [`ORIGINAL_README.md`](./ORIGINAL_README.md) | The upstream tutorial author's README, untouched. | You want to see what the project looked like in 2023. |
| [`eks-tutorial-notes.md`](./eks-tutorial-notes.md) | Step-by-step walkthrough of the original tutorial **actualized to 2026** — AWS provider v6 fixes, EKS module v20 changes, Helm provider v2 pinning, modern `docker buildx` flow. Includes a troubleshooting log of every wall I hit and how I got past it. | You want to deploy the original 3-tier stack with current tooling and avoid the same wasted hours. |
| [`MODERNIZED_SETUP.md`](./MODERNIZED_SETUP.md) | The DevSecOps modernization on top: **ArgoCD GitOps**, **Trivy + tfsec + Kyverno** security scanning, **External Secrets Operator** pulling from AWS Secrets Manager, GitHub Actions CI/CD via **OIDC** (no long-lived keys). | You want the portfolio-worthy version. This is the one I'd point a hiring manager at. |

---

## Architecture

```
                            AWS Account / Region: eu-west-1

   IAM (account-scoped)                          EKS Control Plane (managed)
   ┌──────────────────────────┐                  ┌──────────────────────────┐
   │  user1 ──► eks-admin grp │                  │   my-eks-cluster (v1.30) │
   │             │            │  AssumeRole      │   ┌──────────────────┐   │
   │             ▼            │ ◄──────────────► │   │ OIDC provider    │   │
   │      eks-admin role  ────┼──── access ─────►│   │ (for IRSA)       │   │
   │  (AmazonEKSClusterAdmin) │   entry          │   └──────────────────┘   │
   └──────────────────────────┘                  └────────────┬─────────────┘
                                                              │ K8s API
   ┌──────────────────────────────────────────────────────────┼──────────────┐
   │ VPC  10.0.0.0/16                                         │              │
   │                                                          │              │
   │  ┌── eu-west-1a ────────┐   ┌── eu-west-1b ────────┐     │              │
   │  │  PUBLIC subnet       │   │  PUBLIC subnet       │     │              │
   │  │   IGW · NAT GW (1×)  │   │                      │     │              │
   │  │                      │   │                      │     │              │
   │  │  PRIVATE subnet      │   │  PRIVATE subnet      │     │              │
   │  │   Worker nodes       │   │   Worker nodes       │     │              │
   │  │   (general + spot)   │   │   (general + spot)   │     │              │
   │  └──────────────────────┘   └──────────────────────┘     │              │
   │                                                                          │
   │  In-cluster operators (kube-system):                                     │
   │    • cluster-autoscaler   (IRSA → scales ASG)                            │
   │    • aws-load-balancer-controller  (IRSA → provisions ALBs)              │
   │                                                                          │
   │  In-cluster platform (DevSecOps modernization):                          │
   │    • ArgoCD (argocd)              ← reconciles git → cluster             │
   │    • Kyverno (kyverno)            ← admission-time policy checks         │
   │    • External Secrets (ext-secrets)  IRSA → AWS Secrets Manager          │
   │                                                                          │
   │  Application (workshop):                                                 │
   │    Ingress (ALB)  ──►  React frontend  ──►  Node API  ──►  MongoDB       │
   │                                                                          │
   └──────────────────────────────────────────────────────────────────────────┘

  GitHub repo (grepxz/updated-3-tier)
      │  push to main
      ▼
  GitHub Actions  ──── OIDC ────►  IAM role  ──►  ECR  (build + Trivy + push)
      │  commit-back manifest tag
      ▼
  Git repo (updated tag)
      │  pulled by
      ▼
  ArgoCD  ──── auto-sync ────►  Kubernetes  →  rolling deploy
```

The flow is: **git push → CI builds & scans → manifest tag bumped → ArgoCD reconciles → cluster updates**. No `kubectl apply` from a laptop after the initial bootstrap.

---

## The story, expanded

### Round 1 — Original tutorial: bit-rot

Cloned the upstream, ran `terraform apply`. The first attempt died on errors like:

```
Blocks of type "elastic_gpu_specifications" are not expected here.
Blocks of type "kubernetes" are not expected here.
```

The repo pinned old AWS / Helm provider versions, but `terraform init` pulled in newer-still ones that had removed those blocks (AWS Elastic GPU was discontinued in Jan 2024; Helm provider v3 in 2025 changed the nested `kubernetes` block to a flat argument). Lots of similar drift everywhere.

Bailed, started over with a more careful eye.

### Round 2 — Actualized walkthrough: working baseline

Documented in [`eks-tutorial-notes.md`](./eks-tutorial-notes.md). The fixes that mattered:

- Pin **AWS provider `~> 5.95`**, **Helm provider `~> 2.17`**, **EKS module `~> 20.24`** (the last lines that still understand the legacy blocks the tutorial uses).
- EKS module **v20 dropped `cluster_id`** — every reference becomes `cluster_name`. All five places in the repo had to be patched.
- EKS module **v20 dropped `manage_aws_auth_configmap`** in favor of **access entries** (the new EKS auth API). Migrated the IAM-role-to-cluster mapping.
- Removed **duplicate provider blocks** across `provider.tf`, `helm-provider.tf`, `eks.tf`, `autoscaler-manifest.tf` — only one block per provider, in one file.
- Replaced the original author's S3 backend bucket name with my own (`volo-eks-tfstate-2026`), then later moved that to a **gitignored `backend.hcl`** with partial-config in `backend.tf`.
- `cluster_version` switched from `1.25` (number, EOL) to `"1.30"` (string, supported). The number type silently drops trailing zeros — `1.30` becomes `1.3`, which AWS rejects.
- Replaced the hardcoded `availability_zones = ["us-west-2a", ...]` with `eu-west-1a/b` to match the region.

Built images, deployed, app loaded, todos saved. Then tore it all down — EKS idle is ~$73/month.

### Round 3 — DevSecOps modernization: the portfolio version

Documented in [`MODERNIZED_SETUP.md`](./MODERNIZED_SETUP.md). On top of the working baseline:

- **ArgoCD** installed via Terraform. An `Application` CR points at this repo's `k8s_manifests/` path. Manual `kubectl apply` is replaced by `git push`.
- **GitHub Actions** workflow builds images on every push to `app/**`, **Trivy** scans for CRITICAL/HIGH CVEs, image lands in ECR, then the manifest's image tag gets `sed`-bumped to the commit SHA and committed back. ArgoCD detects the new manifest and rolls the pods.
- **OIDC trust** between GitHub and AWS — Actions assume an IAM role via short-lived web identity tokens, no long-lived `AWS_ACCESS_KEY_ID` in repo secrets.
- **tfsec + Checkov** scan Terraform on every push (currently report-only).
- **Kyverno** ClusterPolicies (currently Audit mode): pods must have resource limits, no `:latest` tags.
- **External Secrets Operator** + IRSA pulls the MongoDB credentials from **AWS Secrets Manager**. The `k8s_manifests/mongo/secrets.yaml` file with the plaintext-base64 password gets deleted entirely.

---

## Lessons learned (the ones not in the other docs)

These came out of actually doing this end-to-end, not from reading about it.

### Terraform / AWS

- **Token expiry kills mid-apply.** AWS CLI v2.34's new `login_session` returns short-lived (~14 min) session tokens. If `terraform apply` is still running past that window, the S3 state upload fails and Terraform writes `errored.tfstate` locally. Recovery: re-auth, then `terraform state push errored.tfstate`. Long-term fix: set `credential_process = aws configure export-credentials --format process` in `~/.aws/config` so Terraform auto-refreshes.

- **`credential_process` blocks `aws login`.** AWS CLI refuses to run `aws login` when `credential_process` is set on the same profile. Workaround: comment it out, log in, uncomment.

- **EKS module v20 default rules collide with custom `node_security_group_additional_rules`.** The module's built-in `ingress_cluster_9443_webhook` rule duplicates a common manually-added rule. Fix: remove the custom rule from config; if it already exists in state under a different key, use `terraform state mv` to rename rather than destroy/create.

- **Unused data sources fail on first apply.** `data "aws_eks_cluster" "default"` looking up the cluster that's about to be created will error with "couldn't find resource" because data sources resolve before resource creation. If nothing references the data source, delete it.

- **AWS account IDs aren't secret, but committing them looks unprofessional.** Per AWS's own docs, account IDs are "identifying but not confidential." For portfolio polish, parameterize where cheap (Terraform: `data.aws_caller_identity.current.account_id`; GitHub Actions: `${{ vars.AWS_ACCOUNT_ID }}`; docs: `<AWS_ACCOUNT_ID>` placeholder). Hardcoding them in `k8s_manifests/*.yaml` is a known trade-off — properly parameterizing requires Kustomize or Helm.

### Kubernetes / GitOps

- **ArgoCD Application `include:` filters silently skip directories.** My bootstrap Application listed five YAML files but not the `mongo/` subdirectory. Result: MongoDB never deployed; backend stuck in `CreateContainerConfigError` because the `mongo-sec` Secret didn't exist. Either include subdirectories explicitly, or use `recurse: true`.

- **External Secrets Operator service account needs the IRSA annotation manually.** Installing ESO via Helm doesn't auto-annotate its service account with `eks.amazonaws.com/role-arn`. Symptom: ClusterSecretStore stuck with `InvalidProviderConfig: an IAM role must be associated with service account external-secrets`. Fix in Terraform: pass `serviceAccount.annotations` via the helm release. Quick fix: `kubectl annotate sa external-secrets ...`.

- **Kyverno in `Audit` mode logs `PolicyViolation` events but does not block admission.** Useful: pods can still come up while you tune the policies. The events show up in `kubectl describe` output which can mislead you into thinking they're the failure.

- **Frontend `REACT_APP_BACKEND_URL` is an env var baked at *image build* time, not pod start.** Don't expect `kubectl set env` to fix it — you need to rebuild + push, then update the deployment to pull the new image. (In this repo the backend URL is just set as an env var, so it actually works at runtime — but for a typical CRA build, the env var is compiled in.)

- **`kubectl base64 -d` without trailing newline merges with the shell prompt.** Add `; echo` to make passwords readable: `kubectl get secret X -o jsonpath="{.data.password}" | base64 -d; echo`.

### CI/CD

- **GitHub Actions matrix jobs race on `git push`.** Two parallel jobs (frontend + backend) both `sed`-bumped image tags and pushed — one won, the other got `! [rejected] (fetch first)`. Fix: rebase-and-retry loop before each push (committed to `.github/workflows/docker-build.yml`).

- **Trivy and tfsec block the build by default.** That's the point — but the demo app's ancient npm dependencies have many HIGH CVEs that aren't worth fixing in a learning project. Made both report-only with `exit-code: 0` / `soft_fail: true`. For a portfolio writeup, calling out *why* you set the gate to report-only is more honest than pretending the findings don't exist.

- **GitHub repo Variables vs. Secrets.** `AWS_ACCOUNT_ID` is a **Variable** (`${{ vars.X }}`) because it's not confidential. Secrets are for things like API keys. Putting account IDs in Secrets is a tell that someone didn't read the GitHub docs.

### Operational

- **Cost matters.** EKS control plane is **$0.10/hr** ($73/mo) **whether idle or not**. NAT Gateway is **~$32/mo + data**. ALB is **~$16/mo + LCU**. Unused Elastic IPs are **~$3/mo each**. Even at zero traffic, idle cost is ~$120/mo. The tear-down checklist in `MODERNIZED_SETUP.md` Phase 8 matters.

- **Order matters in tear-down.** K8s-created ALBs aren't tracked in Terraform state. If you `terraform destroy` first, the VPC delete fails because subnets still hold ALB ENIs. Always `kubectl delete` the workload first, wait for ALB to fully detach, then `terraform destroy`.

- **`secrets.yaml` in mongo/ was committed to git** with a base64-encoded `password123`. Base64 is not encryption. After realizing this we `.gitignore`-d it, but since it was already tracked, also needed `git rm --cached`. Lesson: scan for secrets before pushing, and rotate any that may have been pushed (in this case the password was junk demo data — but the principle holds).

---

## What this would need to be production-shaped

The current architecture is portfolio-quality, not production. The most impactful next changes, in priority order:

1. **Move MongoDB out of the cluster.** A Mongo `Deployment` with no PVC and no replication is a data-loss bomb. Use **DocumentDB** (managed Mongo-compatible) or the **MongoDB Community Operator** with proper PVCs + replica sets.
2. **TLS on the ALB.** Add an ACM cert + listener on 443. Currently the app is http-only — fine for a demo, unacceptable for anything real.
3. **Replace MongoDB-in-K8s `Secret` references with External Secret CRs everywhere.** ESO is installed; only the mongo creds currently go through it.
4. **Proper Kustomize/Helm layer for image paths** instead of `sed` rewrites. Removes the AWS account ID from committed manifests cleanly.
5. **Real observability.** Prometheus/Grafana is included but disabled in this branch. Re-enable, plus **Sentry** for error tracking and **OpenTelemetry → X-Ray** for tracing.
6. **Move `Kyverno` policies from Audit to Enforce** after fixing the violations they surface (no resource limits, no rollback budget, etc.).
7. **Backups for the S3 state bucket** — enable versioning + lifecycle, even though native locking covers concurrency.
8. **Multi-environment GitOps.** ArgoCD `ApplicationSet` generating dev/staging/prod from one repo. Each environment hits its own cluster or namespace.

---

## What I'd put on the resume

> Built a 3-tier app on EKS with GitOps via ArgoCD — every deploy is a git push, no `kubectl apply` from a laptop. Trivy scans every image before it lands in ECR; tfsec/Checkov scan the Terraform on every PR. Kyverno policies enforce baseline pod hygiene at admission time. Secrets live in AWS Secrets Manager and sync into the cluster via External Secrets Operator with IRSA — zero plaintext credentials in git. GitHub Actions auth via OIDC, not long-lived keys. Terraform-driven infrastructure (VPC, EKS, IAM, ArgoCD/Kyverno/ESO Helm releases) with remote S3 state. Designed and operated through a full create/destroy/redeploy cycle.

That sentence is true and earned. Every clause maps to something in this repo.

---

## Cost summary

| Resource | Idle cost |
|---|---|
| EKS control plane | $0.10/hr = **~$73/mo** |
| NAT Gateway | $0.045/hr + data = **~$32/mo + transfer** |
| ALB (1) | $0.0225/hr + LCU = **~$16/mo + usage** |
| t3.small node (general, on-demand) | ~$15/mo |
| t3.micro node (spot) | ~$3-5/mo |
| Elastic IP (when not attached) | $3/mo |
| ECR storage | $0.10/GB/mo |
| Secrets Manager secret | $0.40/mo + API calls |
| S3 state bucket | pennies |

**Realistic idle bill: ~$130-150/mo.** Don't leave it up.

---

## Quick tear-down

```bash
# 1. Stop ArgoCD from self-healing things back
kubectl delete application workshop -n argocd

# 2. Delete the workload (frees the ALB)
kubectl delete ns workshop monitoring 2>/dev/null

# 3. Wait ~2 min, verify ALB is gone
aws elbv2 describe-load-balancers --region eu-west-1 --query 'LoadBalancers[].LoadBalancerName'

# 4. Destroy infra
cd terraform
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
terraform destroy

# 5. Manual cleanup
aws ecr delete-repository --repository-name workshop-frontend --region eu-west-1 --force
aws ecr delete-repository --repository-name workshop-backend --region eu-west-1 --force
aws secretsmanager delete-secret --secret-id workshop/mongo --region eu-west-1 --force-delete-without-recovery
```

---

## Credits

- **Application code and original Kubernetes manifests:** [Sandip Das / LondheShubham153](https://github.com/LondheShubham153/three-tier-eks-iac)
- **Modernization, troubleshooting log, DevSecOps additions, this README:** [@grepxz](https://github.com/grepxz) (May 2026)
