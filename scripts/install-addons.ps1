<#
==============================================================================
Deploys MetalLB and Traefik once the whole cluster is up. Run automatically
by the Vagrantfile trigger after `vagrant up` finishes (see the
`config.trigger.after :up` block near the bottom of ..\Vagrantfile) - or run
by hand any time afterward to re-apply/retry just this part:

  PS> .\scripts\install-addons.ps1

Skip the automatic run with $env:SKIP_ADDONS = '1' (see ..\README.md).

Requires on the machine you run this from: vagrant, kubectl, helm.
Deliberately does NOT need an scp/password step - it pulls the kubeconfig
through `vagrant ssh`, which already knows how to reach kmaster (same
insecure key the template's `vagrant` user trusts), so there's no root
password or extra SSH plumbing on the Windows side at all.
==============================================================================
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir
$KubeconfigPath = [Environment]::GetEnvironmentVariable('KUBECONFIG_PATH')
if ([string]::IsNullOrEmpty($KubeconfigPath)) { $KubeconfigPath = Join-Path $RepoRoot '.kubeconfig' }

foreach ($bin in @('vagrant', 'kubectl', 'helm')) {
    if (-not (Get-Command $bin -ErrorAction SilentlyContinue)) {
        Write-Error "ERROR: '$bin' is required but not found in PATH"
        exit 1
    }
}

Push-Location $RepoRoot
try {

    Write-Host "Fetching kubeconfig from kmaster via 'vagrant ssh'..."
    $kubeconfigLines = & vagrant ssh kmaster -c "sudo cat /etc/kubernetes/admin.conf"
    if ($LASTEXITCODE -ne 0 -or -not $kubeconfigLines) { throw "'vagrant ssh kmaster' failed to fetch the kubeconfig" }
    $kubeconfigText = ($kubeconfigLines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($KubeconfigPath, $kubeconfigText, (New-Object System.Text.UTF8Encoding($false)))
    $env:KUBECONFIG = $KubeconfigPath

    Write-Host "Waiting for all nodes to be Ready (up to 5 minutes)..."
    & kubectl wait --for=condition=Ready nodes --all --timeout=300s
    if ($LASTEXITCODE -ne 0) { throw "kubectl wait for node readiness failed" }

    Write-Host "Applying MetalLB..."
    & kubectl apply --server-side --force-conflicts -f (Join-Path $RepoRoot 'misc\metallb\01_metallb.yaml')
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply of MetalLB failed" }
    & kubectl -n metallb-system wait --for=condition=Available deployment/controller --timeout=180s
    if ($LASTEXITCODE -ne 0) { throw "MetalLB controller did not become ready in time" }
    & kubectl apply --server-side --force-conflicts -f (Join-Path $RepoRoot 'misc\metallb\02_metallb-config.yaml')
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply of the MetalLB IP pool failed" }

    Write-Host "Installing Traefik via Helm..."
    & helm repo add traefik https://traefik.github.io/charts 2>$null | Out-Null
    & helm repo update | Out-Null
    & kubectl create namespace traefik-system --dry-run=client -o yaml | kubectl apply -f -
    & helm upgrade --install traefik traefik/traefik `
        --namespace traefik-system `
        --values (Join-Path $RepoRoot 'misc\traefik\values.yaml') `
        --wait
    if ($LASTEXITCODE -ne 0) { throw "helm install of Traefik failed" }

    Write-Host "Applying Traefik dashboard route..."
    & kubectl apply -f (Join-Path $RepoRoot 'misc\traefik\02-dashboard.yaml')
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply of the Traefik dashboard route failed" }

    Write-Host ""
    Write-Host "Done. MetalLB and Traefik are installed."
    Write-Host ""
    Write-Host "kubeconfig saved to: $KubeconfigPath"
    Write-Host "  `$env:KUBECONFIG = '$KubeconfigPath'"
    Write-Host "(this is a separate copy - your default `$env:USERPROFILE\.kube\config, if you"
    Write-Host " set one up per the README's step 3, is untouched)"
    Write-Host ""
    & kubectl get svc -n traefik-system
    Write-Host ""
    Write-Host "Traefik dashboard: http://<EXTERNAL-IP above>/dashboard/  (admin / traefik-admin -"
    Write-Host "change this - see misc\traefik\02-dashboard.yaml's header comment)"

}
finally {
    Pop-Location
}
