#requires -Version 7.0
<#
.SYNOPSIS
  Phase 1 bootstrap: kind cluster + Argo CD + app-of-apps. Argo CD then
  installs Istio (via Helm) and reconciles the saga services.

.PARAMETER ClusterName
  kind cluster name. Default 'saga'.

.PARAMETER RepoURL
  Git URL of THIS repo (the gitops repo) that Argo CD will reconcile.
  If omitted, the placeholder 'https://github.com/REPLACE_ME_OWNER/saga-gitops.git'
  is left as-is and you must edit apps/*.yaml + apps/app-of-apps.yaml manually
  before running step 3.

.PARAMETER SkipCluster
  Skip 'kind create cluster' (use an existing cluster context).

.EXAMPLE
  pwsh ./scripts/bootstrap-kind.ps1 -RepoURL https://github.com/acme/saga-gitops.git
#>
[CmdletBinding()]
param(
    [string]$ClusterName = 'saga',
    [string]$RepoURL,
    [switch]$SkipCluster
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    Write-Host "==> repo root: $root" -ForegroundColor Cyan

    foreach ($cmd in 'kind', 'kubectl') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "$cmd not found on PATH"
        }
    }

    if (-not $SkipCluster) {
        $existing = & kind get clusters 2>$null
        if ($existing -contains $ClusterName) {
            Write-Host "==> kind cluster '$ClusterName' already exists; skipping create" -ForegroundColor Yellow
        } else {
            Write-Host "==> creating kind cluster '$ClusterName'" -ForegroundColor Cyan
            & kind create cluster --name $ClusterName --config scripts/kind-config.yaml
            if ($LASTEXITCODE -ne 0) { throw "kind create cluster failed" }
        }
    }

    & kubectl cluster-info --context "kind-$ClusterName" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cannot reach cluster context kind-$ClusterName" }

    Write-Host "==> installing Argo CD (kustomize over upstream v2.12.6)" -ForegroundColor Cyan
    & kubectl apply -k platform/argocd/
    if ($LASTEXITCODE -ne 0) { throw "argocd install failed" }

    Write-Host "==> waiting for argocd-server to become Available" -ForegroundColor Cyan
    & kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
    if ($LASTEXITCODE -ne 0) { throw "argocd-server did not become ready" }

    $appOfApps = Get-Content apps/app-of-apps.yaml -Raw
    if ($RepoURL) {
        Write-Host "==> substituting repoURL: $RepoURL" -ForegroundColor Cyan
        $appOfApps = $appOfApps -replace 'https://github\.com/REPLACE_ME_OWNER/saga-gitops\.git', $RepoURL
    }
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $appOfApps -NoNewline
    & kubectl apply -n argocd -f $tmp
    $applyExit = $LASTEXITCODE
    Remove-Item $tmp -Force
    if ($applyExit -ne 0) { throw "app-of-apps apply failed" }

    Write-Host ""
    Write-Host "==> bootstrap complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. argocd UI:    kubectl -n argocd port-forward svc/argocd-server 8080:443"
    Write-Host "                   browse https://localhost:8080 (admin / pwd below)"
    Write-Host "  2. admin pwd:    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | %{ [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$_)) }"
    Write-Host "  3. webui:        http://localhost/   (host:80 -> kind worker NodePort 30080 -> istio-ingressgateway -> web-ui)"
    Write-Host "  4. watch sync:   kubectl -n argocd get applications -w"
    Write-Host ""
    if (-not $RepoURL) {
        Write-Host "WARNING: -RepoURL was not provided. Argo CD will fail to fetch from REPLACE_ME_OWNER/saga-gitops." -ForegroundColor Yellow
        Write-Host "         Edit apps/app-of-apps.yaml + apps/*.yaml + apps/saga-mesh.yaml to point at your fork, commit, then re-apply." -ForegroundColor Yellow
    }
}
finally {
    Pop-Location
}
