# eks-quick-terraform

Spin an Amazon EKS cluster up for a class or lab session, then tear it down again, with one command each.
It's built on the community [`terraform-aws-modules`](https://github.com/terraform-aws-modules) and set up for **low cost and quick turnaround**, not production.

```bash
./up.sh richard     # ~15 minutes later: a working cluster, kubectl already configured
./down.sh richard   # everything deleted, billing stops
```

## What gets created

```
VPC 10.0.0.0/16  (2 availability zones)
├── public subnets   10.0.101.0/24, 10.0.102.0/24  ── Internet Gateway, NAT Gateway, public load balancers
└── private subnets  10.0.1.0/24,   10.0.2.0/24    ── worker nodes, internal load balancers
                                                       │
EKS control plane (Kubernetes 1.36, public API endpoint)
└── managed node group: 2 × t3.medium, Amazon Linux 2023 (scales 1 to 3)

EKS add-ons: vpc-cni, kube-proxy, coredns, eks-pod-identity-agent,
             aws-ebs-csi-driver (IAM via EKS Pod Identity), metrics-server
```

Every resource is named and tagged after the student (`eks-<name>`, `vpc-<name>`, `Owner=<name>`), so many students can share one AWS account without clashing.

## Cost

Approximate on-demand prices in `us-east-1` with the defaults:

| Resource               | Per hour    |
| ---------------------- | ----------- |
| EKS control plane      | $0.10       |
| 2 × t3.medium nodes    | $0.083      |
| NAT Gateway            | $0.045 + data processed |
| **Total**              | **≈ $0.23/h (≈ $5.50/day)** |

**Run `./down.sh <your-name>` when you finish.** A cluster forgotten over a weekend costs about $15.
Set `capacity_type = "SPOT"` to cut the node cost by roughly two thirds.

## Prerequisites

