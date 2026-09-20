<#
==============================================================================
Automated Ubuntu 22.04 vSphere template builder for the K8s Vagrant cluster.
Windows / PowerShell port of build-template.sh - same steps, same result.

What it does, end to end, with no ISO and no manual VM console work:
  1. Downloads Canonical's official Ubuntu 22.04 cloud image OVA to a local
     folder (verified against Ubuntu's published SHA256SUMS).
  2. Imports it into vCenter with govc, using the OVA's built-in OVF/cloud-init
     properties to inject an SSH key, create a `vagrant` user, and install
     open-vm-tools - the same prep Vagrant boxes normally ship with.
  3. Grows the disk, boots it once so cloud-init can do that prep, waits for
     it to shut itself down, then converts it to a vSphere template.

Result: a template ready for VSPHERE_TEMPLATE in ..\Vagrantfile.

Requires: govc.exe on PATH (https://github.com/vmware/govmomi/releases -
pick the windows-amd64 zip). PowerShell 5.1+ (ships with Windows) or
PowerShell 7 both work - no jq/curl/sha256sum needed, this uses only
built-in cmdlets.

Usage (PowerShell):
  .\build-template.ps1
  $env:DOWNLOAD_DIR = 'D:\isos'; .\build-template.ps1      # download OVA elsewhere
  $env:VSPHERE_COMPUTE_RESOURCE = 'MyCluster'; .\build-template.ps1
==============================================================================
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-EnvOrDefault {
    param([string]$Name, [string]$Default)
    $val = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($val)) { return $Default }
    return $val
}

# ------------------------------------------------------------------------------
# vCenter connection + inventory - matches ..\Vagrantfile. Override any of
# these with an environment variable of the same name instead of editing here.
# ------------------------------------------------------------------------------
$env:GOVC_URL        = Get-EnvOrDefault 'GOVC_URL'        '10.10.10.250'
$env:GOVC_USERNAME   = Get-EnvOrDefault 'GOVC_USERNAME'   'administrator@vsphere.local'          #change this to your vSphere user if different
$env:GOVC_PASSWORD   = Get-EnvOrDefault 'GOVC_PASSWORD'   '*********'
$env:GOVC_INSECURE   = Get-EnvOrDefault 'GOVC_INSECURE'   '1'
$env:GOVC_DATACENTER = Get-EnvOrDefault 'GOVC_DATACENTER' 'Intl-site'

$VsphereComputeResource = Get-EnvOrDefault 'VSPHERE_COMPUTE_RESOURCE' 'Intl-cluster'
$VsphereResourcePool    = Get-EnvOrDefault 'VSPHERE_RESOURCE_POOL'    'Resources/k8s-demo-Resources'  # every cluster has an implicit root pool called "Resources" - custom pools nest under it
$VsphereDatastore       = Get-EnvOrDefault 'VSPHERE_DATASTORE'        'NetApp SSD Data'
$VsphereNetwork         = Get-EnvOrDefault 'VSPHERE_NETWORK'          'Intl-VM-Prod'
$VsphereFolder          = Get-EnvOrDefault 'VSPHERE_FOLDER'           'k8s-demo'      # holds both the template and the cluster VMs

$env:GOVC_DATASTORE      = $VsphereDatastore
$env:GOVC_RESOURCE_POOL  = "$VsphereComputeResource/$VsphereResourcePool"

# ------------------------------------------------------------------------------
# Template / build settings
# ------------------------------------------------------------------------------
$TemplateName     = Get-EnvOrDefault 'TEMPLATE_NAME'     'ubuntu-2204-k8s-template'
$UbuntuRelease    = Get-EnvOrDefault 'UBUNTU_RELEASE'     '22.04'
$DownloadDir      = Get-EnvOrDefault 'DOWNLOAD_DIR'       (Join-Path (Get-Location) 'downloads')  # <-- "any folder": override freely
$TemplateCpu      = Get-EnvOrDefault 'TEMPLATE_CPU'       '2'
$TemplateMemMb    = Get-EnvOrDefault 'TEMPLATE_MEM_MB'    '2048'
$TemplateDiskGb   = Get-EnvOrDefault 'TEMPLATE_DISK_GB'   '40'
$RootPassword     = Get-EnvOrDefault 'ROOT_PASSWORD'      'kubeadmin'
$VagrantPubkeyUrl = Get-EnvOrDefault 'VAGRANT_PUBKEY_URL' 'https://raw.githubusercontent.com/hashicorp/vagrant/master/keys/vagrant.pub'

