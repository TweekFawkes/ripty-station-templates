output "instance_id" {
  description = "The EC2 instance. It shows on the Stations page once it enrolls."
  value       = aws_instance.station.id
}

output "public_ip" {
  description = "The instance's public IPv4 address."
  value       = aws_instance.station.public_ip
}

output "private_ip" {
  description = "The instance's private IPv4 address."
  value       = aws_instance.station.private_ip
}
