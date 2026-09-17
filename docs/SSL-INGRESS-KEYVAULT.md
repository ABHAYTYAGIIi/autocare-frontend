# HTTPS Ingress with Azure Application Gateway + Key Vault

## Purpose

This document records the working HTTPS/TLS setup used by AutoCare UAT with:

- AKS + AGIC (Application Gateway Ingress Controller)
- Azure Application Gateway Standard_v2
- Azure Key Vault with Azure RBAC
- Key Vault Private Endpoint
- Private DNS for Key Vault
- User-assigned managed identity for Application Gateway
- Kubernetes Ingress/Kustomize for listener and routing configuration

The configuration was tested end-to-end on UAT.

> **Important:** Do not commit PFX files, certificate private keys, CA private keys, passwords, or other secret material to Git.

---

## 1. Target architecture

```text
Browser
  |
  | HTTPS :443
  v
Azure Application Gateway
  |
  | certificate retrieval
  v
Azure Key Vault
  |
  | Private Endpoint
  v
Private DNS -> 10.x.x.x

Application Gateway listener/rules are managed by AGIC from the Kubernetes Ingress.
Do not manually create competing listeners or routing rules in Application Gateway.
```

For this project the UAT hostname is:

```text
uat.autocare.local
```

The `.local` hostname is a lab/test hostname. A real public domain should be used for production with a publicly trusted certificate.

---

## 2. Roles and identities — use this order

There are **three different permissions/identities** involved. Keep them separate.

### A. Application Gateway managed identity

Create a dedicated user-assigned managed identity for Application Gateway.

Example:

```text
id-appgw-keyvault
```

Attach this identity to Application Gateway.

**Purpose:** Application Gateway uses this identity to retrieve the TLS certificate from Key Vault.

Assign this identity:

```text
Key Vault Secrets User
```

Scope:

```text
The target Key Vault only
```

Microsoft documents `Key Vault Secrets User` as the required RBAC role for Application Gateway to retrieve a Key Vault certificate/secret. See Microsoft Learn: [TLS termination with Key Vault certificates](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs).

---

### B. AGIC identity

AKS's Application Gateway Ingress Controller has its own managed identity.

This identity already has permission to modify Application Gateway, but it also needs permission to **assign/use the Application Gateway user-assigned identity** while reconciling the Ingress.

Assign to the AGIC identity, scoped only to the Application Gateway identity resource:

```text
Managed Identity Operator
```

Scope:

```text
id-appgw-keyvault
```

This permission fixed the original AGIC error:

```text
LinkedAuthorizationFailed
Microsoft.ManagedIdentity/userAssignedIdentities/assign/action
```

Do not give AGIC broad subscription-level identity permissions for this purpose.

---

### C. Human/operator identity

The Azure user performing certificate import/configuration needs the appropriate Key Vault certificate-management permission.

For importing the PFX into a Key Vault using Azure RBAC, the operator can use:

```text
Key Vault Certificates Officer
```

on the target Key Vault.

This is an operator permission. It is **not** the identity Application Gateway uses at runtime.

---

## 3. Recommended identity sequence

Use this exact order:

```text
1. Create id-appgw-keyvault
             |
             v
2. Give id-appgw-keyvault -> Key Vault Secrets User
             |
             v
3. Attach id-appgw-keyvault -> Application Gateway
             |
             v
4. Give AGIC identity -> Managed Identity Operator
   scoped to id-appgw-keyvault
             |
             v
5. Import/prepare certificate in Key Vault
             |
             v
6. Register the Key Vault secret with Application Gateway
             |
             v
7. Let AGIC create HTTPS listener/routing from Kubernetes Ingress
```

The key distinction is:

```text
Application Gateway identity
    = reads certificate

AGIC identity
    = configures Application Gateway and can assign the App Gateway identity

Human/operator identity
    = performs administrative certificate/import operations
```

---

## 4. Key Vault certificate requirements

Application Gateway TLS integration requires a PFX certificate and the certificate must be enabled.

Verify:

```powershell
az keyvault secret show `
  --vault-name "<KEY_VAULT_NAME>" `
  --name "<CERTIFICATE_SECRET_NAME>" `
  --query "{enabled:attributes.enabled,contentType:contentType}" `
  -o json
```

Expected:

```text
enabled: true
contentType: application/x-pkcs12
```

The private key/PFX must stay outside Git.

---

## 5. Key Vault private networking

For a private Key Vault architecture, keep:

```text
publicNetworkAccess = Disabled
```

Create/use a Key Vault Private Endpoint in the Application Gateway VNet.

Example project resources:

```text
VNet:                 vnet-azure-project
App Gateway subnet:   snet-appgw
Key Vault PE:         pe-kv-azure-project
```

The private endpoint must be approved.

### Private DNS

