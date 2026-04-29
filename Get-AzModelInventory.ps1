<#
.SYNOPSIS
    Inventories all LLM model deployments across Azure subscriptions with retirement awareness.

.DESCRIPTION
    Scans all enabled Azure subscriptions accessible to the logged-in account for:
      - Azure OpenAI (Cognitive Services) model deployments
      - Azure Machine Learning online endpoint model deployments

    Enriches Azure OpenAI deployments with lifecycle status and retirement dates from
    the Azure OpenAI Models API, then highlights each deployment by retirement risk:

      Color    Risk      Meaning
      ──────   ────────  ────────────────────────────────────────────
      Red      Retired   Model no longer listed in Azure (likely retired)
      Red      Critical  Retiring within 30 days
      Yellow   High      Retiring within 31-60 days
      Cyan     Medium    Retiring within 61-90 days
      Green    Low       Retiring in more than 90 days
      White    None      No retirement date / AML endpoint

    New CSV columns: LifecycleStatus, RetirementDate, DaysUntilRetirement, RetirementRisk

.PARAMETER OutputPath
    Path to the output CSV file.
    Defaults to 'model-inventory-<yyyyMMdd-HHmmss>.csv' in the current directory.

.PARAMETER SubscriptionIds
    Optional. One or more subscription IDs to scan.
    If omitted, all enabled subscriptions accessible to the logged-in account are used.

.EXAMPLE
    .\Get-AzModelInventory.ps1

.EXAMPLE
    .\Get-AzModelInventory.ps1 -OutputPath "C:\Reports\model-inventory.csv"

.EXAMPLE
    .\Get-AzModelInventory.ps1 -SubscriptionIds "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

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

function Get-ModelLifecycleMap([string]$AccountId) {
    # Queries the Azure OpenAI Models API for an account and returns a hashtable
    # keyed by "modelName::version" with LifecycleStatus and RetirementDate.
    $url  = "https://management.azure.com$($AccountId)/models?api-version=2024-10-01"
    $resp = Invoke-AzRestJson -Url $url
    $map  = @{}
    if ($resp -and $resp.value) {
        foreach ($entry in $resp.value) {
            $m = if ($entry.PSObject.Properties['model']) { $entry.model } else { $entry }
            if (-not $m -or -not $m.name) { continue }
            $retireDate = $null
            if ($m.PSObject.Properties['deprecationDate'] -and $m.deprecationDate) {
                try { $retireDate = [datetime]$m.deprecationDate } catch {}
            }
            $key      = "$($m.name)::$($m.version)"
            $map[$key] = @{
                LifecycleStatus = if ($m.lifecycleStatus) { $m.lifecycleStatus } else { 'Unknown' }
                RetirementDate  = $retireDate
            }
        }
    }
    return $map
}

function Get-RetirementRisk {
    param(
        [string] $LifecycleStatus,
        $RetirementDate
    )
    if ($LifecycleStatus -eq 'Retired') { return 'Retired' }
    if ($null -eq $RetirementDate)      { return 'None'    }
    $days = ([datetime]$RetirementDate - (Get-Date)).TotalDays
    if ($days -lt 0)  { return 'Retired'  }
    if ($days -le 30) { return 'Critical' }
    if ($days -le 60) { return 'High'     }
    if ($days -le 90) { return 'Medium'   }
    return 'Low'
}

function Get-RiskColor([string]$Risk) {
    switch ($Risk) {
        'Retired'  { return 'Red'    }
        'Critical' { return 'Red'    }
        'High'     { return 'Yellow' }
        'Medium'   { return 'Cyan'   }
        'Low'      { return 'Green'  }
        default    { return 'White'  }
    }
}

