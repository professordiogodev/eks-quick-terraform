output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "kubernetes_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "region" {
  description = "AWS region the cluster runs in."
  value       = var.region
}

output "vpc_id" {
  description = "ID of the cluster VPC."
  value       = module.vpc.vpc_id
}

output "connect_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --alias ${module.eks.cluster_name}"
}
