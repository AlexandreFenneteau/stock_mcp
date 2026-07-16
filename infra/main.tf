########################################
# MCP Stock Management Demo - Infra
# Minimal, public, demo-only infrastructure
########################################

terraform {
  required_version = ">= 1.6"

  # Remote state, shared between local runs and GitHub Actions CI (so CI
  # doesn't try to recreate resources that already exist). The storage
  # account/container are bootstrapped once, manually, outside Terraform
  # (avoids a chicken-and-egg dependency on the state backend itself).
  # Auth uses Azure AD (RBAC "Storage Blob Data Contributor"), matching the
  # OIDC-only / no-secrets approach used everywhere else in this repo.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-mcpstock"
    storage_account_name = "sttfstatemcpstockatsmi"
    container_name       = "tfstate"
    key                  = "mcp-stock.tfstate"
    use_azuread_auth     = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}

  # Register only the core Resource Providers actually needed by this config
  # (e.g. Microsoft.Web). Using "all" can fail with 409 ConflictingConcurrentWriteNotAllowed
  # when Azure is already registering providers concurrently on the subscription.
  resource_provider_registrations = "core"
}

provider "azuread" {}

########################################
# Variables
########################################

variable "prefix" {
  description = "Prefix used to name all resources"
  type        = string
  default     = "mcpstock"
}

variable "admin_object_id" {
  description = <<-EOT
    Object ID of the human user/group that owns all Entra ID App Registrations
    (in addition to the GitHub-Actions-Deploy service principal, added
    automatically). Must be a FIXED value (not derived from
    data.azuread_client_config.current, which resolves to whoever is running
    Terraform - your user locally, but the GitHub-Actions-Deploy service
    principal itself in CI - causing ownership to flip-flop on every apply).
    Get yours with: az ad signed-in-user show --query id -o tsv
  EOT
  type        = string
}

variable "location" {
  description = "Azure region for the resources"
  type        = string
  default     = "francecentral"
}

variable "app_service_sku" {
  description = "SKU for the Linux App Service Plan (F1 = Free, B1 = Basic)"
  type        = string
  default     = "B1"
}

variable "static_web_app_location" {
  description = "Azure region for the Static Web App (limited availability: centralus, eastus2, westus2, westeurope, eastasia)"
  type        = string
  default     = "eastus2"
}

variable "github_repository" {
  description = "GitHub repository in \"owner/repo\" form, used to scope the OIDC federated credential for GitHub Actions"
  type        = string
}

data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

locals {
  suffix = random_string.suffix.result
}

########################################
# Resource Group
########################################

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.prefix}-${local.suffix}"
  location = var.location
}

########################################
# Entra ID - Backend-API App Registration
# Exposes the "Stock.ReadWrite" App Role
########################################

resource "random_uuid" "stock_readwrite_role_id" {}
resource "random_uuid" "stock_readwrite_scope_id" {}

locals {
  backend_api_identifier_uri = "api://backend-api-${local.suffix}"
}

resource "azuread_application" "backend_api" {
  display_name     = "Backend-API"
  owners           = [var.admin_object_id, azuread_service_principal.github_actions.object_id]
  sign_in_audience = "AzureADMyOrg"

  identifier_uris = [local.backend_api_identifier_uri]

  # App-only permission (application role), used by the MCP-Server daemon app
  # via the Client Credentials flow.
  app_role {
    id                   = random_uuid.stock_readwrite_role_id.result
    allowed_member_types = ["Application"]
    description          = "Allows read/write access to the stock inventory"
    display_name         = "Stock.ReadWrite"
    value                = "Stock.ReadWrite"
    enabled              = true
  }

  api {
    requested_access_token_version = 2

    # Delegated permission (user scope), used by the Angular SPA via
    # Authorization Code + PKCE on behalf of the signed-in user.
    oauth2_permission_scope {
      id                         = random_uuid.stock_readwrite_scope_id.result
      admin_consent_description  = "Allows the app to read and write the stock inventory on behalf of the signed-in user"
      admin_consent_display_name = "Access Stock as the signed-in user"
      user_consent_description   = "Allow the app to read and write the stock inventory on your behalf"
      user_consent_display_name  = "Access Stock as you"
      value                      = "access_as_user"
      type                       = "User"
      enabled                    = true
    }
  }
}

