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
  purpose = "PRIVATE_SERVICE_CONNECT"
  network = google_compute_network.networks[var.VPCs[0].name].id
  address = "10.3.0.5"
}

resource "google_compute_global_forwarding_rule" "default" {
  name = "globalrule"
  target = "all-apis"
  network = google_compute_network.networks[var.VPCs[0].name].id
  ip_address = google_compute_global_address.default.id
  load_balancing_scheme = ""
}