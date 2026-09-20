# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# ==============================================================================
# Kubernetes cluster on VMware vSphere, provisioned with Vagrant
#
# Topology : 1 control-plane node (kmaster) + 2 worker nodes (kworker1/2)
# Provider : vagrant-vsphere  ->  vagrant plugin install vagrant-vsphere
# Target   : vCenter 7.x at 10.10.10.250, datacenter "intl-site"
#
# Everything you MUST change for your own environment is marked "CHANGE ME"
# below, or can be overridden with an environment variable of the same name
# (preferred for the vCenter password - don't commit real credentials).
# ==============================================================================

VAGRANT_API_VERSION       = "2"
ENV['VAGRANT_NO_PARALLEL'] = 'yes'

# ------------------------------------------------------------------------------
# Kubernetes cluster settings
# ------------------------------------------------------------------------------
K8S_VERSION          = ENV.fetch('K8S_VERSION', '1.37')        # kubernetes.io/releases -> latest stable minor
CALICO_VERSION        = ENV.fetch('CALICO_VERSION', 'v3.32.1')  # github.com/projectcalico/calico/releases
WORKER_NODES_COUNT    = 2
CPUS_MASTER_NODE      = 2
CPUS_WORKER_NODE      = 2
MEMORY_MASTER_NODE    = 4096
MEMORY_WORKER_NODE    = 2048
NODE_ROOT_PASSWORD    = ENV.fetch('NODE_ROOT_PASSWORD', 'kubeadmin')

# ------------------------------------------------------------------------------
# Guest network - static IPs for the cluster nodes.
# This lab runs the cluster on the same flat 10.10.10.0/24 as vCenter's own
# management address (10.10.10.250). If your real VM network/VLAN differs,
# override these and update the vSphere Customization Specifications
# described in the README to match.
# ------------------------------------------------------------------------------
NETWORK_NETMASK  = ENV.fetch('K8S_NETWORK_NETMASK', '255.255.255.0')
NETWORK_GATEWAY  = ENV.fetch('K8S_NETWORK_GATEWAY', '10.10.10.1')
NETWORK_DNS      = ENV.fetch('K8S_NETWORK_DNS', '8.8.8.8')
MASTER_IP        = ENV.fetch('K8S_MASTER_IP', '10.10.10.240')
WORKER_IPS       = [
  ENV.fetch('K8S_KWORKER1_IP', '10.10.10.241'),
  ENV.fetch('K8S_KWORKER2_IP', '10.10.10.242'),
]

# ------------------------------------------------------------------------------
# vCenter connection and inventory. CHANGE the inventory names (datacenter,
# compute resource, resource pool, datastore, network, template) to match
# what actually exists in your vSphere client - these are placeholders.
# ------------------------------------------------------------------------------
VSPHERE_HOST             = ENV.fetch('VSPHERE_HOST', '10.10.10.250')
VSPHERE_USER             = ENV.fetch('VSPHERE_USER', 'administrator@vsphere.local')          #change this to your vSphere user if different
VSPHERE_PASSWORD         = ENV.fetch('VSPHERE_PASSWORD', '********')                         #change this to your vSphere password if different
VSPHERE_INSECURE         = true   # true = skip TLS verification (typical for self-signed vCenter certs)

VSPHERE_DATACENTER       = ENV.fetch('VSPHERE_DATACENTER', 'Intl-site')
VSPHERE_COMPUTE_RESOURCE = ENV.fetch('VSPHERE_COMPUTE_RESOURCE', 'Intl-cluster')
VSPHERE_RESOURCE_POOL    = ENV.fetch('VSPHERE_RESOURCE_POOL', 'k8s-demo-Resources')
# Confirmed against vagrant-vsphere 1.15.0 source (lib/vSphere/util/vim_helpers.rb):
# for a ClusterComputeResource it searches the direct children of the cluster's
# root pool by exact name - the plain leaf name, NOT "Resources/k8s-demo-Resources"
# (govc's -pool path convention is different and does not apply here).
VSPHERE_DATASTORE        = ENV.fetch('VSPHERE_DATASTORE', 'NetApp SSD Data')
VSPHERE_NETWORK          = ENV.fetch('VSPHERE_NETWORK', 'Intl-VM-Prod')
VSPHERE_TEMPLATE         = ENV.fetch('VSPHERE_TEMPLATE', 'k8s-demo/ubuntu-2204-k8s-template') # built by template/build-template.sh
VSPHERE_VM_FOLDER        = ENV.fetch('VSPHERE_VM_FOLDER', 'k8s-demo')

# Name of a vSphere Customization Specification (Menu > Policies and Profiles
# > VM Customization Specifications) to apply per node so each clone comes up
# with the right static IP. Create one per node first - see README. Leave a
# value as "" to fall back to whatever the template does by default (DHCP).
CUSTOMIZATION_SPECS = {
  "kmaster"  => ENV.fetch('VSPHERE_CUSTOMIZATION_KMASTER', 'k8s-kmaster-static'),
  "kworker1" => ENV.fetch('VSPHERE_CUSTOMIZATION_KWORKER1', 'k8s-kworker1-static'),
  "kworker2" => ENV.fetch('VSPHERE_CUSTOMIZATION_KWORKER2', 'k8s-kworker2-static'),
}

