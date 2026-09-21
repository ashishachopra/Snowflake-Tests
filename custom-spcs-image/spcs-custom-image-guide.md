# Fork and Customize an SPCS Base Image
End-to-end workflow for pulling a Snowpark Container Services base image, customizing it, pushing it back to the Snowflake registry, and deploying it as a service.

## Prerequisites
- Docker installed locally
- Snowflake CLI (`snow`) installed, or Docker login credentials
- A role with `CREATE IMAGE REPOSITORY` on the target schema and `WRITE` on the repository

---

## Step 1: Create an Image Repository (if you don't have one)
```sql
USE ROLE my_role;
USE DATABASE my_db;
USE SCHEMA my_schema;

CREATE IMAGE REPOSITORY IF NOT EXISTS my_repo;
```

Verify and get the repository URL:

```sql
SHOW IMAGE REPOSITORIES;
-- Look at the "repository_url" column in the output
```

The URL will look like:

```
<orgname>-<acctname>.registry.snowflakecomputing.com/my_db/my_schema/my_repo
```

---

## Step 2: Authenticate Docker to the Snowflake Registry
**Option A — Snowflake CLI (recommended):**
```bash
snow spcs image-registry login
```

**Option B — PAT (programmatic access token):**
```bash
docker login <orgname>-<acctname>.registry.snowflakecomputing.com \
  -u USER \
  --password-stdin <<< "<your-PAT-token>"
```

> **Note:** Replace underscores in the account name with dashes in the hostname
> (e.g. `my_account` becomes `my-account`).

---

## Step 3: List Existing Images and Pull the Base Image
List what's already in the repo:
```sql
SHOW IMAGES IN IMAGE REPOSITORY my_db.my_schema.my_repo;
```

Pull the base image locally:
```bash
docker pull <orgname>-<acctname>.registry.snowflakecomputing.com/my_db/my_schema/my_repo/base_image:latest
```

---
## Step 4: Write a Dockerfile to Customize the Image
Create a `Dockerfile` that uses the pulled Snowflake image as its base:

```dockerfile
FROM <orgname>-<acctname>.registry.snowflakecomputing.com/my_db/my_schema/my_repo/base_image:latest

# Install additional packages
RUN apt-get update && apt-get install -y \
    curl \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir pandas flask

# Copy your custom application code
COPY ./my_app /opt/my_app

# Set working directory
WORKDIR /opt/my_app

# Expose a port
EXPOSE 8080

# Override entrypoint if needed
CMD ["python", "app.py"]
```

---
## Step 5: Build the Forked Image
Build for `linux/amd64` (the platform SPCS requires):

```bash
docker build --rm --platform linux/amd64 \
  -t <orgname>-<acctname>.registry.snowflakecomputing.com/my_db/my_schema/my_repo/my_custom_image:v1 \
  .
```

---
## Step 6: Push the Forked Image Back to the Snowflake Registry
```bash
docker push <orgname>-<acctname>.registry.snowflakecomputing.com/my_db/my_schema/my_repo/my_custom_image:v1
```

Verify it arrived:
```sql
SHOW IMAGES IN IMAGE REPOSITORY my_db.my_schema.my_repo;
```

---
## Step 7: Deploy as an SPCS Service
First ensure you have a compute pool:
```sql
-- Check existing pools
SHOW COMPUTE POOLS;

-- Or create one
CREATE COMPUTE POOL my_pool
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_XS;

-- Wait until state is ACTIVE or IDLE
DESCRIBE COMPUTE POOL my_pool;
```

Create the service using your custom image:
```sql
CREATE SERVICE my_custom_service
  IN COMPUTE POOL my_pool
  FROM SPECIFICATION $$
  spec:
    containers:
    - name: main
      image: /my_db/my_schema/my_repo/my_custom_image:v1
      env:
        PORT: "8080"
      readinessProbe:
        port: 8080
        path: /healthcheck
    endpoints:
    - name: app
      port: 8080
      public: true
  $$
  MIN_INSTANCES=1
  MAX_INSTANCES=1;
```

Check that it's running:
```sql
DESCRIBE SERVICE my_custom_service;
SHOW SERVICE CONTAINERS IN SERVICE my_custom_service;
```

