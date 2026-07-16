# MCP Stock Management Demo

Demo built for a webinar on "MCP tools Azure & custom": a stock management app driven by an AI agent through MCP (Model Context Protocol), secured with Microsoft Entra ID. Intentionally minimal/public — this is a teaching demo, not production.

- [`infra/`](infra) — Terraform (Entra ID apps, Static Web App, App Service Plan + 2 Web Apps).
- [`backend/`](backend) — FastAPI stock API.
- [`frontend/`](frontend) — Angular SPA.
- [`mcp-server/`](mcp-server) — FastMCP server (SSE, Entra ID OAuth).
- [`agent-client/`](agent-client) — local fast-agent chat client.

## Publishing guide

Follow these steps **in order** the first time you publish this project to Azure. Steps 1–3 are done once, locally. Steps 4+ are one-time GitHub setup, after which every `git push` to `main` redeploys automatically.

### 1. Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.6
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), logged in with `az login`, using an account that can create Entra ID App Registrations in the tenant and resources in the subscription
- A GitHub repository for this project (`git remote -v` to check, or create one and `git push -u origin main`)
- [uv](https://docs.astral.sh/uv/) (for `backend/`, `mcp-server/`, `agent-client/`) and Node.js 20+ (for `frontend/`), if you want to run components locally before/after deploying

### 2. Provision the Azure infrastructure (Terraform, local)

This creates the Resource Group, the 4 Entra ID App Registrations (`Backend-API`, `Frontend-Angular`, `MCP-Server`, `GitHub-Actions-Deploy`), the Static Web App, the App Service Plan, and the 2 Web Apps. Run it **locally** the first time — the `GitHub-Actions-Deploy` app registration it creates is what the GitHub Actions workflows will authenticate with later, so it can't yet exist in CI.

```powershell
cd infra
terraform init
terraform plan -out dev.tfplan -var="github_repository=<your-github-org-or-user>/<your-repo-name>" -var="admin_object_id=<your-object-id>"
terraform apply "dev.tfplan"
```

- `github_repository` **must** match your actual GitHub repo (e.g. `"alexandre/mcp_stock"`) — it scopes the OIDC federated credential so only workflows running from that repo's `main` branch can authenticate as `GitHub-Actions-Deploy`.
  - **Enterprise Managed User (EMU) orgs**: the OIDC subject claim GitHub sends isn't the plain `owner/repo` you'd expect — it's suffixed with numeric IDs, e.g. `Alex@89245300/stock_mcp@2197128252`. If `azure/login` fails with `AADSTS700213: No matching federated identity record found`, check the actual `subject claim` value logged by the failed workflow run and re-apply Terraform with `-var="github_repository=<that exact value minus the ':ref:refs/heads/main' suffix>"`.
- `admin_object_id` **must** be a fixed value — get yours with `az ad signed-in-user show --query id -o tsv`. It's used to co-own the Entra ID App Registrations alongside the `GitHub-Actions-Deploy` service principal; without a fixed value, ownership would flip-flop between your user (local runs) and the CI service principal (CI runs), causing 403 errors.
- Full list of variables/outputs, and troubleshooting for common Azure/Terraform errors, is in [`infra/README.md`](infra/README.md).
- Keep the terminal open (or re-run `terraform output` later) — you'll need several outputs in the next steps.

### 3. Sanity-check the deployed infra (optional but recommended)

```powershell
terraform output static_web_app_url
terraform output backend_api_url
terraform output mcp_server_url
```

At this point the 3 Web Apps/Static Web App exist but have **no application code** deployed yet (Terraform only provisions infrastructure) — visiting the URLs will show default/empty pages until step 6 runs.

### 4. Configure the GitHub repository (one-time)

All values below come from `terraform output` (run from `infra/`).

1. **Create a `production` environment**: repo Settings → Environments → New environment → name it `production`. This gates both workflows behind an environment (add required reviewers here if you want a manual approval click before every deploy).
2. **Add repository secrets**: repo Settings → Secrets and variables → Actions → **Secrets** tab → New repository secret, for each of:

   | Secret name | Value |
   | --- | --- |
   | `AZURE_CLIENT_ID` | `terraform output -raw github_actions_client_id` |
   | `AZURE_TENANT_ID` | `terraform output -raw tenant_id` |
   | `AZURE_SUBSCRIPTION_ID` | `terraform output -raw subscription_id` |
   | `AZURE_STATIC_WEB_APPS_API_TOKEN` | `terraform output -raw static_web_app_api_key` |
   | `TENANT_ID` | `terraform output -raw tenant_id` |
   | `FRONTEND_CLIENT_ID` | `terraform output -raw frontend_angular_client_id` |
   | `BACKEND_API_CLIENT_ID` | `terraform output -raw backend_api_client_id` |
   | `BACKEND_API_IDENTIFIER_URI` | `terraform output -raw backend_api_app_id_uri` |
   | `FRONTEND_URL` | `terraform output -raw static_web_app_url` |
   | `BACKEND_API_URL_PROD` | `terraform output -raw backend_api_url` |

3. **Add repository variables**: same page → **Variables** tab → New repository variable, for each of:

   | Variable name | Value |
   | --- | --- |
   | `BACKEND_API_APP_NAME` | `terraform output -raw backend_api_app_name` |
   | `MCP_SERVER_APP_NAME` | `terraform output -raw mcp_server_app_name` |
   | `GH_REPOSITORY_OIDC_SUBJECT` | the exact repo identifier from the OIDC `subject claim` (see note above — may differ from plain `owner/repo` on EMU orgs) |
   | `ADMIN_OBJECT_ID` | the same value passed as `-var="admin_object_id=..."` above |

The secrets for `TENANT_ID`, `*_CLIENT_ID`, etc. are used by the `deploy-apps.yml` workflow to generate the Angular environment file (`environment.ts`) at build time — it is not committed to the repo.

No Azure client secret is ever stored in GitHub for deployments — `AZURE_CLIENT_ID` authenticates via OpenID Connect (Workload Identity Federation), matching the federated credential created in step 2.

### 5. Push to `main`

```powershell
git add .
git commit -m "Initial infra + app code"
git branch -M main
git push -u origin main
```

This triggers two workflows (see `.github/workflows/`):

- **`infra-terraform.yml`** — runs `terraform plan` on PRs touching `infra/**` (commented on the PR), and `terraform apply` on push to `main`. Since you already applied locally in step 2, this run should show "no changes" unless you've since edited `infra/main.tf`.
- **`deploy-apps.yml`** — builds and deploys `backend/`, `mcp-server/` (zip-deploy via `azure/webapps-deploy`, OIDC auth) and `frontend/` (Angular build, deployed via `Azure/static-web-apps-deploy`).

Watch progress under the repo's **Actions** tab. If you added required reviewers to the `production` environment, approve the pending deployment when prompted.

### 6. Verify the deployment

```powershell
# From infra/, or reuse the values from step 3
terraform output static_web_app_url   # Angular frontend
terraform output backend_api_url      # FastAPI backend (try GET /api/stock)
terraform output mcp_server_url       # FastMCP server (SSE endpoint is <this>/sse)
```

- Open the frontend URL, sign in with Entra ID, and confirm the stock table loads and +1/-1 buttons work.
- The MCP server itself isn't meant to be opened in a browser — it's consumed by an MCP client (see step 7).

### 7. Point the local agent client at the deployed MCP server

By default [`agent-client/fast-agent.yaml`](agent-client/fast-agent.yaml) targets `http://localhost:8001/sse`. To talk to the deployed server **without editing the file**, set the fast-agent environment variable override before running the client:

```powershell
cd infra
$mcpUrl = terraform output -raw mcp_server_sse_url
cd ../agent-client
$env:MCP__SERVERS__STOCK_MCP__URL = $mcpUrl
uv run python agent.py
```

(`mcp_server_sse_url` is also pre-set as an app setting on the MCP Server Web App itself, for reference — see [`infra/main.tf`](infra/main.tf).)

### 8. Subsequent updates

Any push to `main` that touches `backend/`, `mcp-server/`, or `frontend/` re-runs `deploy-apps.yml` automatically. Any push touching `infra/**` re-runs `infra-terraform.yml`'s plan/apply. Pull requests only ever get a Terraform **plan** comment — nothing is applied until merged to `main`.

### Tearing everything down

```powershell
cd infra
terraform destroy -var="github_repository=<your-github-org-or-user>/<your-repo-name>" -var="admin_object_id=<your-object-id>"
```

This removes every Azure resource and Entra ID App Registration created in step 2. It does not touch the GitHub repository or its secrets/variables (delete those manually if you want a full cleanup).
