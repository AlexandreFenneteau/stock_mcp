---
description: Project-wide architecture and conventions for the MCP Stock Management demo (webinar project).
applyTo: "**"
---
# Project: MCP Stock Management Demo

This repo is a demo built for a 1-hour webinar on "MCP tools Azure & custom". It showcases a stock management app driven by an AI agent through MCP (Model Context Protocol), secured with Azure Entra ID. Keep everything intentionally minimal/public — this is a demo, not production.

## Architecture Overview

- **Infrastructure** (`infra/`, Terraform, `azurerm` + `azuread` providers):
  - 3 Entra ID App Registrations: `Backend-API` (exposes App Role `Stock.ReadWrite`), `Frontend-Angular` (SPA, auth code + PKCE), `MCP-Server` (daemon app, client credentials flow, has `Stock.ReadWrite` app role assignment).
  - 1 more Entra ID App Registration + Service Principal: `GitHub-Actions-Deploy`, federated (OIDC, no client secret) for `repo:<github_repository>:ref:refs/heads/main`, granted `Contributor` on the resource group only — used by both GitHub Actions workflows to authenticate to Azure.
  - 1 Azure Static Web App (Angular front).
  - 1 Linux App Service Plan (B1 or F1) + 2 Web Apps (Python 3.11+): one for the FastAPI backend, one for the FastMCP server.
  - Everything public (no VNET/private endpoints) to simplify the demo.
  - Terraform outputs: Client IDs, Tenant ID, MCP client secret, Web App URLs/names, Static Web App name/API key, GitHub Actions OIDC client ID, subscription ID.
  - Requires a `github_repository` variable (`"owner/repo"` form) to scope the OIDC federated credential.

- **Backend API** (`backend/`, Python + FastAPI, managed with `uv`):
  - In-memory stock store (plain dict/list), pre-seeded with a few items (id, name, quantity).
  - `GET /api/stock` — list items.
  - `POST /api/stock/adjust` — body `{id, quantity_change}`.
  - Validates JWT Bearer tokens from Entra ID (accepts both user tokens from the Angular front and app-only tokens from the MCP server via Client Credentials with `Stock.ReadWrite`).
  - CORS enabled for the Static Web App URL and localhost.

- **Frontend** (`frontend/`, Angular, single page):
  - `@azure/msal-browser` + `@azure/msal-angular` for login (Entra ID).
  - HTTP interceptor attaches the Bearer token to API calls.
  - Single page: connection status banner, table of stock (ID, name, quantity), +1/-1 buttons per row calling the backend.

- **MCP Server** (`mcp-server/`, Python + `fastmcp`, managed with `uv`) — implemented:
  - Transport: SSE (Server-Sent Events) via `mcp.run(transport="sse", ...)` — required for Azure Web App hosting.
  - Auth: secured with Microsoft Entra ID OAuth via FastMCP's `AzureProvider` (OAuth Proxy pattern — brokers Authorization Code + PKCE with Entra ID on behalf of any MCP client, since Entra ID doesn't support Dynamic Client Registration). MCP clients (fast-agent `auth.oauth: true`, MCP Inspector's OAuth flow, etc.) authenticate normally with no manual token handling.
  - Backend-API calls run "on behalf of" the signed-in user via the On-Behalf-Of (OBO) flow, using FastMCP's `EntraOBOToken` dependency.
  - Tools: `check_inventory()` (GET `/api/stock`, formatted for the LLM), `modify_inventory(item_id, change)` (POST `/api/stock/adjust`).
  - Config via environment variables: `TENANT_ID`, `MCP_CLIENT_ID`, `MCP_CLIENT_SECRET`, `MCP_SERVER_BASE_URL`, `BACKEND_API_APP_ID_URI`, `BACKEND_API_URL`, `PORT` (see `mcp-server/.env.example`).

- **Local Agent Client** (`agent-client/`, `fast-agent`):
  - Runs locally, connects to the MCP server over SSE (`http://localhost:8001/sse` locally, or `https://<mcp-webapp>.azurewebsites.net/sse` deployed).
  - Auth: `fast-agent.yaml` sets `auth.oauth: true` on the `stock_mcp` server — fast-agent handles the Authorization Code + PKCE flow against the MCP server's `AzureProvider` automatically (login link on first use, tokens cached in the OS keychain).
  - Uses a standard LLM (Anthropic/OpenAI) via local API keys in `fast-agent.secrets.yaml` (copy from `fast-agent.secrets.yaml.example`, git-ignored).
  - Run with `uv run python agent.py` for an interactive terminal chat during the live demo.

## Conventions

- Keep code simple and readable — this is a teaching demo, avoid over-engineering or unnecessary abstractions.
- Secrets/keys/IDs are always read from environment variables, never committed.
- Prefer lightweight, well-known packages (`pyjwt`, `cryptography`, `fastmcp`, `fastapi`) over custom implementations.
- Each component (infra, backend, frontend, mcp-server, agent-client) lives in its own top-level folder.
- This file must be kept up to date as the architecture evolves during development — update it whenever a component, endpoint, tool, or infra resource is added/changed/removed.

## CI/CD (`.github/workflows/`)

- **`infra-terraform.yml`** — Terraform plan (PRs touching `infra/**`, commented on the PR) / apply (push to `main`, gated by the `production` GitHub environment). Authenticates to Azure via OIDC (`azure/login`, no stored secrets) using the `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` repo secrets — bootstrap the very first `terraform apply` locally (with your own `az login`) to create the `GitHub-Actions-Deploy` app registration, then copy its outputs into those secrets.
- **`deploy-apps.yml`** — builds and deploys `backend/`, `mcp-server/` (zip-deploy via `azure/webapps-deploy`, same OIDC secrets, app names from the `BACKEND_API_APP_NAME` / `MCP_SERVER_APP_NAME` repo variables) and `frontend/` (Angular build, deployed via `Azure/static-web-apps-deploy` using the `AZURE_STATIC_WEB_APPS_API_TOKEN` repo secret from the `static_web_app_api_key` Terraform output). Triggered by push to `main` on path changes, or manually.
- Provisioning (Terraform) and app deployment are intentionally separate workflows — deploy-apps assumes the infra already exists.

## Python tooling: uv

All Python components (`backend/`, `mcp-server/`, `agent-client/`) are managed with [uv](https://docs.astral.sh/uv/) — never use `pip`/`venv`/`python` directly.

- Each Python component is its own uv project (`pyproject.toml` + `uv.lock`), no shared `requirements.txt`.
- Add a dependency: `uv add <package>` (run from the component's folder).
- Run the app/scripts: `uv run <command>` (e.g. `uv run uvicorn main:app --reload`, `uv run python main.py`).
- Sync an existing lockfile: `uv sync`.
- Azure Web Apps build via `SCM_DO_BUILD_DURING_DEPLOYMENT`/Oryx, which detects `pyproject.toml`/`uv.lock` and installs with uv automatically — no separate `requirements.txt` needed.
