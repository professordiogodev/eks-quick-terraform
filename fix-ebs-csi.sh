#!/usr/bin/env bash
set -euo pipefail

# Disable the AWS CLI's pager — otherwise JSON output from commands like
# `aws iam create-role` opens in `less` and blocks the script until you hit q.
export AWS_PAGER=""

# Usage: ./fix-ebs-csi.sh <your-name>      e.g.  ./fix-ebs-csi.sh richard
#
# Fixes the "aws-ebs-csi-driver addon stuck in CREATE_FAILED" problem by
# creating an IAM role the controller can actually assume (IRSA) and
# re-pointing the addon at it.
NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "Usage: ./fix-ebs-csi.sh <your-name>   (e.g. ./fix-ebs-csi.sh richard)"
  exit 1
fi

REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="eks-${NAME}"
ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole_${NAME}"
SA_NAMESPACE="kube-system"
SA_NAME="ebs-csi-controller-sa"

echo ">> Fixing EBS CSI driver for cluster: ${CLUSTER_NAME} (region ${REGION})"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

OIDC_URL=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_HOST="${OIDC_URL#https://}"
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${PROVIDER_ARN}" >/dev/null 2>&1; then
  echo "!! No IAM OIDC provider found for this cluster (${PROVIDER_ARN})."
  echo "!! This should already exist if the cluster was created by our Terraform config."
  echo "!! Ask your instructor before continuing."
  exit 1
fi

echo ">> Creating/updating IAM role: ${ROLE_NAME}"
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:sub": "system:serviceaccount:${SA_NAMESPACE}:${SA_NAME}",
        "${OIDC_HOST}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF
)

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "${TRUST_POLICY}"
else
  aws iam create-role --role-name "${ROLE_NAME}" --assume-role-policy-document "${TRUST_POLICY}" >/dev/null
fi

aws iam attach-role-policy --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo ">> Checking current addon status..."
CURRENT_STATUS=$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver \
  --region "${REGION}" --query 'addon.status' --output text 2>/dev/null || echo "NOT_FOUND")
echo "   current addon status: ${CURRENT_STATUS}"

case "${CURRENT_STATUS}" in
  NOT_FOUND)
    echo ">> Addon doesn't exist yet — creating it..."
    aws eks create-addon \
      --cluster-name "${CLUSTER_NAME}" \
      --addon-name aws-ebs-csi-driver \
      --service-account-role-arn "${ROLE_ARN}" \
      --region "${REGION}"
    ;;
  CREATING|UPDATING|DELETING)
    # AWS rejects create-addon/update-addon while the addon is mid-transition.
    # If it's already CREATING/UPDATING, the role is very likely already wired
    # up (or about to be) — skip straight to fixing pods below rather than
    # polling and possibly erroring out on a slow transition.
    echo "   addon is already ${CURRENT_STATUS} — skipping create/update call, fixing pods directly."
    ;;
  *)
    echo ">> Updating addon to use the correct IAM role..."
    aws eks update-addon \
      --cluster-name "${CLUSTER_NAME}" \
      --addon-name aws-ebs-csi-driver \
      --service-account-role-arn "${ROLE_ARN}" \
      --resolve-conflicts OVERWRITE \
      --region "${REGION}"
    ;;
esac

echo ">> Connecting kubectl to your cluster..."
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

# Existing controller pods keep running with their OLD identity (no IRSA
# token mounted) even after the service account gets the new role-arn
# annotation — only pods created AFTER the annotation exists pick it up.
# So always force a rollout restart, regardless of the branch taken above.
echo ">> Restarting controller pods so every replica picks up the IAM role..."
kubectl -n kube-system rollout restart deployment ebs-csi-controller
kubectl -n kube-system rollout status deployment ebs-csi-controller --timeout=180s || true

echo ">> Controller pods:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

echo ">> Addon status:"
aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver \
  --region "${REGION}" --query 'addon.status' --output text