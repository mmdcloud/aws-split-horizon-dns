# =============================================================================
# Load Balancer Outputs
# =============================================================================
output "aws_lb_dns_name" {
  description = "Public DNS name of the AWS Application Load Balancer."
  value       = module.aws_lb.dns_name
}

output "aws_lb_arn" {
  description = "ARN of the AWS Application Load Balancer."
  value       = module.aws_lb.arn
}

output "gcp_lb_ip_address" {
  description = "Internal IPv4 address of the GCP Load Balancer."
  value       = module.gcp_lb.lb_ip_address
}

# =============================================================================
# Split-Horizon DNS Outputs
# =============================================================================
output "aws_route53_public_zone_id" {
  description = "Zone ID of the AWS Route 53 Public Hosted Zone."
  value       = aws_route53_zone.public.zone_id
}

output "aws_route53_public_name_servers" {
  description = "Authoritative name servers for the AWS Route 53 Public Hosted Zone."
  value       = aws_route53_zone.public.name_servers
}

output "aws_route53_private_zone_id" {
  description = "Zone ID of the AWS Route 53 Private Hosted Zone (AWS VPC)."
  value       = aws_route53_zone.private.zone_id
}

output "gcp_dns_managed_zone_name" {
  description = "Name of the Google Cloud DNS Private Managed Zone (GCP VPC)."
  value       = google_dns_managed_zone.private_zone.name
}

output "gcp_dns_name_servers" {
  description = "Name servers for the Google Cloud DNS Private Managed Zone."
  value       = google_dns_managed_zone.private_zone.name_servers
}

output "split_horizon_public_fqdn" {
  description = "Public FQDN resolved via Route 53 Public Zone to AWS Public ALB."
  value       = aws_route53_record.public_record.fqdn
}

output "split_horizon_private_record_name" {
  description = "Private record name resolved in VPCs to GCP Internal LB IP."
  value       = "${var.dns_record_prefix}.${var.dns_name}"
}

# =============================================================================
# VPN & BGP Verification Outputs
# =============================================================================
output "bgp_status_command" {
  description = "Command to verify all four BGP sessions are Established."
  value       = "gcloud compute routers get-status ${google_compute_router.router.name} --region ${var.gcp_region} --project ${var.gcp_project_id}"
}