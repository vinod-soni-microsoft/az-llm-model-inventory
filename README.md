# Get-AzModelInventory

A PowerShell script that inventories all LLM model deployments across your Azure subscriptions and exports the results to a CSV report.

## Overview

This script scans all enabled Azure subscriptions accessible to the signed-in account and produces a consolidated CSV report covering:

- **Azure OpenAI** (Cognitive Services) model deployments
- **Azure Machine Learning** online endpoint model deployments

### CSV columns

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
| `ProvisionState` | Provisioning state (e.g. `Succeeded`, `Failed`) |
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
[2/4] Retrieving model deployments from each Azure OpenAI account...
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
  Report saved to       : C:\Reports\model-inventory-20260325-150547.csv
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Who is this for?

- **Azure administrators / cloud ops teams** — audit what AI models are deployed across a large tenant
- **FinOps / cost teams** — identify all deployments and their capacity for cost tracking
- **Security & compliance officers** — verify only approved models are deployed
- **AI/ML platform teams** — build an inventory before model upgrades or retirements
- **Microsoft CSAs and partners** — run assessments on behalf of customers

## How it works

1. **Prerequisites check** — validates Azure CLI login and auto-installs the `resource-graph` extension if needed
2. **Subscription discovery** — enumerates all enabled subscriptions (or uses the list you provide)
3. **Azure OpenAI accounts** — queries Azure Resource Graph for all Cognitive Services accounts of kind `OpenAI`
4. **OpenAI deployments** — calls the ARM Deployments API (`2024-10-01`) for each account
5. **AML online endpoints** — queries Azure Resource Graph for all `machinelearningservices/workspaces/onlineendpoints`
6. **AML deployments** — calls the ARM Online Deployments API (`2024-04-01`) for each endpoint
7. **Export** — writes a sorted CSV and prints a summary table to the console

Both Resource Graph queries use automatic pagination (1 000 records per page) to handle large tenants reliably.

## Permissions

The signed-in account needs at minimum the **Reader** role on each subscription being scanned. No write permissions are required. The script performs read-only API calls only.

## License

MIT
