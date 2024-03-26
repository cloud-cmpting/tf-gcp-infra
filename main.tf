provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
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

  source_ranges = [var.allowed_source_range]
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

resource "google_compute_instance" "instance" {
  name         = var.instance
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = var.boot_disk_image
      type  = var.boot_disk_type
      size  = var.boot_disk_size
    }
  }

  network_interface {
    network    = google_compute_network.networks[var.VPCs[0].name].id
    subnetwork = google_compute_subnetwork.subnets[0].id
    access_config {

    }
  }

  service_account {
    email  = google_service_account.vm_service_account.email
    scopes = ["https://www.googleapis.com/auth/logging.write", "https://www.googleapis.com/auth/monitoring.write"]
  }

  depends_on = [
    google_sql_database_instance.database_instance,
    google_sql_database.database,
    google_sql_user.user,
    google_service_account.vm_service_account,
    google_project_iam_binding.logging_admin_binding,
    google_project_iam_binding.monitoring_metric_writer_binding
  ]

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

resource "google_dns_record_set" "a-record" {
  name         = var.domain
  type         = var.record_type
  ttl          = var.record_ttl
  managed_zone = var.dns_zone

  rrdatas = [google_compute_instance.instance.network_interface[0].access_config[0].nat_ip]

  depends_on = [google_compute_instance.instance]
}

resource "google_pubsub_topic" "topic" {
  name = var.topic_name
  message_retention_duration = var.message_retention_duration
}

resource "google_storage_bucket" "bucket" {
  name     = "${local.project}-cloud-function-bucket"
  location = "US"
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_object" "object" {
  name   = "cloud-function.zip"
  bucket = google_storage_bucket.bucket.name
  source = "./cloud-function.zip"
}

resource "google_service_account" "cloud_func_account" {
  account_id   = "cloud-func-account"
  display_name = "Cloud Function Account"
}

resource "google_project_iam_member" "gcs-pubsub-publishing" {
  project = var.project
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.cloud_func_account.email}"
}

resource "google_project_iam_member" "invoking" {
  project = var.project
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.cloud_func_account.email}"
  depends_on = [google_project_iam_member.gcs-pubsub-publishing]
}

resource "google_cloudfunctions2_function" "function" {
  name = "pub-sub-cloud-func"
  location = var.region

  build_config {
    runtime = "nodejs20"
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
      JWT_SECRET_KEY = var.JWT_SECRET_KEY,
      MAILGUN_API_KEY = var.MAILGUN_API_KEY,
      ROOT_URL = var.ROOT_URL
    }
    ingress_settings = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision = true
    service_account_email = google_service_account.cloud_func_account.email
  }

  event_trigger {
    trigger_region = var.region
    event_type = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic = google_pubsub_topic.topic.id
    retry_policy = "RETRY_POLICY_RETRY"
  }
}