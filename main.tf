locals {
  cluster_name = "eks-${var.student_name}"

  # Two AZs is the minimum EKS accepts and keeps the subnet count (and cost) low.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

data "aws_availability_zones" "available" {
  # use1-az3 (us-east-1) doesn't support the EKS control plane.
  exclude_zone_ids = ["use1-az3"]

  # Skip Local Zones / Wavelength Zones, which EKS doesn't support.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

check "node_counts" {
  assert {
    condition     = var.min_nodes <= var.desired_nodes && var.desired_nodes <= var.max_nodes
    error_message = "Node counts must satisfy min_nodes <= desired_nodes <= max_nodes."
  }
}

# --- Network ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = "vpc-${var.student_name}"
  cidr = var.vpc_cidr
  azs  = local.azs

  # /24 subnets: 10.0.1.0/24, 10.0.2.0/24 (private) and 10.0.101.0/24, 10.0.102.0/24 (public)
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 1)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 101)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # one NAT gateway instead of one per AZ; fine for a lab, not for production
  enable_dns_hostnames = true

  # Let Kubernetes find the right subnets for public and internal load balancers.
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

# --- EKS cluster + worker nodes ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = var.endpoint_public_access_cidrs
  enable_cluster_creator_admin_permissions = true # whoever runs `terraform apply` gets kubectl admin

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # nodes live in private subnets, reachable only via the NAT

  # Module v21 doesn't let EKS install the default self-managed add-ons, so the
  # core networking ones must be listed here. `before_compute` creates them
  # before the node group, otherwise nodes never become Ready.
  addons = {
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
    metrics-server         = {} # enables `kubectl top` and the HorizontalPodAutoscaler
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.instance_types
      capacity_type  = var.capacity_type

      min_size     = var.min_nodes
      max_size     = var.max_nodes
      desired_size = var.desired_nodes
    }
  }
}

# --- IAM role for the EBS CSI driver (EKS Pod Identity) ---
# The driver creates EBS volumes for PersistentVolumeClaims, so it needs its own
# IAM permissions; the node role alone isn't enough.
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  name            = "ebs-csi-${var.student_name}"
  use_name_prefix = false

  attach_aws_ebs_csi_policy = true
}
