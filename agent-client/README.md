# Stock Management Agent Client

A local [fast-agent](https://fast-agent.ai/) client that connects to the [Stock Management MCP Server](../mcp-server) and lets you chat with an LLM that can inspect and modify the stock inventory through MCP tools.

## What it does

- Connects to the MCP server over SSE (`http://localhost:8001/sse` by default — see `fast-agent.yaml`).
- Authentication is fully automatic: the MCP server is secured with Microsoft Entra ID OAuth (FastMCP `AzureProvider`). fast-agent's built-in MCP OAuth client (`auth.oauth: true`) handles the Authorization Code + PKCE flow — on first use it prints a clickable login link, and afterward tokens are cached in your OS keychain (Windows Credential Manager / macOS Keychain / Linux Secret Service).
- Runs an interactive terminal chat (`agent.interactive()`) using a standard LLM provider (Anthropic, OpenAI, etc.).

## Prerequisites

- The [mcp-server](../mcp-server) running locally (or reachable at the URL configured in `fast-agent.yaml`).
- [uv](https://docs.astral.sh/uv/) installed.
- An API key for at least one LLM provider supported by fast-agent (Anthropic, OpenAI, etc.).

## Setup

```powershell
cd agent-client
uv sync
cp fast-agent.secrets.yaml.example fast-agent.secrets.yaml
```

Edit `fast-agent.secrets.yaml` and fill in your LLM provider API key (this file is git-ignored — never commit real keys).

By default `fast-agent.yaml` targets `http://localhost:8001/sse`. For the deployed MCP server, change the `url` to `https://<mcp-webapp>.azurewebsites.net/sse` (see `terraform output mcp_server_url`).

## Run

```powershell
uv run python agent.py
```

On the first tool call, fast-agent prints an authorization link:

```
Open this link to authorize:
http://localhost:8001/authorize?...
```

Open it, sign in with your Entra ID account, and approve. The chat session then proceeds — subsequent runs won't require logging in again (tokens are cached) until they expire.

## Useful commands in the chat

- `/mcp` — inspect the connected MCP server's status/health.
- `/tools` — list the available MCP tools (`check_inventory`, `create_stock_item`, `modify_inventory`).
- Just ask in natural language, e.g. *"Peux-tu me donner mes stocks ?"* or *"Ajoute 5 casques audio au stock."*

## Clearing cached OAuth tokens

If you need to force a fresh login (e.g. after an infra change to the `MCP-Server` app registration):

```powershell
uv run fast-agent auth clear --identity http://localhost:8001
```
