provider "google" {
    project = var.project
    region = var.region
    zone = var.zone
}

locals {
  vpc_subnet_info = flatten([
    for vpc in var.VPCs : [
      for subnet in vpc.subnets : {
        network_name = vpc.name
        subnet_name = subnet.name
        subnet_region = subnet.region
        subnet_cidr = subnet.ip_cidr_range
        private_ip_google_access = subnet.private_ip_google_access
      }
    ]
  ])

  vpc_routes_info = flatten([
    for vpc in var.VPCs : [
      for route in vpc.routes : {
        network_name = vpc.name
        route_name = route.name
        dest_range = route.dest_range
        next_hop_gateway = route.next_hop_gateway
      }
    ]
  ])
}

resource "google_compute_network" "networks" {
  for_each = { for vpc in var.VPCs: vpc.name => vpc }

  name = each.value.name
  auto_create_subnetworks = each.value.auto_create_subnetworks
  routing_mode = each.value.routing_mode
  delete_default_routes_on_create = each.value.delete_default_routes_on_create
}

resource "google_compute_subnetwork" "subnets" {
  for_each = { for i, subnet in local.vpc_subnet_info: i => subnet }

  network = google_compute_network.networks[each.value.network_name].id
  name    = each.value.subnet_name
  region  = each.value.subnet_region
  ip_cidr_range = each.value.subnet_cidr
  private_ip_google_access = each.value.private_ip_google_access
}

resource "google_compute_route" "routes" {
  for_each = { for i, route in local.vpc_routes_info: i => route }

  network = google_compute_network.networks[each.value.network_name].id
  name = each.value.route_name
  dest_range = each.value.dest_range
  next_hop_gateway = each.value.next_hop_gateway
}

resource "google_compute_firewall" "allow" {
  name = var.allowed_firewall_name
  network = google_compute_network.networks[var.VPCs[0].name].id

  allow {
    protocol = var.protocol
    ports = [var.allowed_port]
  }

  source_ranges = [var.allowed_source_range]
  priority = var.priority
}

resource "google_compute_firewall" "deny" {
  name = var.denied_firewall_name
  network = google_compute_network.networks[var.VPCs[0].name].id

  deny {
    protocol = var.protocol
    ports = [var.denied_port]
  }

  source_ranges = [var.allowed_source_range]
  priority = var.priority
}

resource "google_compute_instance" "instance" {
  name = var.network_name
  machine_type = var.machine_type
  zone = var.zone

  boot_disk {
    initialize_params {
      image = var.boot_disk_image
      type  = var.boot_disk_type
      size = var.boot_disk_size
    }
  }

  network_interface {
    network = google_compute_network.networks[var.VPCs[0].name].id
    subnetwork = google_compute_subnetwork.subnets[0].id
    access_config {
      
    }
  }
}

resource "google_compute_global_address" "default" {
  name = "global-psconnect-ip"
  address_type = "INTERNAL"
  purpose = "VPC_PEERING"
  network = google_compute_network.networks[var.VPCs[0].name].id
  prefix_length = 16
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network = google_compute_network.networks[var.VPCs[0].name].id
  service = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.default.name]
}

resource "random_id" "db_name_suffix" {
  byte_length = 4
}

resource "google_sql_database_instance" "database_instance" {
  name = "private-instance-${random_id.db_name_suffix.hex}"
  database_version = "MYSQL_5_7"
  region = var.region
  deletion_protection = false

  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier = "db-f1-micro"
    availability_type = "REGIONAL"
    disk_type = "pd-ssd"
    disk_size = 10

    ip_configuration {
      ipv4_enabled = false
      private_network = google_compute_network.networks[var.VPCs[0].name].id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled = true
      binary_log_enabled = true
    }
  }
}

resource "google_sql_database" "database" {
  name = "webapp"
  instance = google_sql_database_instance.database_instance.name
}

resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_sql_user" "user" {
  name     = "webapp"
  instance = google_sql_database_instance.database_instance.name
  password = random_password.password.result
}