Use the Azure private DNS zone:

```text
privatelink.vaultcore.azure.net
```

The zone must be linked to the VNet containing Application Gateway.

The private endpoint must have a DNS zone group associated with that zone. This causes the Key Vault record to point to the private endpoint IP.

Verify:

```powershell
az network private-endpoint dns-zone-group list `
  --resource-group "<PRIVATE_ENDPOINT_RESOURCE_GROUP>" `
  --endpoint-name "<PRIVATE_ENDPOINT_NAME>" `
  -o table
```

Verify the A record:

```powershell
az network private-dns record-set a show `
  --resource-group "<DNS_RESOURCE_GROUP>" `
  --zone-name "privatelink.vaultcore.azure.net" `
  --name "<KEY_VAULT_NAME>" `
  --query "arecords[].ipv4Address" `
  -o tsv
```

Microsoft's Application Gateway documentation requires the `privatelink.vaultcore.azure.net` zone to be linked to the Application Gateway VNet when using a Key Vault private endpoint.

---

## 6. Key Vault trusted-services bypass

For this project, Application Gateway continued to receive:

```text
ApplicationGatewayKeyVaultSecretAccessDenied
```

until the Key Vault networking exception was set to:

```text
AzureServices
```

The final working configuration is:

```text
publicNetworkAccess = Disabled
networkAcls.defaultAction = Deny
networkAcls.bypass = AzureServices
```

Set it with:

```powershell
az keyvault update `
  --name "<KEY_VAULT_NAME>" `
  --bypass AzureServices
```

**Important:** `AzureServices` does not enable general public access. `publicNetworkAccess` remains disabled. It permits supported trusted Microsoft services to bypass the Key Vault firewall.

Microsoft documents that the trusted-services bypass continues to apply when `publicNetworkAccess` is `Disabled`.

> **Project-specific troubleshooting note:** Microsoft documentation states that a Key Vault private endpoint can be used by Application Gateway when the private DNS configuration is correct. In this project's actual UAT deployment, certificate retrieval still returned `ApplicationGatewayKeyVaultSecretAccessDenied` until `bypass=AzureServices` was enabled while keeping `publicNetworkAccess=Disabled`. Treat this as part of the tested project configuration.

---

## 7. Register the Key Vault certificate with Application Gateway

After the certificate exists in Key Vault and the Application Gateway identity has `Key Vault Secrets User`, register the Key Vault secret with Application Gateway.

Use a **versionless** Key Vault secret reference so certificate rotation can be synchronized:

```powershell
az network application-gateway ssl-cert create `
  --resource-group "<APP_GATEWAY_RESOURCE_GROUP>" `
  --gateway-name "<APP_GATEWAY_NAME>" `
  --name "<APP_GATEWAY_SSL_CERT_NAME>" `
  --key-vault-secret-id "https://<KEY_VAULT_NAME>.vault.azure.net/secrets/<CERTIFICATE_SECRET_NAME>/"
```

This command creates the certificate reference on Application Gateway. It does **not** create the Kubernetes Ingress listener/routing rule.

AGIC will create those from the Kubernetes Ingress.

---

## 8. Kubernetes Ingress configuration

The frontend Ingress should use the AGIC SSL annotations.

Example:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: autocare
  annotations:
    appgw.ingress.kubernetes.io/appgw-ssl-certificate: autocare-uat-tls
    appgw.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  rules:
    - host: uat.autocare.local
      http:
        paths:
          - path: /autocare/
            pathType: Prefix
            backend:
              service:
                name: autocare-frontend
                port:
                  number: 8080
```

AGIC uses this to create:

```text
HTTPS listener :443
        |
        +-- certificate: autocare-uat-tls
        |
        +-- host: uat.autocare.local
        |
        +-- path: /autocare/
        |
        +-- backend: autocare-frontend:8080
```

HTTP-to-HTTPS redirect is controlled by:

```yaml
appgw.ingress.kubernetes.io/ssl-redirect: "true"
```

---

## 9. Apply the Ingress

With the Kustomize overlay:

```powershell
kubectl apply -k .\k8s\overlays\uat
```

If AGIC needs to be forced to reconcile after an Azure-side permission/network change:

```powershell
kubectl annotate ingress autocare -n uat autocare.azure.com/reconcile="$(Get-Date -Format o)" --overwrite
```

Normally do not manually create Application Gateway listeners or routing rules. AGIC is the source of truth for the Kubernetes-managed configuration.

---

## 10. Verification sequence

### Check Ingress

```powershell
kubectl get ingress autocare -n uat
```

Note: seeing `80` in the `PORTS` column here does **not** prove that HTTPS is missing. Kubernetes Ingress output can still show the backend HTTP service port while Application Gateway has a 443 HTTPS listener.

### Check Application Gateway provisioning

```powershell
az network application-gateway show `
  --resource-group "<APP_GATEWAY_RESOURCE_GROUP>" `
  --name "<APP_GATEWAY_NAME>" `
  --query "provisioningState"
```