function Truncate([string]$s, [int]$len) {
    if ([string]::IsNullOrEmpty($s)) { return ''.PadRight($len) }
    if ($s.Length -le $len)          { return $s.PadRight($len) }
    return ($s.Substring(0, $len - 1) + [char]0x2026).PadRight($len)
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

$report         = [System.Collections.Generic.List[pscustomobject]]::new()
$lifecycleCache = @{}   # keyed by account resource ID; one API call per account

# ── Step 1: Discover Azure OpenAI accounts ────────────────────────────────────
Write-Host "`n[1/4] Querying Azure OpenAI accounts via Resource Graph..."
$oaiQuery    = "Resources | where type =~ 'microsoft.cognitiveservices/accounts' | where kind has 'OpenAI' or properties.kind has 'OpenAI' | project subscriptionId, resourceGroup, name, location, kind, id"
$oaiAccounts = Invoke-GraphQuery -Query $oaiQuery -Subscriptions $subs
Write-Host "      Found $($oaiAccounts.Count) Azure OpenAI account(s)."

# ── Step 2: List model deployments per OpenAI account (with lifecycle data) ───
Write-Host "[2/4] Retrieving model deployments and lifecycle data from each Azure OpenAI account..."
$i = 0
foreach ($acct in $oaiAccounts) {
    $i++
    Write-Progress -Activity "Azure OpenAI Deployments" `
                   -Status  "$i / $($oaiAccounts.Count)  —  $($acct.name)  ($($acct.resourceGroup))" `
                   -PercentComplete ([math]::Round($i / [math]::Max($oaiAccounts.Count, 1) * 100))

    # Fetch lifecycle map once per account and cache it
    if (-not $lifecycleCache.ContainsKey($acct.id)) {
        $lifecycleCache[$acct.id] = Get-ModelLifecycleMap -AccountId $acct.id
    }
    $lcMap = $lifecycleCache[$acct.id]

    $url  = "https://management.azure.com$($acct.id)/deployments?api-version=2024-10-01"
    $resp = Invoke-AzRestJson -Url $url
    if ($resp -and $resp.value) {
        foreach ($d in $resp.value) {
            $mName    = $d.properties.model.name
            $mVersion = $d.properties.model.version
            $lcKey    = "$mName::$mVersion"
            $lcInfo   = $lcMap[$lcKey]

            # A model absent from the models list is treated as already retired
            $lcStatus = if ($lcInfo) { $lcInfo.LifecycleStatus } else { 'Retired' }
            $retDate  = if ($lcInfo) { $lcInfo.RetirementDate  } else { $null     }
            $risk     = Get-RetirementRisk -LifecycleStatus $lcStatus -RetirementDate $retDate
            $daysLeft = if ($retDate) { [int]([datetime]$retDate - (Get-Date)).TotalDays } else { $null }

            $report.Add([pscustomobject]@{
                Source              = 'AzureOpenAI'
                SubscriptionId      = $acct.subscriptionId
                ResourceGroup       = $acct.resourceGroup
                AccountName         = $acct.name
                Location            = $acct.location
                DeploymentName      = $d.name
                ModelName           = $mName
                ModelVersion        = $mVersion
                SkuName             = $d.sku.name
                Capacity            = $d.sku.capacity
                UpgradePolicy       = $d.properties.versionUpgradeOption
                ProvisionState      = $d.properties.provisioningState
                LifecycleStatus     = $lcStatus
                RetirementDate      = if ($retDate) { $retDate.ToString('yyyy-MM-dd') } else { '' }
                DaysUntilRetirement = $daysLeft
                RetirementRisk      = $risk
                ResourceId          = $d.id
            })
        }
    }
}
Write-Progress -Activity "Azure OpenAI Deployments" -Completed
$oaiDeployCount = ($report | Where-Object Source -eq 'AzureOpenAI').Count
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
                Source              = 'AMLOnlineEndpoint'
                SubscriptionId      = $ep.subscriptionId
                ResourceGroup       = $ep.resourceGroup
                AccountName         = $ep.name
                Location            = $d.location
                DeploymentName      = $d.name
                ModelName           = $d.properties.model
                ModelVersion        = ''
                SkuName             = $d.sku.name
                Capacity            = $d.sku.capacity
                UpgradePolicy       = ''
                ProvisionState      = $d.properties.provisioningState
                LifecycleStatus     = 'Unknown'
                RetirementDate      = ''
                DaysUntilRetirement = $null
                RetirementRisk      = 'None'
                ResourceId          = $d.id
            })
        }
    }
}
Write-Progress -Activity "AML Online Endpoint Deployments" -Completed
$amlDeployCount = ($report | Where-Object Source -eq 'AMLOnlineEndpoint').Count
Write-Host "      Found $amlDeployCount AML deployment(s)."

