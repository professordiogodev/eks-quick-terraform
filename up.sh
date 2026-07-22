#!/usr/bin/env bash
set -euo pipefail

# Disable the AWS CLI's pager — otherwise JSON output from commands open in `less` and blocks the script until you hit q.
export AWS_PAGER=""

# Usage: ./up.sh <your-name>      e.g.  ./up.sh richard
NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "Usage: ./up.sh <your-name>   (e.g. ./up.sh richard)"
  exit 1
fi
REGION="${AWS_REGION:-us-east-1}"

echo ">> Initialising Terraform..."
terraform init -input=false

echo ">> Building your EKS cluster (+ EBS CSI driver). This takes ~15 minutes — go get a coffee."
terraform apply -auto-approve -var="student_name=${NAME}"

echo ">> Connecting kubectl to your cluster..."
aws eks update-kubeconfig --name "eks-${NAME}" --region "${REGION}"

echo ">> Installing Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

echo ">> Waiting for Metrics Server to become ready..."
kubectl rollout status deployment metrics-server -n kube-system --timeout=120s || true

echo ">> Done! Your nodes:"
kubectl get nodes