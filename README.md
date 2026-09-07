# 🚀 AWS EKS GitOps Microservices Deployment

A production-style microservices deployment project demonstrating **Infrastructure as Code, containerization, CI/CD and GitOps** on AWS.

The project deploys a five-service microservices application to **Amazon EKS** using **Terraform, Docker, Amazon ECR, GitHub Actions, Helm and Argo CD**.

---

## 📌 Project Overview

This project demonstrates an end-to-end DevOps workflow:

```text
Developer
   │
   │ git push
   ▼
GitHub
   │
   ▼
GitHub Actions
   │
   ├── Build Docker images
   │
   └── Push images
        │
        ▼
   Amazon ECR
        │
        ▼
   Update Helm values.yaml
        │
        ▼
      GitHub
        │
        ▼
     Argo CD
        │
        ▼
     Amazon EKS
        │
        ▼
NGINX Ingress Controller
        │
        ▼
AWS Load Balancer
        │
        ▼
   Microservices Application
```

The main goal is to implement a **GitOps-based continuous delivery workflow**, where Kubernetes deployment configuration is maintained in Git and Argo CD continuously reconciles the cluster with the Git repository.

---

# 🏗️ Architecture

The application contains five microservices:

| Service  | Technology         | Port |
| -------- | ------------------ | ---: |
| UI       | Java / Spring Boot | 8080 |
| Catalog  | Go                 | 8081 |
| Cart     | Java / Spring Boot | 8082 |
| Orders   | Java / Spring Boot | 8083 |
| Checkout | Node.js / NestJS   | 8084 |

The services are containerized individually and deployed to Kubernetes using Helm charts.

---

# 🛠️ Technologies Used

### Cloud & Infrastructure

* AWS
* Amazon EKS
* Amazon ECR
* VPC
* IAM
* Security Groups
* Terraform

### Containers & Kubernetes

* Docker
* Kubernetes
* Helm
* NGINX Ingress Controller

### CI/CD & GitOps

* GitHub
* GitHub Actions
* Argo CD

### Application

* Java / Spring Boot
* Go
* Node.js / NestJS

---

# 📂 Project Structure

```text
ArgocdPractice/
│
├── .github/
│   └── workflows/
│       └── deploy.yml
│
└── retail-store-sample-app/
    │
    ├── terraform/
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── locals.tf
    │   ├── security.tf
    │   └── argocd.tf
    │
    ├── argocd/
    │   └── applications/
    │       ├── retail-store-ui.yaml
    │       ├── retail-store-cart.yaml
    │       ├── retail-store-catalog.yaml
    │       ├── retail-store-orders.yaml
    │       └── retail-store-checkout.yaml
    │
    └── src/
        ├── ui/
        │   ├── Dockerfile
        │   ├── src/
        │   └── chart/
        │       ├── Chart.yaml
        │       ├── values.yaml
        │       └── templates/
        │
        ├── catalog/
        │   ├── Dockerfile
        │   └── chart/
        │
        ├── cart/
        │   ├── Dockerfile
        │   └── chart/
        │
        ├── orders/
        │   ├── Dockerfile
        │   └── chart/
        │
        └── checkout/
            ├── Dockerfile
            └── chart/
```

---

# ⚙️ CI/CD Pipeline

The GitHub Actions workflow automates the container build and GitOps manifest update process.

## 1. Source Code

A developer pushes application changes to the `main` branch.

```bash
git add .
git commit -m "Update application"
git push origin main
```

---

## 2. GitHub Actions

GitHub Actions automatically:

1. Checks out the source code
2. Configures AWS credentials
3. Authenticates with Amazon ECR
4. Builds Docker images
5. Tags images using the Git commit SHA
6. Pushes images to ECR

Example image:

```text
866435872216.dkr.ecr.us-east-1.amazonaws.com/retail-store-ui:<GIT_COMMIT_SHA>
```

Using the Git commit SHA provides an immutable reference to the version being deployed.

---

# 🐳 Amazon ECR

Each microservice has its own ECR repository.

```text
retail-store-ui
retail-store-cart
retail-store-catalog
retail-store-orders
retail-store-checkout
```

The CI pipeline pushes a new image whenever application source code changes.

Example:

```text
retail-store-ui:7bbd59f5fba7fadc668c4ddc5267a9f8de2c3e4c
```

---

# 📦 Helm & GitOps

After the Docker image is pushed, GitHub Actions updates the corresponding Helm `values.yaml`.

Example:

```yaml
image:
  repository: <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/retail-store-ui
  pullPolicy: Always
  tag: "<GIT_COMMIT_SHA>"
```

The updated Helm configuration is committed back to the `main` branch.

---

# 🔄 Argo CD