---

## Service Specification YAML Templates
### Minimal spec
The simplest spec with one container, one endpoint, and a readiness probe:

```yaml
spec:
  containers:
  - name: main
    image: /my_db/my_schema/my_repo/my_custom_image:v1
    readinessProbe:
      port: 8080
      path: /healthcheck
  endpoints:
  - name: app
    port: 8080
    public: true
```

### Full-featured spec with environment variables, probes, resources, and volumes
```yaml
spec:
  containers:
  - name: main
    image: /my_db/my_schema/my_repo/my_custom_image:v1

    # ── Environment variables ──
    # Static key-value pairs injected into the container at startup.
    env:
      SERVER_PORT: "8080"
      LOG_LEVEL: "INFO"
      APP_ENV: "production"
      MAX_WORKERS: "4"
      SNOWFLAKE_WAREHOUSE: my_warehouse

    # ── Readiness probe ──
    # Snowflake checks this endpoint to decide when the container is
    # ready to receive traffic. The service stays in PENDING until
    # the probe succeeds.
    readinessProbe:
      port: 8080
      path: /healthcheck
      initialDelaySeconds: 10   # wait before first check
      periodSeconds: 30         # interval between checks
      timeoutSeconds: 5         # timeout per check
      failureThreshold: 3       # failures before marking unready

    # ── Resource requests ──
    # Guarantees a minimum amount of memory on the compute pool node.
    # Prevents resource starvation when multiple services share a pool.
    resources:
      requests:
        memory: 2G
      limits:
        memory: 4G

    # ── Volume mounts ──
    volumeMounts:
    - name: stage-data
      mountPath: /opt/data
    - name: local-scratch
      mountPath: /tmp/scratch

  # ── Endpoints ──
  endpoints:
  - name: app
    port: 8080
    public: true          # accessible from the internet via ingress URL
  - name: internal-api
    port: 9090
    public: false         # only reachable by other SPCS services

  # ── Volumes ──
  volumes:
  - name: stage-data
    source: "@my_db.my_schema.my_stage"   # mount a Snowflake stage
  - name: local-scratch
    source: local                          # ephemeral node-local storage
    size: 10Gi
```

### Spec with secrets from Snowflake
Use Snowflake secrets to inject sensitive values (API keys, tokens) without hardcoding them:

```yaml
spec:
  containers:
  - name: main
    image: /my_db/my_schema/my_repo/my_custom_image:v1
    env:
      SERVER_PORT: "8080"
    secrets:
    - snowflakeSecret: my_db.my_schema.my_api_secret   # a SECRET object
      secretKeyRef: username                             # key within the secret
      envVarName: API_USER                               # exposed as $API_USER
    - snowflakeSecret: my_db.my_schema.my_api_secret
      secretKeyRef: password
      envVarName: API_KEY
    readinessProbe:
      port: 8080
      path: /healthcheck
  endpoints:
  - name: app
    port: 8080
    public: true
```

Create the secret in Snowflake first:
```sql
CREATE SECRET my_db.my_schema.my_api_secret
  TYPE = password
  USERNAME = 'my_api_user'
  PASSWORD = 'my_api_key_value';
```

### Spec with specification templates (parameterized)
Use `{{ variable }}` placeholders to create reusable specs across environments:

```yaml
spec:
  containers:
  - name: main
    image: /my_db/my_schema/my_repo/my_custom_image:{{ image_tag }}
    env:
      APP_ENV: "{{ environment }}"
      LOG_LEVEL: "{{ log_level }}"
    readinessProbe:
      port: 8080
      path: /healthcheck
  endpoints:
  - name: app
    port: 8080
    public: true
```

Deploy with different values per environment:

```sql
-- Production
CREATE SERVICE my_service_prod
  IN COMPUTE POOL prod_pool
  FROM SPECIFICATION $$ ... $$
  USING (image_tag => 'v2.1', environment => 'production', log_level => 'WARN');

-- Development
CREATE SERVICE my_service_dev
  IN COMPUTE POOL dev_pool
  FROM SPECIFICATION $$ ... $$
  USING (image_tag => 'latest', environment => 'development', log_level => 'DEBUG');
```

