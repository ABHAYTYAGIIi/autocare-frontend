# Docker Deep Dive — AutoCare Frontend

## Purpose

This document analyzes the frontend from a **Linux-server deployment perspective**.

The goal is to understand, without guessing:

- exactly what Docker would build;
- which source files participate in the build/runtime artifact;
- what environment variables are used;
- which paths matter;
- what Linux/Docker changes occur at build and runtime;
- and which details still depend on the actual Dockerfile.

## Important repository state

The GitHub `main` branch currently contains the React/Vite application but **does not contain a `Dockerfile`**.

Therefore this document does not invent a Dockerfile. A line-by-line Dockerfile analysis will be added after the actual Dockerfile is committed.

---

## 1. Application/build system

`package.json` defines:

```text
npm run dev     -> vite
npm run build   -> vite build
npm run preview -> vite preview
```

The project uses:

- React;
- React DOM;
- Vite;
- `@vitejs/plugin-react`.

There is no server-side Node application shown in the package scripts. The normal production artifact is produced by `vite build`.

---

## 2. Application entry chain

The browser entry point is:

```text
index.html
   |
   +--> /src/main.jsx
          |
          +--> ./App
          |
          +--> ./styles.css
```

`src/main.jsx` creates the React root from the HTML element whose ID is `root` and renders `<App />` inside `StrictMode`.

`src/App.jsx` imports the main pages and `AppShell`, then selects the page based on the current route.

The currently referenced pages include:

- Dashboard
- Customers
- Vehicles
- Service Centers
- Bookings
- Maintenance

---

## 3. Vite build process

The verified build command is:

```bash
npm run build
```

which invokes:

```bash
vite build
```

At a high level:

```text
React source + Vite configuration
              |
              v
        Vite build process
              |
              v
     browser production assets
```

The exact final output directory and exact Docker copy instructions cannot be stated as Docker facts until the Dockerfile exists.

Vite configuration does establish the application base path.

---

## 4. `vite.config.js` and environment usage

The configuration loads environment values using Vite's `loadEnv` and reads:

```text
VITE_APP_BASE_PATH
```

If it is not supplied, the configuration defaults to:

```text
/autocare/
```

The final Vite `base` value is normalized to end in `/`.

The Vite development server is configured for port `5173`.

---

## 5. Environment variables

`.env.example` currently defines:

```text
VITE_APP_BASE_PATH=/autocare/
VITE_API_BASE_URL=/autocare/api
```

These are **Vite client-visible variables** because they begin with `VITE_`.

Important security rule:

> Values exposed through Vite `VITE_*` variables must be treated as public application configuration, not secrets.

Do not place database passwords, private keys, access tokens, or other credentials in them.

The frontend's API base is currently represented as:

```text
/autocare/api
```

which is a relative browser URL/path rather than a database credential or server-side secret.

---

## 6. Paths

Verified repository paths include:

```text
index.html
src/main.jsx
src/App.jsx
src/styles.css
vite.config.js
package.json
package-lock.json
.env.example
```

The source entry is referenced by `index.html` as:

```text
/src/main.jsx
```

The **container filesystem paths are intentionally not guessed** because the Dockerfile is missing from GitHub.

For example, we cannot truthfully state that the production assets are `/app/dist` until the Dockerfile/build configuration confirms the container working directory and copy steps.

---

## 7. Dockerfile status and required analysis

When the real Dockerfile is committed, document every instruction in order:

| Docker question | What we will trace |
|---|---|
| `FROM` | Linux base image and Node/runtime version |
| `WORKDIR` | Container source/build directory |
| `ARG` | Build-time inputs |
| `ENV` | Image/runtime environment values |
| `COPY` | Exact source files entering each stage |
| `RUN` | npm installation/build commands and their filesystem effects |
| multi-stage stages | Which artifacts survive into the final image |
| `USER` | Whether the web server runs as root/non-root |
| `EXPOSE` | Documented container port |
| `CMD`/`ENTRYPOINT` | Exact process started by the container |

This is especially important for frontend containers because a Dockerfile may either:

1. run a Node-based Vite preview server; or
2. compile static assets and serve them from a separate web server image.

Those two architectures have very different runtime behavior, so the actual Dockerfile must decide which one applies.

---

## 8. Linux OS-level model

For a Linux server, the conceptual path is:

```text
Linux host kernel
      |
      +-- Docker Engine
             |
             +-- frontend container
                    |
                    +-- web-serving process
                           |
                           +-- static React/Vite assets
```

The container is not a VM and does not have its own kernel.

Docker isolates the process and filesystem environment using Linux kernel mechanisms such as namespaces and cgroups, together with the container filesystem and security configuration.

Exactly which process runs in the final container depends on the missing Dockerfile.

---

## 9. Build-time vs runtime

For a static frontend, it is useful to distinguish:

### Build time

The build machine/container has the Node.js toolchain and source code.

It runs:

```text
npm install/ci
     |
     v
vite build
     |
     v
static production assets
```

### Runtime

A production container may contain only the generated assets and a web server, depending on the Dockerfile.

If that is the architecture used, the runtime does not need the full React source tree or Vite development toolchain.

We will verify this from the Dockerfile rather than assume it.

---

## 10. Networking relationship to AutoCare API

The frontend has:

```text
VITE_API_BASE_URL=/autocare/api
```

This indicates the browser is expected to reach the API through that path in the current example configuration.

Whether `/autocare/api` is handled by a reverse proxy, ingress, web server, or another component is not determined by this repository alone.

That routing layer should be documented separately from the frontend Dockerfile so that browser routing and container networking are not confused.

---

## 11. Credentials and secrets

No secret credential is shown in `.env.example`.

The two visible variables are application configuration values intended to be embedded/used by the frontend build.

Never put a secret into `VITE_*` variables because browser-delivered JavaScript can expose those values to users.

---

## 12. Deep-dive completion condition

This document is intentionally **partially complete** because the repository does not yet contain the actual Dockerfile.

Once it is pushed, the remaining work is mechanical and exact:

```text
Dockerfile line
      |
      +--> build-time filesystem effect
      +--> image-layer effect
      +--> Linux user/process effect
      +--> runtime environment effect
      +--> application file dependency
      +--> network/path consequence
```

That is the standard we will use for the three AutoCare Dockerfiles.
