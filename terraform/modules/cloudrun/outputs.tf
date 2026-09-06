output "service_url" {
  value = google_cloud_run_v2_service.app.uri
}

output "runtime_sa_email" {
  value = google_service_account.runtime.email
}