### Readiness probe reference
| Field | Description | Default |
|-------|-------------|---------|
| `port` | Port to probe (required) | — |
| `path` | HTTP GET path (required) | — |
| `initialDelaySeconds` | Seconds to wait before first probe | 0 |
| `periodSeconds` | Seconds between probes | 10 |
| `timeoutSeconds` | Seconds before probe times out | 1 |
| `failureThreshold` | Consecutive failures to mark unready | 3 |

The probe sends an HTTP GET to `http://localhost:<port><path>`. Any `2xx` or `3xx` response is treated as success. If the probe never passes, the service stays in `PENDING` state — check `SHOW SERVICE CONTAINERS` and service logs for diagnostics.

---

## Quick Reference
| Step | Where | Command |
|------|-------|---------|
| Create repo | Snowflake | `CREATE IMAGE REPOSITORY` |
| Auth Docker | Local | `snow spcs image-registry login` |
| Pull base image | Local | `docker pull <repo_url>/base_image:tag` |
| Customize | Local | Write `Dockerfile` with `FROM` base image |
| Build | Local | `docker build --platform linux/amd64 -t <repo_url>/custom:v1 .` |
| Push | Local | `docker push <repo_url>/custom:v1` |
| Deploy | Snowflake | `CREATE SERVICE ... image: /db/schema/repo/custom:v1` |

## Troubleshooting
### `no Host in request URL` on docker push/pull
Your account name contains an underscore. Docker CLI does not accept underscores in hostnames.

```
# Wrong
docker push myorg-my_acct.registry.snowflakecomputing.com/...

# Correct — replace underscore with dash
docker push myorg-my-acct.registry.snowflakecomputing.com/...
```

Use `SHOW IMAGE REPOSITORIES` to get a valid repository URL.

### `authentication required` or `unauthorized` on push/pull

Your Docker session has expired or was never authenticated.
```bash
# Re-authenticate
snow spcs image-registry login

# Verify login succeeded
docker pull <repo_url>/base_image:latest
```

If using a PAT, confirm the token has not expired and that you pass `USER` (literal) as the username.

### `denied: requested access to the resource is denied`

Your current Snowflake role lacks the required privilege on the repository.
- **Pull** requires `READ` (or `OWNERSHIP`/`WRITE`) on the image repository.
- **Push** requires `WRITE` (or `OWNERSHIP`) on the image repository.

```sql
-- Grant push/pull access
GRANT WRITE ON IMAGE REPOSITORY my_db.my_schema.my_repo TO ROLE my_role;
```

### `docker login` fails with credential store error

Docker may use case-sensitive credential keys. Do not mix uppercase and lowercase in the hostname between `docker login` and `docker push`/`pull`.

```bash
# Use the exact same (lowercase) hostname for login and push
docker login myorg-myacct.registry.snowflakecomputing.com
docker push  myorg-myacct.registry.snowflakecomputing.com/my_db/my_schema/my_repo/image:v1
```

### `manifest unknown` or `not found` on pull

The image name or tag does not exist in the repository.

```sql
-- List all images and tags to confirm the correct name
SHOW IMAGES IN IMAGE REPOSITORY my_db.my_schema.my_repo;
```

### Push hangs or times out on large images

The max compressed layer size is 160 GiB (AWS) / 195 GiB (Azure). If your image has very large layers:

- Use multi-stage Docker builds to reduce final image size.
- Avoid copying large data files into the image — mount them from a Snowflake stage at runtime instead.
- Check network/proxy settings if behind a corporate firewall.

### `invalid consent request` when accessing a public service endpoint

This happens when the user's **default role** is a privileged role like `ACCOUNTADMIN` or `SECURITYADMIN`.

```sql
-- Change the user's default role to a non-privileged role
ALTER USER my_user SET DEFAULT_ROLE = my_role;
```

### Service stuck in `PENDING` after push

The image pushed successfully but the service won't start.

```sql
-- Check container-level status for error details
SHOW SERVICE CONTAINERS IN SERVICE my_custom_service;

-- Check service logs
SELECT SYSTEM$GET_SERVICE_LOGS('my_custom_service', 0, 'main');
```

