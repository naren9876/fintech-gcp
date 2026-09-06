terraform {
  # Partial configuration: the bucket is supplied per environment at init time:
  #   terraform init -backend-config=environments/<env>.gcsbackend
  # One code path, three isolated states.
  backend "gcs" {
    prefix = "terraform/state"
  }
}
