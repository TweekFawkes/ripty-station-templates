output "instance_id" {
  description = "The Azure VM. It shows on the Stations page once it enrolls."
  value       = azurerm_linux_virtual_machine.station.id
}

output "public_ip" {
  description = "The VM's public IPv4 address."
  value       = azurerm_public_ip.station.ip_address
}

output "private_ip" {
  description = "The VM's private IPv4 address."
  value       = azurerm_network_interface.station.private_ip_address
}