Common causes:
- Image was built for the wrong platform (must be `linux/amd64`).
- The container crashes on startup — check logs for application errors.
- Compute pool is not in `ACTIVE`/`IDLE` state — run `DESCRIBE COMPUTE POOL my_pool`.
- Resource starvation on the compute pool node — specify memory requests in the spec or use a larger instance family.

### `SNOWFLAKE_FULL` encryption throttling

If you see intermittent push failures or slowdowns, Snowflake may throttle requests under `SNOWFLAKE_FULL` encryption when detecting unusually large parallel requests. Retry with backoff, or create the repository with `SNOWFLAKE_SSE` encryption if Tri-Secret Secure is not required:

```sql
CREATE IMAGE REPOSITORY my_repo ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
```

---

## CI/CD Pipeline Automation

### Required secrets / variables

Store these in your CI/CD platform's secret management (GitHub Secrets, GitLab CI Variables, etc.):

| Variable | Description | Example |
|----------|-------------|---------|
| `SNOWFLAKE_ACCOUNT` | Org and account (dashes, no underscores) | `myorg-myacct` |
| `SNOWFLAKE_USER` | Service account username | `CI_DEPLOYER` |
| `SNOWFLAKE_PAT` | Programmatic access token | *(generated via Snowsight)* |
| `SNOWFLAKE_ROLE` | Role with WRITE on the image repo | `CI_DEPLOY_ROLE` |
| `SNOWFLAKE_WAREHOUSE` | Warehouse for SQL commands | `CI_WH` |
| `IMAGE_REPO_URL` | Full repository URL | `myorg-myacct.registry.snowflakecomputing.com/my_db/my_schema/my_repo` |

---

### GitHub Actions

```yaml
# .github/workflows/spcs-deploy.yml
name: Build and Deploy SPCS Image

on:
  push:
    branches: [main]
    paths:
      - 'docker/**'
      - '.github/workflows/spcs-deploy.yml'

env:
  REGISTRY: ${{ secrets.SNOWFLAKE_ACCOUNT }}.registry.snowflakecomputing.com
  IMAGE_REPO: ${{ secrets.IMAGE_REPO_URL }}
  IMAGE_NAME: my_custom_image

jobs:
  build-push-deploy:
    runs-on: ubuntu-latest
    steps:

    - name: Checkout code
      uses: actions/checkout@v4

    - name: Set image tag
      id: tag
      run: |
        SHORT_SHA=$(echo "${{ github.sha }}" | cut -c1-7)
        echo "TAG=${SHORT_SHA}" >> "$GITHUB_OUTPUT"
        echo "TAG_LATEST=latest" >> "$GITHUB_OUTPUT"

    - name: Login to Snowflake image registry
      run: |
        echo "${{ secrets.SNOWFLAKE_PAT }}" | \
          docker login "$REGISTRY" -u USER --password-stdin

    - name: Build image (linux/amd64)
      run: |
        docker build --rm --platform linux/amd64 \
          -t "$IMAGE_REPO/$IMAGE_NAME:${{ steps.tag.outputs.TAG }}" \
          -t "$IMAGE_REPO/$IMAGE_NAME:${{ steps.tag.outputs.TAG_LATEST }}" \
          -f docker/Dockerfile \
          docker/

    - name: Push image to Snowflake registry
      run: |
        docker push "$IMAGE_REPO/$IMAGE_NAME:${{ steps.tag.outputs.TAG }}"
        docker push "$IMAGE_REPO/$IMAGE_NAME:${{ steps.tag.outputs.TAG_LATEST }}"

    - name: Install Snowflake CLI
      uses: Snowflake-Labs/snowflake-cli-action@v1
      with:
        cli-version: latest
        default-config-file-path: .snowflake/config.toml

    - name: Deploy / update service
      env:
        SNOWFLAKE_CONNECTIONS_DEFAULT_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
        SNOWFLAKE_CONNECTIONS_DEFAULT_USER: ${{ secrets.SNOWFLAKE_USER }}
        SNOWFLAKE_CONNECTIONS_DEFAULT_AUTHENTICATOR: PROGRAMMATIC_ACCESS_TOKEN
        SNOWFLAKE_CONNECTIONS_DEFAULT_TOKEN: ${{ secrets.SNOWFLAKE_PAT }}
        SNOWFLAKE_CONNECTIONS_DEFAULT_ROLE: ${{ secrets.SNOWFLAKE_ROLE }}
        SNOWFLAKE_CONNECTIONS_DEFAULT_WAREHOUSE: ${{ secrets.SNOWFLAKE_WAREHOUSE }}
      run: |
        snow sql -q "
          ALTER SERVICE IF EXISTS my_db.my_schema.my_custom_service
            FROM SPECIFICATION \$\$
            spec:
              containers:
              - name: main
                image: /my_db/my_schema/my_repo/$IMAGE_NAME:${{ steps.tag.outputs.TAG }}
                readinessProbe:
                  port: 8080
                  path: /healthcheck
              endpoints:
              - name: app
                port: 8080
                public: true
            \$\$;
        "
```

