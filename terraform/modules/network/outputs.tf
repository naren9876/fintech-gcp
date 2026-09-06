output "network_id" {
  value = google_compute_network.vpc.id
}

output "network_name" {
  value = google_compute_network.vpc.name
}

output "connector_id" {
  value       = google_vpc_access_connector.connector.id
  description = "Full connector path for Cloud Run vpc_access"
}

output "psa_connection" {
  value       = google_service_networking_connection.psa.id
  description = "Data modules depend on the network module, which owns this"
}
