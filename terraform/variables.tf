variable "project_id" {
  type        = string
  description = "GCP project ID for THIS environment"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "environment" {
  type        = string
  description = "dev | staging | prod"
}

variable "service_name" {
  type    = string
  default = "auth-service"
}

variable "container_port" {
  type    = number
  default = 3001
}

variable "vpc_cidr_subnet" {
  type    = string
  default = "10.30.0.0/24"
}

variable "connector_cidr" {
  type    = string
  default = "10.8.0.0/28"
}

variable "alert_email" {
  type    = string
  default = ""
}

# ---- sizing knobs: the ONLY thing that differs between environments ----
variable "db_tier" {
  type = string
}

variable "db_availability_type" {
  type = string # ZONAL (dev/stg) | REGIONAL (prod HA)
}

variable "db_backups_enabled" {
  type = bool
}

variable "db_deletion_protection" {
  type = bool
}

variable "redis_tier" {
  type = string # BASIC | STANDARD_HA
}

variable "redis_memory_gb" {
  type = number
}

variable "run_min_instances" {
  type = number
}

variable "run_max_instances" {
  type = number
}
