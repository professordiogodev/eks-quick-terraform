variable "student_name" {
  description = "Your name: lowercase letters, digits and hyphens, starting with a letter (keeps your resources unique)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.student_name))
    error_message = "student_name must be 2-21 characters: lowercase letters, digits and hyphens, starting with a letter (e.g. \"richard\")."
  }
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "kubernetes_version" {
  description = "Kubernetes version. Keep it in EKS *standard* support; extended support costs 6x more. Check: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html"
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Each student gets their own VPC, so identical ranges never conflict."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, e.g. 10.0.0.0/16."
  }
}

variable "endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the Kubernetes API endpoint. Narrow this to your own IP (e.g. [\"203.0.113.7/32\"]) for anything beyond a classroom."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "instance_types" {
  description = "EC2 instance types for the worker nodes."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "capacity_type" {
  description = "ON_DEMAND, or SPOT for roughly 60-70% cheaper nodes that AWS may reclaim at short notice."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "desired_nodes" {
  description = "Number of worker nodes to start with. Must be between min_nodes and max_nodes."
  type        = number
  default     = 2
}

variable "min_nodes" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 1

  validation {
    condition     = var.min_nodes >= 0
    error_message = "min_nodes cannot be negative."
  }
}

variable "max_nodes" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 3

  validation {
    condition     = var.max_nodes >= 1
    error_message = "max_nodes must be at least 1."
  }
}

variable "tags" {
  description = "Extra tags to apply to every resource."
  type        = map(string)
  default     = {}
}
