# ==============================================================================
# Builds the Ubuntu 22.04 vSphere template that Vagrant (via vagrant-vsphere)
# clones for every cluster node. Run this ONCE per vSphere environment before
# `vagrant up`. Not required if you already have a suitable template - point
# VSPHERE_TEMPLATE in ../Vagrantfile at it instead and skip this directory.
#
# This is the ISO-install route (ships its own installer automation). If you'd
# rather not deal with an ISO at all, ../template/build-template.sh builds the
# same kind of template by downloading Canonical's official Ubuntu 22.04
# cloud image instead - see ../README.md for which one to use.
#
# Install:
#   packer plugins install github.com/hashicorp/vsphere
#
# Build:
#   packer init .
#   packer build \
#     -var "vcenter_password=$VSPHERE_PASSWORD" \
#     -var "iso_path=[datastore1] ISOs/ubuntu-22.04.5-live-server-amd64.iso" \
#     .
#
# The resulting VM is converted to a template named `template_name` below,
# ready for vagrant-vsphere's `vsphere.template_name`.
# ==============================================================================

packer {
  required_plugins {
    vsphere = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/vsphere"
    }
  }
}

variable "vcenter_server" {
  type    = string
  default = "10.10.10.250"
}

variable "vcenter_user" {
  type    = string
  default = "administrator@vsphere.local"
}

variable "vcenter_password" {
  type      = string
  default   = "URn0t+hE1."
  sensitive = true
}

variable "vcenter_insecure_connection" {
  type    = bool
  default = true
}

# CHANGE cluster/datastore/network to match your vSphere inventory (same
# names used in ../Vagrantfile)
variable "datacenter" {
  type    = string
  default = "intl-site"
}

variable "cluster" {
  type    = string
  default = "Cluster"
}

variable "datastore" {
  type    = string
  default = "datastore1"
}

variable "network" {
  type    = string
  default = "VM Network"
}

variable "folder" {
  type    = string
  default = "k8s-demo"
}

variable "template_name" {
  type    = string
  default = "ubuntu-2204-k8s-template"
}

# Datastore path to an uploaded Ubuntu 22.04 Server ISO, e.g.
# "[datastore1] ISOs/ubuntu-22.04.5-live-server-amd64.iso"
variable "iso_path" {
  type = string
}

variable "ssh_username" {
  type    = string
  default = "vagrant"
}

variable "ssh_password" {
  type      = string
  default   = "vagrant"
  sensitive = true
}

source "vsphere-iso" "ubuntu" {
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_user
  password            = var.vcenter_password
  insecure_connection = var.vcenter_insecure_connection

  datacenter = var.datacenter
  cluster    = var.cluster
  datastore  = var.datastore
  folder     = var.folder

  vm_name       = var.template_name
  guest_os_type = "ubuntu64Guest"
  CPUs          = 2
  RAM           = 2048
  disk_controller_type = ["pvscsi"]

  storage {
    disk_size             = 20480
    disk_thin_provisioned = true
  }

  network_adapters {
    network      = var.network
    network_card = "vmxnet3"
  }

  iso_paths    = [var.iso_path]
  boot_order   = "disk,cdrom"
  boot_wait    = "3s"
  boot_command = [
    "<esc><wait>e<wait>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<wait>",
    "<f10>"
  ]

  http_directory = "http"

  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "30m"

  shutdown_command = "sudo /usr/sbin/shutdown -h now"
  convert_to_template = true
}

build {
  sources = ["source.vsphere-iso.ubuntu"]

  provisioner "shell" {
    inline = [
      "sudo cloud-init status --wait",
      "sudo apt-get update -qq",
      # perl: required for VMware's Linux guest customization (the vSphere
      # Customization Specification's static IP application on first boot) to
      # run at all - fails silently without it (VMware KB 2075048), leaving a
      # clone with no network config and no IP. Installed explicitly rather
      # than assumed, since the autoinstall packages list already includes it
      # but this provisioner shouldn't depend on that staying true.
      "sudo apt-get install -qq -y open-vm-tools perl",
      "sudo systemctl enable open-vm-tools",
      "sudo mkdir -p /home/${var.ssh_username}/.ssh",
      # subiquity (the autoinstall backend) and/or cloud-init's own network
      # stage write a netplan file here matched to THIS BUILD VM's MAC
      # address. Every vSphere clone gets a different MAC, so on a clone that
      # stale match binds to nothing and blocks the vSphere Customization
      # Specification's static IP (../template/cloud-init-user-data.yaml.tmpl
      # has the same fix, and a longer explanation, for the other template
      # build path) - the interface is left down with no address. Deleting
      # any pre-existing netplan configs here, in the template, is
      # permanent: nothing regenerates them before convert_to_template runs.
      "sudo rm -f /etc/netplan/*.yaml",
      "echo 'Base image ready for vagrant-vsphere cloning'"
    ]
  }
}
