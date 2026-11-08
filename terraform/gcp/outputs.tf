output "instance_id" {
  description = "The Compute Engine VM. It shows on the Stations page once it enrolls."
  value       = google_compute_instance.station.instance_id
}

output "public_ip" {
  description = "The VM's public IPv4 address."
  value       = google_compute_instance.station.network_interface[0].access_config[0].nat_ip
}

output "private_ip" {
  description = "The VM's private IPv4 address."
  value       = google_compute_instance.station.network_interface[0].network_ip
}
