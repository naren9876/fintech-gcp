project_id  = "fintech-gcp-prd-16305"
region      = "us-central1"
environment = "prod"
alert_email = ""

db_tier                = "db-custom-1-3840"
db_availability_type   = "REGIONAL" # HA: automatic failover
db_backups_enabled     = true
db_deletion_protection = true # destroy must be a deliberate two-step
redis_tier             = "STANDARD_HA"
redis_memory_gb        = 1
run_min_instances      = 1 # no cold starts in prod
run_max_instances      = 4
