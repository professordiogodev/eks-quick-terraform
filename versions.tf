terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.59"
    }
  }
}

provider "aws" {
  region = var.region

  # Applied to every taggable resource, so you can always tell who owns what
  # (and filter the bill by student in Cost Explorer).
  default_tags {
    tags = merge(var.tags, {
      Project   = "eks-quick-terraform"
      Owner     = var.student_name
      ManagedBy = "terraform"
    })
  }
}
