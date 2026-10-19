# =============================================================================
# AWS <-> GCP HA VPN (4 tunnels, BGP) + GCP external LB -> hybrid NEG -> AWS NLB
# =============================================================================
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# Tunnel topology
# -----------------------------------------------------------------------------
locals {
  vpn_tunnels = {
    "0-1" = { conn = "0", aws_tunnel = 1, gcp_interface = 0, peer_interface = 0 }
    "0-2" = { conn = "0", aws_tunnel = 2, gcp_interface = 0, peer_interface = 1 }
    "1-1" = { conn = "1", aws_tunnel = 1, gcp_interface = 1, peer_interface = 2 }
    "1-2" = { conn = "1", aws_tunnel = 2, gcp_interface = 1, peer_interface = 3 }
  }

  aws_vpn_connections = {
    "0" = aws_vpn_connection.vpn_conn_0
    "1" = aws_vpn_connection.vpn_conn_1
  }
}

# One PSK per tunnel. AWS rejects PSKs starting with "0", so prefix with a letter.
resource "random_password" "psk" {
  for_each = local.vpn_tunnels
  length   = 32
  special  = false
}

locals {
  psk = { for k, v in random_password.psk : k => "vpn_${v.result}" }
}

# -----------------------------------------------------------------------------
# VPN Configuration
# -----------------------------------------------------------------------------
module "gcp_vpc" {
  source                          = "./modules/gcp/vpc"
  vpc_name                        = "gcp-vpc"
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  subnets = [
    {
      name                     = "workload-subnet"
      region                   = var.gcp_region
      purpose                  = "PRIVATE"
      role                     = "ACTIVE"
      private_ip_google_access = true
      ip_cidr_range            = "10.10.1.0/24"
    },
    {
      name                     = "hybrid-neg-subnet"
      region                   = var.gcp_region
      purpose                  = "PRIVATE"
      role                     = "ACTIVE"
      private_ip_google_access = true
      ip_cidr_range            = "10.20.1.0/24"
    }
  ]
  firewall_data = [
    {
      name          = "allow-from-aws"
      description   = "Allow web/ICMP traffic from the AWS VPC"
      direction     = "INGRESS"
      priority      = 1000
      source_ranges = ["10.0.0.0/16"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["80", "443"]
        },
        {
          protocol = "icmp"
        }
      ]
    },
    {
      name          = "allow-health-checks"
      description   = "Allow Google Cloud Load Balancer health check probes"
      direction     = "INGRESS"
      priority      = 1000
      source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["80", "443"]
        }
      ]
    }
  ]
}

resource "google_compute_router" "router" {
  name    = "cr-ha-vpn"
  region  = var.gcp_region
  network = module.gcp_vpc.vpc_name

  bgp {
    asn               = 64514
    advertise_mode    = "CUSTOM"
    advertised_groups = ["ALL_SUBNETS"]

    # Advertise the Google LB / health-check source ranges so AWS routes return
    # traffic for them back over the VPN.
    dynamic "advertised_ip_ranges" {
      for_each = toset(var.gcp_lb_source_cidrs)
      content {
        range       = advertised_ip_ranges.value
        description = "Google Cloud LB / health check source range"
      }
    }
  }
}

resource "google_compute_ha_vpn_gateway" "ha_gateway" {
  name    = "gcp-ha-vpn-gw"
  region  = var.gcp_region
  network = module.gcp_vpc.vpc_name
}

module "aws_vpc" {
  source                  = "./modules/aws/vpc"
  vpc_name                = "aws-vpc"
  vpc_cidr                = "10.0.0.0/16"
  azs                     = var.azs
  public_subnets          = var.public_subnets
  private_subnets         = var.private_subnets
  enable_dns_hostnames    = true
  enable_dns_support      = true
  create_igw              = true
  map_public_ip_on_launch = true
  enable_nat_gateway      = true
  single_nat_gateway      = true
  one_nat_gateway_per_az  = false
  tags                    = var.tags
}

resource "aws_vpn_gateway" "vpn_gw" {
  vpc_id          = module.aws_vpc.vpc_id
  amazon_side_asn = 64512

  tags = {
    Name = "aws-vgw-gcp"
  }
}

resource "aws_vpn_gateway_route_propagation" "route_propagation" {
  vpn_gateway_id = aws_vpn_gateway.vpn_gw.id
  route_table_id = module.aws_vpc.vpc_main_route_table_id
}

resource "aws_vpn_gateway_route_propagation" "private" {
  count          = length(module.aws_vpc.private_route_table_ids)
  vpn_gateway_id = aws_vpn_gateway.vpn_gw.id
  route_table_id = module.aws_vpc.private_route_table_ids[count.index]
}

resource "aws_customer_gateway" "gcp_cgw_0" {
  bgp_asn    = google_compute_router.router.bgp[0].asn
  ip_address = google_compute_ha_vpn_gateway.ha_gateway.vpn_interfaces[0].ip_address
  type       = "ipsec.1"

  tags = {
    Name = "gcp-customer-gw-0"
  }
}