Argo CD monitors the Git repository and the application manifests.

The Argo CD applications use:

```text
Repository: GitHub repository
Branch: main
Path: retail-store-sample-app/src/<service>/chart
```

When GitHub Actions updates the Helm image tag:

```text
Git change
    ↓
Argo CD detects change
    ↓
Application becomes OutOfSync
    ↓
Argo CD synchronizes
    ↓
Kubernetes Deployment updated
    ↓
New Pod created
```

This provides a GitOps-based deployment model where Git acts as the source of truth.

---

# ☸️ Kubernetes Deployment

The services are deployed into the `retail-store` namespace.

Example:

```bash
kubectl get pods -n retail-store
```

The UI is exposed internally through a Kubernetes `ClusterIP` service.

NGINX Ingress provides external access to the application.

```text
AWS Load Balancer
        ↓
NGINX Ingress
        ↓
retail-store-ui Service
        ↓
retail-store-ui Pod
```

---

# 🌐 Application Access

The application is exposed through the NGINX Ingress Controller and its AWS Load Balancer.

Example architecture:

```text
Internet
   ↓
AWS Load Balancer
   ↓
NGINX Ingress Controller
   ↓
retail-store-ui
   ↓
Spring Boot Application
```

---

# 🐛 Troubleshooting Experience

One of the most useful parts of this project was troubleshooting a deployment that appeared to succeed but was still serving an older UI version.

## The Problem

The UI source code contained the new change:

```text
🚀 GitOps Deployment Test
```

GitHub Actions successfully built and pushed a new Docker image to Amazon ECR.

However, the application was still displaying the previous version.

---

## 🔍 Investigation

The deployment was traced layer by layer.

### 1. Check the Git commit

The latest UI change was committed to:

```text
7bbd59f
```

### 2. Check ECR

The corresponding image existed in ECR:

```text
7bbd59f5fba7fadc668c4ddc5267a9f8de2c3e4c
```

So the Docker build and ECR push were successful.

### 3. Check Helm

The Helm `values.yaml` was still referencing:

```text
ffd0cbc3176221456e7dacc78b355e9e61ad4634
```

### 4. Find the root cause

The GitHub Actions manifest-update job was still configured to:

```yaml
ref: gitops
```

and:

```bash
git push origin gitops
```

while Argo CD was monitoring:

```text
main
```

Therefore:

```text
GitHub Actions
      │
      ├── New image → ECR ✅
      │
      └── Helm update → gitops ❌
                         │
                         └── Argo CD was watching main
```

The new image existed, but the GitOps configuration consumed by Argo CD had not been updated.

---

# ✅ Solution

The workflow was updated so that the manifest job uses `main`.

### Checkout

```yaml
with:
  ref: main
  fetch-depth: 0
```

### Push

```yaml
- name: Push changes to GitHub
  run: git push origin main
```

The final workflow became:

```text
Application change
       ↓
      main
       ↓
GitHub Actions
       ↓
Build & Push image
       ↓
      ECR
       ↓
Update Helm values
       ↓
      main
       ↓
    Argo CD
       ↓
      EKS
       ↓
NGINX Ingress
       ↓
 Application
```

After the fix, the new UI version was successfully deployed and became accessible through the AWS Load Balancer.

---

# 🧠 Key Learnings

This project provided hands-on experience with:

* Infrastructure as Code using Terraform
* AWS EKS
* Docker containerization
* Amazon ECR
* GitHub Actions CI/CD
* Kubernetes deployments
* Helm charts
* GitOps principles
* Argo CD
* NGINX Ingress
* AWS Load Balancers
* Debugging CI/CD pipelines
* Debugging Git branch and deployment mismatches

### Most important lesson

A successful CI pipeline does not automatically mean the application is running the new version.

For GitOps deployments, every layer needs to be verified:

```text
Source Code
    ↓
Git Commit
    ↓
CI Pipeline
    ↓
Docker Image
    ↓
Container Registry
    ↓
Helm Manifest
    ↓
Git Branch
    ↓
Argo CD
    ↓
Kubernetes
    ↓
Ingress
    ↓
Application
```

Tracing the deployment through each layer makes troubleshooting much easier.

---

# 🚀 Future Improvements

Possible improvements for this project include:

* Add Prometheus and Grafana monitoring
* Add centralized logging
* Add automated testing to the CI pipeline
* Add security scanning for container images
* Add Terraform remote state management
* Add environment-specific deployments
* Add automated rollback strategies
* Add HTTPS with cert-manager and a custom domain

---

# 👨‍💻 Project

**Repository:** `NikhilBCA2022/ArgocdPractice`

This project was built as a hands-on implementation of modern **DevOps, Kubernetes and GitOps practices on AWS**.