$OvaFile = "ubuntu-$UbuntuRelease-server-cloudimg-amd64.ova"
$OvaUrl  = "https://cloud-images.ubuntu.com/releases/$UbuntuRelease/release/$OvaFile"
$ShaUrl  = "https://cloud-images.ubuntu.com/releases/$UbuntuRelease/release/SHA256SUMS"

if (-not (Get-Command govc -ErrorAction SilentlyContinue)) {
    Write-Error "ERROR: 'govc' is required but not found in PATH. Download the windows-amd64 build from https://github.com/vmware/govmomi/releases and put govc.exe on PATH."
    exit 1
}

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("k8s-template-build-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $WorkDir | Out-Null

try {

    Write-Host "[1/8] Downloading $OvaFile to $DownloadDir (skips if already present and valid)"
    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $OvaPath     = Join-Path $DownloadDir $OvaFile
    $ShaSumsPath = Join-Path $WorkDir 'SHA256SUMS'
    Invoke-WebRequest -Uri $ShaUrl -OutFile $ShaSumsPath -UseBasicParsing

    $shaLine = Select-String -Path $ShaSumsPath -Pattern ([regex]::Escape($OvaFile)) | Select-Object -First 1
    if (-not $shaLine) {
        Write-Error "ERROR: couldn't find $OvaFile in Ubuntu's SHA256SUMS - check UBUNTU_RELEASE"
        exit 1
    }
    $expectedSha = (($shaLine.Line -split '\s+')[0]).ToLower()

    $needsDownload = $true
    if (Test-Path $OvaPath) {
        $actualSha = (Get-FileHash -Path $OvaPath -Algorithm SHA256).Hash.ToLower()
        if ($actualSha -eq $expectedSha) {
            Write-Host "      already downloaded and checksum matches, skipping"
            $needsDownload = $false
        }
    }
    if ($needsDownload) {
        Invoke-WebRequest -Uri $OvaUrl -OutFile $OvaPath -UseBasicParsing
        $actualSha = (Get-FileHash -Path $OvaPath -Algorithm SHA256).Hash.ToLower()
        if ($actualSha -ne $expectedSha) {
            Write-Error "ERROR: checksum mismatch for $OvaFile (expected $expectedSha, got $actualSha)"
            exit 1
        }
    }

    Write-Host "[2/8] Fetching the Vagrant insecure public key for template SSH access"
    $VagrantPubKeyPath = Join-Path $WorkDir 'vagrant.pub'
    Invoke-WebRequest -Uri $VagrantPubkeyUrl -OutFile $VagrantPubKeyPath -UseBasicParsing
    $VagrantPubKey = (Get-Content $VagrantPubKeyPath -Raw).Trim()

    Write-Host "[3/8] Rendering cloud-init user-data"
    $ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
    $TemplateFile = Join-Path $ScriptDir 'cloud-init-user-data.yaml.tmpl'
    $UserDataPath = Join-Path $WorkDir 'user-data.yaml'
    $rendered = (Get-Content $TemplateFile -Raw).
        Replace('__VAGRANT_PUBLIC_KEY__', $VagrantPubKey).
        Replace('__ROOT_PASSWORD__', $RootPassword)
    # cloud-config is YAML - write with LF line endings and no BOM, same as the bash version
    [System.IO.File]::WriteAllText($UserDataPath, $rendered.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $UserDataB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($UserDataPath))

    Write-Host "[4/8] Ensuring the vCenter VM folder `"$VsphereFolder`" exists"
    & govc folder.create "/$($env:GOVC_DATACENTER)/vm/$VsphereFolder" 2>$null | Out-Null
    # non-zero exit here just means the folder already exists - fine either way

    Write-Host "[5/8] Building the OVF import spec"
    $specJson = & govc import.spec $OvaPath
    if ($LASTEXITCODE -ne 0) { throw "govc import.spec failed" }
    $spec = $specJson | ConvertFrom-Json

    $spec.Name           = $TemplateName
    $spec.PowerOn         = $false
    $spec.WaitForIP       = $false
    $spec.MarkAsTemplate  = $false
    $spec.InjectOvfEnv    = $true
    $spec.NetworkMapping  = @( [PSCustomObject]@{ Name = $spec.NetworkMapping[0].Name; Network = $VsphereNetwork } )
    $spec.PropertyMapping = @(
        [PSCustomObject]@{ Key = 'instance-id'; Value = 'id-ovf' },
        [PSCustomObject]@{ Key = 'hostname';    Value = $TemplateName },
        [PSCustomObject]@{ Key = 'seedfrom';    Value = '' },
        [PSCustomObject]@{ Key = 'public-keys'; Value = '' },
        [PSCustomObject]@{ Key = 'user-data';   Value = $UserDataB64 },
        [PSCustomObject]@{ Key = 'password';    Value = '' }
    )

    $specPath = Join-Path $WorkDir 'spec.json'
    $specJsonOut = $spec | ConvertTo-Json -Depth 10
    # govc's JSON decoder (Go) chokes on a UTF-8 BOM, which Set-Content -Encoding UTF8
    # always adds on Windows PowerShell 5.1 - write it explicitly without one instead.
    [System.IO.File]::WriteAllText($specPath, $specJsonOut, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "[6/8] Importing OVA into vCenter as `"$VsphereFolder/$TemplateName`" (this can take a few minutes)"
    # Pass -ds explicitly rather than relying on govc's GOVC_DATASTORE name lookup -
    # a datastore name that isn't unique across the inventory (e.g. visible via more
    # than one path/host) makes that lookup fail with "resolves to multiple instances".
    & govc import.ova -options="$specPath" -folder="/$($env:GOVC_DATACENTER)/vm/$VsphereFolder" -ds="/$($env:GOVC_DATACENTER)/datastore/$VsphereDatastore" $OvaPath
    if ($LASTEXITCODE -ne 0) { throw "govc import.ova failed with exit code $LASTEXITCODE" }

    $VmPath = "/$($env:GOVC_DATACENTER)/vm/$VsphereFolder/$TemplateName"

    Write-Host "[7/8] Sizing the VM ($TemplateCpu vCPU, ${TemplateMemMb}MB RAM, ${TemplateDiskGb}GB disk) and booting it once for cloud-init to run"
    & govc vm.change -vm $VmPath -c $TemplateCpu -m $TemplateMemMb -e="disk.enableUUID=1"
    if ($LASTEXITCODE -ne 0) { throw "govc vm.change failed" }
    # Splatted (array) rather than a composed string - Windows PowerShell can mangle a bare
    # "-word.word" argument token (like -disk.label) when passed to a native exe as part of
    # a string; passing each element as a discrete array item avoids that re-tokenizing entirely.
    $diskChangeArgs = @('vm.disk.change', '-vm', $VmPath, '-disk.label', 'Hard disk 1', '-size', "${TemplateDiskGb}G")
    & govc @diskChangeArgs
    if ($LASTEXITCODE -ne 0) { throw "govc vm.disk.change failed" }
    & govc vm.power -on=true $VmPath
    if ($LASTEXITCODE -ne 0) { throw "govc vm.power -on failed" }

    Write-Host "      waiting for cloud-init to finish and the VM to power itself off (usually 2-5 minutes)"
    $powerState = ''
    while ($powerState -ne 'poweredOff') {
        Start-Sleep -Seconds 10
        $infoJson = & govc vm.info -json $VmPath
        $info = $infoJson | ConvertFrom-Json
        $vmInfo = if ($info.virtualMachines) { $info.virtualMachines[0] } else { $info.VirtualMachines[0] }
        $powerState = if ($vmInfo.runtime) { $vmInfo.runtime.powerState } else { $vmInfo.Runtime.PowerState }
    }

    Write-Host "[8/8] Converting to a template"
    & govc vm.markastemplate $VmPath
    if ($LASTEXITCODE -ne 0) { throw "govc vm.markastemplate failed" }

    Write-Host ""
    Write-Host "Done. Template ready at: $VsphereFolder/$TemplateName"
    Write-Host ""
    Write-Host "Set this in ..\Vagrantfile (or leave it - it's already the default there):"
    Write-Host "  VSPHERE_TEMPLATE = `"$VsphereFolder/$TemplateName`""
    Write-Host ""
    Write-Host "Remember this template still needs a vSphere Customization Specification per"
    Write-Host "node (kmaster/kworker1/kworker2) for static IP assignment on clone - see"
    Write-Host "..\README.md."

}
finally {
    Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
}