resource "aws_customer_gateway" "gcp_cgw_1" {
  bgp_asn    = google_compute_router.router.bgp[0].asn
  ip_address = google_compute_ha_vpn_gateway.ha_gateway.vpn_interfaces[1].ip_address
  type       = "ipsec.1"

  tags = {
    Name = "gcp-customer-gw-1"
  }
}

resource "aws_vpn_connection" "vpn_conn_0" {
  vpn_gateway_id      = aws_vpn_gateway.vpn_gw.id
  customer_gateway_id = aws_customer_gateway.gcp_cgw_0.id
  type                = "ipsec.1"
  static_routes_only  = false

  tunnel1_inside_cidr   = "169.254.10.0/30"
  tunnel1_preshared_key = local.psk["0-1"]
  tunnel1_ike_versions  = ["ikev2"]

  tunnel2_inside_cidr   = "169.254.10.4/30"
  tunnel2_preshared_key = local.psk["0-2"]
  tunnel2_ike_versions  = ["ikev2"]

  tags = {
    Name = "aws-to-gcp-conn-0"
  }
}

resource "aws_vpn_connection" "vpn_conn_1" {
  vpn_gateway_id      = aws_vpn_gateway.vpn_gw.id
  customer_gateway_id = aws_customer_gateway.gcp_cgw_1.id
  type                = "ipsec.1"
  static_routes_only  = false

  tunnel1_inside_cidr   = "169.254.11.0/30"
  tunnel1_preshared_key = local.psk["1-1"]
  tunnel1_ike_versions  = ["ikev2"]

  tunnel2_inside_cidr   = "169.254.11.4/30"
  tunnel2_preshared_key = local.psk["1-2"]
  tunnel2_ike_versions  = ["ikev2"]

  tags = {
    Name = "aws-to-gcp-conn-1"
  }
}

resource "google_compute_external_vpn_gateway" "external_gw" {
  name            = "peer-gw"
  redundancy_type = "FOUR_IPS_REDUNDANCY"

  interface {
    id         = 0
    ip_address = aws_vpn_connection.vpn_conn_0.tunnel1_address
  }

  interface {
    id         = 1
    ip_address = aws_vpn_connection.vpn_conn_0.tunnel2_address
  }

  interface {
    id         = 2
    ip_address = aws_vpn_connection.vpn_conn_1.tunnel1_address
  }

  interface {
    id         = 3
    ip_address = aws_vpn_connection.vpn_conn_1.tunnel2_address
  }
}

resource "google_compute_vpn_tunnel" "tunnel" {
  for_each = local.vpn_tunnels

  name                            = "ha-vpn-tunnel-${each.key}"
  region                          = var.gcp_region
  vpn_gateway                     = google_compute_ha_vpn_gateway.ha_gateway.id
  vpn_gateway_interface           = each.value.gcp_interface
  peer_external_gateway           = google_compute_external_vpn_gateway.external_gw.id
  peer_external_gateway_interface = each.value.peer_interface
  shared_secret                   = local.psk[each.key]
  router                          = google_compute_router.router.id
  ike_version                     = 2
}

resource "google_compute_router_interface" "interface" {
  for_each = local.vpn_tunnels

  name       = "cr-interface-${each.key}"
  router     = google_compute_router.router.name
  region     = var.gcp_region
  ip_range   = "${local.aws_vpn_connections[each.value.conn]["tunnel${each.value.aws_tunnel}_cgw_inside_address"]}/30"
  vpn_tunnel = google_compute_vpn_tunnel.tunnel[each.key].name
}

resource "google_compute_router_peer" "bgp_peer" {
  for_each = local.vpn_tunnels

  name                      = "bgp-peer-${each.key}"
  router                    = google_compute_router.router.name
  region                    = var.gcp_region
  peer_ip_address           = local.aws_vpn_connections[each.value.conn]["tunnel${each.value.aws_tunnel}_vgw_inside_address"]
  peer_asn                  = aws_vpn_gateway.vpn_gw.amazon_side_asn
  interface                 = google_compute_router_interface.interface[each.key].name
  advertised_route_priority = 100
}

# -----------------------------------------------------------------------------------------
# GCP Application configuration
# -----------------------------------------------------------------------------------------
module "instance_template" {
  source = "./modules/gcp/launch-template"

  region     = var.producer_region
  project_id = data.google_project.project.project_id

  name_prefix       = var.instance_template_name_prefix
  machine_type      = var.instance_template_machine_type
  source_image      = data.google_compute_image.ubuntu_2404.self_link
  boot_disk_size_gb = var.boot_disk_size_gb
  boot_disk_type    = var.boot_disk_type

  network          = module.producer_vpc.self_link
  subnetwork       = module.producer_vpc.subnets_by_name[var.mig_subnet_name].self_link
  assign_public_ip = false
  network_tags     = [var.producer_instance_tag]

  create_service_account = true
  service_account_roles  = var.service_account_roles

  startup_script = templatefile("${path.module}/scripts/user_data.sh", {})

  labels = var.common_labels
}

module "mig" {
  source = "./modules/gcp/mig"

  project_id = var.project_id
  name       = var.mig_name
  region     = var.producer_region

