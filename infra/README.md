# Infrastructure (Terraform)

Minimal, **public** Azure infrastructure for the MCP Stock Management demo. Not production-grade — no VNET/private endpoints, secrets are only protected by Terraform's `sensitive` marking.

## What it deploys

- **Resource Group** — `rg-<prefix>-<suffix>`.
- **Entra ID App Registrations** (`azuread` provider):
  - `Backend-API` — exposes:
    - an **app role** `Stock.ReadWrite` (app-only, for the MCP-Server's Client Credentials flow),
    - a **delegated scope** `access_as_user` (for the Angular SPA's Authorization Code + PKCE flow).
  - `Frontend-Angular` — SPA redirect URIs (Static Web App + `localhost:4200`), requests the `access_as_user` scope on Backend-API.
  - `MCP-Server` — daemon app:
    - a generated **client secret**,
    - **app role assignment** of `Stock.ReadWrite` on Backend-API (Client Credentials),
    - web redirect URIs + its own exposed `access_as_user` scope, used as an OAuth Proxy (FastMCP `AzureProvider`) so MCP clients (fast-agent, MCP Inspector, ...) can authenticate without Dynamic Client Registration,
    - a **delegated permission grant** (admin-consented) so it can call Backend-API on behalf of the signed-in user via On-Behalf-Of (OBO), without interactive consent.
  - `GitHub-Actions-Deploy` — daemon app used only by CI/CD:
    - **no client secret** — federated (OIDC) for `repo:<github_repository>:ref:refs/heads/main`, so GitHub Actions authenticates with a short-lived token,
    - **Contributor** role assignment scoped to the Resource Group only (not the whole subscription),
    - Microsoft Graph **application permission** `Application.ReadWrite.OwnedBy` (app-only, admin-consented) so it can manage `Backend-API`/`Frontend-Angular`/`MCP-Server` via Terraform in CI — being listed as an *owner* of those apps only grants rights in delegated (signed-in user) context, not app-only/service-principal context, so this explicit Graph permission is required in addition to co-ownership.
- **Static Web App** (Free tier) — hosts the Angular frontend.
- **Linux App Service Plan** (`B1` by default) + **2 Linux Web Apps** (Python 3.11):
  - Backend API (FastAPI) — CORS restricted to the Static Web App + localhost.
  - MCP Server (FastMCP) — app settings wired with the Entra IDs, MCP client secret, and Backend API URL.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.6
- Azure CLI, logged in (`az login`) with rights to create App Registrations in the tenant and resources in the subscription
- The `Microsoft.Web` resource provider registered on the subscription (see [Troubleshooting](#troubleshooting))

## Remote state

State is stored remotely in Azure Blob Storage (`backend "azurerm"` block in `main.tf`), **not** locally — this lets both your machine and GitHub Actions CI operate on the same state, avoiding CI trying to recreate resources that already exist. Auth uses Azure AD RBAC (`use_azuread_auth = true`, `Storage Blob Data Contributor` role), no storage account keys.

The storage account/container are bootstrapped **once, manually** (outside Terraform, to avoid a chicken-and-egg dependency on the backend itself):

```powershell
az group create --name rg-tfstate-mcpstock --location francecentral
az storage account create --name <globally-unique-name> --resource-group rg-tfstate-mcpstock --location francecentral --sku Standard_LRS --allow-blob-public-access false
az storage container create --name tfstate --account-name <name> --auth-mode login

# Grant yourself and the GitHub-Actions-Deploy service principal access:
az role assignment create --assignee <your-object-id-or-sp-object-id> --role "Storage Blob Data Contributor" --scope <storage-account-resource-id>
```

Then update the `backend "azurerm" {}` block in `main.tf` with your storage account name, and run `terraform init` (or `terraform init -migrate-state` if migrating from local state).

## Usage

```powershell
cd infra
terraform init
terraform plan -out dev.tfplan -var="github_repository=<owner>/<repo>"
terraform apply "dev.tfplan"
```

To tear everything down:

```powershell
terraform destroy -var="github_repository=<owner>/<repo>"
```

## Variables

| Name                       | Default          | Description                                                                                     |
| --------------------------- | ---------------- | ------------------------------------------------------------------------------------------------- |
| `prefix`                    | `mcpstock`        | Prefix used to name all resources.                                                                 |
| `location`                  | `francecentral`   | Azure region for the Resource Group, App Service Plan, and Web Apps.                               |
| `app_service_sku`           | `B1`              | SKU for the Linux App Service Plan (`F1` = Free, `B1` = Basic).                                    |
| `static_web_app_location`   | `eastus2`         | Region for the Static Web App. Azure Static Web Apps are only available in a small set of regions and some may reject new resources — see [Troubleshooting](#troubleshooting). |
| `github_repository`        | *(required)*      | GitHub repository in `"owner/repo"` form, scopes the OIDC federated credential for `GitHub-Actions-Deploy`. |
| `admin_object_id`          | *(required)*      | Object ID of the human user/group that co-owns all Entra ID App Registrations alongside `GitHub-Actions-Deploy`. Must be a fixed value (get yours with `az ad signed-in-user show --query id -o tsv`) — never derive it from the identity currently running Terraform, since that differs between your local user and the CI service principal and causes ownership to flip-flop on every apply. |

Override with `-var` or a `*.tfvars` file, e.g.:

```powershell
terraform plan -out dev.tfplan -var="location=westeurope" -var="prefix=demo"
```

## Outputs

| Output                        | Sensitive | Description                                                                 |
| ------------------------------ | :-------: | ----------------------------------------------------------------------------- |
| `tenant_id`                     |           | Entra ID Tenant ID.                                                           |
| `backend_api_client_id`         |           | Client ID of `Backend-API`.                                                   |
| `backend_api_app_id_uri`        |           | App ID URI (`identifier_uris`) exposed by `Backend-API`.                      |
| `frontend_angular_client_id`    |           | Client ID of `Frontend-Angular`.                                              |
| `mcp_server_client_id`          |           | Client ID of `MCP-Server`.                                                    |
| `mcp_server_app_id_uri`         |           | App ID URI exposed by `MCP-Server` (callers must get a token for `<uri>/access_as_user`). |
| `mcp_server_client_secret`      |    yes    | Client secret for `MCP-Server` (Client Credentials flow).                     |
| `static_web_app_url`            |           | URL of the Angular Static Web App.                                            |
| `static_web_app_api_key`        |    yes    | Deployment API key for the Static Web App (used by SWA CLI/CI to deploy).      |
| `backend_api_url`               |           | URL of the Backend API Web App.                                              |
| `mcp_server_url`                |           | URL of the MCP Server Web App.                                               |
| `backend_api_app_name`          |           | Name of the Backend API Web App (used by the deploy workflow).               |
| `mcp_server_app_name`           |           | Name of the MCP Server Web App (used by the deploy workflow).                |
| `static_web_app_name`           |           | Name of the Static Web App.                                                   |
| `resource_group_name`           |           | Name of the Resource Group.                                                   |
| `subscription_id`               |           | Azure Subscription ID.                                                       |
| `github_actions_client_id`      |           | Client ID of `GitHub-Actions-Deploy` (OIDC, no secret).                       |

View a sensitive output:

```powershell
terraform output -raw mcp_server_client_secret
```

## Wiring up CI/CD (GitHub Actions)

The workflows in `.github/workflows/` (`infra-terraform.yml`, `deploy-apps.yml`) need these **once**, after your first local `terraform apply` (`var.github_repository` must already be set to your `owner/repo`):

1. Create a `production` GitHub environment (Settings → Environments) — used as a manual approval gate for both workflows.
2. Repository **secrets** (Settings → Secrets and variables → Actions → Secrets):
   - `AZURE_CLIENT_ID` = `terraform output -raw github_actions_client_id`
   - `AZURE_TENANT_ID` = `terraform output -raw tenant_id`
   - `AZURE_SUBSCRIPTION_ID` = `terraform output -raw subscription_id`
   - `AZURE_STATIC_WEB_APPS_API_TOKEN` = `terraform output -raw static_web_app_api_key`
3. Repository **variable** (Settings → Secrets and variables → Actions → Variables):
   - `GH_REPOSITORY_OIDC_SUBJECT` — the exact repo identifier GitHub puts in the OIDC token's `subject` claim. For most repos this is `owner/repo`, but **Enterprise Managed User (EMU)** orgs append numeric suffixes (e.g. `owner@12345/repo@67890`). Find the real value by triggering a workflow once and reading the `subject claim` line logged by `azure/login` on failure, then set this variable to match (everything before `:ref:...` or `:environment:...`).
   - `ADMIN_OBJECT_ID` — same value used for `-var="admin_object_id=..."` locally, so CI keeps ownership of the Entra apps consistent with your local runs instead of overwriting it with the CI service principal's own ID.
3. Repository **variables** (same page, "Variables" tab):
   - `BACKEND_API_APP_NAME` = `terraform output -raw backend_api_app_name`
   - `MCP_SERVER_APP_NAME` = `terraform output -raw mcp_server_app_name`

No Azure client secret is stored for the Web Apps/Terraform deploys — `AZURE_CLIENT_ID` authenticates via OpenID Connect (Workload Identity Federation).

## Troubleshooting

These issues were hit while first standing up this stack and are fixed in the current config, kept here for reference:

- **`MissingSubscriptionRegistration: ... namespace 'Microsoft.Web'`** — the subscription hadn't registered the `Microsoft.Web` resource provider yet. Register it once manually and wait for completion:

  ```powershell
  az provider register --namespace Microsoft.Web --wait
  ```

  The `azurerm` provider block sets `resource_provider_registrations = "core"` (instead of the default `"all"`) to avoid Terraform trying to re-register every RP on each run, which can otherwise fail with `409 ConflictingConcurrentWriteNotAllowed` on subscriptions where most providers are already registered.

- **`LocationNotAvailableForResourceType` / `RequestDisallowedByAzure` (region not accepting new customers)** — Azure Static Web Apps are only available in a handful of regions (`centralus`, `eastus2`, `westus2`, `westeurope`, `eastasia`), and some of those can be temporarily closed to new resources. That's why `static_web_app_location` is a separate variable from `location` — if you hit this, try another region from that list.

- **`URI must have a trailing slash when there is no path segment`** — Entra ID requires a trailing `/` on redirect URIs that have no path (e.g. `https://example.com/` instead of `https://example.com`). Already handled in the SPA/web redirect URIs above; keep this in mind if you add more.
