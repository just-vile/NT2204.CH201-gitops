# Phase 2 helm template validation across all 5 services.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Push-Location $repo
try {
    foreach ($svc in 'order-service','payment-service','inventory-service','shipping-service','web-ui') {
        Write-Host ""
        Write-Host ("===== {0} =====" -f $svc) -ForegroundColor Cyan
        $rendered = docker run --rm -v "${repo}:/work" alpine/helm:3.16.2 template /work/charts/saga-service -f "/work/environments/local/values-$svc.yaml" 2>&1
        $matches = $rendered | Select-String -Pattern "name: RabbitMq__|name: ConnectionStrings|secretKeyRef|value: ""saga"""
        if ($matches) {
            $matches | ForEach-Object { "  $_" }
        } else {
            Write-Host "  (no env-related lines matched — web-ui expected)" -ForegroundColor DarkGray
        }
    }
}
finally {
    Pop-Location
}
