provider "google" {
  project = var.project
  region  = var.region
}

locals {
  project = var.project

  vpc_subnet_info = flatten([
    for vpc in var.VPCs : [
      for subnet in vpc.subnets : {
        network_name             = vpc.name
        subnet_name              = subnet.name
        subnet_region            = subnet.region
        subnet_cidr              = subnet.ip_cidr_range
        private_ip_google_access = subnet.private_ip_google_access
      }
    ]
  ])

  vpc_routes_info = flatten([
    for vpc in var.VPCs : [
      for route in vpc.routes : {
        network_name     = vpc.name
        route_name       = route.name
        dest_range       = route.dest_range
        next_hop_gateway = route.next_hop_gateway
      }
    ]
  ])
}

resource "google_compute_network" "networks" {
  for_each = { for vpc in var.VPCs : vpc.name => vpc }

  name                            = each.value.name
  auto_create_subnetworks         = each.value.auto_create_subnetworks
  routing_mode                    = each.value.routing_mode
  delete_default_routes_on_create = each.value.delete_default_routes_on_create
}

resource "google_compute_subnetwork" "subnets" {
  for_each = { for i, subnet in local.vpc_subnet_info : i => subnet }

  network                  = google_compute_network.networks[each.value.network_name].id
  name                     = each.value.subnet_name
  region                   = each.value.subnet_region
  ip_cidr_range            = each.value.subnet_cidr
  private_ip_google_access = each.value.private_ip_google_access
}

resource "google_compute_route" "routes" {
  for_each = { for i, route in local.vpc_routes_info : i => route }

  network          = google_compute_network.networks[each.value.network_name].id
  name             = each.value.route_name
  dest_range       = each.value.dest_range
  next_hop_gateway = each.value.next_hop_gateway
}

resource "google_compute_firewall" "allow" {
  name    = var.allowed_firewall
  network = google_compute_network.networks[var.VPCs[0].name].id

  allow {
    protocol = var.protocol
    ports    = [var.allowed_port]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  priority      = var.priority
}

resource "google_compute_firewall" "deny" {
  name    = var.denied_firewall
  network = google_compute_network.networks[var.VPCs[0].name].id

  deny {
    protocol = var.protocol
    ports    = [var.denied_port]
  }

  source_ranges = [var.allowed_source_range]
  priority      = var.priority
}

resource "google_compute_global_address" "default" {
  name          = var.google_compute_global_address_name
  address_type  = var.google_compute_global_address_type
  purpose       = var.google_compute_global_address_purpose
  network       = google_compute_network.networks[var.VPCs[0].name].id
  prefix_length = 16
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.networks[var.VPCs[0].name].id
  service                 = var.google_service_networking_connection_service
  reserved_peering_ranges = [google_compute_global_address.default.name]
}

resource "random_id" "db_name_suffix" {
  byte_length = 4
}

resource "google_sql_database_instance" "database_instance" {
  name                = "private-instance-${random_id.db_name_suffix.hex}"
  database_version    = var.database_version
  region              = var.region
  deletion_protection = var.db_instance_deletion_protection

  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier              = var.db_instance_machine_type
    availability_type = var.db_instance_availability_type
    disk_type         = var.db_instance_disk_type
    disk_size         = var.db_instance_disk_size

    ip_configuration {
      ipv4_enabled                                  = var.db_instance_ipv4_enabled
      private_network                               = google_compute_network.networks[var.VPCs[0].name].id
      enable_private_path_for_google_cloud_services = var.db_instance_enable_private_path_for_gcp_services
    }

    backup_configuration {
      enabled            = var.db_instance_backup_enabled
      binary_log_enabled = var.db_instance_backup_binary_log_enabled
    }
  }
}

resource "google_sql_database" "database" {
  name     = var.database
  instance = google_sql_database_instance.database_instance.name
}

resource "random_password" "password" {
  length           = var.password_length
  special          = var.use_special_chars
  override_special = var.use_these_special_chars
}

resource "google_sql_user" "user" {
  name     = var.database_user
  instance = google_sql_database_instance.database_instance.name
  password = random_password.password.result
}

resource "google_vpc_access_connector" "connector" {
  name          = "vpc-connector"
  network       = google_compute_network.networks[var.VPCs[0].name].id
  region        = var.region
  ip_cidr_range = "10.8.0.0/28"
}

resource "google_service_account" "vm_service_account" {
  account_id   = var.account_id
  display_name = var.display_name
}

resource "google_project_iam_binding" "logging_admin_binding" {
  project = var.project
  role    = "roles/logging.admin"
  members = [
    "serviceAccount:${google_service_account.vm_service_account.email}",
  ]
}

resource "google_project_iam_binding" "monitoring_metric_writer_binding" {
  project = var.project
  role    = "roles/monitoring.metricWriter"
  members = [
    "serviceAccount:${google_service_account.vm_service_account.email}",
  ]
}

resource "google_project_iam_binding" "gcs-pubsub-publishing" {
  project = var.project
  role    = "roles/pubsub.publisher"
  members = [
    "serviceAccount:${google_service_account.vm_service_account.email}",
  ]
}

