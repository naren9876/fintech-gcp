# ---- Phase 1 outputs ----
output "network_id" {
  value = module.network.network_id
}

output "artifact_registry_url" {
  value       = module.registry.image_base
  description = "Push images here as <this>:<git-sha>"
}

# ---- Phase 2 outputs ----
output "cloudsql_private_ip" {
  value     = module.cloudsql.private_ip
  sensitive = true
}
#
output "redis_host" {
  value     = module.memorystore.host
  sensitive = true
}

# ---- Phase 3 outputs ----
# output "service_url" {
#   value       = module.cloudrun.service_url
#   description = "Public HTTPS URL of the auth service"
# }

# ---- Phase 4 outputs ----
# output "dashboard_url" {
#   value = module.monitoring.dashboard_url
# }
