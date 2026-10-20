# eks-quick-terraform

Spin an Amazon EKS cluster up for a class or lab session, then tear it down again, with one command each.
It's built on the community [`terraform-aws-modules`](https://github.com/terraform-aws-modules) and set up for **low cost and quick turnaround**, not production.

```bash
./up.sh richard     # ~15 minutes later: a working cluster, kubectl already configured
./down.sh richard   # everything deleted, billing stops
```

## What gets created

```
VPC 10.0.0.0/16  (2 availability zones: us-east-1a, us-east-1b)
├── public subnets   10.0.101.0/24, 10.0.102.0/24  ── Internet Gateway, NAT Gateway, public load balancers
└── private subnets  10.0.1.0/24,   10.0.2.0/24    ── worker nodes, internal load balancers
                                                       │
EKS control plane (Kubernetes 1.33, public API endpoint)
└── managed node group: 2 × t3.medium (scales 1 to 3)

Extras: EBS CSI driver add-on (with its own IAM role via IRSA), Metrics Server
```

Every resource is named after the student (`eks-<name>`, `vpc-<name>`), so several students can share one AWS account without clashing.

## Cost

Approximate on-demand prices in `us-east-1` with the defaults:

| Resource            | Per hour |
| ------------------- | -------- |
| EKS control plane   | $0.10    |
| 2 × t3.medium nodes | $0.083   |
| NAT Gateway         | $0.045 + data processed |
| **Total**           | **≈ $0.23/h (≈ $5.50/day)** |

**Run `./down.sh <your-name>` when you finish.** A cluster forgotten over a weekend costs about $15.

## Prerequisites

| Tool | Check |
| --- | --- |
| [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5 | `terraform version` |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | `aws --version` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | `kubectl version --client` |

You also need AWS credentials that can create VPC, EKS, EC2 and IAM resources (check with `aws sts get-caller-identity`).
The scripts are Bash; on Windows, run them from [WSL](https://learn.microsoft.com/windows/wsl/install).

## Quick start

```bash
git clone https://github.com/professordiogodev/eks-quick-terraform.git
cd eks-quick-terraform
chmod +x up.sh down.sh fix-ebs-csi.sh

./up.sh <your-name>      # e.g. ./up.sh richard
kubectl get nodes
kubectl top nodes        # Metrics Server is installed

./down.sh <your-name>    # same name you used for up.sh
```

Use a short, lowercase name with no spaces. It becomes part of every resource name.

### What the scripts do

| Script | What it does |
| --- | --- |
| `up.sh <name>` | Runs `terraform apply`, points `kubectl` at the new cluster, installs Metrics Server and lists the nodes. |
| `down.sh <name>` | Deletes any `type: LoadBalancer` Services first (Kubernetes creates those load balancers outside Terraform, and they would block the VPC from being deleted), then runs `terraform destroy`. |
| `fix-ebs-csi.sh <name>` | Repairs an EBS CSI driver add-on stuck in `CREATE_FAILED` by (re)creating its IAM role and restarting the controller. Only needed for clusters created before the IRSA fix in `main.tf`. |

## Configuration

Override any variable with `-var` when running Terraform directly, or in a `terraform.tfvars` file (git-ignored):

| Variable | Description | Default |
| --- | --- | --- |
| `student_name` | Your name, used in every resource name. **Required.** | |
| `region` | AWS region. | `us-east-1` |
| `k8s_version` | EKS Kubernetes version. Keep it in [standard support](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html); extended support costs 6x more. | `1.33` |
| `desired_nodes` / `min_nodes` / `max_nodes` | Node group size. | `2` / `1` / `3` |

Outputs: `cluster_name`, and `connect_command` (the command that configures `kubectl`).

## Design decisions

This repo optimises for a classroom and makes trade-offs you shouldn't copy into production unchanged:

| Choice here | Why | In production you'd usually... |
| --- | --- | --- |
| Local state | Zero setup; each student runs from their own clone. | Use a remote backend (S3 with state locking). |
| Single NAT Gateway | Saves ~$32/month per extra AZ. | Run one NAT Gateway per AZ for resilience. |
| Public API endpoint | Students connect from anywhere; access still requires valid IAM credentials. | Restrict the allowed CIDRs or use a private endpoint. |
| `-auto-approve` in the scripts | One command, no prompts. | Review `terraform plan` before every apply. |
| Cluster creator is cluster admin | `kubectl` works immediately. | Grant access explicitly through EKS access entries. |

Done the production way already: worker nodes in private subnets, a dedicated IAM role for the EBS CSI driver instead of node-wide permissions, and pinned module versions.

## Troubleshooting

**`terraform destroy` hangs on the VPC or subnets.**
Something outside Terraform still uses the network, usually a load balancer created by Kubernetes. Find it in the EC2 console under *Load Balancers*, delete it, and run `./down.sh <name>` again.

**`kubectl` says `You must be logged in to the server (Unauthorized)`.**
Only the IAM identity that created the cluster is admin. Make sure `aws sts get-caller-identity` shows the identity you used for `up.sh`.

**EBS CSI add-on stuck in `CREATE_FAILED`.**
Run `./fix-ebs-csi.sh <name>`.

**Make sure nothing is left behind.**

```bash
aws eks list-clusters --region us-east-1
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
```