---

### GitLab CI

```yaml
# .gitlab-ci.yml
stages:
  - build
  - deploy

variables:
  REGISTRY: ${SNOWFLAKE_ACCOUNT}.registry.snowflakecomputing.com
  IMAGE_REPO: ${IMAGE_REPO_URL}
  IMAGE_NAME: my_custom_image

build-and-push:
  stage: build
  image: docker:24-dind
  services:
    - docker:24-dind
  variables:
    DOCKER_TLS_CERTDIR: ""
  before_script:
    - echo "${SNOWFLAKE_PAT}" | docker login "${REGISTRY}" -u USER --password-stdin
  script:
    - TAG="${CI_COMMIT_SHORT_SHA}"
    - >
      docker build --rm --platform linux/amd64
      -t "${IMAGE_REPO}/${IMAGE_NAME}:${TAG}"
      -t "${IMAGE_REPO}/${IMAGE_NAME}:latest"
      -f docker/Dockerfile docker/
    - docker push "${IMAGE_REPO}/${IMAGE_NAME}:${TAG}"
    - docker push "${IMAGE_REPO}/${IMAGE_NAME}:latest"
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      changes:
        - docker/**/*

deploy-service:
  stage: deploy
  image: python:3.11-slim
  before_script:
    - pip install snowflake-cli-labs
  script:
    - TAG="${CI_COMMIT_SHORT_SHA}"
    - >
      snow sql -q "
        ALTER SERVICE IF EXISTS my_db.my_schema.my_custom_service
          FROM SPECIFICATION \$\$
          spec:
            containers:
            - name: main
              image: /my_db/my_schema/my_repo/${IMAGE_NAME}:${TAG}
              readinessProbe:
                port: 8080
                path: /healthcheck
            endpoints:
            - name: app
              port: 8080
              public: true
          \$\$;
      "
  environment:
    name: production
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  needs: [build-and-push]
```

---

### Generic shell script (any CI system)

A standalone script you can call from Jenkins, Azure DevOps, CircleCI, or locally:

```bash
#!/usr/bin/env bash
# deploy-spcs.sh — Build, push, and deploy an SPCS image
set -euo pipefail

# ── Configuration (override via env vars or CI secrets) ──
REGISTRY="${SNOWFLAKE_ACCOUNT}.registry.snowflakecomputing.com"
IMAGE_REPO="${IMAGE_REPO_URL}"
IMAGE_NAME="${IMAGE_NAME:-my_custom_image}"
TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
DOCKERFILE="${DOCKERFILE_PATH:-docker/Dockerfile}"
BUILD_CONTEXT="${BUILD_CONTEXT:-docker/}"

FULL_IMAGE="${IMAGE_REPO}/${IMAGE_NAME}"

echo "==> Authenticating to Snowflake registry..."
echo "${SNOWFLAKE_PAT}" | docker login "${REGISTRY}" -u USER --password-stdin

echo "==> Building image ${FULL_IMAGE}:${TAG} (linux/amd64)..."
docker build --rm --platform linux/amd64 \
  -t "${FULL_IMAGE}:${TAG}" \
  -t "${FULL_IMAGE}:latest" \
  -f "${DOCKERFILE}" \
  "${BUILD_CONTEXT}"

echo "==> Pushing image to Snowflake registry..."
docker push "${FULL_IMAGE}:${TAG}"
docker push "${FULL_IMAGE}:latest"

echo "==> Verifying image in repository..."
snow sql -q "SHOW IMAGES IN IMAGE REPOSITORY my_db.my_schema.my_repo;" \
  | grep "${IMAGE_NAME}" || echo "WARNING: image not found in listing"

echo "==> Updating service..."
snow sql -q "
  ALTER SERVICE IF EXISTS my_db.my_schema.my_custom_service
    FROM SPECIFICATION \$\$
    spec:
      containers:
      - name: main
        image: /my_db/my_schema/my_repo/${IMAGE_NAME}:${TAG}
        readinessProbe:
          port: 8080
          path: /healthcheck
      endpoints:
      - name: app
        port: 8080
        public: true
    \$\$;
"

echo "==> Checking service status..."
snow sql -q "DESCRIBE SERVICE my_db.my_schema.my_custom_service;"

echo "==> Done. Deployed ${FULL_IMAGE}:${TAG}"
```

