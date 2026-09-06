output "jwt_secret_id" {
  value = google_secret_manager_secret.jwt.secret_id
}