def configure_vsphere(vsphere, vm_name, cpus, memory_mb)
  vsphere.host                  = VSPHERE_HOST
  vsphere.user                  = VSPHERE_USER
  vsphere.password              = VSPHERE_PASSWORD
  vsphere.insecure              = VSPHERE_INSECURE

  vsphere.data_center_name      = VSPHERE_DATACENTER
  vsphere.compute_resource_name = VSPHERE_COMPUTE_RESOURCE
  vsphere.resource_pool_name    = VSPHERE_RESOURCE_POOL
  vsphere.data_store_name       = VSPHERE_DATASTORE
  vsphere.template_name         = VSPHERE_TEMPLATE
  vsphere.vm_base_path          = VSPHERE_VM_FOLDER

  vsphere.name                  = vm_name
  vsphere.clone_from_vm         = false
  vsphere.linked_clone          = false
  vsphere.cpu_count             = cpus
  vsphere.memory_mb             = memory_mb
  vsphere.ip_address_timeout    = 300
  vsphere.wait_for_sysprep      = false

  spec = CUSTOMIZATION_SPECS[vm_name]
  vsphere.customization_spec_name = spec unless spec.nil? || spec.empty?
end

Vagrant.configure(VAGRANT_API_VERSION) do |config|

  # vagrant-vsphere clones a template rather than downloading a box, but
  # Vagrant still needs a placeholder box to be satisfied. Shipped locally as
  # dummy.box (next to this Vagrantfile) rather than pointed at a URL - the
  # upstream vagrant-vsphere repo's own spec/dummy.box has gone 404, and this
  # way `vagrant up` never depends on an external download for it at all.
  config.vm.box               = "vsphere-dummy"
  config.vm.box_url           = File.expand_path("dummy.box", File.dirname(__FILE__))
  config.vm.box_check_update  = false

  # Nothing here relies on the project folder being live-mounted inside a node -
  # provisioning runs entirely through the shell scripts below, which Vagrant
  # uploads and runs directly. Disabling the default "." -> "/vagrant" synced
  # folder avoids Vagrant's Windows fallback of prompting for SMB share
  # credentials (there's no VirtualBox-style shared-folder driver for vsphere).
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.provision "shell", path: "bootstrap.sh", env: {
    "K8S_VERSION"    => K8S_VERSION,
    "ROOT_PASSWORD"  => NODE_ROOT_PASSWORD,
    "MASTER_IP"      => MASTER_IP,
    "WORKER_IPS"     => WORKER_IPS.join(","),
    "WORKER_COUNT"   => WORKER_NODES_COUNT.to_s,
  }

  # ---------------------------------------------------------------------
  # Kubernetes control-plane node
  # ---------------------------------------------------------------------
  config.vm.define "kmaster" do |node|

    node.vm.hostname = "kmaster.example.com"

    node.vm.provider :vsphere do |vsphere|
      configure_vsphere(vsphere, "kmaster", CPUS_MASTER_NODE, MEMORY_MASTER_NODE)
    end

    node.vm.provision "shell", path: "bootstrap_kmaster.sh", env: {
      "MASTER_IP"      => MASTER_IP,
      "CALICO_VERSION" => CALICO_VERSION,
    }

  end

  # ---------------------------------------------------------------------
  # Kubernetes worker nodes
  # ---------------------------------------------------------------------
  (1..WORKER_NODES_COUNT).each do |i|

    config.vm.define "kworker#{i}" do |node|

      node.vm.hostname = "kworker#{i}.example.com"

      node.vm.provider :vsphere do |vsphere|
        configure_vsphere(vsphere, "kworker#{i}", CPUS_WORKER_NODE, MEMORY_WORKER_NODE)
      end

      node.vm.provision "shell", path: "bootstrap_kworker.sh", env: {
        "MASTER_IP"     => MASTER_IP,
        "ROOT_PASSWORD" => NODE_ROOT_PASSWORD,
      }

    end

  end

  # ---------------------------------------------------------------------
  # Add-ons: MetalLB + Traefik, applied once the whole cluster is up.
  # Fires after kworker2 (the last machine `vagrant up` provisions), so all
  # three nodes already exist by the time it runs - see scripts/install-addons.*
  # for what it actually does. Skip it with SKIP_ADDONS=1 (or, in PowerShell,
  # $env:SKIP_ADDONS = '1') if you'd rather apply add-ons by hand later.
  # ---------------------------------------------------------------------
  unless ENV['SKIP_ADDONS']
    config.trigger.after :up, only_on: "kworker2" do |trigger|
      trigger.name    = "Deploy add-ons (MetalLB + Traefik)"
      trigger.info    = "Waiting for all nodes to be Ready, then applying MetalLB and installing Traefik..."
      trigger.on_error = :halt
      if Vagrant::Util::Platform.windows?
        trigger.run = { inline: "powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\\install-addons.ps1" }
      else
        trigger.run = { inline: "bash scripts/install-addons.sh" }
      end
    end
  end

end