Make it executable: `chmod +x deploy-spcs.sh`

---

### CI/CD best practices
- **Tag images with the commit SHA** (e.g. `my_image:a1b2c3d`) for traceability. Also push a `latest` tag for convenience.
- **Use a dedicated service account** with a PAT and a role scoped to only `WRITE` on the image repo and `OPERATE` on the service. Never use `ACCOUNTADMIN` in CI.
- **Pin the base image tag** in your Dockerfile (`FROM ...base_image:v2.1`, not `:latest`) so builds are reproducible.
- **Cache Docker layers** — use `--cache-from` or CI-native caching to speed up builds.
- **Gate production deploys** behind a manual approval step or a separate pipeline triggered by tags/releases.
- **Validate before deploy** — run `docker run --rm <image> <healthcheck-command>` in CI to catch startup errors before pushing.
- **Use `ALTER SERVICE`** (not `DROP` + `CREATE`) to update a running service with a new image. This preserves the service name, endpoints, and grants.

---

## Rollback to a Previous Image Version

### 1. Identify available image versions

List all images and tags in your repository:

```sql
SHOW IMAGES IN IMAGE REPOSITORY my_db.my_schema.my_repo;
```

This returns image names, tags, and digests. Note the tag you want to roll back to (e.g. `v1.0`, `a1b2c3d`).

### 2. Check the currently deployed image

```sql
-- View the current service specification (includes the image tag)
DESCRIBE SERVICE my_db.my_schema.my_custom_service;

-- View container-level detail
SHOW SERVICE CONTAINERS IN SERVICE my_db.my_schema.my_custom_service;
```

### 3. Roll back with ALTER SERVICE

Use `ALTER SERVICE` to swap the image tag back to a known-good version. This preserves the service name, grants, and endpoints:

```sql
ALTER SERVICE my_db.my_schema.my_custom_service
  FROM SPECIFICATION $$
  spec:
    containers:
    - name: main
      image: /my_db/my_schema/my_repo/my_custom_image:v1.0
      readinessProbe:
        port: 8080
        path: /healthcheck
    endpoints:
    - name: app
      port: 8080
      public: true
  $$;
```

### 4. Verify the rollback

```sql
-- Confirm the service is running with the old image
DESCRIBE SERVICE my_db.my_schema.my_custom_service;

-- Check container status is READY
SHOW SERVICE CONTAINERS IN SERVICE my_db.my_schema.my_custom_service;

-- Check logs for startup errors
SELECT SYSTEM$GET_SERVICE_LOGS('my_db.my_schema.my_custom_service', 0, 'main');
```

### 5. Rollback via CI/CD

If you use the CI/CD pipelines from the previous section, you can roll back by re-running a previous pipeline or by passing the old tag explicitly.

**GitHub Actions — manual dispatch with a rollback tag:**

```yaml
on:
  workflow_dispatch:
    inputs:
      rollback_tag:
        description: 'Image tag to roll back to (e.g. a1b2c3d)'
        required: true
```

Then reference `${{ github.event.inputs.rollback_tag }}` in the deploy step instead of the commit SHA.

**Shell script:**

