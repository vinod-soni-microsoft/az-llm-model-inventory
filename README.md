# Get-AzModelInventory

A PowerShell script that inventories all LLM model deployments across your Azure subscriptions, enriches each deployment with **lifecycle and retirement data** from the Azure OpenAI Models API, and exports a color-coded report to CSV.

## Overview

This script scans all enabled Azure subscriptions accessible to the signed-in account and produces a consolidated CSV report covering:

- **Azure OpenAI** (Cognitive Services) model deployments
- **Azure Machine Learning** online endpoint model deployments

For every Azure OpenAI deployment, the script calls the Azure OpenAI Models API to determine the model's current lifecycle status and published retirement date. Deployments are then classified into a **RetirementRisk** tier so you can immediately see which models need attention.

## Retirement risk tiers

| Console color | Risk tier | Meaning |
|---|---|---|
| 🔴 Red | `Retired` | Model is no longer listed by Azure — deployments will fail |
| 🔴 Red | `Critical` | Retirement date is within **30 days** |
| 🟡 Yellow | `High` | Retirement date is within **31–60 days** |
| 🔵 Cyan | `Medium` | Retirement date is within **61–90 days** |
| 🟢 Green | `Low` | Retirement date is more than **90 days** away |
| ⚪ White | `None` | No retirement date published, or AML endpoint (no data) |

## CSV columns

| Column | Description |
|---|---|
| `Source` | `AzureOpenAI` or `AMLOnlineEndpoint` |
| `SubscriptionId` | Azure subscription ID |
| `ResourceGroup` | Resource group name |
| `AccountName` | Azure OpenAI account or AML endpoint name |
| `Location` | Azure region |
| `DeploymentName` | Name of the model deployment |
| `ModelName` | Model identifier (e.g. `gpt-4o`, `gpt-4.1`) |
| `ModelVersion` | Deployed model version |
| `SkuName` | SKU name (e.g. `Standard`, `GlobalStandard`) |
| `Capacity` | Provisioned capacity (PTUs or TPM units) |
| `UpgradePolicy` | Auto-upgrade policy for the deployment |
| `ProvisionState` | Provisioning state (e.g. `Succeeded`, `Failed`, `Disabled`) |
| `LifecycleStatus` | `GenerallyAvailable`, `Preview`, `Deprecated`, `Retired`, or `Unknown` |
| `RetirementDate` | Published retirement date in `yyyy-MM-dd` format, or empty |
| `DaysUntilRetirement` | Integer days until retirement; negative means already past the date |
| `RetirementRisk` | `Retired`, `Critical`, `High`, `Medium`, `Low`, or `None` |
| `ResourceId` | Full Azure resource ID |

## Prerequisites

