resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  lifecycle {
    prevent_destroy = false
  }
}
resource "azurerm_virtual_network" "net" {
  name                = "vm-net"
  address_space       = ["192.168.0.0/24"]
  location            = resource_group_name.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}
resource "azurerm_subnet" "internal" {
  name                 = "vm-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.net.name
  address_prefixes     = ["192.168.0.0/24"]
}

resource "azurerm_network_security_group" "nsg" {
  name                = "vm-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule = {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  #   security_rule = {
  #     name                       = "InternetOut"
  #     priority                   = 100
  #     direction                  = "Outbound"
  #     access                     = "Allow"
  #     protocol                   = "Tcp"
  #     source_port_range          = "*"
  #     destination_port_range     = "80"
  #     source_address_prefix      = "*"
  #     destination_address_prefix = "*"
  #   }
}
resource "azurerm_public_ip" "control_ip" {
  name                = "control-ip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Dynamic"
}
resource "azurerm_public_ip" "nodes" {
  count               = 2
  name                = "node${count.index + 1}-public-ip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Dynamic"
}

resource "azurerm_network_interface" "control_nic" {
  name                = "nic-control"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Dynamic"
    #private_ip_address            = "192.168.0.100"
    public_ip_address_id = azurerm_public_ip.control_ip.ip
  }
}
resource "azurerm_network_interface" "nodes_nic" {
  count               = 2
  name                = "nic-node${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Dynamic"
    #private_ip_address            = "192.168.0.${101 + count.index}"
    public_ip_address_id = azurerm_public_ip.nodes[count.index].id
  }
}
# Associate NSG with NICs
resource "azurerm_network_interface_security_group_association" "control" {
  network_interface_id      = azurerm_network_interface.control_nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_network_interface_security_group_association" "nodes" {
  count                     = 2
  network_interface_id      = azurerm_network_interface.nodes_nic[count.index].id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "tls_private_key" "vm_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "control" {
  name                  = "control.example.com"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = "Standard_B1s" # 1 vCPU, 1 GiB RAM
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.control_nic.id]
  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.vm_ssh.public_key_openssh
  }
  os_disk {
    caching              = "ReadWrite"
    disk_size_gb         = 10
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "22_04-LTS"
    version   = "latest"
  }
}

resource "azurerm_linux_virtual_machine" "nodes" {
  count                 = 2
  name                  = "node${count.index + 1}.example.com"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = "Standard_B1s" # 1 vCPU, 1 GiB RAM
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nodes_nic[count.index].id]
  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.vm_ssh.public_key_openssh
  }
  os_disk {
    caching              = "ReadWrite"
    disk_size_gb         = 10
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "22_04-LTS"
    version   = "latest"
  }
}

# Configuration of /etc/hosts and SSH config
# resource "null_resource" "configure_hosts" {
#   depends_on = [
#     azurerm_linux_virtual_machine.control,
#     azurerm_linux_virtual_machine.nodes
#   ]
#   connection {
#     type        = "ssh"
#     host        = azurerm_linux_virtual_machine.control.public_ip_address
#     user        = var.admin_username
#     private_key = tls_private_key.vm_ssh.private_key_openssh
#   }
#   #Provisioner to update /etc/hosts on control node
#   provisioner "remote-exec" {
#     inline = [
#       "echo '192.168.0.100 control.example.com control' | sudo tee -a /etc/hosts",
#       "echo '192.168.0.101 node1.example.com node1' | sudo tee -a /etc/hosts",
#       "echo '192.168.0.102 node2.example.com node2' | sudo tee -a /etc/hosts",
#     ]
#   }
#   # Provisioner to create SSH config on control node
#   provisioner "file" {
#     content     = <<-EOF
#     Host node*
#     StrickHostKeyChecking no
#     UserKnownHostFile /dev/null
#     User ${var.admin_username}
#     IdentityFile ~/.ssh/id_rsa
#   EOF
#     destination = "home/${var.admin_username}/.ssh/config"
#   }
# }
