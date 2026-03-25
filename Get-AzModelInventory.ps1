<#
.SYNOPSIS
    Inventories all LLM model deployments across Azure subscriptions.

.DESCRIPTION
    Scans all enabled Azure subscriptions accessible to the logged-in account for:
      - Azure OpenAI (Cognitive Services) model deployments
      - Azure Machine Learning online endpoint model deployments

    Outputs a consolidated CSV report with deployment details including subscription,
    resource group, account/endpoint name, model name, version, SKU, capacity, and
    provisioning state.

.PARAMETER OutputPath
    Path to the output CSV file.
    Defaults to 'model-inventory-<yyyyMMdd-HHmmss>.csv' in the current directory.

.PARAMETER SubscriptionIds
    Optional. One or more subscription IDs to scan.
    If omitted, all enabled subscriptions accessible to the logged-in account are used.

.EXAMPLE
    .\models.ps1

.EXAMPLE
    .\models.ps1 -OutputPath "C:\Reports\model-inventory.csv"

.EXAMPLE
    .\models.ps1 -SubscriptionIds "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
    Prerequisites:
      - Azure CLI installed  : https://learn.microsoft.com/cli/azure/install-azure-cli
      - Authenticated        : run 'az login' before executing this script
      - Permissions required : Reader role on all target subscriptions
      - The 'resource-graph' Azure CLI extension is auto-installed if missing
#>

[CmdletBinding()]
param(
    [string]   $OutputPath      = "model-inventory-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    [string[]] $SubscriptionIds = @()
)

$ErrorActionPreference = 'Continue'

# ── Helper functions ───────────────────────────────────────────────────────────

