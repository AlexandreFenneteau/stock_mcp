# Stock Management MCP Server

FastMCP server exposing the Stock Management API as MCP tools, secured with Microsoft Entra ID OAuth.

## What it does

- Transport: SSE (`http://localhost:8001/sse` locally, or the deployed Azure Web App's `/sse` endpoint).
- Auth: [`fastmcp.server.auth.providers.azure.AzureProvider`](https://gofastmcp.com/integrations/azure) — since Entra ID doesn't support Dynamic Client Registration, this server brokers Authorization Code + PKCE with Entra ID on behalf of any MCP client (OAuth Proxy pattern). Clients just need standard MCP OAuth support (fast-agent's `auth.oauth: true`, `fastmcp.Client(auth="oauth")`, etc.) — no manual token handling.
- Backend calls run **on behalf of the signed-in user** via the On-Behalf-Of (OBO) flow, using FastMCP's `EntraOBOToken` dependency — so calls are authorized and audited as the real user, not a service identity.
- Tools:
  - `check_inventory()` — list current stock (id, name, quantity).
  - `create_stock_item(name, quantity=0)` — create a new stock item.
  - `modify_inventory(item_id, change)` — adjust an existing item's quantity (positive or negative).

## Prerequisites

- The `infra/` Terraform stack applied at least once (creates the `Backend-API` and `MCP-Server` Entra ID app registrations and the `azure_readwrite`/`access_as_user` scopes).
- The [backend/](../backend) API running (locally at `http://localhost:8000`, or deployed).
- [uv](https://docs.astral.sh/uv/) installed.

## Setup

```powershell
cd mcp-server
uv sync
cp .env.example .env   # then fill in the values below
```

Required environment variables (see `.env.example`):

| Variable | Description | Where to get it |
|---|---|---|
| `TENANT_ID` | Entra ID tenant ID | `terraform output tenant_id` |
| `MCP_CLIENT_ID` | Client ID of the `MCP-Server` app registration | `terraform output mcp_server_client_id` |
| `MCP_CLIENT_SECRET` | Client secret of the `MCP-Server` app registration | `terraform output mcp_server_client_secret` |
| `MCP_SERVER_BASE_URL` | Base URL this server is reachable at (must match a redirect URI registered on `MCP-Server`, e.g. `http://localhost:8001`) | — |
| `MCP_SERVER_APP_ID_URI` | App ID URI exposed by `MCP-Server` (e.g. `api://mcp-server-xxxxxxxx`) | `terraform output mcp_server_app_id_uri` |
| `BACKEND_API_APP_ID_URI` | App ID URI exposed by `Backend-API` (e.g. `api://backend-api-xxxxxxxx`) | `terraform output backend_api_app_id_uri` |
| `BACKEND_API_URL` | URL of the running Backend API | `http://localhost:8000` locally, `terraform output backend_api_url` deployed |
| `PORT` | Port to listen on | `8001` |

## Run

```powershell
uv run python main.py
```

The server starts on SSE transport at `http://localhost:8001/sse`.

## Testing it

The easiest way to test end-to-end is via [agent-client](../agent-client) (fast-agent), whose built-in OAuth client works seamlessly against this server's `AzureProvider`.

> **Note**: MCP Inspector's OAuth/Dynamic Client Registration flow over SSE has shown issues in current versions (its own local proxy 404s on `POST /register`, unrelated to this server — verified by calling `/register` directly with `curl`/`Invoke-RestMethod`). Prefer `agent-client` for OAuth-flow testing.

## Deployment

Deployed as an Azure Linux Web App by `infra/` (`azurerm_linux_web_app.mcp_server`). Azure App Service builds via Oryx, which detects `pyproject.toml`/`uv.lock` and installs dependencies automatically. Startup command: `uv run python main.py` (see `startup.sh`).
