"""
Stock Management API — FastAPI backend.

In-memory demo stock store, secured with Entra ID JWT Bearer tokens (see auth.py).
Accepts both user tokens (Angular SPA) and application tokens (MCP Server,
via Client Credentials with the "Stock.ReadWrite" app role).
"""

import os
import dotenv
dotenv.load_dotenv()

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from auth import require_stock_access

app = FastAPI(title="Stock Management API", version="1.0.0")

# ---------------------------------------------------------------------------
# CORS: allow the Angular Static Web App and local development.
# ---------------------------------------------------------------------------
_default_origins = "http://localhost:4200"
allowed_origins = os.environ.get("ALLOWED_ORIGINS", _default_origins).split(",")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[origin.strip() for origin in allowed_origins if origin.strip()],
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)

# ---------------------------------------------------------------------------
# In-memory stock store (demo only — resets on every restart).
# ---------------------------------------------------------------------------
stock: dict[int, dict] = {
    1: {"id": 1, "name": "Ordinateur", "quantity": 10},
    2: {"id": 2, "name": "Écran", "quantity": 25},
    3: {"id": 3, "name": "Clavier", "quantity": 50},
    4: {"id": 4, "name": "Souris", "quantity": 0},
}
_next_id = max(stock) + 1


class StockItem(BaseModel):
    id: int
    name: str
    quantity: int


class StockAdjustment(BaseModel):
    id: int
    quantity_change: int = Field(..., description="Positive to add stock, negative to remove.")


class NewStockItem(BaseModel):
    name: str
    quantity: int = Field(0, ge=0, description="Initial quantity, defaults to 0.")


@app.get("/api/stock", response_model=list[StockItem])
def list_stock(_claims: dict = Depends(require_stock_access)):
    """Return the current list of stock items and their quantities."""
    return list(stock.values())


@app.post("/api/stock", response_model=StockItem, status_code=201)
def create_stock_item(new_item: NewStockItem, _claims: dict = Depends(require_stock_access)):
    """Create a new stock item with an auto-generated id."""
    global _next_id
    item = {"id": _next_id, "name": new_item.name, "quantity": new_item.quantity}
    stock[_next_id] = item
    _next_id += 1
    return item


@app.post("/api/stock/adjust", response_model=StockItem)
def adjust_stock(adjustment: StockAdjustment, _claims: dict = Depends(require_stock_access)):
    """Adjust the quantity of an existing stock item (positive or negative delta)."""
    item = stock.get(adjustment.id)
    if item is None:
        raise HTTPException(status_code=404, detail=f"Item {adjustment.id} not found.")

    new_quantity = item["quantity"] + adjustment.quantity_change
    if new_quantity < 0:
        raise HTTPException(
            status_code=400,
            detail=f"Cannot adjust item {adjustment.id}: resulting quantity would be negative.",
        )

    item["quantity"] = new_quantity
    return item


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", 8000)),
        reload=bool(os.environ.get("RELOAD")),
    )