Expected:

```text
"Succeeded"
```

### Check HTTPS frontend port

```powershell
az network application-gateway frontend-port list `
  --resource-group "<APP_GATEWAY_RESOURCE_GROUP>" `
  --gateway-name "<APP_GATEWAY_NAME>" `
  --query "[].{name:name,port:port}" `
  -o table
```

Expected to include:

```text
443
```

### Check HTTPS listener and certificate

```powershell
az network application-gateway http-listener list `
  --resource-group "<APP_GATEWAY_RESOURCE_GROUP>" `
  --gateway-name "<APP_GATEWAY_NAME>" `
  --query "[].{name:name,protocol:protocol,hostnames:hostNames,frontendPort:frontendPort.id,sslCertificate:sslCertificate.id}" `
  -o table
```

Expected:

```text
Protocol:       Https
Frontend port:  fp-443 / 443
Certificate:    autocare-uat-tls
```

### Check routing rule

```powershell
az network application-gateway rule list `
  --resource-group "<APP_GATEWAY_RESOURCE_GROUP>" `
  --gateway-name "<APP_GATEWAY_NAME>" `
  --query "[].{name:name,ruleType:ruleType,httpListener:httpListener.id}" `
  -o table
```

### Browser test

For a local `.local` lab hostname, map the hostname to the Application Gateway public IP on the test machine:

```text
<APP_GATEWAY_PUBLIC_IP> uat.autocare.local
```

Then test:

```text
https://uat.autocare.local/autocare/
```

A local CA certificate may produce a browser trust warning. That warning is separate from whether TLS/HTTPS encryption is functioning.

---

## 11. Common failure sequence encountered in UAT

### Failure 1 — AGIC could not apply Application Gateway identity

Error:

```text
LinkedAuthorizationFailed
Microsoft.ManagedIdentity/userAssignedIdentities/assign/action
```

Cause:

```text
AGIC identity lacked Managed Identity Operator
on id-appgw-keyvault.
```

Fix:

```text
AGIC identity
  -> Managed Identity Operator
  -> scope: id-appgw-keyvault
```

### Failure 2 — Application Gateway entered Failed provisioning state

Error:

```text
ApplicationGatewayKeyVaultSecretException
```

Initial investigation showed the Key Vault private DNS record-set existed but had no A record IP.

The private endpoint was:

```text
pe-kv-azure-project
10.20.2.7
Approved
```

But the private endpoint had no DNS zone group.

Fix:

```text
Private Endpoint
  -> DNS Zone Group
  -> privatelink.vaultcore.azure.net
```

This created:

```text
kv-azure-aks-project -> 10.20.2.7
```

### Failure 3 — Certificate access still denied

Error:

```text
ApplicationGatewayKeyVaultSecretAccessDenied
```

RBAC was already correct:

```text
id-appgw-keyvault
  -> Key Vault Secrets User
  -> kv-azure-aks-project
```

The final working change was:

```text
Key Vault
  publicNetworkAccess = Disabled
  defaultAction       = Deny
  bypass              = AzureServices
```

After that, AGIC reconciliation produced:

```text
Application Gateway provisioningState = Succeeded
```

---

## 12. Security rules for future changes

1. **Never enable general public access to Key Vault just to make Application Gateway work.**
2. Keep `publicNetworkAccess=Disabled` for this private architecture.
3. Keep the Key Vault firewall default action as `Deny`.
4. Use the dedicated `id-appgw-keyvault` identity for Application Gateway certificate retrieval.
5. Keep `Key Vault Secrets User` scoped to the target Key Vault.
6. Keep `Managed Identity Operator` for AGIC scoped to the Application Gateway identity resource.
7. Do not commit PFX files, private keys, certificate passwords, or local CA private keys.
8. Do not manually create competing Application Gateway listeners/routing rules when AGIC owns the Ingress configuration.
9. Use versionless Key Vault secret IDs for Application Gateway certificate references.
10. For production, replace `.local` hostnames/self-signed or private-CA certificates with a real DNS name and an appropriate publicly trusted certificate.

---

## Microsoft references

- TLS termination with Key Vault certificates: https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs
- Application Gateway Key Vault common errors: https://learn.microsoft.com/en-us/azure/application-gateway/application-gateway-key-vault-common-errors
- Troubleshoot Application Gateway failed state: https://learn.microsoft.com/en-us/troubleshoot/azure/application-gateway/troubleshoot-appgw-failed-state-issues
- Key Vault network security: https://learn.microsoft.com/en-us/azure/key-vault/general/network-security
