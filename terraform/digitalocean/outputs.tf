output "instance_id" {
  description = "The droplet. It shows on the Stations page once it enrolls."
  value       = digitalocean_droplet.station.id
}

output "public_ip" {
  description = "The droplet's public IPv4 address."
  value       = digitalocean_droplet.station.ipv4_address
}

output "private_ip" {
  description = "The droplet's private IPv4 address."
  value       = digitalocean_droplet.station.ipv4_address_private
}
