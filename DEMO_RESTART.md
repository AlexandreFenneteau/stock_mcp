# Demo Restart Guide

This guide helps you quickly rebuild the entire infrastructure and deploy the MCP Stock Management demo when needed (e.g., 1 day before the webinar).

## Prerequisites

- Azure CLI (`az login`)
- Terraform installed
- Git and GitHub CLI (`gh`)
- Local files already committed/pushed to GitHub

## Step 1: Get Your EMU OIDC Subject & Admin Object ID

Get these values from your existing GitHub variables and Azure:

**For `github_repository` (EMU OIDC subject):**
- Check your GitHub repo → Settings → Variables → `GH_REPOSITORY_OIDC_SUBJECT`
- Or look at `infra/terraform.tfstate` or `infra/dev.tfplan` (search for `subject_identifier`)
- Example: `AlexandreFenneteau@52283300/stock_mcp@1302728241`

**For Azure admin object ID:**

```powershell
az ad signed-in-user show --query "id" -o tsv
```

Example output:
```
github_repository: AlexandreFenneteau@52283300/stock_mcp@1302728241
admin_object_id: 12345678-1234-1234-1234-123456789012
```

## Step 2: Create GitHub Variables & Secrets

In your GitHub repo settings, set these **variables** (Settings → Variables):

```
GH_REPOSITORY_OIDC_SUBJECT=<your EMU OIDC subject from Step 1>
ADMIN_OBJECT_ID=<your Azure object ID from Step 1>
BACKEND_API_APP_NAME=app-backend-mcpstock-<random>
MCP_SERVER_APP_NAME=app-mcp-mcpstock-<random>
```

Set these **secrets** (Settings → Secrets and variables → Secrets):

```
AZURE_CLIENT_ID=<GitHub-Actions-Deploy app registration client ID>
AZURE_TENANT_ID=<your Azure tenant ID>
AZURE_SUBSCRIPTION_ID=<your Azure subscription ID>
TENANT_ID=<same as AZURE_TENANT_ID>
FRONTEND_CLIENT_ID=<Frontend-Angular app registration client ID>
BACKEND_API_CLIENT_ID=<Backend-API app registration app ID URI>
BACKEND_API_IDENTIFIER_URI=api://<Backend-API app registration client ID>
BACKEND_API_URL_PROD=https://<backend-app-name>.azurewebsites.net
FRONTEND_URL=https://<static-web-app-url>
AZURE_STATIC_WEB_APPS_API_TOKEN=<from Static Web App deployment credentials>
```

## Step 3: Configure Terraform Variables

```powershell
cd infra

# Copy the example and fill in your values
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your actual values:
# github_repository = "AlexandreFenneteau@52283300/stock_mcp@1302728241"
# admin_object_id   = "your-azure-object-id"
```

Then initialize remote state (first time only):

```powershell
# Bootstrap: Create storage account manually (one-time setup)
# OR run Terraform with local state first, then migrate

terraform init -backend=false  # Start without backend

# After storage account exists, add backend config:
terraform init -migrate-state  # Migrates to remote backend
```

## Step 4: Deploy Infrastructure (1 Day Before Demo)

```powershell
cd infra

# Plan (automatically uses terraform.tfvars)
terraform plan -out=demo.tfplan

# Apply
terraform apply demo.tfplan
```

This creates:
- ✅ Resource group
- ✅ 3 Entra ID app registrations (Backend-API, Frontend-Angular, MCP-Server)
- ✅ 2 Linux Web Apps (Backend, MCP Server)
- ✅ 1 Static Web App (Frontend)
- ✅ Service Principal for GitHub Actions with OIDC federated credentials
- ✅ Azure Storage for Terraform state

## Step 5: Deploy Applications via GitHub Actions

Either:

**Option A: Push to main** (triggers deploy-apps.yml automatically)
```powershell
git commit -am "Demo restart" --allow-empty
git push origin main
```

**Option B: Manual trigger** (via GitHub UI)
1. Go to Actions → "Deploy Apps" → "Run workflow" → select `main`

Wait for all three jobs to complete:
- ✅ Deploy Backend API
- ✅ Deploy MCP Server
- ✅ Deploy Frontend

## Step 6: Verify Deployment

### Backend API
```powershell
curl https://<backend-app-name>.azurewebsites.net/api/stock
# Should return JSON stock list, not 404
```

### MCP Server
```powershell
curl https://<mcp-app-name>.azurewebsites.net/sse
# Should establish SSE connection (no immediate response needed)
```

### Frontend
Open `https://<static-web-app-url>` in a browser
- ✅ Entra ID login prompt appears
- ✅ After login, stock table displays
- ✅ +1/-1 buttons work (calls backend API)

## Step 7: Run Local Agent Client (Optional)

```powershell
cd agent-client

# Copy secrets template
cp fast-agent.secrets.yaml.example fast-agent.secrets.yaml
# Edit fast-agent.secrets.yaml and add your LLM keys (ANTHROPIC_API_KEY or OPENAI_API_KEY)

# Update fast-agent.yaml with deployed MCP server URL
# Change: url: http://localhost:8001/sse → https://<mcp-app-name>.azurewebsites.net/sse

# Run the agent
uv run python agent.py
```

The agent will:
1. Prompt for Entra ID login (opens browser)
2. Cache OAuth tokens in OS keychain
3. Connect to the deployed MCP server
4. Execute inventory checks and modifications via LLM

## Cleanup: Destroy Resources After Demo

```powershell
cd infra

# Destroy all Azure resources (uses terraform.tfvars automatically)
terraform destroy
```

This removes:
- ✅ Resource group (Web Apps, Static Web App, etc.)
- ✅ Entra ID app registrations (Backend-API, Frontend-Angular, MCP-Server)
- ⚠️ Note: Terraform state remains in Azure Storage (low cost); delete manually if needed

## Troubleshooting

### 403 Unauthorized on Terraform Apply
- Check `admin_object_id` matches your actual Azure user
- Check `github_repository` matches your EMU account's OIDC subject claim

### Backend/MCP returns 404
- Verify `app_command_line = "bash startup.sh"` is set in Web Apps
- Check app logs: `az webapp log tail --name <app-name> --resource-group <rg-name>`

### Frontend can't reach backend
- Verify `BACKEND_API_URL_PROD` secret matches deployed backend URL
- Check CORS settings in backend/main.py (should allow Static Web App domain)

### MCP Server OAuth fails
- Verify `MCP_CLIENT_ID`, `MCP_CLIENT_SECRET`, `TENANT_ID` env vars are set
- Check app secrets in Azure Portal

## Files Changed Since Initial Setup

When restarting, ensure these files are committed:
- `infra/main.tf` (Terraform config with remote backend)
- `.github/workflows/infra-terraform.yml` (Terraform workflow)
- `.github/workflows/deploy-apps.yml` (App deployment workflow)
- `backend/startup.sh` (gunicorn entrypoint)
- `backend/pyproject.toml` (includes gunicorn)
- `mcp-server/startup.sh` (gunicorn with --workers 1)
- `mcp-server/main.py` (module-level `app` for gunicorn)
- `mcp-server/pyproject.toml` (includes gunicorn)
- `frontend/angular.json` (environment config)
- `README.md` (project documentation)

## Estimated Timeline

| Step | Duration |
|------|----------|
| GitHub Variables/Secrets setup | 5 min |
| Terraform init + plan | 2 min |
| Terraform apply | 5-10 min |
| GitHub Actions deploy | 5-10 min |
| Verification | 2-5 min |
| **Total** | **20-30 min** |

Use this guide the day before the demo to ensure everything is ready!