| Requirement | Notes |
|---|---|
| Azure CLI | [Install guide](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| Azure CLI login | Run `az login` before executing the script |
| PowerShell 5.1+ | PowerShell 7 recommended |
| Reader role | Required on all target subscriptions |
| `resource-graph` extension | **Auto-installed** by the script if missing |

## Usage

```powershell
# Scan all enabled subscriptions (default)
.\Get-AzModelInventory.ps1

# Save report to a specific path
.\Get-AzModelInventory.ps1 -OutputPath "C:\Reports\model-inventory.csv"

# Scan specific subscriptions only
.\Get-AzModelInventory.ps1 -SubscriptionIds "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

# Combine both parameters
.\Get-AzModelInventory.ps1 -SubscriptionIds "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -OutputPath "C:\Reports\model-inventory.csv"
```

## Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-OutputPath` | `string` | No | `model-inventory-<timestamp>.csv` in current directory | Path to the output CSV file |
| `-SubscriptionIds` | `string[]` | No | All enabled subscriptions | One or more subscription IDs to scan |

## Sample output

```
Checking prerequisites...
  Discovered 12 enabled subscription(s).

[1/4] Querying Azure OpenAI accounts via Resource Graph...
      Found 3 Azure OpenAI account(s).
[2/4] Retrieving model deployments and lifecycle data from each Azure OpenAI account...
      Found 5 Azure OpenAI deployment(s).
[3/4] Querying Azure ML online endpoints via Resource Graph...
      Found 0 AML online endpoint(s).
[4/4] Retrieving model deployments from each AML online endpoint...
      Found 0 AML deployment(s).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Scan complete.
  Subscriptions scanned : 12
  Azure OpenAI deploys  : 5
  AML endpoint deploys  : 0
  Total deployments     : 5

  Retirement Risk Summary:
    [RETIRED ]  1 deployment(s) — model no longer available, immediate action required!
    [CRITICAL]  1 deployment(s) — retiring within 30 days!
    [HIGH    ]  1 deployment(s) — retiring within 31-60 days
    [LOW     ]  2 deployment(s) — retiring in more than 90 days

  Report saved to       : C:\Reports\model-inventory-20260429-090000.csv
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Risk       Source           ResourceGroup        AccountName            DeploymentName         ModelName              Version        RetirementDate Days    ProvisionState
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Retired    AzureOpenAI      rg-prod              oai-prod               gpt35-legacy           gpt-35-turbo           0301                          -120    Succeeded
Critical   AzureOpenAI      rg-prod              oai-prod               gpt4-old               gpt-4                  0613           2026-05-15     17      Succeeded
High       AzureOpenAI      rg-dev               oai-dev                gpt4o-mini-dev         gpt-4o-mini            2024-07-18     2026-06-10     43      Succeeded
Low        AzureOpenAI      rg-prod              oai-prod               gpt4o-prod             gpt-4o                 2024-11-20     2026-09-30     155     Succeeded
Low        AzureOpenAI      rg-prod              oai-prod               gpt41-prod             gpt-4.1                2025-04-14     2026-10-15     170     Succeeded
```

## How retirement is detected

The script calls the **Azure OpenAI Models API** (`GET .../models?api-version=2024-10-01`) once per Azure OpenAI account and caches the result. This API returns the `lifecycleStatus` and `deprecationDate` for every available model version in that account's region.

| Scenario | Result |
|---|---|
| Model present in API with `deprecationDate` | `RetirementDate` and `DaysUntilRetirement` are populated; risk tier is calculated |
| Model present in API, no `deprecationDate` | `LifecycleStatus` is `GenerallyAvailable` or `Preview`; risk is `None` |
| Model **not present** in the API response | Treated as `Retired` — Azure removes retired models from the listing entirely |

> **Note:** Microsoft publishes retirement dates in advance via the [Azure OpenAI model retirements documentation](https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/model-retirements). The `RetirementDate` column in the CSV is sourced directly from the ARM API and will be empty when Microsoft has not yet announced a date.

## Who is this for?

- **Azure administrators / cloud ops teams** — audit what AI models are deployed across a large tenant and spot retirement risks immediately
- **FinOps / cost teams** — identify all deployments and their capacity for cost tracking
- **Security & compliance officers** — verify only approved, non-retired models are deployed
- **AI/ML platform teams** — plan model upgrades proactively before retirement deadlines
- **Microsoft CSAs and partners** — run assessments on behalf of customers with a single command

## How it works

1. **Prerequisites check** — validates Azure CLI login and auto-installs the `resource-graph` extension if needed
2. **Subscription discovery** — enumerates all enabled subscriptions (or uses the list you provide)
3. **Azure OpenAI accounts** — queries Azure Resource Graph for all Cognitive Services accounts of kind `OpenAI`
4. **OpenAI deployments + lifecycle** — calls the ARM Deployments API (`2024-10-01`) and the Models API (`2024-10-01`) per account; results are cached per account to minimise API calls
5. **Retirement classification** — each deployment is assigned a `RetirementRisk` tier based on its retirement date relative to today
6. **AML online endpoints** — queries Azure Resource Graph for all `machinelearningservices/workspaces/onlineendpoints`
7. **AML deployments** — calls the ARM Online Deployments API (`2024-04-01`) for each endpoint
8. **Export** — writes a sorted CSV with all columns and prints a color-coded, urgency-sorted table plus a risk summary banner to the console

Both Resource Graph queries use automatic pagination (1 000 records per page) to handle large tenants reliably.

## Permissions

The signed-in account needs at minimum the **Reader** role on each subscription being scanned. No write permissions are required. The script performs read-only API calls only.

## License

MIT
