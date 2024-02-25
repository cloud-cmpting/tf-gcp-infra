// project properties
variable "project" {}
variable "region" {}
variable "zone" {}

// firewall properties
variable "protocol" {}
variable "allowed_firewall" {}
variable "denied_firewall" {}
variable "allowed_port" {}
variable "denied_port" {}
variable "allowed_source_range" {}
variable "priority" {}

// VM properties
variable "instance" {}
variable "machine_type" {}
variable "boot_disk_image" {}
variable "boot_disk_type" {}
variable "boot_disk_size" {}

// For private DB instance
variable "google_service_networking_connection_service" {}
variable "google_compute_global_address_prefix_length" {}
variable "google_compute_global_address_purpose" {}
variable "google_compute_global_address_type" {}
variable "google_compute_global_address_name" {}

// database instance properties
variable "db_instance_machine_type" {}
variable "db_instance_availability_type" {}
variable "db_instance_disk_type" {}
variable "db_instance_disk_size" {}
variable "db_instance_deletion_protection" {}
variable "db_instance_ipv4_enabled" {}
variable "db_instance_enable_private_path_for_gcp_services" {}
variable "db_instance_backup_enabled" {}
variable "db_instance_backup_binary_log_enabled" {}

// database properties
variable "database_version" {}
variable "database" {}
variable "database_user" {}

// network properties
variable "VPCs" {}

// password properties
variable "password_length" {}
variable "use_special_chars" {}
variable "use_these_special_chars" {}