  instance_template = module.instance_template.self_link_unique

  named_ports = [
    { name = var.mig_named_port_name, port = var.mig_named_port_number }
  ]

  health_check = {
    type         = var.mig_health_check_type
    port         = var.mig_health_check_port
    request_path = var.mig_health_check_request_path
  }

  autoscaling_enabled = true
  autoscaler_name     = "mig-autoscaler"
  min_replicas        = var.mig_autoscaling_min_replicas
  max_replicas        = var.mig_autoscaling_max_replicas

  labels = var.common_labels
}

module "lb" {
  source             = "./modules/gcp/lb"
  project_id         = var.project_id
  name               = var.lb_name
  load_balancer_type = var.lb_type
  region             = var.producer_region
  network            = module.producer_vpc.self_link
  subnetwork         = module.producer_vpc.subnets_by_name[var.lb_subnet_name].self_link

  create_proxy_only_subnet = true
  proxy_only_subnet_cidr   = var.proxy_only_subnet_cidr

  backends = {
    lb = {
      is_default          = true
      protocol            = var.lb_backend_protocol
      port_name           = var.lb_backend_port_name
      health_check_id     = module.mig.health_check_id
      manage_health_check = false
      groups = [
        {
          group           = module.mig.instance_group_self_link
          balancing_mode  = var.lb_balancing_mode
          capacity_scaler = var.lb_capacity_scaler
          max_utilization = var.lb_max_utilization
        }
      ]
    }
  }

  allow_global_access     = var.lb_allow_global_access
  enable_ssl              = var.lb_enable_ssl
  enable_http             = var.lb_enable_http
  managed_ssl_certificate = var.lb_managed_ssl_certificate
  enable_cloud_armor      = var.lb_enable_cloud_armor
  depends_on              = [module.mig]
}

# -----------------------------------------------------------------------------------------
# AWS Application configuration ( Public Application)
# -----------------------------------------------------------------------------------------
resource "aws_iam_role" "ec2_role" {
  name = var.ec2_role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_instance_profile" "iam_instance_profile" {
  name = "${var.ec2_role}-instance-profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

locals {
  lb_logs_bucket_name = "lb-logs-${random_id.id.hex}"
}

data "aws_elb_service_account" "elb_service_account" {}

module "aws_launch_template" {
  source                               = "./modules/aws/launch_template"
  name                                 = "launch_template"
  description                          = "launch_template"
  ebs_optimized                        = true
  image_id                             = data.aws_ami.ubuntu.id
  instance_type                        = var.instance_type
  instance_initiated_shutdown_behavior = "terminate"
  instance_profile_name                = aws_iam_instance_profile.iam_instance_profile.name

  network_interfaces = [
    {
      associate_public_ip_address = false
      security_groups             = [module.asg_sg.id]
    }
  ]

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Enforces IMDSv2
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  user_data = base64encode(templatefile("${path.module}/scripts/user_data.sh", {}))
}

module "aws_asg" {
  source                    = "./modules/aws/auto_scaling_group"
  name                      = "asg"
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.desired_capacity
  health_check_grace_period = 300
  health_check_type         = "ELB"
  force_delete              = !var.is_production
  target_group_arns         = [module.aws_lb.target_groups.lb_target_group.arn]
  vpc_zone_identifier       = module.aws_vpc.private_subnets
  launch_template_id        = module.aws_launch_template.id
  launch_template_version   = "$Latest"
    }

resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "cpu-target-tracking"
  autoscaling_group_name = module.aws_asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = 60.0
    disable_scale_in = false
  }
}

module "aws_lb_logs" {
  source      = "./modules/aws/s3"
  bucket_name = local.lb_logs_bucket_name
  region      = var.aws_region
  objects     = []
  bucket_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSELBAccountWrite"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_elb_service_account.elb_service_account.id}:root"
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${local.lb_logs_bucket_name}/AWSLogs/*"
      }
    ]
  })
  cors               = []
  versioning_enabled = "Disabled"
  force_destroy      = true
  tags = {
    Project = "aws-split-horizon-dns"
  }
}

module "aws_lb" {
  source                     = "terraform-aws-modules/alb/aws"
  name                       = "lb"
  load_balancer_type         = "application"
  vpc_id                     = module.aws_vpc.vpc_id
  subnets                    = module.aws_vpc.private_subnets
  enable_deletion_protection = var.is_production
  drop_invalid_header_fields = true
  ip_address_type            = "ipv4"
  internal                   = false

  security_groups = [
    module.aws_lb_sg.id
  ]

  access_logs = {
    bucket = "${module.aws_lb_logs.bucket}"
  }

  listeners = {
    lb_http_listener = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "lb_target_group"
      }
    }
  }

  target_groups = {
    lb_target_group = {
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
      health_check = {
        enabled             = true
        healthy_threshold   = 3
        interval            = 30
        path                = "/"
        port                = 80
        protocol            = "HTTP"
        unhealthy_threshold = 3
      }
      create_attachment = false
    }
  }

  tags = {
    Project = "aws-split-horizon-dns"
  }
}