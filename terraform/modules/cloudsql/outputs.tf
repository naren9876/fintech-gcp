output "private_ip" {
  value     = google_sql_database_instance.pg.private_ip_address
  sensitive = true
}

output "database_url_secret_id" {
  value = google_secret_manager_secret.database_url.secret_id
}
