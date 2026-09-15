# AutoCare Frontend — Docker & API Proxy Validation

## Scope

This document records the frontend container validation completed on Windows with Docker Desktop. The goal was to verify that the React/Vite SPA can be served under `/autocare/` and that browser/API requests under `/autocare/api/` are reverse-proxied to the AutoCare API.

## Container layout

| Component | Container | Host port |
|---|---|---:|
| Frontend | `autocare-frontend-local` | `8080` |
| API | `autocare-api-local` | `3000` |
| Maintenance service | `autocare-maintenance-service-local` | `8001` |

The frontend container listens on nginx port `8080`.

## Frontend paths

- Application base path: `/autocare/`
- API path exposed through the frontend: `/autocare/api/`
- SPA entry point: `/autocare/index.html`

The frontend uses the Vite build-time values:

```text
VITE_APP_BASE_PATH=/autocare/
VITE_API_BASE_URL=/autocare/api
```

The nginx configuration serves the SPA and proxies `/autocare/api/` to the API upstream. The upstream is supplied to the Docker build through `API_UPSTREAM`, so the Dockerfile does not need a Docker-specific API hostname baked into its nginx configuration.

## Validation performed

### 1. Frontend image build

Built successfully:

```powershell
docker build -t autocare-frontend:local .
```

The image build completed successfully, including `npm ci` and `npm run build`.

### 2. Frontend container

Verified the running containers:

```powershell
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"
```

Expected frontend mapping:

```text
autocare-frontend-local  autocare-frontend:local  0.0.0.0:8080->8080/tcp
```

### 3. Frontend root path

```powershell
Invoke-WebRequest http://localhost:8080/autocare/ -UseBasicParsing
```

Result: **HTTP 200 OK** with the SPA `index.html`.

### 4. `/autocare` path

```powershell
Invoke-WebRequest http://localhost:8080/autocare -UseBasicParsing
```

Result: **HTTP 200 OK**. The configured `/autocare` → `/autocare/` redirect behavior is therefore valid through the running container.

### 5. SPA fallback

```powershell
Invoke-WebRequest http://localhost:8080/autocare/some-client-route -UseBasicParsing
```

Result: **HTTP 200 OK** with the SPA `index.html`.

This confirms that client-side routes can be requested directly without nginx returning a 404.

### 6. API reverse proxy health check

```powershell
Invoke-WebRequest http://localhost:8080/autocare/api/health -UseBasicParsing
```

Result: **HTTP 200 OK** and JSON from `autocare-api`:

```json
{"service":"autocare-api","status":"ok","databaseConfigured":false}
```

This confirms the request travelled through nginx rather than requiring the browser to call the API directly on port `3000`.

### 7. API create-customer through frontend proxy

Created a customer through:

```text
POST /autocare/api/customers
```

Result: **success**, with a customer ID returned by the API.

### 8. API create-vehicle through frontend proxy

Created a vehicle through:

```text
POST /autocare/api/vehicles
```

Result: **success**, linked to the newly created customer.

### 9. Maintenance analysis through frontend proxy

Called:

```text
POST /autocare/api/vehicles/{vehicleId}/maintenance-analysis
```

Result: **success**, with maintenance analysis returned by the API (`riskLevel=medium` in the test).

### 10. Browser UI validation

Opened the application at:

```text
http://localhost:8080/autocare/customers
```

The Customers page loaded successfully and displayed the API-connected workspace, including customer data created during the proxy test.

## Result

**Frontend Docker + nginx routing + API reverse proxy validation passed.**

The validated request flow is:

```text
Browser
  |
  | /autocare/...
  v
Frontend nginx :8080
  |
  | /autocare/api/*  -> API upstream
  v
AutoCare API :3000
  |
  | maintenance analysis when requested
  v
Maintenance service :8001
```

## AKS deployment note

The same frontend Dockerfile can be reused for AKS by supplying a different `API_UPSTREAM` value at image build time. The application-facing paths (`/autocare/` and `/autocare/api/`) remain unchanged.

For AKS, the nginx upstream should resolve to the Kubernetes API Service DNS name rather than `host.docker.internal`. The local Docker value is only for the current Docker Desktop environment.

The frontend application code does not need to call `localhost:3000`; it calls the relative `/autocare/api` path, allowing nginx/ingress routing to keep the browser-side API URL environment-independent.