resource "azuread_service_principal" "backend_api" {
  client_id = azuread_application.backend_api.client_id
  owners    = [var.admin_object_id, azuread_service_principal.github_actions.object_id]
}

########################################
# Entra ID - Frontend-Angular App Registration
# SPA, Authorization Code + PKCE
########################################

resource "azuread_application" "frontend_angular" {
  display_name     = "Frontend-Angular"
  owners           = [var.admin_object_id, azuread_service_principal.github_actions.object_id]
  sign_in_audience = "AzureADMyOrg"

  single_page_application {
    redirect_uris = [
      "https://${azurerm_static_web_app.frontend.default_host_name}/",
      "http://localhost:4200/"
    ]
  }

  required_resource_access {
    resource_app_id = azuread_application.backend_api.client_id

    resource_access {
      id   = random_uuid.stock_readwrite_scope_id.result
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "frontend_angular" {
  client_id = azuread_application.frontend_angular.client_id
  owners    = [var.admin_object_id, azuread_service_principal.github_actions.object_id]
}

########################################
# Entra ID - MCP-Server App Registration
# Daemon app, Client Credentials flow
########################################

resource "random_uuid" "mcp_server_scope_id" {}

locals {
  mcp_server_identifier_uri = "api://mcp-server-${local.suffix}"
  # Predictable *.azurewebsites.net hostname, computed from the name we assign
  # below — avoids a Terraform dependency cycle with azurerm_linux_web_app.mcp_server
  # (whose app_settings reference this app registration's client ID/secret).
  mcp_server_hostname = "app-mcp-${var.prefix}-${local.suffix}.azurewebsites.net"
}

resource "azuread_application" "mcp_server" {
  display_name     = "MCP-Server"
  owners           = [var.admin_object_id, azuread_service_principal.github_actions.object_id]
  sign_in_audience = "AzureADMyOrg"

  identifier_uris = [local.mcp_server_identifier_uri]

  # Web redirect URIs for FastMCP's AzureProvider (OAuth Proxy pattern): the
  # MCP server itself brokers the Authorization Code + PKCE exchange with
  # Entra ID on behalf of any MCP client (fast-agent, Inspector, etc.), since
  # Entra ID doesn't support Dynamic Client Registration.
  web {
    redirect_uris = [
      "http://localhost:8001/auth/callback",
      "https://${local.mcp_server_hostname}/auth/callback",
    ]
  }

  # Delegated permission: lets the MCP server call Backend-API on behalf of
  # the signed-in user via the OAuth2 On-Behalf-Of (OBO) flow.
  required_resource_access {
    resource_app_id = azuread_application.backend_api.client_id

    resource_access {
      id   = random_uuid.stock_readwrite_scope_id.result
      type = "Scope"
    }
  }

  api {
    requested_access_token_version = 2

    # Delegated permission exposed by the MCP server itself: a caller (the
    # Angular SPA, agent-client, or MCP Inspector for testing) must acquire a
    # token for THIS scope (aud = MCP-Server) before calling the MCP server,
    # so the OBO assertion's audience matches the client presenting it.
    oauth2_permission_scope {
      id                         = random_uuid.mcp_server_scope_id.result
      admin_consent_description  = "Allows the app to call the MCP server on behalf of the signed-in user"
      admin_consent_display_name = "Access MCP Server as the signed-in user"
      user_consent_description   = "Allow the app to call the MCP server on your behalf"
      user_consent_display_name  = "Access MCP Server as you"
      value                      = "access_as_user"
      type                       = "User"
      enabled                    = true
    }
  }
}

resource "azuread_service_principal" "mcp_server" {
  client_id = azuread_application.mcp_server.client_id
  owners    = [var.admin_object_id, azuread_service_principal.github_actions.object_id]
}

resource "azuread_application_password" "mcp_server" {
  application_id = azuread_application.mcp_server.id
  display_name   = "mcp-server-secret"
}

# Admin-consent the MCP-Server's delegated "access_as_user" permission on Backend-API,
# so the OBO token exchange doesn't require interactive user consent.
resource "azuread_service_principal_delegated_permission_grant" "mcp_server_access_as_user" {
  service_principal_object_id          = azuread_service_principal.mcp_server.object_id
  resource_service_principal_object_id = azuread_service_principal.backend_api.object_id
  claim_values                         = ["access_as_user"]
}

########################################
# Azure Static Web App - Angular Frontend
########################################

resource "azurerm_static_web_app" "frontend" {
  name                = "swa-${var.prefix}-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.static_web_app_location
  sku_tier            = "Free"
  sku_size            = "Free"
}

########################################
# App Service Plan (Linux) + Web Apps (Python)
########################################

resource "azurerm_service_plan" "main" {
  name                = "asp-${var.prefix}-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku
}

# Backend API (FastAPI) Web App
resource "azurerm_linux_web_app" "backend_api" {
  name                = "app-backend-${var.prefix}-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_service_plan.main.location
  service_plan_id     = azurerm_service_plan.main.id

  site_config {
    application_stack {
      python_version = "3.11"
    }
    cors {
      allowed_origins = [
        "https://${azurerm_static_web_app.frontend.default_host_name}",
        "http://localhost:4200"
      ]
    }
  }

  app_settings = {
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "TENANT_ID"                      = data.azurerm_client_config.current.tenant_id
    "BACKEND_API_CLIENT_ID"          = azuread_application.backend_api.client_id
    "FRONTEND_CLIENT_ID"             = azuread_application.frontend_angular.client_id
    "MCP_SERVER_CLIENT_ID"           = azuread_application.mcp_server.client_id
    "ALLOWED_ORIGINS"                = "https://${azurerm_static_web_app.frontend.default_host_name},http://localhost:4200"
  }
}

# MCP Server (FastMCP) Web App
resource "azurerm_linux_web_app" "mcp_server" {
  name                = "app-mcp-${var.prefix}-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_service_plan.main.location
  service_plan_id     = azurerm_service_plan.main.id

  site_config {
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "TENANT_ID"                      = data.azurerm_client_config.current.tenant_id
    "MCP_SERVER_CLIENT_ID"           = azuread_application.mcp_server.client_id
    "MCP_SERVER_CLIENT_SECRET"       = azuread_application_password.mcp_server.value
    "MCP_SERVER_BASE_URL"            = "https://${local.mcp_server_hostname}"
    "MCP_SERVER_APP_ID_URI"          = local.mcp_server_identifier_uri
    "BACKEND_API_CLIENT_ID"          = azuread_application.backend_api.client_id
    "BACKEND_API_APP_ID_URI"         = local.backend_api_identifier_uri
    "BACKEND_API_URL"                = "https://${azurerm_linux_web_app.backend_api.default_hostname}"
    # Consumed by the agent-client's fast-agent.yaml env var override, so a
    # fast-agent process running alongside this Web App (or configured with
    # this app's settings) points at this deployed MCP server without editing
    # fast-agent.yaml.
    "MCP__SERVERS__STOCK_MCP__URL" = "https://${local.mcp_server_hostname}/sse"
  }
}

########################################
# Entra ID - GitHub Actions OIDC App Registration
# Used by the CI/CD workflows to deploy the app code without any stored
# client secret: GitHub issues a short-lived OIDC token, exchanged by
# azure/login against the federated credential below.
########################################

resource "azuread_application" "github_actions" {
  display_name     = "GitHub-Actions-Deploy"
  owners           = [var.admin_object_id]
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "github_actions" {
  client_id = azuread_application.github_actions.client_id
  owners    = [var.admin_object_id]
}

# Microsoft Graph service principal, well-known appId in every tenant.
data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

# CI runs as this service principal in APP-ONLY context (client credentials /
# OIDC), where Microsoft Graph ignores "ownership" of an application - being
# listed as an owner only grants rights in DELEGATED (signed-in user)
# context. App-only calls need an actual Graph API permission instead, so
# grant the least-privilege one scoped to apps this SP owns (not
# Application.ReadWrite.All, which would cover the whole tenant).
resource "azuread_app_role_assignment" "github_actions_manage_owned_apps" {
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids["Application.ReadWrite.OwnedBy"]
  principal_object_id = azuread_service_principal.github_actions.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Allow the workflow to run from both the main branch and pull_request events.
resource "azuread_application_federated_identity_credential" "github_actions_main" {
  application_id = azuread_application.github_actions.id
  display_name   = "github-actions-main-branch"
  description    = "GitHub Actions deploying from the main branch"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_repository}:ref:refs/heads/main"
}

# Jobs that declare `environment: production` (both workflows do) send a
# different OIDC subject claim — "environment:<name>" instead of
# "ref:refs/heads/<branch>" — so a separate federated credential is required.
resource "azuread_application_federated_identity_credential" "github_actions_production_environment" {
  application_id = azuread_application.github_actions.id
  display_name   = "github-actions-production-environment"
  description    = "GitHub Actions deploying from the production environment"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_repository}:environment:production"
}

# Contributor on the resource group only (not subscription-wide) — least
# privilege needed to zip-deploy the two Web Apps and the Static Web App.
resource "azurerm_role_assignment" "github_actions_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.github_actions.object_id
}

########################################
# Outputs
########################################

output "tenant_id" {
  description = "Entra ID Tenant ID"
  value       = data.azurerm_client_config.current.tenant_id
}

output "backend_api_client_id" {
  description = "Client ID of the Backend-API App Registration"
  value       = azuread_application.backend_api.client_id
}

output "backend_api_app_id_uri" {
  description = "App ID URI (identifier_uris) exposed by the Backend-API App Registration"
  value       = local.backend_api_identifier_uri
}

output "frontend_angular_client_id" {
  description = "Client ID of the Frontend-Angular App Registration"
  value       = azuread_application.frontend_angular.client_id
}

output "mcp_server_client_id" {
  description = "Client ID of the MCP-Server App Registration"
  value       = azuread_application.mcp_server.client_id
}

output "mcp_server_app_id_uri" {
  description = "App ID URI (identifier_uris) exposed by the MCP-Server App Registration. Callers must acquire a user token for '<this>/access_as_user' before calling the MCP server."
  value       = local.mcp_server_identifier_uri
}

output "mcp_server_client_secret" {
  description = "Client secret of the MCP-Server App Registration"
  value       = azuread_application_password.mcp_server.value
  sensitive   = true
}

output "static_web_app_url" {
  description = "URL of the Angular Static Web App"
  value       = "https://${azurerm_static_web_app.frontend.default_host_name}"
}

output "static_web_app_api_key" {
  description = "Deployment API key (token) for the Static Web App, used by the Azure/static-web-apps-deploy GitHub Action"
  value       = azurerm_static_web_app.frontend.api_key
  sensitive   = true
}

output "backend_api_url" {
  description = "URL of the Backend API Web App"
  value       = "https://${azurerm_linux_web_app.backend_api.default_hostname}"
}

output "mcp_server_url" {
  description = "URL of the MCP Server Web App"
  value       = "https://${azurerm_linux_web_app.mcp_server.default_hostname}"
}

output "mcp_server_sse_url" {
  description = "SSE endpoint of the deployed MCP Server, for the agent-client's MCP__SERVERS__STOCK_MCP__URL env var override"
  value       = "https://${local.mcp_server_hostname}/sse"
}

output "backend_api_app_name" {
  description = "Name of the Backend API Web App (used by az webapps deploy / GitHub Actions)"
  value       = azurerm_linux_web_app.backend_api.name
}

output "mcp_server_app_name" {
  description = "Name of the MCP Server Web App (used by az webapps deploy / GitHub Actions)"
  value       = azurerm_linux_web_app.mcp_server.name
}

output "static_web_app_name" {
  description = "Name of the Static Web App"
  value       = azurerm_static_web_app.frontend.name
}

output "resource_group_name" {
  description = "Name of the Resource Group holding all resources"
  value       = azurerm_resource_group.main.name
}

output "subscription_id" {
  description = "Azure Subscription ID (set as the AZURE_SUBSCRIPTION_ID GitHub secret)"
  value       = data.azurerm_client_config.current.subscription_id
}

output "github_actions_client_id" {
  description = "Client ID of the GitHub-Actions-Deploy App Registration (set as the AZURE_CLIENT_ID GitHub secret). No client secret is needed — auth uses OIDC federation."
  value       = azuread_application.github_actions.client_id
}
