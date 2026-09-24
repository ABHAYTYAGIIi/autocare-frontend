# AutoCare Frontend — AKS Deployment

## Status

The AutoCare React frontend is deployed and externally reachable from the AKS `dev` environment.

The frontend is built as a static Vite application and served by nginx. nginx also proxies frontend API requests to the internal AutoCare API Kubernetes Service.

## Complete architecture

```text
                         Internet / Browser
                                |
                                | HTTP
                                v
                    +--------------------------+
                    | Azure Application Gateway |
                    | Public IP: 4.247.238.128 |
                    +------------+-------------+
                                 |
                                 | Kubernetes Ingress
                                 | /autocare/
                                 v
                    +--------------------------+
                    | autocare-frontend Service |
                    | ClusterIP :8080           |
                    +------------+-------------+
                                 |
                                 v
                    +--------------------------+
                    | Frontend Pod              |
                    | nginx :8080               |
                    | React static files        |
                    +------------+-------------+
                                 |
                  /autocare/api/|
                                 | proxy
                                 v
                    +--------------------------+
                    | autocare-api Service      |
                    | ClusterIP :3000           |
                    +------------+-------------+
                                 |
                                 v
                    +--------------------------+
                    | AutoCare API Pod          |
                    | Node.js + Express :3000   |
                    +------------+-------------+
                         |                 |
                         | SQL             | HTTP
                         v                 v
              +------------------+  +-----------------------------+
              | Azure SQL        |  | autocare-maintenance-service |
              | sqldb-autocare-dev|  | ClusterIP :8001             |
              +------------------+  +-----------------------------+

Frontend configuration:

  VITE_APP_BASE_PATH=/autocare/
  VITE_API_BASE_URL=/autocare/api
```

## Application

The frontend is a Vite/React application.

The production build is a static bundle and is served by nginx on port `8080`.

The configured public application base path is:

```text
/autocare/
```

The frontend API base path is:

```text
/autocare/api
```

These values are also represented in the repository's `.env.example`.

## Kubernetes environment

- Cluster: `aks-azure-project`
- Resource group: `rg-azure-aks`
- Namespace: `dev`
- ACR: `acrazureproject.azurecr.io`
- Frontend Deployment: `autocare-frontend`
- Frontend Service: `autocare-frontend:8080`
- Ingress class: `azure-application-gateway`

## Frontend Service

The frontend Service is a Kubernetes `ClusterIP` Service on port `8080`.

It is intentionally internal to the cluster. External traffic reaches it through the Azure Application Gateway Ingress.

## Ingress

The development Ingress routes:

```text
/autocare/ -> autocare-frontend:8080
```

The Ingress uses the AKS Application Gateway Ingress Controller through:

```yaml
ingressClassName: azure-application-gateway
```

Application Gateway currently has the public IP:

```text
4.247.238.128
```

## nginx API proxy

The frontend nginx configuration handles API requests under:

```text
/autocare/api/
```

and proxies them to:

```text
http://autocare-api:3000/api/
```

This keeps the browser using one public application path while API traffic remains internal after reaching the frontend Service.

The important distinction is:

```text
Application Gateway
    = external ingress / reverse proxy

Frontend nginx
    = static-file server + frontend-to-API proxy

Kubernetes Service
    = internal service discovery/load balancing
```

## Container image

The frontend image is stored in Azure Container Registry:

```text
acrazureproject.azurecr.io/autocare-frontend
```

The currently deployed image for this verification was:

```text
acrazureproject.azurecr.io/autocare-frontend:v2
```

The `v2` image was built with the AKS internal API Service as its nginx upstream:

```text
http://autocare-api:3000
```

This avoids the Docker-local `host.docker.internal` dependency inside AKS.

## Manual deployment

Current development deployment is manual.

Example workflow:

```powershell
az acr login --name acrazureproject

docker build -t acrazureproject.azurecr.io/autocare-frontend:<tag> .
docker push acrazureproject.azurecr.io/autocare-frontend:<tag>

kubectl set image deployment/autocare-frontend `
  frontend=acrazureproject.azurecr.io/autocare-frontend:<tag> `
  -n dev

kubectl rollout status deployment/autocare-frontend -n dev
```

## Verification completed

The frontend Service was tested from inside the cluster:

```text
GET http://autocare-frontend:8080/autocare/
-> 200 OK
```

The frontend nginx API proxy was tested:

```text
GET http://autocare-frontend:8080/autocare/api/health
-> 200 OK
```

The public Application Gateway path was tested:

```text
GET http://4.247.238.128/autocare/
-> 200 OK

GET http://4.247.238.128/autocare/api/health
-> 200 OK
```

This proves the external frontend path and frontend-to-API proxy path are working.

## Current public endpoint

```text
http://4.247.238.128/autocare/
```

The current endpoint uses HTTP and the Application Gateway public IP. Domain and HTTPS/TLS are future deployment work.

## Future deployment model

The current manual image-tag workflow will later be replaced with CI/CD and Kustomize.

Target flow:

```text
Git push
   -> CI build/test
   -> Docker image
   -> ACR
   -> immutable image tag/digest
   -> Kustomize dev overlay
   -> AKS Deployment
```

Environment-specific configuration and image references should eventually be managed by Kustomize rather than manually editing deployment manifests.

A change