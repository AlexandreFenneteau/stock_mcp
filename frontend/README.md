# Frontend — Gestion de stock (Angular)

Application Angular (standalone components) qui affiche et permet d'ajuster l'inventaire exposé par le [Backend API](../backend). Authentification via Microsoft Entra ID (`@azure/msal-browser` + `@azure/msal-angular`).

## Prérequis

- Node.js 18+ et npm
- Angular CLI (utilisé via `npx`, pas besoin d'installation globale) : `npx ng ...`

## Installation

```powershell
cd frontend
npm install
```

## Lancer en local

```powershell
npx ng serve
```

L'application est servie sur http://localhost:4200. Le backend doit tourner en local sur `http://localhost:8000` (voir [../backend](../backend)) et autoriser cette origine en CORS (c'est le cas par défaut).

## Build de production

```powershell
npx ng build --configuration production
```

`src/environments/environment.ts` n'est pas committé (voir `.gitignore`) et doit être créé localement (copier `environment.ts.example`) avec vos propres valeurs (tenant, client IDs, URL backend). Le pipeline CI (`deploy-apps.yml`) le génère automatiquement à partir des secrets GitHub avant le build. Le résultat est généré dans `dist/frontend`.

## Structure du projet

```
src/
  app/
    app.component.ts/html/css   Composant racine : bandeau de connexion + tableau de stock
    app.config.ts               Configuration MSAL (instance, guard, interceptor) + HttpClient
    msal.config.ts              Factories MSAL (instance, guard, interceptor) et scopes demandés
    stock.service.ts            Appels HTTP vers l'API (GET /api/stock, POST /api/stock/adjust)
  environments/
    environment.ts               Config (tenant, client IDs, URL backend) - non committé, généré par CI ou copié depuis environment.ts.example
```

## Authentification (Entra ID)

- Flow : Authorization Code + PKCE (redirect), configuré dans `msal.config.ts`.
- Le scope demandé pour appeler le backend est un scope délégué exposé par l'app **Backend-API** :
  `api://backend-api-<suffix>/access_as_user` (distinct de l'App Role `Stock.ReadWrite`, réservé aux appels
  application-only du serveur MCP).
- Le `MsalInterceptor` attache automatiquement le token Bearer à toute requête HTTP dont l'URL correspond à
  `environment.backendApiUrl` (voir `protectedResourceMap` dans `MSALInterceptorConfigFactory`).
- Les identifiants (tenant ID, client IDs, App ID URI) proviennent des outputs Terraform (`infra/`) et sont
  recopiés dans `src/environments/`.

## Notes

- Pas de routing/guard (application mono-page) : l'affichage conditionnel connecté/non-connecté est géré
  directement dans `app.component.html`.
- `MsalService.handleRedirectObservable()` doit être appelé (via `APP_INITIALIZER`) pour que l'état
  `MsalBroadcastService.inProgress$` passe correctement de `Startup` à `None` — sans cela, aucune requête
  vers le backend n'est déclenchée après connexion.

