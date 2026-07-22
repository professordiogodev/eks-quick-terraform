#!/usr/bin/env bash
set -euo pipefail

# Usage: ./down.sh <your-name>     e.g.  ./down.sh richard
NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "Usage: ./down.sh <your-name>   (e.g. ./down.sh richard)"
  exit 1
fi
REGION="${AWS_REGION:-us-east-1}"

echo ">> Initialising Terraform..."
terraform init -input=false

echo ">> Connecting kubectl to your cluster..."
aws eks update-kubeconfig --name "eks-${NAME}" --region "${REGION}"

# IMPORTANT: Kubernetes "LoadBalancer" services create AWS load balancers that
# Terraform doesn't know about. If you leave them, "terraform destroy" gets stuck
# trying to delete the network. So we delete them first.
echo ">> Removing any LoadBalancer services (Terraform can't see these)..."
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  for svc in $(kubectl get svc -n "$ns" \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{" "}{end}'); do
    echo "   deleting service '$svc' in namespace '$ns' (waiting for the AWS load balancer to actually go away)..."
    kubectl delete svc "$svc" -n "$ns" --timeout=180s || true
  done
done

echo ">> Destroying all cluster infrastructure..."
terraform destroy -auto-approve -var="student_name=${NAME}"

echo ">> Done. Everything is gone. Your bill for this cluster is now \$0."