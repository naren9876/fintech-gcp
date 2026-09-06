# App-level secrets: a 48-char JWT signing secret no human has ever seen.
# Terraform generates it, Secret Manager stores it, the container consumes it.

resource "random_password" "jwt" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "jwt" {
  secret_id = "fintech-${var.environment}-jwt-secret"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "jwt" {
  secret      = google_secret_manager_secret.jwt.id
  secret_data = random_password.jwt.result
}
