FROM node:22-bookworm-slim AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . ./

# Vite replaces these public values while producing the static bundle.
ARG VITE_APP_BASE_PATH=/autocare/
ARG VITE_API_BASE_URL=/autocare/api
ENV VITE_APP_BASE_PATH=$VITE_APP_BASE_PATH
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
RUN npm run build

FROM nginxinc/nginx-unprivileged:alpine

ARG API_UPSTREAM=http://autocare-api:3000

USER root

COPY --from=build /app/dist /usr/share/nginx/html/autocare

# nginx-unprivileged listens as a non-root user on 8080. Preserve the Vite
# base path and return the SPA entry point for client-side routes.
RUN printf '%s\n' \
  'server {' \
  '    listen 8080;' \
  '    server_name _;' \
  '    root /usr/share/nginx/html;' \
  '    index index.html;' \
  '' \
  '    location = /autocare {' \
  '        return 301 /autocare/;' \
  '    }' \
  '' \
  '    location /autocare/api/ {' \
  "        proxy_pass ${API_UPSTREAM}/api/;" \
  '        proxy_set_header Host $host;' \
  '        proxy_set_header X-Real-IP $remote_addr;' \
  '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
  '        proxy_set_header X-Forwarded-Proto $scheme;' \
  '    }' \
  '' \
  '    location /autocare/ {' \
  '        try_files $uri $uri/ /autocare/index.html;' \
  '    }' \
  '}' > /etc/nginx/conf.d/default.conf

EXPOSE 8080
USER nginx
