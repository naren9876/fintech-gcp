# The cache. AUTH on; TLS deferred to prod (dev avoids CA-cert mounting -
# traffic already never leaves the VPC). Memorystore GENERATES the auth
# string itself; Terraform reads it and bakes the ready-made redis:// URL.

resource "google_redis_instance" "cache" {
  name           = "fintech-${var.environment}-redis"
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory_gb
  region         = var.region
  redis_version  = "REDIS_7_2"

  authorized_network = var.network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  auth_enabled            = true
  transit_encryption_mode = "DISABLED" # dev; prod: SERVER_AUTHENTICATION + rediss://
}

resource "google_secret_manager_secret" "redis_url" {
  secret_id = "fintech-${var.environment}-redis-url"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "redis_url" {
  secret      = google_secret_manager_secret.redis_url.id
  secret_data = "redis://:${google_redis_instance.cache.auth_string}@${google_redis_instance.cache.host}:${google_redis_instance.cache.port}"
}