resource "google_service_account" "cloud_func_service_account" {
  account_id   = "cloud-function-service-account"
  display_name = "Cloud Function Service Account"
}

resource "google_project_iam_binding" "invoking" {
  project = var.project
  role    = "roles/cloudfunctions.invoker"
  members = [
    "serviceAccount:${google_service_account.cloud_func_service_account.email}",
  ]
}

resource "google_compute_region_instance_template" "instance_template" {
  name_prefix  = "instance-template-"
  machine_type = var.machine_type
  region       = var.region

  disk {
    source_image = var.boot_disk_image
    auto_delete  = true
    boot         = true
    disk_type    = var.boot_disk_type
    disk_size_gb = var.boot_disk_size
  }

  network_interface {
    network    = google_compute_network.networks[var.VPCs[0].name].id
    subnetwork = google_compute_subnetwork.subnets[0].id
    access_config {
    }
  }

  service_account {
    email  = google_service_account.vm_service_account.email
    scopes = ["https://www.googleapis.com/auth/logging.write", "https://www.googleapis.com/auth/monitoring.write", "https://www.googleapis.com/auth/pubsub"]
  }

  metadata_startup_script = <<-SCRIPT
    #!/bin/bash

    echo "Starting startup script..."

    sudo sh -c  'cat << EOF > /opt/app/.env
    MYSQL_HOST=${google_sql_database_instance.database_instance.private_ip_address}
    MYSQL_USER=${google_sql_user.user.name}
    MYSQL_PASSWORD=${google_sql_user.user.password}
    MYSQL_DATABASE=${google_sql_database.database.name}
    EOF'

    echo "Startup script executed successfully!"
  SCRIPT
}

resource "google_compute_health_check" "health_check" {
  name                = "health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }
}

resource "google_compute_region_autoscaler" "autoscaler" {
  name   = "autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.instance_group_manager.id

  autoscaling_policy {
    max_replicas    = 6
    min_replicas    = 3
    cooldown_period = 60

    cpu_utilization {
      target = 0.05
    }
  }

  depends_on = [google_compute_region_instance_group_manager.instance_group_manager]
}

resource "google_compute_region_instance_group_manager" "instance_group_manager" {
  name               = "instance-group-manager"
  base_instance_name = "instance"
  region             = var.region

  version {
    instance_template = google_compute_region_instance_template.instance_template.id
  }

  named_port {
    name = "custom-port"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.health_check.id
    initial_delay_sec = 300
  }
}

resource "google_compute_global_forwarding_rule" "forwarding_rule" {
  name       = "forwarding-rule"
  target     = google_compute_target_https_proxy.https_proxy.id
  port_range = "443"
}

resource "google_compute_target_https_proxy" "https_proxy" {
  name             = "https-proxy"
  url_map          = google_compute_url_map.url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.ssl_certificate.id]
}

resource "google_compute_url_map" "url_map" {
  name            = "url-map"
  default_service = google_compute_backend_service.backend_service.id
}

resource "google_compute_backend_service" "backend_service" {
  name                  = "backend-service"
  port_name             = "custom-port"
  protocol              = "HTTP"
  health_checks         = [google_compute_health_check.health_check.id]
  load_balancing_scheme = "EXTERNAL"

  backend {
    group = google_compute_region_instance_group_manager.instance_group_manager.instance_group
  }
}

resource "google_compute_managed_ssl_certificate" "ssl_certificate" {
  name = "ssl-certificate"

  managed {
    domains = [var.domain]
  }
}

resource "google_dns_record_set" "a-record" {
  name         = var.domain
  type         = var.record_type
  ttl          = var.record_ttl
  managed_zone = var.dns_zone

  rrdatas = [google_compute_global_forwarding_rule.forwarding_rule.ip_address]

  depends_on = [google_compute_global_forwarding_rule.forwarding_rule]
}

resource "google_pubsub_topic" "topic" {
  name                       = var.topic_name
  message_retention_duration = var.message_retention_duration
}

resource "google_storage_bucket" "bucket" {
  name                        = "${local.project}-cloud-function-bucket"
  location                    = "US"
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_object" "object" {
  name   = "cloud-function.zip"
  bucket = google_storage_bucket.bucket.name
  source = "./cloud-function.zip"
}

resource "google_cloudfunctions2_function" "function" {
  name     = "pub-sub-cloud"
  location = var.region

  build_config {
    runtime     = "nodejs20"
    entry_point = "helloPubSub"
    source {
      storage_source {
        bucket = google_storage_bucket.bucket.name
        object = google_storage_bucket_object.object.name
      }
    }
  }

  service_config {
    environment_variables = {
      MAILGUN_API_KEY = var.MAILGUN_API_KEY,
      ROOT_URL        = var.ROOT_URL
      MYSQL_HOST      = google_sql_database_instance.database_instance.private_ip_address
      MYSQL_USER      = google_sql_user.user.name
      MYSQL_PASSWORD  = google_sql_user.user.password
      MYSQL_DATABASE  = google_sql_database.database.name
    }

    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    service_account_email = google_service_account.cloud_func_service_account.email
    vpc_connector         = google_vpc_access_connector.connector.id
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.topic.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}