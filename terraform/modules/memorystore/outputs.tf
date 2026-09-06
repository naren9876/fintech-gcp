output "host" {
  value     = google_redis_instance.cache.host
  sensitive = true
}

output "redis_url_secret_id" {
  value = google_secret_manager_secret.redis_url.secret_id
}
