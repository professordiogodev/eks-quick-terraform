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

cleanup_guardduty() {
  local vpc_id="$1" endpoints sg i
  endpoints="$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=service-name,Values=com.amazonaws.${REGION}.guardduty-data" \
    --query "VpcEndpoints[?State!='deleted' && State!='deleting'].VpcEndpointId" --output text)"
  if [[ -n "$endpoints" ]]; then
    log "Removing GuardDuty VPC endpoint(s): ${endpoints}"
    # shellcheck disable=SC2086 # word splitting is intended: one argument per ID
    aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids $endpoints >/dev/null
  fi

  sg="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=GuardDutyManagedSecurityGroup-*" \
    --query 'SecurityGroups[].GroupId' --output text)"
  [[ -n "$sg" ]] || return 0

  # The group stays in use until the endpoint's network interfaces are gone,
  # which takes a minute or two after the endpoint is deleted.
  log "Removing GuardDuty security group ${sg} (waits for the endpoint to finish deleting)..."
  for ((i = 0; i < 30; i++)); do
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 && return 0
    sleep 10
  done
  warn "Could not delete security group ${sg}; the VPC deletion below may fail. Delete it in the EC2 console and re-run."
}

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
  kubectl delete pvc --all --all-namespaces --wait=false
  # A PVC is only released once no pod mounts it, so remove the workload pods too.
  for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    [[ "$ns" == kube-* ]] || kubectl delete pods --all -n "$ns" --wait=false >/dev/null
  done
  if [[ -n "$(kubectl get pv -o name)" ]]; then
    kubectl wait --for=delete pv --all --timeout=180s >/dev/null ||
      warn "Some PersistentVolumes still exist; check for leftover EBS volumes in the EC2 console."
  fi
else
  warn "Cluster ${CLUSTER_NAME} not found in ${REGION}; skipping Kubernetes cleanup."
fi

# Read before anything is destroyed; empty if the state has no VPC.
VPC_ID="$(terraform output -raw vpc_id 2>/dev/null || true)"

log "Destroying the EKS cluster..."
terraform destroy -input=false -auto-approve "${TF_VARS[@]}" -target=module.eks

# GuardDuty Runtime Monitoring (when "automated agent configuration" is on)
# adds a guardduty-data VPC endpoint and security group to every VPC with an
# EKS cluster. Terraform doesn't know about them and GuardDuty doesn't always
# remove them, so they'd make the subnet/VPC deletion fail with
# DependencyViolation. Delete them now that the cluster is gone.
[[ -n "$VPC_ID" ]] && cleanup_guardduty "$VPC_ID"

log "Destroying the network and remaining resources..."
terraform destroy -input=false -auto-approve "${TF_VARS[@]}"

log "Cleaning up local state and kubeconfig..."
if [[ "$(terraform workspace show)" == "$NAME" ]]; then
  terraform workspace select default >/dev/null
  terraform workspace delete "$NAME" >/dev/null
fi
kubectl config delete-context "$CLUSTER_NAME" >/dev/null 2>&1 || true

log "Done. Everything is gone; this cluster no longer costs anything."
