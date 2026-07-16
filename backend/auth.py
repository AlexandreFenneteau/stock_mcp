"""
Entra ID (Azure AD) JWT Bearer token validation for the Stock Management API.

Accepts two kinds of tokens:
  - User (delegated) tokens issued to the Angular SPA (Authorization Code + PKCE).
  - Application (app-only) tokens issued to the MCP Server via Client Credentials,
    which must carry the "Stock.ReadWrite" App Role.

Validation performed:
  - Signature verification against Entra ID's public JWKS (cached, auto-refreshed).
  - Issuer (`iss`) matches the expected tenant.
  - Audience (`aud`) matches the Backend API application.
  - Expiration / not-before (handled by PyJWT).
  - For app-only tokens (no `scp` claim), the "Stock.ReadWrite" role must be present.
"""

import os
import dotenv
dotenv.load_dotenv()
from typing import Any

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient

TENANT_ID = os.environ["TENANT_ID"]
BACKEND_API_CLIENT_ID = os.environ["BACKEND_API_CLIENT_ID"]

AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}/v2.0"
JWKS_URL = f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys"
REQUIRED_APP_ROLE = "Stock.ReadWrite"

# Entra ID may set the audience to either the API's client ID or its
# "api://..." App ID URI, depending on how the caller requested the token.
ACCEPTED_AUDIENCES = {
    BACKEND_API_CLIENT_ID,
    f"api://{BACKEND_API_CLIENT_ID}",
}

_bearer_scheme = HTTPBearer(auto_error=True)
_jwk_client = PyJWKClient(JWKS_URL)


def _decode_token(token: str) -> dict[str, Any]:
    """Verify signature, issuer and audience of a raw JWT. Raises HTTPException on failure."""
    try:
        signing_key = _jwk_client.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=list(ACCEPTED_AUDIENCES),
            issuer=AUTHORITY,
            options={"require": ["exp", "iss", "aud"]},
        )
    except jwt.PyJWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid or expired token: {exc}",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
    return claims


def require_stock_access(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer_scheme),
) -> dict[str, Any]:
    """
    FastAPI dependency validating the Bearer token and authorizing access to the stock API.

    - Delegated (user) tokens: any successfully authenticated Entra ID user is authorized.
    - Application (app-only) tokens: the "roles" claim must contain "Stock.ReadWrite".
    """
    claims = _decode_token(credentials.credentials)

    is_app_only_token = "scp" not in claims  # client-credentials tokens have no "scp" claim
    if is_app_only_token:
        roles = claims.get("roles", [])
        if REQUIRED_APP_ROLE not in roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Application token is missing the required '{REQUIRED_APP_ROLE}' role.",
            )

    return claims
