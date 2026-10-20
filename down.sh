#!/usr/bin/env bash
# Destroy your EKS cluster and everything that came with it.
# Usage: ./down.sh <your-name>     e.g.  ./down.sh richard
source "$(dirname "${BASH_SOURCE[0]}")/scripts/common.sh"

NAME="${1:-}"
validate_name down.sh "$NAME"
CLUSTER_NAME="eks-${NAME}"

require_tools terraform aws kubectl
require_aws_credentials
tf_init
select_workspace "$NAME" existing
TF_VARS=(-var "student_name=${NAME}" -var "region=${REGION}")

# Kubernetes creates some AWS resources on its own: load balancers for
# `type: LoadBalancer` Services / Ingresses, and EBS volumes for
# PersistentVolumeClaims. Terraform doesn't know about them, so they'd either
# block `terraform destroy` (load balancers hold on to subnets) or keep costing
# money after the cluster is gone (EBS volumes). Delete them while the cluster
# is still around to clean up after itself.
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  log "Connecting kubectl to your cluster..."
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" >/dev/null

  log "Deleting Ingresses and LoadBalancer Services (waits for AWS to remove the load balancers)..."
  kubectl delete ingress --all --all-namespaces --timeout=180s || warn "Some Ingresses could not be deleted."
  kubectl get svc --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
    while read -r ns svc; do
      [[ -n "$svc" ]] || continue
      log "  service ${ns}/${svc}"
      kubectl delete svc "$svc" -n "$ns" --timeout=180s || warn "Could not delete service ${ns}/${svc}."
    done

  log "Deleting PersistentVolumeClaims (so their EBS volumes get deleted too)..."
  kubectl delete pvc --all --all-namespaces --timeout=180s || warn "Some PVCs could not be deleted."
  if [[ -n "$(kubectl get pv -o name)" ]]; then
    kubectl wait --for=delete pv --all --timeout=180s >/dev/null ||
      warn "Some PersistentVolumes still exist; check for leftover EBS volumes in the EC2 console."
  fi
else
  warn "Cluster ${CLUSTER_NAME} not found in ${REGION}; skipping Kubernetes cleanup."
fi

log "Destroying all cluster infrastructure..."
terraform destroy -input=false -auto-approve "${TF_VARS[@]}"

log "Cleaning up local state and kubeconfig..."
if [[ "$(terraform workspace show)" == "$NAME" ]]; then
  terraform workspace select default >/dev/null
  terraform workspace delete "$NAME" >/dev/null
fi
kubectl config delete-context "$CLUSTER_NAME" >/dev/null 2>&1 || true

log "Done. Everything is gone; this cluster no longer costs anything."
