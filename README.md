# Compose Workflow

Reusable GitHub Actions workflows for Docker Compose deployments across multiple repositories.

## Overview

This repository contains centralized, reusable workflows that can be called from other repositories to standardize the deployment process for Docker Compose-based applications.

## Available Workflows

### 1. Lint Workflow (`lint.yml`)

Performs comprehensive linting and validation of Docker Compose configurations.

**Features:**
- GitGuardian secret scanning
- YAML validation with yamllint
- Docker Compose syntax validation
- Discord notifications with detailed results

**Usage:**
```yaml
name: Lint Docker Compose
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

jobs:
  lint:
    uses: owine/compose-workflow/.github/workflows/lint.yml@main
    secrets: inherit
    with:
      stacks: '["stack1", "stack2", "stack3"]'
      webhook-url: "op://Docker/discord-github-notifications/webhook_url"
      repo-name: "my-docker-repo"
```

### 2. Deploy Workflow (`deploy.yml`)

Handles complete deployment pipeline including rollback capabilities.

**Features:**
- Secure Tailscale connection
- Parallel stack deployment
- Health checking
- Automatic rollback on failure
- Docker image cleanup
- Discord notifications

**Usage:**
```yaml
name: Deploy Docker Compose
on:
  workflow_dispatch:
    inputs:
      args:
        description: "docker compose up -d arguments"
        type: "string"
  workflow_run:
    workflows: [Lint Docker Compose]
    types: [completed]
    branches: [main]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

jobs:
  deploy:
    uses: owine/compose-workflow/.github/workflows/deploy.yml@main
    secrets: inherit
    with:
      args: ${{ inputs.args }}
      stacks: '["stack1", "stack2", "stack3"]'
      webhook-url: "op://Docker/discord-github-notifications/webhook_url"
      repo-name: "my-docker-repo"
      has-dockge: true
```

## Input Parameters

### Lint Workflow

| Parameter | Description | Required | Type |
|-----------|-------------|----------|------|
| `stacks` | JSON array of stack names to lint | ✅ | string |
| `webhook-url` | 1Password reference to Discord webhook URL | ✅ | string |
| `repo-name` | Repository display name for notifications | ✅ | string |

### Deploy Workflow

| Parameter | Description | Required | Type | Default |
|-----------|-------------|----------|------|---------|
| `args` | docker compose up -d arguments | ❌ | string | |
| `stacks` | JSON array of stack names to deploy | ✅ | string | |
| `webhook-url` | 1Password reference to Discord webhook URL | ✅ | string | |
| `repo-name` | Repository display name for notifications | ✅ | string | |
| `has-dockge` | Whether this deployment includes Dockge | ❌ | boolean | false |

## Required Secrets

The calling repositories must have the following secrets configured:

- `OP_SERVICE_ACCOUNT_TOKEN` - 1Password service account token
- `SSH_USER` - SSH username for deployment server
- `SSH_HOST` - SSH hostname for deployment server

## Repository Structure Requirements

For the workflows to function properly, calling repositories must have:

```
├── .yamllint                    # yamllint configuration
├── stack1/
│   └── compose.yaml            # Docker Compose file
├── stack2/
│   └── compose.yaml            # Docker Compose file
└── stack3/
    └── compose.yaml            # Docker Compose file
```

## Discord Webhook Configuration

Webhook URLs should be stored in 1Password with references like:
- `op://Docker/discord-github-notifications/zendc_webhook_url`
- `op://Docker/discord-github-notifications/piwine_webhook_url`

## Examples

### Repository with Dockge
```yaml
with:
  stacks: '["dozzle", "portainer", "services"]'
  webhook-url: "op://Docker/discord-github-notifications/piwine_webhook_url"
  repo-name: "docker-piwine"
  has-dockge: true
```

### Repository without Dockge  
```yaml
with:
  stacks: '["barassistant", "beszel", "logging", "media", "services", "zencommand"]'
  webhook-url: "op://Docker/discord-github-notifications/zendc_webhook_url"
  repo-name: "docker-zendc"
  has-dockge: false
```

## Benefits

- **Centralized Maintenance**: Update workflows in one place
- **Consistency**: Standardized deployment process across all repositories
- **Reduced Duplication**: Eliminate repetitive workflow code
- **Version Control**: Pin to specific versions of the reusable workflows
- **Security**: Centralized secret management and security practices

## Contributing

When updating the reusable workflows, consider:
1. Backward compatibility with existing implementations
2. Comprehensive testing across different repository configurations
3. Clear documentation of any breaking changes
4. Semantic versioning for major changes