| Tool | Version | Check |
| --- | --- | --- |
| [Terraform](https://developer.hashicorp.com/terraform/install) | ≥ 1.5.7 | `terraform version` |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | 2.x | `aws --version` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | within one minor version of the cluster | `kubectl version --client` |

You also need AWS credentials that can create VPC, EKS, EC2 and IAM resources (check with `aws sts get-caller-identity`).
The scripts are Bash; on Windows, run them from [WSL](https://learn.microsoft.com/windows/wsl/install).

## Quick start

```bash
git clone https://github.com/professordiogodev/eks-quick-terraform.git
cd eks-quick-terraform

./up.sh <your-name>      # e.g. ./up.sh richard
kubectl get nodes
kubectl top nodes        # metrics-server is installed

./down.sh <your-name>    # same name you used for up.sh
```

`<your-name>` must be 2 to 21 characters of lowercase letters, digits or hyphens, starting with a letter.
To use a region other than `us-east-1`, export it first: `export AWS_REGION=eu-west-1`.

### What the scripts do

**`up.sh`** checks your tools and AWS credentials, selects a Terraform workspace named after you (so each name gets its own state), runs `terraform apply`, configures `kubectl` with a context called `eks-<name>`, and waits for the nodes to be `Ready`.

**`down.sh`** first deletes the AWS resources Kubernetes created behind Terraform's back:

- load balancers from `type: LoadBalancer` Services and Ingresses, which would otherwise block the VPC from being deleted
- EBS volumes from PersistentVolumeClaims, which would otherwise keep costing money

Then it destroys the cluster and removes the VPC endpoint and security group that [GuardDuty Runtime Monitoring](https://docs.aws.amazon.com/guardduty/latest/ug/runtime-monitoring.html) adds to every VPC with an EKS cluster (they'd otherwise make the VPC deletion fail with `DependencyViolation`). Finally it destroys the network, removes your workspace and deletes the `kubectl` context.

## Using Terraform directly

The scripts are a convenience; everything is plain Terraform.

```bash
cp terraform.tfvars.example terraform.tfvars   # set student_name, etc.
terraform init
terraform plan
terraform apply
$(terraform output -raw connect_command)
# ...
terraform destroy   # delete LoadBalancer Services and PVCs first (see down.sh)
```

### Inputs

| Name | Description | Default |
| --- | --- | --- |
| `student_name` | Your name, used to name and tag every resource. **Required.** | |
| `region` | AWS region. | `us-east-1` |
| `kubernetes_version` | EKS Kubernetes version. Keep it in [standard support](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html); extended support costs 6x more. | `1.36` |
| `vpc_cidr` | VPC CIDR block. | `10.0.0.0/16` |
| `endpoint_public_access_cidrs` | CIDRs allowed to reach the Kubernetes API. | `["0.0.0.0/0"]` |
| `instance_types` | Worker node instance types. | `["t3.medium"]` |
| `capacity_type` | `ON_DEMAND` or `SPOT`. | `ON_DEMAND` |
| `desired_nodes` / `min_nodes` / `max_nodes` | Node group size. | `2` / `1` / `3` |
| `tags` | Extra tags for every resource. | `{}` |

### Outputs

| Name | Description |
| --- | --- |
| `cluster_name` | EKS cluster name. |
| `cluster_endpoint` | Kubernetes API endpoint. |
| `kubernetes_version` | Control plane version. |
| `region` | AWS region. |
| `vpc_id` | VPC ID. |
| `connect_command` | Command that configures `kubectl` for the cluster. |

## Design decisions

This repo optimises for a classroom, and makes trade-offs you shouldn't copy into production unchanged:

| Choice here | Why | In production you'd usually... |
| --- | --- | --- |
| Local state, one workspace per student | Zero setup; each student runs from their own clone. | Use a remote backend (S3 with state locking) so state is shared and backed up. |
| Single NAT Gateway | Saves ~$32/month per extra AZ. | Run one NAT Gateway per AZ so losing an AZ doesn't cut off egress. |
| Public API endpoint open to `0.0.0.0/0` | Students connect from anywhere; access still requires valid IAM credentials. | Restrict `endpoint_public_access_cidrs` or use a private endpoint. |
| `-auto-approve` in the scripts | One command, no prompts. | Review `terraform plan` before every apply, ideally in CI. |
| The cluster creator is cluster admin | `kubectl` works immediately. | Grant access explicitly through EKS access entries. |

Things already done the way you'd do them in production: nodes in private subnets, IAM for the EBS CSI driver through EKS Pod Identity (no node-wide permissions), EKS-managed add-ons, pinned module versions and a committed provider lock file, input validation, and default tags on every resource.

## Troubleshooting

**`down.sh` says there's no state for my name.**
You need the same name and the same clone you used for `up.sh`. Check `terraform workspace list`.

**`terraform destroy` hangs on the VPC or subnets.**
Something outside Terraform still uses the network. `down.sh` already removes the usual suspects; if one survives, delete it in the EC2 console and run `./down.sh <name>` again:

- a load balancer created by Kubernetes (*Load Balancers*, tagged `kubernetes.io/cluster/eks-<name>`)
- the GuardDuty endpoint (*VPC → Endpoints*, service `com.amazonaws.<region>.guardduty-data`) and its `GuardDutyManagedSecurityGroup-<vpc-id>` security group

For a lab account you can stop GuardDuty creating these at all: in *GuardDuty → Runtime Monitoring*, turn off **automated agent configuration** for EKS and EC2. GuardDuty itself stays on.

**`kubectl` says `You must be logged in to the server (Unauthorized)`.**
Only the IAM identity that created the cluster is admin. Make sure `aws sts get-caller-identity` shows the same identity you used for `up.sh`.

**Make sure nothing is left behind.**

```bash
aws eks list-clusters --region us-east-1
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
```

## Contributing

Before opening a PR, run `terraform fmt`, `terraform validate`, [TFLint](https://github.com/terraform-linters/tflint) and [ShellCheck](https://www.shellcheck.net/):

```bash
terraform fmt -recursive
terraform init -backend=false && terraform validate
tflint --init && tflint
shellcheck -x up.sh down.sh scripts/common.sh
```
