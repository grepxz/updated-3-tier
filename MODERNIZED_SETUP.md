# Modernized 3-Tier EKS Setup (2026)

This is your standard tutorial path **plus three add-ons** that turn it from "I deployed an app" into something you can actually point to in a DevSecOps portfolio:

1. **GitOps with ArgoCD** — deploys come from git pushes, not manual `kubectl apply`
2. **Security scanning** — tfsec/Checkov on infra, Trivy on images, Kyverno policies on the cluster
3. **External Secrets Operator** — secrets live in AWS Secrets Manager, not in K8s YAML

Sections marked **🆕 NEW** are additions to the original tutorial. Everything else is the same baseline you've already done once.

---

## Conventions

- `<AWS_ACCOUNT_ID>` — replace with your 12-digit AWS account number wherever it appears in this doc.
- `<grepxz>` — your GitHub username (or org).
- Before running any command, set both in your shell:
  ```bash
  export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  export AWS_REGION=eu-west-1
  ```
  Then `$AWS_ACCOUNT_ID` works anywhere `<AWS_ACCOUNT_ID>` appears in a code block.
- In **GitHub Actions** workflows, the value comes from `${{ vars.AWS_ACCOUNT_ID }}` — set it once at *Repo → Settings → Secrets and variables → Actions → Variables*.

### Known trade-off

The `k8s_manifests/*-deployment.yaml` files contain literal `<AWS_ACCOUNT_ID>.dkr.ecr.eu-west-1.amazonaws.com/...` image paths. Cleaning that up properly requires Kustomize or Helm — left as a future exercise. AWS treats account IDs as non-confidential (per their docs), so this is a portfolio-hygiene issue rather than a security issue.

---

## Prerequisites (assumed done)

- AWS CLI v2 with `credential_process` configured in `~/.aws/config`
- Docker Desktop installed
- `kubectl`, `helm`, `terraform` installed
- Repo pushed to GitHub (needed for ArgoCD + GitHub Actions)
- Repo Variable `AWS_ACCOUNT_ID` set in GitHub
- `terraform/backend.hcl` exists locally (gitignored — see `backend.hcl.example` for the template)

---

## Phase 0 — Add new files to repo (🆕 NEW, one-time)

Create these **before** `terraform apply` so they're version-controlled.

### 0.1  Three new Terraform files for the add-ons

**`terraform/argocd.tf`**
```hcl
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.7.10"

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
}
```

**`terraform/kyverno.tf`**
```hcl
resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  version          = "3.3.4"
}
```

**`terraform/external-secrets.tf`**
```hcl
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "0.10.5"

  set {
    name  = "installCRDs"
    value = "true"
  }
}

module "external_secrets_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name = "external-secrets"
  role_policy_arns = {
    secrets = aws_iam_policy.external_secrets_read.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_policy" "external_secrets_read" {
  name = "external-secrets-read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = "arn:aws:secretsmanager:eu-west-1:*:secret:workshop/*"
    }]
  })
}
```

### 0.2  GitHub Actions workflows

**`.github/workflows/terraform-scan.yml`**
```yaml
name: Terraform Security Scan
on:
  pull_request:
    paths: ['terraform/**']
  push:
    branches: [main]
    paths: ['terraform/**']

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run tfsec
        uses: aquasecurity/tfsec-action@v1.0.3
        with:
          working_directory: terraform

      - name: Run Checkov
        uses: bridgecrewio/checkov-action@master
        with:
          directory: terraform
          framework: terraform
          soft_fail: true
```

**`.github/workflows/docker-build.yml`**
```yaml
name: Build and Push Images
on:
  push:
    branches: [main]
    paths: ['app/**']

permissions:
  id-token: write
  contents: write

jobs:
  build:
    strategy:
      matrix:
        service: [frontend, backend]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<AWS_ACCOUNT_ID>:role/github-actions-deploy
          aws-region: eu-west-1

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build image
        run: |
          docker buildx build --platform linux/amd64 \
            -t <AWS_ACCOUNT_ID>.dkr.ecr.eu-west-1.amazonaws.com/workshop-${{ matrix.service }}:${{ github.sha }} \
            --load \
            app/${{ matrix.service }}

      - name: Trivy scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: <AWS_ACCOUNT_ID>.dkr.ecr.eu-west-1.amazonaws.com/workshop-${{ matrix.service }}:${{ github.sha }}
          format: table
          severity: CRITICAL,HIGH
          exit-code: 1
          ignore-unfixed: true

      - name: Push image
        run: docker push <AWS_ACCOUNT_ID>.dkr.ecr.eu-west-1.amazonaws.com/workshop-${{ matrix.service }}:${{ github.sha }}

      - name: Update manifest tag
        run: |
          sed -i "s|workshop-${{ matrix.service }}:.*|workshop-${{ matrix.service }}:${{ github.sha }}|" \
            k8s_manifests/${{ matrix.service }}-deployment.yaml
          git config user.name github-actions
          git config user.email github-actions@github.com
          git add k8s_manifests/${{ matrix.service }}-deployment.yaml
          git diff --cached --quiet || git commit -m "ci: bump ${{ matrix.service }} to ${{ github.sha }}"
          git push
```

