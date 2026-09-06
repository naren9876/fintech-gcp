# Artifact Registry: the image warehouse (ECR equivalent).
# The pipeline pushes <region>-docker.pkg.dev/<project>/fintech/auth-service:<git-sha>
resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = "fintech"
  description   = "FinTech ${var.environment} container images"
  format        = "DOCKER"
}