function Invoke-AzRestJson([string]$Url) {
    # Calls the Azure ARM REST API via the CLI and returns a parsed object.
    $raw = az rest --method get --url $Url --only-show-errors 2>$null
    if (-not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Invoke-GraphQuery([string]$Query, [string[]]$Subscriptions) {
    # Executes a Resource Graph query with automatic pagination.
    $results   = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    do {
        $page = if ($skipToken) {
            az graph query -q $Query -s $Subscriptions --first 1000 `
                --skip-token $skipToken -o json --only-show-errors 2>$null | ConvertFrom-Json
        } else {
            az graph query -q $Query -s $Subscriptions --first 1000 `
                -o json --only-show-errors 2>$null | ConvertFrom-Json
        }
        if ($page -and $page.data) { $results.AddRange([object[]]$page.data) }
        $skipToken = if ($page) { $page.skip_token } else { $null }
    } while ($skipToken)
    return $results
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
Write-Host "Checking prerequisites..."

$azAccount = az account show -o json --only-show-errors 2>$null
if (-not $azAccount) {
    Write-Error "Not logged in to Azure CLI. Run 'az login' first, then re-run this script."
    exit 1
}

$rgExt = az extension list --query "[?name=='resource-graph']" -o json --only-show-errors 2>$null | ConvertFrom-Json
if (-not $rgExt) {
    Write-Host "  Installing 'resource-graph' Azure CLI extension..."
    az extension add --name resource-graph --allow-preview true --only-show-errors
}

# ── Subscription discovery ─────────────────────────────────────────────────────
if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
    $subs = $SubscriptionIds
    Write-Host "  Using $($subs.Count) subscription(s) provided as input."
} else {
    $subs = az account list --query "[?state=='Enabled'].id" -o json --only-show-errors 2>$null | ConvertFrom-Json
    Write-Host "  Discovered $($subs.Count) enabled subscription(s)."
}

if (-not $subs -or $subs.Count -eq 0) {
    Write-Error "No enabled subscriptions found. Ensure your account has access to at least one enabled subscription."
    exit 1
}

$report = [System.Collections.Generic.List[pscustomobject]]::new()

# ── Step 1: Discover Azure OpenAI accounts ────────────────────────────────────
Write-Host "`n[1/4] Querying Azure OpenAI accounts via Resource Graph..."
$oaiQuery = "Resources | where type =~ 'microsoft.cognitiveservices/accounts' | where kind has 'OpenAI' or properties.kind has 'OpenAI' | project subscriptionId, resourceGroup, name, location, kind, id"
$oaiAccounts = Invoke-GraphQuery -Query $oaiQuery -Subscriptions $subs
Write-Host "      Found $($oaiAccounts.Count) Azure OpenAI account(s)."

# ── Step 2: List model deployments per OpenAI account ─────────────────────────
Write-Host "[2/4] Retrieving model deployments from each Azure OpenAI account..."
$i = 0
foreach ($acct in $oaiAccounts) {
    $i++
    Write-Progress -Activity "Azure OpenAI Deployments" `
                   -Status  "$i / $($oaiAccounts.Count)  —  $($acct.name)  ($($acct.resourceGroup))" `
                   -PercentComplete ([math]::Round($i / [math]::Max($oaiAccounts.Count, 1) * 100))
    $url  = "https://management.azure.com$($acct.id)/deployments?api-version=2024-10-01"
    $resp = Invoke-AzRestJson -Url $url
    if ($resp -and $resp.value) {
        foreach ($d in $resp.value) {
            $report.Add([pscustomobject]@{
                Source          = "AzureOpenAI"
                SubscriptionId  = $acct.subscriptionId
                ResourceGroup   = $acct.resourceGroup
                AccountName     = $acct.name
                Location        = $acct.location
                DeploymentName  = $d.name
                ModelName       = $d.properties.model.name
                ModelVersion    = $d.properties.model.version
                SkuName         = $d.sku.name
                Capacity        = $d.sku.capacity
                UpgradePolicy   = $d.properties.versionUpgradeOption
                ProvisionState  = $d.properties.provisioningState
                ResourceId      = $d.id
            })
        }
    }
}
Write-Progress -Activity "Azure OpenAI Deployments" -Completed
$oaiDeployCount = ($report | Where-Object Source -eq "AzureOpenAI").Count
Write-Host "      Found $oaiDeployCount Azure OpenAI deployment(s)."

# ── Step 3: Discover Azure ML online endpoints ────────────────────────────────
Write-Host "[3/4] Querying Azure ML online endpoints via Resource Graph..."
$amlQuery = "Resources | where type =~ 'microsoft.machinelearningservices/workspaces/onlineendpoints' | project subscriptionId, resourceGroup, name, id"
$amlEndpoints = Invoke-GraphQuery -Query $amlQuery -Subscriptions $subs
Write-Host "      Found $($amlEndpoints.Count) AML online endpoint(s)."

# ── Step 4: List model deployments per AML online endpoint ────────────────────
Write-Host "[4/4] Retrieving model deployments from each AML online endpoint..."
$j = 0
foreach ($ep in $amlEndpoints) {
    $j++
    Write-Progress -Activity "AML Online Endpoint Deployments" `
                   -Status  "$j / $($amlEndpoints.Count)  —  $($ep.name)  ($($ep.resourceGroup))" `
                   -PercentComplete ([math]::Round($j / [math]::Max($amlEndpoints.Count, 1) * 100))
    $url  = "https://management.azure.com$($ep.id)/deployments?api-version=2024-04-01"
    $resp = Invoke-AzRestJson -Url $url
    if ($resp -and $resp.value) {
        foreach ($d in $resp.value) {
            $report.Add([pscustomobject]@{
                Source          = "AMLOnlineEndpoint"
                SubscriptionId  = $ep.subscriptionId
                ResourceGroup   = $ep.resourceGroup
                AccountName     = $ep.name
                Location        = $d.location
                DeploymentName  = $d.name
                ModelName       = $d.properties.model
                ModelVersion    = ""
                SkuName         = $d.sku.name
                Capacity        = $d.sku.capacity
                UpgradePolicy   = ""
                ProvisionState  = $d.properties.provisioningState
                ResourceId      = $d.id
            })
        }
    }
}
Write-Progress -Activity "AML Online Endpoint Deployments" -Completed
$amlDeployCount = ($report | Where-Object Source -eq "AMLOnlineEndpoint").Count
Write-Host "      Found $amlDeployCount AML deployment(s)."

# ── Export ────────────────────────────────────────────────────────────────────
$total = $report.Count
if ($total -eq 0) {
    Write-Warning "No model deployments found. CSV not created."
} else {
    $report | Sort-Object Source, SubscriptionId, ResourceGroup, AccountName |
        Export-Csv -NoTypeInformation -Path $OutputPath
    $resolvedPath = Resolve-Path $OutputPath
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Host "  Scan complete."
    Write-Host "  Subscriptions scanned : $($subs.Count)"
    Write-Host "  Azure OpenAI deploys  : $oaiDeployCount"
    Write-Host "  AML endpoint deploys  : $amlDeployCount"
    Write-Host "  Total deployments     : $total"
    Write-Host "  Report saved to       : $resolvedPath"
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    $report | Select-Object Source, ResourceGroup, AccountName, DeploymentName,
                  ModelName, ModelVersion, Location, SkuName, Capacity, ProvisionState |
        Format-Table -AutoSize
}