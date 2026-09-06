# The compute (ECS-module equivalent), with both AWS lessons ported:
#
# 1) TWO identities, least privilege made visible:
#    - a dedicated RUNTIME service account whose ONLY permission is reading
#      exactly the three secrets (the "task role is empty" idea, GCP style)
# 2) The Terraform-vs-pipeline truce:
#    - image = ":latest" is for BOOTSTRAP ONLY; every pipeline deploy pins a
#      git SHA. lifecycle ignore_changes stops terraform plan from trying to
#      "fix" pipeline deploys back to :latest.

resource "google_service_account" "runtime" {
  account_id   = "${var.service_name}-runtime"
  display_name = "Runtime SA for ${var.service_name} (secret access only)"
}

resource "google_secret_manager_secret_iam_member" "runtime_secrets" {
  for_each = toset([
    var.database_url_secret_id,
    var.redis_url_secret_id,
    var.jwt_secret_id,
  ])
  secret_id = each.key
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_cloud_run_v2_service" "app" {
  name     = var.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL" # the public front door (ALB equivalent)

  template {
    service_account = google_service_account.runtime.email

    scaling {
      min_instance_count = var.run_min_instances
      max_instance_count = var.run_max_instances
    }

    vpc_access {
      connector = var.connector_id
      egress    = "PRIVATE_RANGES_ONLY" # only VPC traffic rides the connector
    }

    containers {
      image = "${var.image_base}:latest" # bootstrap ONLY - pipeline pins SHAs

      ports {
        container_port = var.container_port
      }

      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = var.database_url_secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "REDIS_URL"
        value_source {
          secret_key_ref {
            secret  = var.redis_url_secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "JWT_SECRET"
        value_source {
          secret_key_ref {
            secret  = var.jwt_secret_id
            version = "latest"
          }
        }
      }

      # The ALB health check, reborn: Cloud Run gates traffic on /health
      # (which queries the database - "healthy" means truly healthy)
      startup_probe {
        http_get {
          path = "/health"
          port = var.container_port
        }
        initial_delay_seconds = 10
        period_seconds        = 10
        failure_threshold     = 6
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image, # the pipeline owns the image from now on
      client,
      client_version,
    ]
  }

  depends_on = [google_secret_manager_secret_iam_member.runtime_secrets]
}

# Public access, like an internet-facing ALB (the app enforces its own auth)
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.app.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}
