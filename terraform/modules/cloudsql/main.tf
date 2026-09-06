# The database - with the AWS lessons baked in:
# - POSTGRES_16 (major only; Google manages the minor - the "pinned 16.1 broke" lesson)
# - random_password with special = false (the "% broke the URL" lesson)
# - deletion_protection = false + no final snapshot demands (dev teardown-friendly)
# - Terraform assembles the FULL connection URL and stores it as ONE secret;
#   the app reads a single DATABASE_URL env var and knows nothing else.

resource "random_password" "db" {
  length  = 24
  special = false # URL-safe by construction
}

resource "google_sql_database_instance" "pg" {
  name                = "fintech-${var.environment}-pg"
  database_version    = "POSTGRES_16"
  region              = var.region
  deletion_protection = var.db_deletion_protection

  settings {
    tier              = var.db_tier
    availability_type = var.db_availability_type

    ip_configuration {
      ipv4_enabled    = false # NO public IP, ever
      private_network = var.network_id
    }

    backup_configuration {
      enabled                        = var.db_backups_enabled
      point_in_time_recovery_enabled = var.db_backups_enabled
    }
  }
}

resource "google_sql_database" "app" {
  name     = "fintech"
  instance = google_sql_database_instance.pg.name
}

resource "google_sql_user" "app" {
  name     = "appuser"
  instance = google_sql_database_instance.pg.name
  password = random_password.db.result
}

# The clever bit, ported: one ready-to-use URL, stored once.
# sslmode=disable is acceptable on a private-IP-only path (traffic never
# leaves the VPC); prod would use Cloud SQL connectors or verify-full.
resource "google_secret_manager_secret" "database_url" {
  secret_id = "fintech-${var.environment}-database-url"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "database_url" {
  secret = google_secret_manager_secret.database_url.id
  secret_data = "postgresql://${google_sql_user.app.name}:${random_password.db.result}@${google_sql_database_instance.pg.private_ip_address}:5432/${google_sql_database.app.name}?sslmode=disable"
}
