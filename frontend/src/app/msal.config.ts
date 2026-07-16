import {
  IPublicClientApplication,
  PublicClientApplication,
  InteractionType,
  BrowserCacheLocation,
  LogLevel,
} from '@azure/msal-browser';
import {
  MsalGuardConfiguration,
  MsalInterceptorConfiguration,
} from '@azure/msal-angular';
import { environment } from '../environments/environment';

/**
 * MSAL instance configuration.
 * Uses Authorization Code flow with PKCE (default in msal-browser for SPAs).
 */
export function MSALInstanceFactory(): IPublicClientApplication {
  return new PublicClientApplication({
    auth: {
      clientId: environment.frontendClientId,
      authority: `https://login.microsoftonline.com/${environment.tenantId}`,
      redirectUri: environment.redirectUri,
      postLogoutRedirectUri: environment.redirectUri,
    },
    cache: {
      cacheLocation: BrowserCacheLocation.LocalStorage,
    },
    system: {
      loggerOptions: {
        loggerCallback: (level: LogLevel, message: string, containsPii: boolean) => {
          if (containsPii) {
            return;
          }
          switch (level) {
            case LogLevel.Error:
              console.error(message);
              return;
            case LogLevel.Warning:
              console.warn(message);
              return;
          }
        },
      },
    },
  });
}

/**
 * The delegated scope exposed by the Backend-API app registration
 * (oauth2_permission_scope "access_as_user"), requested for the signed-in user.
 * Distinct from the "Stock.ReadWrite" App Role used by app-only (client
 * credentials) callers such as the MCP server.
 */
export const backendApiScopes = [`${environment.backendApiIdentifierUri}/access_as_user`];

/**
 * Guard configuration: redirect to Entra ID login when a protected route is accessed.
 */
export function MSALGuardConfigFactory(): MsalGuardConfiguration {
  return {
    interactionType: InteractionType.Redirect,
    authRequest: {
      scopes: ['user.read'],
    },
  };
}

/**
 * Interceptor configuration: attach the Bearer token to every call made to the
 * backend API, requesting the Stock.ReadWrite scope.
 */
export function MSALInterceptorConfigFactory(): MsalInterceptorConfiguration {
  const protectedResourceMap = new Map<string, Array<string> | null>();
  protectedResourceMap.set(`${environment.backendApiUrl}/*`, backendApiScopes);

  return {
    interactionType: InteractionType.Redirect,
    protectedResourceMap,
  };
}
