# Three-Tier EKS Project — Setup Notes & Troubleshooting Log

Notes from walking through [LondheShubham153/three-tier-eks-iac](https://github.com/LondheShubham153/three-tier-eks-iac) in May 2026, with modernizations and fixes for the bit-rot that's accumulated since the tutorial was written.

---

## Table of contents

1. [What the project is](#what-the-project-is)
2. [Helm fundamentals](#helm-fundamentals)
3. [Modernized step-by-step walkthrough](#modernized-step-by-step-walkthrough)
4. [Troubleshooting log](#troubleshooting-log)
   - [Terraform not in Homebrew](#terraform-not-in-homebrew)
   - [Docker Desktop upgrade error](#docker-desktop-upgrade-error)
   - [Can't find the `terraform` command](#cant-find-the-terraform-command)
   - [S3 backend 403 Forbidden](#s3-backend-403-forbidden)
   - [Deprecated AWS provider blocks](#deprecated-aws-provider-blocks)
   - [Provider block structure errors](#provider-block-structure-errors)

---

## What the project is

A classic **three-tier web app** deployed to a managed Kubernetes cluster on AWS:

- **Tier 1 — Frontend:** static HTML/CSS/JS in a container
- **Tier 2 — Backend:** Node.js REST API in a container
- **Tier 3 — Database:** MongoDB running inside the cluster

The point isn't really the app — it's the **deployment pipeline** around it. **Everything is done through the OS terminal**, not the AWS web console. AWS is just the cloud platform where the resources end up living; provisioning and management happen via command-line tools that talk to AWS APIs. That's what "IaC" (Infrastructure as Code) in the repo name means.

### Folders and their tools

| Folder | Tool | What it does |
|---|---|---|
| `terraform/` | Terraform / OpenTofu (HCL, 56% of repo) | Provisions VPC, subnets, IAM roles, and the EKS cluster itself via AWS APIs |
| `app/` | Docker | Frontend and backend source + Dockerfiles. Built locally, pushed to ECR |
| `k8s_manifests/` | kubectl | Kubernetes YAML for MongoDB, backend, frontend, load balancer |

### Required CLIs

- **AWS CLI v2** — authenticate and configure kubeconfig
- **kubectl** — talk to the Kubernetes API of the EKS cluster
- **Helm** — install cluster add-ons (autoscaler, ALB controller, Prometheus/Grafana)
- **Docker** — build and push container images
- **Terraform** (or **OpenTofu**) — provision AWS infrastructure

### End-to-end flow

1. `terraform apply` → AWS spins up the EKS cluster and networking
2. `aws eks update-kubeconfig` → local `kubectl` now points at that cluster
3. `docker build` + `docker push` → images land in ECR
4. `kubectl apply -f k8s_manifests/...` → MongoDB, backend, frontend, load balancer come up
5. The load balancer service exposes a public ALB URL → frontend is reachable

---

## Helm fundamentals

### What Helm is

Helm is a **package manager for Kubernetes** — same idea as `apt` on Ubuntu, `brew` on Mac, or `npm` for Node.js. Instead of writing all the Kubernetes YAML yourself to install something complex, you just say "install Prometheus" and Helm does it.

- A **chart** is a Helm package — a bundle of pre-written Kubernetes YAML templates
- A **chart repository** is a URL on the internet hosting collections of charts
- Each repo has an **index file** that lists every chart and version available

### What `helm repo update` actually does

It's exactly like `apt update` on Linux. It doesn't update any software — it just refreshes the local cache of *what's available* to install.

| Step | Linux (`apt`) | Helm |
|---|---|---|
| Tell it where to look | `/etc/apt/sources.list` | `helm repo add <name> <url>` |
| Refresh the catalog | `apt update` | `helm repo update` |
| Install something | `apt install nginx` | `helm install my-release bitnami/nginx` |

### Why `helm repo update` errored with "no repositories found"

Out of the box Helm v3 ships with **zero repositories** configured. The old "stable" repo was removed years ago. You need to add at least one repo before `update` has anything to refresh.

### Repos you need for this project

```bash
# Cluster Autoscaler — scales worker nodes based on load
helm repo add autoscaler https://kubernetes.github.io/autoscaler

# AWS Load Balancer Controller — creates real AWS ALBs from k8s Service/Ingress objects
helm repo add eks https://aws.github.io/eks-charts

# Prometheus + Grafana — for the monitoring step
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

helm repo update
```

These are all **official repos** published by the projects that own the software. General rule: prefer the official repo from the project itself, fall back to a third-party packager only when there isn't one.

### A note on Bitnami

**Important August 2025 change:** Broadcom moved most of Bitnami's free public Docker images to a "Bitnami Legacy" archive and stopped updating them. Actively-maintained images are now a paid product called "Bitnami Secure Images." Charts themselves are still on GitHub, but many point at images that are frozen or behind a paywall.

For MongoDB on Kubernetes in 2026, prefer the **MongoDB Community Operator** or use managed **AWS DocumentDB**.

---

## Modernized step-by-step walkthrough

### What's changed since the tutorial was written

- **Kubernetes versions:** EKS now supports 1.35 (released Jan 28, 2026). Safe stable pick: **1.34**.
- **EKS Auto Mode** (Dec 2024) automates the cluster autoscaler, ALB controller, EBS CSI driver, and node management.
- **EKS Pod Identity** (late 2023) is now the recommended way to give pods AWS permissions, replacing IRSA for new workloads.
- **`DOCKER_CLI_EXPERIMENTAL=enabled`** is no longer needed — `buildx` has been standard since 2020.
- **Bitnami images** went paid in August 2025.
- **`public.ecr.aws/w8u5e4v2`** in the original README is the original author's namespace. You can't push to it — you need your own ECR repo.

### 0. Prerequisites

```bash
brew install awscli
brew install kubectl
brew install helm
brew install opentofu             # OR: brew tap hashicorp/tap && brew install hashicorp/tap/terraform
brew install --cask docker
```

Then:

```bash
aws configure
# Paste your Access Key ID, Secret Access Key, default region, output: json
```

### 1. Provision the EKS cluster

Before applying, set the Kubernetes version to 1.34 in the repo's variables.

```bash
cd terraform/
terraform init
terraform plan
terraform apply
# ~15–20 minutes
```

### 2. Connect kubectl to the cluster

```bash
aws eks update-kubeconfig --name my-eks-cluster --region eu-west-1
kubectl get nodes
```

### 3. Install cluster add-ons (skip if using EKS Auto Mode)

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=my-eks-cluster \
  --set serviceAccount.create=true

helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=my-eks-cluster \
  --set awsRegion=eu-west-1
```

Then attach IAM permissions using **Pod Identity** (cleaner than IRSA for new clusters):

```bash
aws eks create-addon --cluster-name my-eks-cluster \
  --addon-name eks-pod-identity-agent

aws eks create-pod-identity-association \
  --cluster-name my-eks-cluster \
  --namespace kube-system \
  --service-account aws-load-balancer-controller \
  --role-arn arn:aws:iam::ACCOUNT_ID:role/AWSLoadBalancerControllerRole
```

### 4. Build and push Docker images

Create your own ECR repos first:

```bash
aws ecr create-repository --repository-name workshop-frontend --region eu-west-1
aws ecr create-repository --repository-name workshop-backend --region eu-west-1

aws ecr get-login-password --region eu-west-1 | \
  docker login --username AWS --password-stdin \
  ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com
```

Build and push in one step:

```bash
# Frontend
cd app/frontend
docker buildx build --platform linux/amd64 \
  -t ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/workshop-frontend:v1 \
  --push .

# Backend
cd ../backend
docker buildx build --platform linux/amd64 \
  -t ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/workshop-backend:v1 \
  --push .
```

### 5. Update manifests with your image URLs

In `k8s_manifests/backend-deployment.yaml` and `frontend-deployment.yaml`, replace the `image:` field with your ECR path.

### 6. Deploy to the cluster

```bash
kubectl create ns workshop
kubectl config set-context --current --namespace workshop

cd k8s_manifests/mongo_v1
kubectl apply -f secrets.yaml
kubectl apply -f deploy.yaml
kubectl apply -f service.yaml

cd ..
kubectl apply -f backend-deployment.yaml
kubectl apply -f backend-service.yaml
kubectl apply -f frontend-deployment.yaml
kubectl apply -f frontend-service.yaml
kubectl apply -f full_stack_lb.yaml
```

### 7. Monitoring

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace

# Grafana password (no longer hardcoded as 'prom-operator')
kubectl get secret monitoring-grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 -d

kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# http://localhost:3000, user: admin, password: from above
# Dashboard ID 1860 still works (Node Exporter Full)
```

### 8. Tear down (don't skip — idle EKS is ~$73/month)

```bash
kubectl delete -f k8s_manifests/   # delete the LB first so it doesn't linger
helm uninstall monitoring -n monitoring
cd terraform/
terraform destroy
```

### Portfolio extensions

To make this distinctive in 2026:

1. **EKS Auto Mode comparison** — deploy the same app twice and write up the tradeoffs
2. **Pod Identity instead of IRSA** — implement and explain why
3. **GitHub Actions CI/CD** — auto-build images on push, auto-deploy via ArgoCD or Flux
4. **Security layer** — `tfsec`/Checkov on Terraform, Trivy on images, Kyverno/OPA on the cluster, External Secrets Operator
5. **Replace MongoDB Deployment** with DocumentDB or the MongoDB Community Operator

---

## Quick reference: commands cheat sheet

```bash
# Verify tools are installed
which kubectl helm aws terraform tofu docker
kubectl version --client
helm version
aws --version
terraform version  # or: tofu version

# AWS auth
aws configure
aws sts get-caller-identity   # verify you're authenticated

# Terraform / OpenTofu lifecycle
terraform init       # download providers and modules
terraform plan       # preview changes
terraform apply      # actually create resources
terraform destroy    # tear everything down
rm -rf .terraform .terraform.lock.hcl   # clean slate

# kubectl basics
kubectl get nodes
kubectl get pods -A
kubectl logs -f POD_NAME -n NAMESPACE
kubectl describe pod POD_NAME -n NAMESPACE
kubectl config set-context --current --namespace=workshop

# Helm basics
helm repo add NAME URL
helm repo update
helm repo list
helm search repo KEYWORD
helm install RELEASE CHART -n NAMESPACE
helm list -A
helm uninstall RELEASE -n NAMESPACE

# ECR auth (modern, no DOCKER_CLI_EXPERIMENTAL needed)
aws ecr get-login-password --region REGION | \
  docker login --username AWS --password-stdin \
  ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com

# Build + push in one step
docker buildx build --platform linux/amd64 -t IMAGE_URL --push .
```
