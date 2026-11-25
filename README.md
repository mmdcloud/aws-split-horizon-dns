# Multi-Cloud Split-Horizon DNS (AWS & GCP) with Terraform

A production-grade multi-cloud Infrastructure-as-Code (IaC) project implementing **Split-Horizon (Split-View) DNS** across **Amazon Web Services (AWS)** and **Google Cloud Platform (GCP)**, interconnected via a high-availability IPsec VPN with dynamic BGP routing.

---

## 📌 Architecture Overview

```
                           ┌────────────────────────────────────────┐
                           │              PUBLIC INTERNET           │
                           └───────────────────┬────────────────────┘
                                               │ Route 53 Public Zone
                                               ▼
                              ┌───────────────────────────────────┐
                              │   AWS Public ALB (module.aws_lb)  │
                              │   internal.mohitd.xyz / apex      │
                              └───────────────────────────────────┘

═════════════════════════════════════════════════════════════════════════════════════

                                      PRIVATE NETWORK
                ┌──────────────────────────────┴──────────────────────────────┐
                ▼                                                             ▼
      ┌───────────────────────────────────┐                 ┌─────────────────────────────────┐
      │ AWS VPC (10.0.0.0/16)             │                 │ GCP VPC (10.1.0.0/16)           │
      │ Route 53 Private Hosted Zone      │     HA VPN      │ Google Cloud DNS Private Zone   │
      │ internal.mohitd.xyz -> 10.1.20.x  │◄═══════════════►│ internal.mohitd.xyz -> 10.1.20.x│
      │ (Resolves to GCP Internal LB)     │      (BGP)      │ (Resolves to GCP Internal LB)   │
      └───────────────────────────────────┘                 └────────────────┬────────────────┘
                                                                             ▼
                                                            ┌─────────────────────────────────┐
                                                            │ GCP Internal LB (module.gcp_lb) │
                                                            └─────────────────────────────────┘
```

---

## 🚀 Key Features

- **Split-Horizon DNS Routing**:
  - **Public Horizon**: Resolves public queries for `internal.mohitd.xyz` and apex `mohitd.xyz` to an internet-facing **AWS Application Load Balancer** via **AWS Route 53 Public Hosted Zone** Alias records.
  - **Private Horizon (AWS)**: Resolves the same domain queries originating inside the AWS VPC to the private IP of the **GCP Internal Load Balancer** across the HA VPN using an **AWS Route 53 Private Hosted Zone**.
  - **Private Horizon (GCP)**: Resolves internal queries inside the Google Cloud VPC to the **GCP Internal Load Balancer** via a **Google Cloud DNS Private Managed Zone**.
- **Cross-Cloud High Availability Interconnect**:
  - 4-tunnel IPsec HA VPN connection between AWS Virtual Private Gateway (VGW) and GCP HA VPN Gateway.
  - Dynamic route propagation and BGP peering configured with Google Cloud Router.
- **Resilient Compute & Application Tiers**:
  - **AWS**: Multi-AZ Auto Scaling Group (EC2 / Ubuntu 24.04 running NGINX) behind an Application Load Balancer with access logging to S3.
  - **GCP**: Regional Managed Instance Group (MIG / Ubuntu 24.04 running NGINX) fronted by a Regional Internal HTTP Application Load Balancer with an Envoy proxy-only subnet.

---

## 📁 Repository Structure

```text
.
├── terraform/
│   ├── main.tf                    # Core infrastructure: VPCs, HA VPN, Compute, LBs, and Split-Horizon DNS
│   ├── variables.tf               # Input variable declarations
│   ├── terraform.tfvars           # Environment-specific configuration values
│   ├── outputs.tf                 # Exported endpoints, zone IDs, and verification commands
│   ├── provider.tf                # Provider definitions (AWS, Google, Random)
│   ├── scripts/
│   │   ├── aws_user_data.sh       # NGINX bootstrap script for AWS EC2 instances
│   │   └── gcp_user_data.sh       # NGINX bootstrap script for GCP MIG instances
│   └── modules/
│       ├── aws/                   # Reusable modules: vpc, alb, asg, launch_template, s3, security_groups
│       └── gcp/                   # Reusable modules: vpc, lb, mig, instance_template
└── README.md
```

---

## 🛠 Prerequisites

- [Terraform](https://www.terraform.io/) `>= 1.5.0`
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate IAM permissions
- [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk) authenticated with access to your GCP project

---

## ⚙️ Quick Start

1. **Clone the repository**:
   ```bash
   git clone https://github.com/mmdcloud/aws-split-horizon-dns.git
   cd aws-split-horizon-dns/terraform
   ```

2. **Customize variables**:
   Review and adjust settings in `terraform.tfvars`:
   - `aws_region`, `azs`, `public_subnets`, `private_subnets`
   - `gcp_project_id`, `gcp_region`, `gcp_zone`
   - `dns_name`, `dns_zone_name`, `dns_record_prefix`

3. **Initialize and Validate**:
   ```bash
   terraform init
   terraform validate
   ```

4. **Deploy**:
   ```bash
   terraform plan -out=tfplan
   terraform apply tfplan
   ```

5. **Verify BGP Status**:
   ```bash
   $(terraform output -raw bgp_status_command)
   ```

---

## 📄 License

This project is licensed under the Apache 2.0 License.
