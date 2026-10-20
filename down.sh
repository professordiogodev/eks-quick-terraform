#!/usr/bin/env bash
set -euo pipefail

# Stop the AWS CLI from opening output in a pager and blocking the script.
export AWS_PAGER=""

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

echo ">> Destroying the EKS cluster..."
terraform destroy -auto-approve -var="student_name=${NAME}" -target=module.eks

# GuardDuty Runtime Monitoring (with "automated agent configuration" on) adds a
# guardduty-data VPC endpoint + security group to every VPC with an EKS cluster.
# Terraform doesn't know about them, so the subnet/VPC deletion would fail with
# DependencyViolation. Delete them now that the cluster is gone.
VPC_ID=$(aws ec2 describe-vpcs --region "${REGION}" --filters "Name=tag:Name,Values=vpc-${NAME}" \
  --query 'Vpcs[0].VpcId' --output text)
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  ENDPOINTS=$(aws ec2 describe-vpc-endpoints --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${REGION}.guardduty-data" \
    --query "VpcEndpoints[?State!='deleted' && State!='deleting'].VpcEndpointId" --output text)
  if [ -n "$ENDPOINTS" ]; then
    echo ">> Removing GuardDuty VPC endpoint(s): ${ENDPOINTS}"
    # shellcheck disable=SC2086 # one argument per endpoint ID
    aws ec2 delete-vpc-endpoints --region "${REGION}" --vpc-endpoint-ids $ENDPOINTS >/dev/null
  fi
  SG=$(aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=GuardDutyManagedSecurityGroup-*" \
    --query 'SecurityGroups[].GroupId' --output text)
  if [ -n "$SG" ]; then
    echo ">> Removing GuardDuty security group ${SG} (waits for the endpoint to finish deleting)..."
    for _ in $(seq 1 30); do
      aws ec2 delete-security-group --region "${REGION}" --group-id "$SG" >/dev/null 2>&1 && break
      sleep 10
    done
  fi
fi

echo ">> Destroying the network and remaining resources..."
terraform destroy -auto-approve -var="student_name=${NAME}"

echo ">> Done. Everything is gone. Your bill for this cluster is now \$0."