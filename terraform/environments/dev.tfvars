project_id  = "fintech-gcp-dev-16305"
region      = "us-central1"
environment = "dev"
alert_email = ""

db_tier                = "db-f1-micro"
db_availability_type   = "ZONAL"
db_backups_enabled     = false
db_deletion_protection = false
redis_tier             = "BASIC"
redis_memory_gb        = 1
run_min_instances      = 0
run_max_instances      = 2
