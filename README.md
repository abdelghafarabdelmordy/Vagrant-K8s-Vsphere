## Provisioning the Kubernetes cluster on VMware vSphere

Cluster topology: **1 control-plane node (kmaster) + 2 worker nodes (kworker1, kworker2)**,
Kubernetes **v1.37** (current stable, kept in sync via `pkgs.k8s.io`), Calico **v3.32.1**
CNI, provisioned by Vagrant against a vCenter 7.x server.

| | |
|---|---|
| vCenter | `10.10.10.250` |
| User | `administrator@vsphere.local` |
| Datacenter | `intl-site` |
| VM/template folder | `k8s-demo` |
| kmaster | `10.10.10.240` |
| kworker1 | `10.10.10.241` |
| kworker2 | `10.10.10.242` |

Don't commit the real vCenter password to git - see [Credentials](#credentials).

> **Running this from Windows?** `vagrant`, `govc`, `helm`, `kubectl` and
> `packer` are all native Windows binaries and work exactly as shown below in
> PowerShell. The two bash scripts in this repo (the template builder and the
> MetalLB/Traefik installer) each have a PowerShell port - `Vagrantfile`
> picks the right one automatically for step 2's automatic add-on install,
> and step 0.3's template builder is a manual choice either way. Two other
> commands below differ on Windows; each is called out with its PowerShell
> equivalent right where it appears: the NFS setup piping (Add-ons) and the
> Traefik test `curl` (Add-ons) - PowerShell aliases `curl` to
> `Invoke-WebRequest`, which doesn't take `-H` the way real curl does.

### 0. Prerequisites