```bash
# Roll back to a specific tag
IMAGE_TAG=v1.0 ./deploy-spcs.sh
```

### 6. Rollback via image digest (immutable)

Tags can be overwritten (e.g. someone pushes a new image as `:v1.0`). For a guaranteed rollback, use the image digest from `SHOW IMAGES`:

```sql
ALTER SERVICE my_db.my_schema.my_custom_service
  FROM SPECIFICATION $$
  spec:
    containers:
    - name: main
      image: /my_db/my_schema/my_repo/my_custom_image@sha256:abc123def456...
      readinessProbe:
        port: 8080
        path: /healthcheck
    endpoints:
    - name: app
      port: 8080
      public: true
  $$;
```

### Rollback checklist

| Step | Command | What to check |
|------|---------|---------------|
| Find old tag | `SHOW IMAGES IN IMAGE REPOSITORY ...` | Confirm the tag/digest exists |
| Check current | `DESCRIBE SERVICE ...` | Note the current image for forward reference |
| Swap image | `ALTER SERVICE ... FROM SPECIFICATION ...` | Use the old tag or digest |
| Verify status | `SHOW SERVICE CONTAINERS IN SERVICE ...` | Status should be `READY` |
| Check logs | `SYSTEM$GET_SERVICE_LOGS(...)` | No startup errors |
| Smoke test | Hit the public endpoint or service function | Application responds correctly |

### Tips

- **Always tag images with the commit SHA** so you have a clear history to roll back to. Relying only on `:latest` makes rollback impossible.
- **Never delete your image repository** to clean up old images — this removes all versions including your rollback targets. Individual image deletion is not currently supported.
- **Keep at least 3-5 previous tags** in the repository as rollback candidates.
- **Document the known-good tag** in a deployment log or as a Snowflake tag on the service object:

```sql
ALTER SERVICE my_db.my_schema.my_custom_service
  SET TAG last_known_good_image = 'v1.0';
```

---

## Secrets Management

Snowflake provides two ways to inject secrets into SPCS containers: as **environment variables** or as **files mounted to a directory**. Both use Snowflake `SECRET` objects, so credentials never appear in your service specification or image.

### Supported secret types

| Secret type | SQL keyword | Typical use |
|-------------|-------------|-------------|
| Username + password | `TYPE = password` | Database credentials, basic auth APIs |
| Generic string | `TYPE = generic_string` | API keys, tokens, license keys |
| OAuth2 | `TYPE = oauth2` | OAuth client credentials |

### Step 1: Create Snowflake SECRET objects

```sql
-- Username/password secret (e.g. for an external database)
CREATE SECRET my_db.my_schema.external_db_creds
  TYPE = password
  USERNAME = 'db_admin'
  PASSWORD = 'S3cureP@ss!';

-- Generic string secret (e.g. for an API key)
CREATE SECRET my_db.my_schema.api_key
  TYPE = generic_string
  SECRET_STRING = 'sk-abc123def456ghi789';

-- OAuth2 secret
CREATE SECRET my_db.my_schema.oauth_creds
  TYPE = oauth2
  OAUTH_REFRESH_TOKEN = 'your-refresh-token'
  OAUTH_REFRESH_TOKEN_EXPIRY_TIME = '2027-01-01 00:00:00'
  API_AUTHENTICATION = my_security_integration;
```

Grant the service owner role access to the secrets:

```sql
GRANT READ ON SECRET my_db.my_schema.external_db_creds TO ROLE my_service_role;
GRANT READ ON SECRET my_db.my_schema.api_key TO ROLE my_service_role;
GRANT READ ON SECRET my_db.my_schema.oauth_creds TO ROLE my_service_role;
```

### Step 2: Inject secrets as environment variables

Use `envVarName` and `secretKeyRef` to expose individual fields as env vars inside the container. The `secretKeyRef` value depends on the secret type:

- `password` type: `username` or `password`
- `generic_string` type: `secret_string`

