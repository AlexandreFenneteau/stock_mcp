"""
Stock Management MCP Server.

Exposes MCP tools (check_inventory, modify_inventory) over SSE transport,
secured with Microsoft Entra ID OAuth via FastMCP's AzureProvider.

FastMCP's AzureProvider implements the OAuth Proxy pattern: since Entra ID
doesn't support Dynamic Client Registration, the MCP server brokers the
Authorization Code + PKCE exchange on behalf of any MCP client (fast-agent,
MCP Inspector, etc.), using a single pre-registered Entra ID app (MCP-Server).
Clients just need standard MCP OAuth support - no manual token handling.

Backend-API calls are made "on behalf of" the signed-in user via the
On-Behalf-Of (OBO) flow, using FastMCP's EntraOBOToken dependency.
"""

import os

import dotenv
dotenv.load_dotenv()

import httpx
from fastmcp import FastMCP
from fastmcp.server.auth.providers.azure import AzureProvider, EntraOBOToken

TENANT_ID = os.environ["TENANT_ID"]
MCP_CLIENT_ID = os.environ["MCP_CLIENT_ID"]
MCP_CLIENT_SECRET = os.environ["MCP_CLIENT_SECRET"]
MCP_SERVER_BASE_URL = os.environ.get("MCP_SERVER_BASE_URL", "http://localhost:8001")
MCP_SERVER_APP_ID_URI = os.environ["MCP_SERVER_APP_ID_URI"]
BACKEND_API_APP_ID_URI = os.environ["BACKEND_API_APP_ID_URI"]
BACKEND_API_URL = os.environ["BACKEND_API_URL"].rstrip("/")

# Delegated scope exposed by Backend-API (see infra/main.tf: oauth2_permission_scope "access_as_user").
BACKEND_API_SCOPE = f"{BACKEND_API_APP_ID_URI}/access_as_user"

auth_provider = AzureProvider(
    client_id=MCP_CLIENT_ID,
    client_secret=MCP_CLIENT_SECRET,
    tenant_id=TENANT_ID,
    base_url=MCP_SERVER_BASE_URL,
    # Must match the App ID URI actually set on the MCP-Server App Registration
    # (identifier_uris in infra/main.tf) — defaults to "api://{client_id}",
    # which does NOT match our custom "api://mcp-server-<suffix>" URI.
    identifier_uri=MCP_SERVER_APP_ID_URI,
    # Scope exposed by MCP-Server itself (see infra/main.tf), required for any
    # client to authenticate to this MCP server.
    required_scopes=["access_as_user"],
    # Requested during the initial authorization so the server can later
    # exchange the user's token for a Backend-API token via OBO.
    additional_authorize_scopes=[BACKEND_API_SCOPE],
)

mcp = FastMCP("Stock Management MCP Server", auth=auth_provider)


def _auth_headers(backend_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {backend_token}"}


# ---------------------------------------------------------------------------
# MCP Tools
# ---------------------------------------------------------------------------
@mcp.tool()
async def check_inventory(
    backend_token: str = EntraOBOToken([BACKEND_API_SCOPE]),
) -> str:
    """Retrieve the current stock inventory (item id, name and quantity)."""
    async with httpx.AsyncClient() as client:
        response = await client.get(f"{BACKEND_API_URL}/api/stock", headers=_auth_headers(backend_token))
    response.raise_for_status()
    items = response.json()

    if not items:
        return "The inventory is currently empty."

    lines = [f"- #{item['id']} {item['name']}: {item['quantity']} unit(s)" for item in items]
    return "Current stock inventory:\n" + "\n".join(lines)


@mcp.tool()
async def create_stock_item(
    name: str,
    quantity: int = 0,
    backend_token: str = EntraOBOToken([BACKEND_API_SCOPE]),
) -> str:
    """
    Create a new stock item.

    Args:
        name: Name of the new stock item.
        quantity: Initial quantity, defaults to 0.
    """
    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"{BACKEND_API_URL}/api/stock",
            json={"name": name, "quantity": quantity},
            headers=_auth_headers(backend_token),
        )
    response.raise_for_status()

    item = response.json()
    return f"Created item #{item['id']} ({item['name']}) with quantity: {item['quantity']}."


@mcp.tool()
async def modify_inventory(
    item_id: int,
    change: int,
    backend_token: str = EntraOBOToken([BACKEND_API_SCOPE]),
) -> str:
    """
    Adjust the quantity of a stock item.

    Args:
        item_id: The id of the stock item to adjust.
        change: Quantity delta to apply (positive to add stock, negative to remove).
    """
    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"{BACKEND_API_URL}/api/stock/adjust",
            json={"id": item_id, "quantity_change": change},
            headers=_auth_headers(backend_token),
        )
    if response.status_code == 404:
        return f"Item {item_id} not found."
    if response.status_code == 400:
        return f"Cannot apply change: {response.json().get('detail', 'invalid adjustment')}"
    response.raise_for_status()

    item = response.json()
    return f"Item #{item['id']} ({item['name']}) new quantity: {item['quantity']}."


if __name__ == "__main__":
    mcp.run(
        transport="sse",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", 8001)),
    )

# ASGI app for production deployment under gunicorn + uvicorn workers (see
# startup.sh: `gunicorn main:app -k uvicorn.workers.UvicornWorker ...`).
# Not used by the `mcp.run(...)` dev entrypoint above.
app = mcp.http_app(transport="sse")
