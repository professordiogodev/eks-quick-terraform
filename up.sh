#!/usr/bin/env bash
# Create (or update) your EKS cluster.
# Usage: ./up.sh <your-name>      e.g.  ./up.sh richard
source "$(dirname "${BASH_SOURCE[0]}")/scripts/common.sh"

NAME="${1:-}"
validate_name up.sh "$NAME"
CLUSTER_NAME="eks-${NAME}"

require_tools terraform aws kubectl
require_aws_credentials
tf_init
select_workspace "$NAME" create
TF_VARS=(-var "student_name=${NAME}" -var "region=${REGION}")

log "Building ${CLUSTER_NAME}. This takes about 15 minutes, go get a coffee."
terraform apply -input=false -auto-approve "${TF_VARS[@]}"

log "Connecting kubectl to your cluster..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" >/dev/null

log "Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null

log "Done! Your nodes:"
kubectl get nodes -o wide
echo
log "Remember to run ./down.sh ${NAME} when you're finished; the cluster costs money every hour it's up."