# ── Export ────────────────────────────────────────────────────────────────────
$total = $report.Count
if ($total -eq 0) {
    Write-Warning "No model deployments found. CSV not created."
} else {
    $report | Sort-Object Source, SubscriptionId, ResourceGroup, AccountName |
        Export-Csv -NoTypeInformation -Path $OutputPath
    $resolvedPath = Resolve-Path $OutputPath

    # ── Risk counts ───────────────────────────────────────────────────────────
    $retiredCnt  = ($report | Where-Object RetirementRisk -eq 'Retired').Count
    $criticalCnt = ($report | Where-Object RetirementRisk -eq 'Critical').Count
    $highCnt     = ($report | Where-Object RetirementRisk -eq 'High').Count
    $mediumCnt   = ($report | Where-Object RetirementRisk -eq 'Medium').Count
    $lowCnt      = ($report | Where-Object RetirementRisk -eq 'Low').Count

    # ── Summary banner ────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Host "  Scan complete."
    Write-Host "  Subscriptions scanned : $($subs.Count)"
    Write-Host "  Azure OpenAI deploys  : $oaiDeployCount"
    Write-Host "  AML endpoint deploys  : $amlDeployCount"
    Write-Host "  Total deployments     : $total"
    Write-Host ""
    Write-Host "  Retirement Risk Summary:"
    if ($retiredCnt  -gt 0) { Write-Host "    [RETIRED ]  $retiredCnt deployment(s) — model no longer available, immediate action required!" -ForegroundColor Red    }
    if ($criticalCnt -gt 0) { Write-Host "    [CRITICAL]  $criticalCnt deployment(s) — retiring within 30 days!"                             -ForegroundColor Red    }
    if ($highCnt     -gt 0) { Write-Host "    [HIGH    ]  $highCnt deployment(s) — retiring within 31-60 days"                               -ForegroundColor Yellow }
    if ($mediumCnt   -gt 0) { Write-Host "    [MEDIUM  ]  $mediumCnt deployment(s) — retiring within 61-90 days"                             -ForegroundColor Cyan   }
    if ($lowCnt      -gt 0) { Write-Host "    [LOW     ]  $lowCnt deployment(s) — retiring in more than 90 days"                             -ForegroundColor Green  }
    if (($retiredCnt + $criticalCnt + $highCnt + $mediumCnt + $lowCnt) -eq 0) {
        Write-Host "    No retirement risks detected." -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  Report saved to       : $resolvedPath"
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ── Color-coded deployment table sorted by urgency ────────────────────────
    $riskOrder = @{ 'Retired'=0; 'Critical'=1; 'High'=2; 'Medium'=3; 'Low'=4; 'None'=5; 'Unknown'=6 }
    $sorted = $report | Sort-Object {
        $p = $riskOrder[$_.RetirementRisk]
        if ($null -eq $p) { 6 } else { $p }
    }, AccountName, DeploymentName

    $cw = @{ Risk=10; Source=16; RG=20; Acct=22; Deploy=22; Model=22; Ver=14; RetDate=14; Days=7; State=13 }
    $hdr = '{0} {1} {2} {3} {4} {5} {6} {7} {8} {9}' -f `
        'Risk'.PadRight($cw.Risk),
        'Source'.PadRight($cw.Source),
        'ResourceGroup'.PadRight($cw.RG),
        'AccountName'.PadRight($cw.Acct),
        'DeploymentName'.PadRight($cw.Deploy),
        'ModelName'.PadRight($cw.Model),
        'Version'.PadRight($cw.Ver),
        'RetirementDate'.PadRight($cw.RetDate),
        'Days'.PadRight($cw.Days),
        'ProvisionState'
    Write-Host ""
    Write-Host $hdr
    Write-Host ('-' * $hdr.Length)

    foreach ($row in $sorted) {
        $color   = Get-RiskColor -Risk $row.RetirementRisk
        $daysStr = if ($null -ne $row.DaysUntilRetirement) { $row.DaysUntilRetirement.ToString() } else { 'N/A' }
        $line = '{0} {1} {2} {3} {4} {5} {6} {7} {8} {9}' -f `
            (Truncate $row.RetirementRisk   $cw.Risk),
            (Truncate $row.Source           $cw.Source),
            (Truncate $row.ResourceGroup    $cw.RG),
            (Truncate $row.AccountName      $cw.Acct),
            (Truncate $row.DeploymentName   $cw.Deploy),
            (Truncate $row.ModelName        $cw.Model),
            (Truncate $row.ModelVersion     $cw.Ver),
            (Truncate $row.RetirementDate   $cw.RetDate),
            $daysStr.PadRight($cw.Days),
            (Truncate $row.ProvisionState   $cw.State)
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ""
}