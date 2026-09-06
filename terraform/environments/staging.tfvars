project_id  = "fintech-gcp-stg-16305"
region      = "us-central1"
environment = "staging"
alert_email = ""

db_tier                = "db-g1-small"
db_availability_type   = "ZONAL"
db_backups_enabled     = true
db_deletion_protection = false
redis_tier             = "BASIC"
redis_memory_gb        = 1
run_min_instances      = 0
run_max_instances      = 2
