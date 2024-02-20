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

resource "google_compute_network" {
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
}

resource "google_compute_route" "routes" {
  for_each = { for i, route in local.vpc_routes_info: i => route }

  network = google_compute_network.networks[each.value.network_name].id
  name = each.value.route_name
  dest_range = each.value.dest_range
  next_hop_gateway = each.value.next_hop_gateway
}