Note: this workflow uses **OIDC** (not long-lived AWS keys). You'll create the `github-actions-deploy` IAM role + GitHub OIDC provider in Phase 1.

### 0.3  Kyverno starter policies

**`k8s_manifests/kyverno-policies.yaml`**
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: Audit  # change to Enforce when comfortable
  rules:
    - name: validate-resources
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Pods must define CPU and memory limits"
        pattern:
          spec:
            containers:
              - resources:
                  limits:
                    memory: "?*"
                    cpu: "?*"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Audit
  rules:
    - name: validate-image-tag
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Image tag 'latest' is not allowed"
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

### 0.4  ArgoCD bootstrap Application

**`k8s_manifests/argocd-app.yaml`** (replace `grepxz`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: workshop
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/grepxz/updated-3-tier
    targetRevision: main
    path: k8s_manifests
    directory:
      recurse: false
      include: '{backend-deployment.yaml,backend-service.yaml,frontend-deployment.yaml,frontend-service.yaml,full_stack_lb.yaml}'
  destination:
    server: https://kubernetes.default.svc
    namespace: workshop
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 0.5  Replace the static mongo secret with an ExternalSecret

**`k8s_manifests/mongo/external-secret.yaml`** (new — replaces `secrets.yaml`)
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-west-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: mongo-sec
  namespace: workshop
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: mongo-sec
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: workshop/mongo
        property: username
    - secretKey: password
      remoteRef:
        key: workshop/mongo
        property: password
```

Then **delete `k8s_manifests/mongo/secrets.yaml`** — that file becomes obsolete.

Commit all of this to your repo before starting.

---

## Phase 1 — Terraform apply (mostly same)

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
cd terraform
terraform init -upgrade -backend-config=backend.hcl   # backend config now external (gitignored)
terraform apply
```

What gets installed compared to last time:
- ✅ Everything you had (VPC, EKS, node groups, ALB controller, autoscaler)
- 🆕 ArgoCD in `argocd` namespace
- 🆕 Kyverno in `kyverno` namespace
- 🆕 External Secrets Operator + IRSA role in `external-secrets` namespace

Takes ~17-22 min (vs ~15 before — Helm releases add 2-3 min).

---

## Phase 2 — Set up GitHub Actions OIDC (🆕 NEW, one-time, ~5 min)

This lets GitHub push to ECR without long-lived AWS keys. Run once and you're done forever.

> **⚠️ Before running:** the heredoc below contains `<AWS_ACCOUNT_ID>` literally. The shell does NOT substitute it for you. Use `$AWS_ACCOUNT_ID` (no angle brackets) so the shell expands it. Make sure you ran `export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)` first.

```bash
# Create the OIDC provider in AWS (one-time per account)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Create the role GitHub Actions assumes
# Note the heredoc uses unquoted EOF (so $AWS_ACCOUNT_ID expands)
cat > /tmp/trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:grepxz/updated-3-tier:*"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name github-actions-deploy \
  --assume-role-policy-document file:///tmp/trust.json

aws iam attach-role-policy \
  --role-name github-actions-deploy \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
```

Replace `grepxz`. After this, the `docker-build.yml` workflow can push to ECR on every commit.

---

## Phase 3 — Build images (same as original, with Trivy)

If you've already pushed your repo to GitHub with the workflow file in `.github/workflows/`, **just push a commit to `app/`** and GitHub Actions does it for you. Trivy scans the image before pushing — CRITICAL/HIGH CVEs block the build.

If you want to do it locally first (e.g., debugging):

```bash
aws ecr create-repository --repository-name workshop-frontend --region eu-west-1
aws ecr create-repository --repository-name workshop-backend --region eu-west-1

aws ecr get-login-password --region eu-west-1 | \
  docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.eu-west-1.amazonaws.com

cd app/frontend
docker buildx build --platform linux/amd64 -t <AWS_ACCOUNT_ID>.dkr.ecr.eu-west-1.amazonaws.com/workshop-frontend:v1 --push .

cd ../backend
docker buildx build --platform linux/amd64 -t <AWS_ACCOUNT_ID>.dkr.ecr.eu-west-1.amazonaws.com/workshop-backend:v1 --push .

# Optional: scan locally too
trivy image <AWS_ACCOUNT_ID>.dkr.ecr.eu-west-1.amazonaws.com/workshop-frontend:v1
```

---

## Phase 4 — Create the mongo secret in AWS Secrets Manager (🆕 NEW)

Instead of committing credentials to YAML:

```bash
aws secretsmanager create-secret \
  --name workshop/mongo \
  --region eu-west-1 \
  --secret-string '{"username":"admin","password":"changeme-super-secret"}'
```

The ExternalSecret you wrote in Phase 0.5 will pull this into a K8s Secret automatically.

---

## Phase 5 — Bootstrap ArgoCD (🆕 NEW — replaces `kubectl apply -f k8s_manifests/`)

You **don't** `kubectl apply` your app manifests anymore. ArgoCD pulls them from Git.

```bash
aws eks update-kubeconfig --name my-eks-cluster --region eu-west-1

# Apply ONLY the ArgoCD Application — it will sync everything else from git
kubectl apply -f k8s_manifests/argocd-app.yaml

# Apply Kyverno policies (these aren't part of the app)
kubectl apply -f k8s_manifests/kyverno-policies.yaml

# Watch ArgoCD deploy your app
kubectl get applications -n argocd -w
```

Within ~30 seconds you'll see the `workshop` Application go `Synced` and `Healthy`. The mongo deploy, backend, frontend, and load balancer all get created without you running `kubectl apply` on them.

### Optional: open the ArgoCD UI

```bash
# Get the auto-generated admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo

# Port-forward
kubectl port-forward -n argocd svc/argocd-server 8080:443
```

Open `https://localhost:8080`, username `admin`, password from above. You'll see your app as a dependency graph that's auto-syncing from git.

---

## Phase 6 — Verify the GitOps loop works (🆕 NEW)

The whole point of this setup. Try it:

```bash
# Change something in the app code
echo "// updated $(date)" >> app/frontend/src/App.js
git commit -am "test: tiny frontend change"
git push
```

Watch:
1. GitHub Actions runs (`Trivy scan` + `Build and push`)
2. The workflow updates `k8s_manifests/frontend-deployment.yaml` with the new image tag and commits it back
3. ArgoCD detects the manifest change and rolls out the new frontend
4. You did not run a single `kubectl` or `docker` command

That's the loop. It's the part that's actually worth talking about in interviews.

---

## Phase 7 — Verify everything

```bash
kubectl get pods -A
kubectl get applications -n argocd
kubectl get clusterpolicies                  # Kyverno
kubectl get externalsecrets -n workshop      # ESO
kubectl get secret mongo-sec -n workshop -o yaml   # should exist, populated by ESO

# Frontend URL
kubectl get ing -n workshop
```

---

## Teardown (modified)

Order still matters, but with ArgoCD you delete the Application first so it doesn't try to "self-heal" things back:

```bash
# 1. Stop ArgoCD from re-creating things
kubectl delete application workshop -n argocd

# 2. Delete what ArgoCD was managing
kubectl delete ns workshop monitoring 2>/dev/null

# 3. Wait ~2 min for ALB to fully delete, then verify
aws elbv2 describe-load-balancers --region eu-west-1 --query 'LoadBalancers[].LoadBalancerName'

# 4. Tear down infra (this also tears down ArgoCD, Kyverno, ESO since they're in TF now)
cd terraform
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
terraform destroy

# 5. Clean up the bits TF doesn't manage (these were created by hand in Phase 2)
# 5a. IAM role: detach policies first or delete-role refuses
aws iam detach-role-policy --role-name github-actions-deploy \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
aws iam delete-role --role-name github-actions-deploy

# 5b. GitHub OIDC provider (created in Phase 2; not in Terraform)
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com

# 5c. ECR repos (created in Phase 3; not in Terraform)
aws ecr delete-repository --repository-name workshop-frontend --region eu-west-1 --force
aws ecr delete-repository --repository-name workshop-backend --region eu-west-1 --force

# 5d. Secrets Manager (created in Phase 4)
aws secretsmanager delete-secret --secret-id workshop/mongo --region eu-west-1 --force-delete-without-recovery

# 6. Final audit — should all return empty
aws eks list-clusters --region eu-west-1 --query 'clusters'
aws ec2 describe-nat-gateways --region eu-west-1 --filter "Name=state,Values=available,pending"
aws elbv2 describe-load-balancers --region eu-west-1 --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-addresses --region eu-west-1 --query 'Addresses[].PublicIp'
```

### Teardown gotchas (collected the hard way)

**Helm releases of admission controllers hang on destroy.** Kyverno, ArgoCD, and ESO each install admission webhooks that intercept resource changes — including their own deletion. When `terraform destroy` tries to remove the helm release, the webhook blocks the API call, and you get:

```
Error: 1 error occurred: * timed out waiting for the condition
```

Recovery pattern (substitute the release name):

```bash
# Delete the webhooks first so they stop interfering
kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
  -l app.kubernetes.io/instance=kyverno --ignore-not-found

# Force-uninstall the helm release without running cleanup hooks
helm uninstall kyverno -n kyverno --no-hooks

# Force-delete the namespace (clears stuck finalizers)
kubectl get ns kyverno -o json | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/kyverno/finalize" -f -
kubectl delete ns kyverno --force --grace-period=0 --ignore-not-found

# Drop the orphan from Terraform state so destroy stops re-attempting
terraform state rm helm_release.kyverno

# Resume
terraform destroy
```

**`delete-role` fails if policies are still attached.** AWS won't tell you which policies — you have to query first:

```bash
ROLE=github-actions-deploy
for arn in $(aws iam list-attached-role-policies --role-name $ROLE \
  --query 'AttachedPolicies[].PolicyArn' --output text); do
  aws iam detach-role-policy --role-name $ROLE --policy-arn $arn
done
aws iam delete-role --role-name $ROLE
```

**Orphan state entries after partial destroy.** If destroy gets interrupted (auth expiry, Ctrl+C, hang), AWS resources may be deleted but state still references them. Next destroy errors with:

```
Error: reading Security Group (sg-XXX): couldn't find resource
```

Fix — remove the orphans from state. Bulk version for SGs:

```bash
terraform state list | grep -E "security_group" > /tmp/orphans.txt
while IFS= read -r line; do
  terraform state rm "$line"
done < /tmp/orphans.txt
terraform destroy   # now proceeds
```

**`terraform destroy` from the wrong directory says "0 to destroy".** If you're in the repo root instead of `terraform/`, destroy reads an empty state (or no state at all) and reports success. Always `cd terraform` first, and double-check with `terraform state list | wc -l` before celebrating.

**The S3 state bucket stays.** It's gitignored (`backend.hcl`) but the bucket itself in AWS is not part of the Terraform state — Terraform can't destroy what holds its own state. Either keep it (~$0.02/mo, lets you redeploy easily) or delete manually:

```bash
aws s3 rm s3://volo-eks-tfstate-2026 --recursive
aws s3api delete-bucket --bucket volo-eks-tfstate-2026 --region eu-west-1
```

---

## What you'd talk about in interviews

After this, your portfolio story is:

> "I built a 3-tier app on EKS with **GitOps via ArgoCD** — every deploy is a git push, no `kubectl apply` from a laptop. **Trivy** scans every image before it lands in ECR, **tfsec/Checkov** scan the Terraform on every PR, and **Kyverno** policies enforce baseline pod hygiene at admission time. Secrets live in **AWS Secrets Manager** and sync into the cluster via **External Secrets Operator** with IRSA — no plaintext credentials in git."

That's a real DevSecOps story, not "I followed a tutorial."

---

## Quick reference — files that are NEW in this version

```
.github/workflows/terraform-scan.yml         🆕 Checkov + tfsec on PRs
.github/workflows/docker-build.yml           🆕 Build + Trivy + push, auto-update manifests
terraform/argocd.tf                          🆕 ArgoCD Helm release
terraform/kyverno.tf                         🆕 Kyverno Helm release
terraform/external-secrets.tf                🆕 ESO + IRSA role
k8s_manifests/argocd-app.yaml                🆕 Bootstrap Application
k8s_manifests/kyverno-policies.yaml          🆕 Starter cluster policies
k8s_manifests/mongo/external-secret.yaml     🆕 Replaces secrets.yaml
```

And the only file you **delete** from the original:
```
k8s_manifests/mongo/secrets.yaml             ❌ Secrets now in AWS Secrets Manager
```
