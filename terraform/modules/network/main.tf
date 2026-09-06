# The neighborhood, GCP flavor:
# - custom VPC + one private subnet (the app never gets public IPs)
# - Private Service Access: the reserved range + peering that lets Cloud SQL
#   and Memorystore live INSIDE the VPC with private IPs only
# - Serverless VPC Access connector: Cloud Run's door into the VPC
#   (the AWS SG-chain equivalent here is: private IPs + IAM; nothing listens publicly)

resource "google_compute_network" "vpc" {
  name                    = "fintech-${var.environment}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "private" {
  name                     = "fintech-${var.environment}-private"
  ip_cidr_range            = var.vpc_cidr_subnet
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# Reserved range for managed services (Cloud SQL / Redis) inside the VPC
resource "google_compute_global_address" "psa_range" {
  name          = "fintech-${var.environment}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

# The single shared peering - created ONCE here, consumed by data modules.
# (Lesson from the first GCP project: shared resources live in exactly one place.)
resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]
}

# Cloud Run's bridge into the VPC (so it can reach private DB/Redis IPs)
resource "google_vpc_access_connector" "connector" {
  name          = "fintech-${var.environment}-conn"
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = var.connector_cidr
  min_instances = 2
  max_instances = 3
}