1. **Vagrant**, plus the vSphere provider plugin:
   ```
   $ vagrant plugin install vagrant-vsphere
   ```
   Also **[Helm 3](https://helm.sh)** and **`kubectl`** on the same machine -
   `vagrant up` now installs MetalLB and Traefik automatically as its last
   step (see [Add-ons](#deploying-add-ons)), and that step needs both. If
   either is missing, `vagrant up` finishes provisioning the cluster fine
   and only that last step fails - safe to fix and re-run.
2. **Network access** from wherever you run `vagrant up`/the template builder
   to `10.10.10.250:443`.
3. **A prepared Ubuntu 22.04 VM template already sitting in vCenter's inventory**
   (folder `k8s-demo`, datacenter `intl-site`). `vagrant-vsphere` clones an
   existing template - it does not build one from an ISO or a Vagrant Cloud
   box the way the VirtualBox/libvirt providers did. Three ways to get one:

   - **Automated, no ISO needed (recommended)** - downloads Canonical's
     official Ubuntu 22.04 cloud image OVA to a local folder of your choice,
     verifies its checksum, imports it into vCenter, preps it (installs
     `open-vm-tools`, creates the `vagrant` user with the Vagrant insecure
     key), and converts it to a template - one command. Two versions of the
     same script, pick the one for your OS:

     **Windows / PowerShell** - [`template/build-template.ps1`](template/build-template.ps1):
     ```powershell
     PS> cd template
     PS> .\build-template.ps1
     # or download the OVA somewhere specific first:
     PS> $env:DOWNLOAD_DIR = 'D:\isos'; .\build-template.ps1
     ```
     Needs `govc.exe` on `PATH` (download the `windows-amd64` zip from
     https://github.com/vmware/govmomi/releases and drop `govc.exe`
     somewhere on your `PATH`, e.g. `C:\Windows\System32` or a folder you add
     yourself). Works in Windows PowerShell 5.1 (built into Windows) or
     PowerShell 7 - no other dependencies (no jq/curl needed, it only uses
     built-in cmdlets).

     **macOS / Linux** - [`template/build-template.sh`](template/build-template.sh):
     ```
     $ cd template
     $ ./build-template.sh
     # or download the OVA somewhere specific first:
     $ DOWNLOAD_DIR=/mnt/isos ./build-template.sh
     ```
     Needs `govc`, `jq` and `curl` on the machine you run it from (`govc`:
     https://github.com/vmware/govmomi/releases).

     Both versions read the same settings, either from environment variables
     or their own defaults at the top of the file (same names as in
     `Vagrantfile`): `VSPHERE_COMPUTE_RESOURCE` (your cluster/host name),
     `VSPHERE_DATASTORE` and `VSPHERE_NETWORK` need to match your real
     inventory. See the script's own header comment for exactly what it does
     at each step.
   - **ISO-based, via Packer** - [`packer/`](packer/) builds the same kind of
     template from an Ubuntu Server ISO instead of the cloud image, if you'd
     rather control the install yourself: `packer init packer/ && packer build packer/`.
     Treat it as a starting point - you supply the ISO's datastore path and
     your own password hash.
   - **Already have a suitable template?** Point `VSPHERE_TEMPLATE` in
     `Vagrantfile` at its name/path and skip both of the above.

   Either build path leaves the template with: `open-vm-tools` installed and
   running, a `vagrant` user with passwordless sudo and the [Vagrant insecure
   public key](https://github.com/hashicorp/vagrant/blob/master/keys/vagrant.pub)
   authorized, and DHCP networking by default (the Customization Specification
   below overrides it per clone).
4. **A vSphere Customization Specification per node**, so each clone comes up
   with the right static IP instead of a random DHCP lease. In the vSphere
   Client: **Menu > Policies and Profiles > VM Customization Specifications >
   New**, guest OS type Linux, and for each node set:

   | Spec name              | Hostname   | IP           | Netmask       | Gateway     | DNS     |
   |-------------------------|------------|--------------|---------------|-------------|---------|
   | `k8s-kmaster-static`   | kmaster    | 10.10.10.240 | 255.255.255.0 | 10.10.10.1  | 8.8.8.8 |
   | `k8s-kworker1-static`  | kworker1   | 10.10.10.241 | 255.255.255.0 | 10.10.10.1  | 8.8.8.8 |
   | `k8s-kworker2-static`  | kworker2   | 10.10.10.242 | 255.255.255.0 | 10.10.10.1  | 8.8.8.8 |

   This lab runs the cluster on the same flat `10.10.10.0/24` as vCenter's own
   management address (`10.10.10.250`) - change the addresses above (and
   `MASTER_IP`/`K8S_KWORKER1_IP`/`K8S_KWORKER2_IP` in `Vagrantfile`) if your
   real VM network/VLAN differs. If you'd rather not manage per-node
   customization specs, leave the matching `CUSTOMIZATION_SPECS` entry blank
   in the Vagrantfile and let DHCP assign addresses instead - you'll then need
   to keep `/etc/hosts` and the node IP variables in sync by hand.

### 1. Configure `Vagrantfile`

Every value you're likely to need to change lives at the top of `Vagrantfile`,
marked `CHANGE ME`, and can also be set via environment variable instead of
editing the file:

| Variable | What it is | Default |
|---|---|---|
| `VSPHERE_HOST` / `VSPHERE_USER` / `VSPHERE_PASSWORD` | vCenter connection | `10.10.10.250` / `admin@vsphere.local` / `*****` |
| `VSPHERE_DATACENTER` | vCenter datacenter name | `intl-site` |
| `VSPHERE_COMPUTE_RESOURCE` | Cluster or standalone ESXi host | `Cluster` **(CHANGE ME)** |
| `VSPHERE_RESOURCE_POOL` | Resource pool | `Resources` |
| `VSPHERE_DATASTORE` | Datastore for the clones | `datastore1` **(CHANGE ME)** |
| `VSPHERE_NETWORK` | Port group / VLAN | `VM Network` **(CHANGE ME)** |
| `VSPHERE_TEMPLATE` | Template to clone (see step 0.3) | `k8s-demo/ubuntu-2204-k8s-template` |
| `VSPHERE_VM_FOLDER` | vCenter folder for the cluster VMs | `k8s-demo` |
| `K8S_MASTER_IP` / `K8S_KWORKER1_IP` / `K8S_KWORKER2_IP` | Static node IPs | `10.10.10.240` / `.41` / `.42` |

`VSPHERE_COMPUTE_RESOURCE`, `VSPHERE_DATASTORE` and `VSPHERE_NETWORK` are the
three values I couldn't fill in for you - they're specific to your vCenter's
actual inventory (cluster/host name, datastore name, port group name) and
aren't guessable. Check the vSphere Client and update them (same variables
are also used by `template/build-template.sh`).

#### Credentials

The defaults embed the vCenter password you gave me so the file works out of
the box, but treat that as a placeholder to replace, not something to leave
in version control. Prefer:
```
$ export VSPHERE_PASSWORD='your-real-password'
$ vagrant up
```
which overrides the in-file default without editing it.

### 2. Bring up the cluster

```
$ vagrant up
```
Vagrant will clone the template three times (kmaster, kworker1, kworker2),
apply each Customization Specification, then run `bootstrap.sh` on every
node followed by `bootstrap_kmaster.sh` / `bootstrap_kworker.sh`. Once all
three nodes are up, a trigger automatically runs
[`scripts/install-addons.sh`](scripts/install-addons.sh) (or
[`.ps1`](scripts/install-addons.ps1) on Windows) to install **MetalLB and
Traefik** - see [Add-ons](#deploying-add-ons) for what that does and how to
skip or re-run it.

### 3. Copy the kubeconfig file from kmaster

Password for the root user is whatever `NODE_ROOT_PASSWORD` is set to
(default `kubeadmin`). Windows 10/11 ships an OpenSSH client, so `scp` works
as-is from PowerShell too:
```
$ mkdir -p ~/.kube
$ scp root@10.10.10.240:/etc/kubernetes/admin.conf ~/.kube/config
```
```powershell
PS> New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.kube" | Out-Null
PS> scp root@10.10.10.240:/etc/kubernetes/admin.conf "$env:USERPROFILE\.kube\config"
```
`kubectl` on Windows reads `%USERPROFILE%\.kube\config` by default, same as
`~/.kube/config` elsewhere - no `KUBECONFIG` env var needed.

### 4. Destroy the cluster

```
$ vagrant destroy -f
```

## Deploying Add-ons

**MetalLB and Traefik install automatically** at the end of `vagrant up` (see
step 2) - the sections below for them are for re-running that step by hand
(it's idempotent, safe to re-run any time) or understanding what it does.
**NFS is still manual** - it isn't wired into the automatic run since it
needs to know which pod/volume workload you actually want it for.

To skip the automatic MetalLB/Traefik install (e.g. you want to configure
them differently), set `SKIP_ADDONS=1` (`$env:SKIP_ADDONS = '1'` in
PowerShell) before `vagrant up`.

## Troubleshooting

### "Timeout while waiting for ip address" while cloning a node

This means the clone booted but never got a network address at all - not
"got the wrong one." The usual cause is that VMware's Linux guest
customization (the step that applies your Customization Specification's
static IP on first boot) needs **Perl on the guest** and fails silently
without it (VMware KB 2075048). If it can't run, nothing writes the clone a
netplan config, so it never gets an IP.

Both template-build paths now install `perl` for this reason. **If you built
your template before this fix, that existing template doesn't have it** -
editing these files alone doesn't change a template already sitting in
vCenter. Rebuild it (`template/build-template.sh` /
`.ps1`, or `packer build packer/`) before trying `vagrant up` again.

If a rebuilt template still times out, the customization step itself is the
next thing to check, not the network settings:
- In the vSphere Client, check **Recent Tasks** for the clone's "Customize
  guest OS" task - it'll show failed if customization itself errored.
- On the guest console (Customization Spec-assigned IPs obviously won't work
  yet, so use the vSphere Client's console tab), check
  `/var/log/vmware-imc/toolsDeployPkg.log` for the actual error.
- Confirm the Customization Specification's name in vCenter matches
  `CUSTOMIZATION_SPECS` in `Vagrantfile` exactly (case-sensitive) - a
  mismatched name fails the clone at a different step, not this one, but is
  worth ruling out.


### MetalLB + Traefik (installed automatically - this is what that step does)

[`scripts/install-addons.sh`](scripts/install-addons.sh) /
[`.ps1`](scripts/install-addons.ps1) - run automatically by the `Vagrantfile`
trigger after `vagrant up`, or by hand any time:
```
$ bash scripts/install-addons.sh
```
```powershell
PS> .\scripts\install-addons.ps1
```
It: pulls a kubeconfig from kmaster via `vagrant ssh` (no root password or
`scp` needed - it reuses Vagrant's own SSH access) into a local
`.kubeconfig` file in the repo root (your own `~/.kube/config` from step 3,
if you set one up, is untouched); waits for all three nodes to be `Ready`;
applies MetalLB (`misc/metallb/`) and waits for its controller; then
`helm upgrade --install`s Traefik (`misc/traefik/`), which grabs a
`LoadBalancer` IP from the MetalLB pool once both are up.

**Why Traefik instead of ingress-nginx**: the Kubernetes project is retiring
`ingress-nginx`, with EOL in **March 2026**
([kubernetes.io announcement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)).
Any manifest that used to say `ingressClassName: nginx` just needs to say
`ingressClassName: traefik` - `misc/traefik/values.yaml` sets Traefik as the
cluster's default `IngressClass`, so plain `Ingress` objects with no
`ingressClassName` route through it automatically too.

MetalLB's IP pool (`misc/metallb/02_metallb-config.yaml`) is
`10.10.10.220-10.10.10.230` - a free slice of the real `10.10.10.0/24`,
clear of `.1`, `.41`, `.42`, `.240` and `.250`. Change it if your real VM
network/VLAN differs.

To test either one, or remove Traefik, once installed:
```
$ export KUBECONFIG=$(pwd)/.kubeconfig
$ kubectl get svc -n traefik-system                      # confirm the LoadBalancer IP
$ kubectl create -f misc/traefik/01-test-ingress.yaml
$ curl -H "Host: whoami.k8s-demo.local" http://<EXTERNAL-IP-from-above>/
$ kubectl delete -f misc/traefik/01-test-ingress.yaml
$ helm uninstall traefik -n traefik-system                # to remove Traefik
```
```powershell
PS> $env:KUBECONFIG = "$(Get-Location)\.kubeconfig"
PS> kubectl get svc -n traefik-system
PS> kubectl create -f misc\traefik\01-test-ingress.yaml
PS> Invoke-WebRequest -Uri "http://<EXTERNAL-IP-from-above>/" -Headers @{ Host = "whoami.k8s-demo.local" }
PS> kubectl delete -f misc\traefik\01-test-ingress.yaml
PS> helm uninstall traefik -n traefik-system
```
(PowerShell aliases `curl` to `Invoke-WebRequest`, which needs `-Headers`
instead of `-H` - or call the real `curl.exe` at
`C:\Windows\System32\curl.exe` directly for the original syntax.)

### Traefik dashboard

The dashboard is off by default (`values.yaml`'s `ingressRoute.dashboard`
stays `false` - the chart's own toggle only puts it on Traefik's internal,
ClusterIP-only entrypoint, not reachable via the LoadBalancer IP anyway).
`misc/traefik/02-dashboard.yaml` exposes it properly instead, on the same
external IP as everything else, behind HTTP basic auth (default
`admin` / `traefik-admin` - see the file's header comment for how to set
your own password):
```
$ kubectl apply -f misc/traefik/02-dashboard.yaml
$ kubectl get svc -n traefik-system                      # same EXTERNAL-IP as before
```
Then browse to `http://<EXTERNAL-IP>/dashboard/` (the trailing slash is
required - Traefik 404s without it) and log in. No hosts-file entry or DNS
name needed, since this one routes on path, not host.

## What changed from the original VirtualBox/libvirt version

- Provider swapped from VirtualBox/libvirt to `vagrant-vsphere`, cloning a
  pre-built template in vCenter 7 at `10.10.10.250` (datacenter `intl-site`,
  folder `k8s-demo`) instead of downloading a Vagrant Cloud box.
- Added an automated, ISO-free template builder that downloads Canonical's
  official Ubuntu 22.04 cloud image and turns it into a vSphere template via
  `govc` - `template/build-template.sh` for macOS/Linux and
  `template/build-template.ps1` for Windows PowerShell (same steps, same
  result) - plus a Packer-based ISO alternative (`packer/`) for anyone who'd
  rather not use the cloud image.
- Node static IPs (`10.10.10.240` / `.241` / `.242`) now come from a vSphere
  Customization Specification per node rather than
  `config.vm.network "private_network"` (vSphere has no equivalent host-only
  network primitive).
- Kubernetes bumped to the current stable release (v1.37) and Calico to
  v3.32.1; both are now variables at the top of `Vagrantfile` instead of
  hardcoded in the bootstrap scripts, so future upgrades are one-line edits.
- `MASTER_IP`, worker IPs and the root password are now defined once in
  `Vagrantfile` and passed to every bootstrap script via the shell
  provisioner's `env`, instead of being duplicated (and able to drift) across
  four files.
- Added `open-vm-tools` and an explicit kubelet `--node-ip` on every node,
  both recommended for VMs running on vSphere.
- Added Traefik (`misc/traefik/`) as the ingress controller add-on, exposed
  via MetalLB, replacing `ingress-nginx` ahead of its March 2026 retirement.
- MetalLB and Traefik now install **automatically** at the end of
  `vagrant up` via a `config.trigger.after :up` in `Vagrantfile`, running
  `scripts/install-addons.sh`/`.ps1` (skip with `SKIP_ADDONS=1`) - previously
  both were manual, separate steps.
- MetalLB's IP pool (`misc/metallb/02_metallb-config.yaml`) now points at a
  free range on the real `10.10.10.0/24` (`10.10.10.220-10.10.10.230`)
  instead of the original lab's `172.16.16.230-172.16.16.250`.
- Topology (1 master, 2 workers) is unchanged from the original.
