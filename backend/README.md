# Backend API — Stock Management

FastAPI backend for the MCP Stock Management demo. Serves an in-memory stock
inventory and validates Entra ID (Azure AD) JWT Bearer tokens on every request.

## Features

- In-memory stock store (dict), pre-seeded with 3 items (resets on restart).
- `GET /api/stock` — list all stock items.
- `POST /api/stock` — create a new stock item (`{name, quantity}`).
- `POST /api/stock/adjust` — adjust an item's quantity (`{id, quantity_change}`, positive or negative).
- Entra ID Bearer token validation (signature, issuer, audience) via `PyJWT` + JWKS, see [auth.py](auth.py):
  - Delegated (user) tokens from the Angular frontend — any authenticated user is authorized.
  - Application (app-only) tokens from the MCP Server (Client Credentials) — must carry the `Stock.ReadWrite` app role.
- CORS enabled for the configured origins (Static Web App + localhost).

## Requirements

- Python 3.11+
- [uv](https://docs.astral.sh/uv/) — used to manage the virtual environment and dependencies. Never use `pip`/`venv` directly in this project.

## Configuration

Environment variables (see `.env` for local dev, git-ignored):

| Variable | Description |
|---|---|
| `TENANT_ID` | Entra ID tenant ID used to validate token issuer/JWKS. |
| `BACKEND_API_CLIENT_ID` | Client ID of the `Backend-API` app registration (expected token audience). |
| `ALLOWED_ORIGINS` | Comma-separated list of allowed CORS origins. Defaults to `http://localhost:4200`. |
| `PORT` | Port to listen on when run via `python main.py`. Defaults to `8000`. |
| `RELOAD` | If set (non-empty), enables uvicorn auto-reload. |

## Run locally

```powershell
uv sync
uv run python main.py
```

The API is served at `http://localhost:8000`, with interactive docs at
`http://localhost:8000/docs`.

## Run with Gunicorn (production-style, see `startup.sh`)

```powershell
uv run gunicorn main:app --worker-class aiohttp.GunicornWebWorker --bind 0.0.0.0:8000 --timeout 600
```

This is the command used by Azure Web App's startup command (`startup.sh`).

## Manual testing

```powershell
# Without a token -> 401 Unauthorized
Invoke-WebRequest -Uri http://localhost:8000/api/stock -Method GET

# With a valid Bearer token
Invoke-RestMethod -Uri http://localhost:8000/api/stock -Method GET -Headers @{ Authorization = "Bearer $token" }
```

## Deployment

Deployed to an Azure Linux Web App (Python 3.11) via Terraform (`infra/`).
`SCM_DO_BUILD_DURING_DEPLOYMENT` triggers Oryx, which detects `pyproject.toml`/`uv.lock`
and installs dependencies with `uv` automatically.
