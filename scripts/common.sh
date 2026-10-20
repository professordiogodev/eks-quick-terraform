# Shared helpers for up.sh and down.sh. Source it, don't run it.
# shellcheck shell=bash

set -euo pipefail

# Stop the AWS CLI from piping output into `less` and blocking the script.
export AWS_PAGER=""
# Keep Terraform output readable in CI logs and non-interactive shells.
export TF_IN_AUTOMATION=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

log() { printf '\033[1;34m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mxx\033[0m %s\n' "$*" >&2
  exit 1
}

# Same rule as the `student_name` validation in variables.tf, checked up front
# so typos fail in a second instead of after `terraform init`.
validate_name() {
  local script="$1" name="$2"
  [[ -n "$name" ]] || die "Usage: ./${script} <your-name>   (e.g. ./${script} richard)"
  [[ "$name" =~ ^[a-z][a-z0-9-]{1,20}$ ]] ||
    die "'${name}' is not a valid name: use 2-21 lowercase letters, digits or hyphens, starting with a letter."
}

require_tools() {
  local tool missing=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  ((${#missing[@]} == 0)) || die "Missing required tools: ${missing[*]} (see Prerequisites in README.md)."
}

require_aws_credentials() {
  local identity
  identity="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)" ||
    die "AWS credentials not found or expired. Run 'aws configure' (or 'aws sso login') first."
  log "AWS identity: ${identity} (region ${REGION})"
}

tf_init() {
  log "Initialising Terraform..."
  terraform init -input=false
}

# True if the default-workspace state file still tracks resources. Clusters
# created before per-student workspaces were introduced live there.
has_legacy_state() {
  [[ -f terraform.tfstate ]] && grep -q '"mode"' terraform.tfstate
}

# Each student gets their own Terraform workspace (and therefore their own
# state file under terraform.tfstate.d/), so running the scripts with two
# different names from one checkout never makes one cluster overwrite another.
#   select_workspace <name> create   -> create the workspace if needed
#   select_workspace <name> existing -> fail if it doesn't exist
select_workspace() {
  local name="$1" mode="$2"
  if terraform workspace select "$name" >/dev/null 2>&1; then
    return 0
  fi
  if has_legacy_state; then
    warn "Found state from an older version of this repo in terraform.tfstate; using it."
    terraform workspace select default >/dev/null
    return 0
  fi
  if [[ "$mode" == "create" ]]; then
    terraform workspace new "$name" >/dev/null
  else
    die "No Terraform state found for '${name}'. Nothing to destroy (or you used a different name with up.sh)."
  fi
}
