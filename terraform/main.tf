terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  default_labels = {
    project     = "fintech"
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ---------------------------------------------------------------------------
# APIs required across all phases (enabling is idempotent and cheap)
# ---------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "vpcaccess.googleapis.com",
    "artifactregistry.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "secretmanager.googleapis.com",
    "run.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# ===========================================================================
# PHASE 1 - Foundation: network + container registry (ACTIVE from first push)
# ===========================================================================
module "network" {
  source          = "./modules/network"
  project_id      = var.project_id
  region          = var.region
  environment     = var.environment
  vpc_cidr_subnet = var.vpc_cidr_subnet
  connector_cidr  = var.connector_cidr

  depends_on = [google_project_service.apis]
}

module "registry" {
  source      = "./modules/registry"
  project_id  = var.project_id
  region      = var.region
  environment = var.environment

  depends_on = [google_project_service.apis]
}

# ===========================================================================
# PHASE 2 - Data layer: database, cache, app secrets  (uncomment via PR)
# The uncommenting IS the deployment mechanism: branch -> uncomment ->
# terraform fmt -> PR -> read the plan comment -> merge -> apply.
# ===========================================================================
module "secrets" {
  source      = "./modules/secrets"
  project_id  = var.project_id
  environment = var.environment
  #
  depends_on = [google_project_service.apis]
}
#
module "cloudsql" {
  source      = "./modules/cloudsql"
  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  network_id  = module.network.network_id
  #
  db_tier                = var.db_tier
  db_availability_type   = var.db_availability_type
  db_backups_enabled     = var.db_backups_enabled
  db_deletion_protection = var.db_deletion_protection
  #
  depends_on = [module.network]
}
#
module "memorystore" {
  source      = "./modules/memorystore"
  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  network_id  = module.network.network_id
  #
  redis_tier      = var.redis_tier
  redis_memory_gb = var.redis_memory_gb
  #
  depends_on = [module.network]
}

# ===========================================================================
# PHASE 3 - Compute: Cloud Run service wired to secrets + private network
# Prerequisite: the app pipeline must have pushed a certified image first
# (the "Interlude" - see README). Uncomment via PR.
# ===========================================================================
module "cloudrun" {
  source                 = "./modules/cloudrun"
  project_id             = var.project_id
  region                 = var.region
  environment            = var.environment
  service_name           = var.service_name
  container_port         = var.container_port
  image_base             = module.registry.image_base
  connector_id           = module.network.connector_id
  database_url_secret_id = module.cloudsql.database_url_secret_id
  redis_url_secret_id    = module.memorystore.redis_url_secret_id
  jwt_secret_id          = module.secrets.jwt_secret_id
  run_min_instances      = var.run_min_instances
  run_max_instances      = var.run_max_instances
  #
  depends_on = [module.cloudsql, module.memorystore, module.secrets]
}

# ===========================================================================
# PHASE 4 - Observability: dashboard + 5xx alert  (uncomment via PR)
# ===========================================================================
# module "monitoring" {
#   source       = "./modules/monitoring"
#   project_id   = var.project_id
#   environment  = var.environment
#   service_name = var.service_name
#   alert_email  = var.alert_email
#
#   depends_on = [module.cloudrun]
# }

# Phase 2 note: staging SQL instance imported after apply-wait timeout
# Phase 3 retry after secretmanager.admin grant