```yaml
spec:
  containers:
  - name: main
    image: /my_db/my_schema/my_repo/my_custom_image:v1
    env:
      APP_PORT: "8080"
    secrets:
    # External database credentials
    - snowflakeSecret:
        objectName: my_db.my_schema.external_db_creds
      secretKeyRef: username
      envVarName: DB_USERNAME              # container reads $DB_USERNAME
    - snowflakeSecret:
        objectName: my_db.my_schema.external_db_creds
      secretKeyRef: password
      envVarName: DB_PASSWORD              # container reads $DB_PASSWORD

    # API key (generic string)
    - snowflakeSecret:
        objectName: my_db.my_schema.api_key
      secretKeyRef: secret_string
      envVarName: API_KEY                  # container reads $API_KEY

    readinessProbe:
      port: 8080
      path: /healthcheck
  endpoints:
  - name: app
    port: 8080
    public: true
```

Your application code reads these like any other env var:

```python
import os

db_user = os.environ['DB_USERNAME']
db_pass = os.environ['DB_PASSWORD']
api_key = os.environ['API_KEY']
```

### Step 3 (alternative): Mount secrets as files

Use `directoryPath` instead of `envVarName` to mount all secret fields as files in a directory. This is useful for secrets that are too large for env vars or for applications that expect credential files.

```yaml
spec:
  containers:
  - name: main
    image: /my_db/my_schema/my_repo/my_custom_image:v1
    secrets:
    # Mounts files at /etc/secrets/db_creds/username and /etc/secrets/db_creds/password
    - snowflakeSecret:
        objectName: my_db.my_schema.external_db_creds
      directoryPath: /etc/secrets/db_creds

    # Mounts file at /etc/secrets/api/secret_string
    - snowflakeSecret:
        objectName: my_db.my_schema.api_key
      directoryPath: /etc/secrets/api

    readinessProbe:
      port: 8080
      path: /healthcheck
  endpoints:
  - name: app
    port: 8080
    public: true
```

Your application reads the files:

```python
with open('/etc/secrets/db_creds/username') as f:
    db_user = f.read().strip()

with open('/etc/secrets/db_creds/password') as f:
    db_pass = f.read().strip()

with open('/etc/secrets/api/secret_string') as f:
    api_key = f.read().strip()
```

### Using object references (for Native Apps)
If your service runs inside a Native App, use `objectReference` instead of `objectName`. The reference maps to a consumer-provided secret defined in the app's `manifest.yml`:

```yaml
spec:
  containers:
  - name: main
    image: /my_db/my_schema/my_repo/my_custom_image:v1
    secrets:
    - snowflakeSecret:
        objectReference: consumer_api_secret    # reference name from manifest.yml
      secretKeyRef: secret_string
      envVarName: API_KEY
    readinessProbe:
      port: 8080
      path: /healthcheck
  endpoints:
  - name: app
    port: 8080
    public: true
```

### Snowflake-provided session token
Every SPCS container automatically receives a Snowflake OAuth token for executing SQL — no secret object needed:

| Item | Location |
|------|----------|
| OAuth token | `/snowflake/session/token` (auto-refreshed every few minutes, valid up to 1 hour) |
| Account locator | `$SNOWFLAKE_ACCOUNT` env var |
| Hostname | `$SNOWFLAKE_HOST` env var |

```python
import os
import snowflake.connector

def get_login_token():
    with open('/snowflake/session/token', 'r') as f:
        return f.read()

conn = snowflake.connector.connect(
    host=os.environ['SNOWFLAKE_HOST'],
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    token=get_login_token(),
    authenticator='oauth'
)
```

You can customize the token path and permissions with `sessionTokenConfig`:

```yaml
spec:
  containers:
  - name: main
    image: /my_db/my_schema/my_repo/my_custom_image:v1
    sessionTokenConfig:
      path: /opt/app/credentials          # token at /opt/app/credentials/token
      permission: "0600"                   # restrict to container user only
      mountConnectionConfig: true          # also generate connections.toml
    readinessProbe:
      port: 8080
      path: /healthcheck
  endpoints:
  - name: app
    port: 8080
    public: true

---

## Key Constraints

- Always build for `linux/amd64`
- Replace underscores with dashes in the registry hostname
- Use the fully qualified image path (`/db/schema/repo/image:tag`) in the service specification
- Max compressed layer size: 160 GiB (AWS) / 195 GiB (Azure)
- Dropping individual images from a repository is not supported — you can only drop the entire repository
