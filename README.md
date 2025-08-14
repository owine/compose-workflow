# Compose Workflow

Reusable GitHub Actions workflows for Docker Compose deployments across multiple repositories.

## Overview

This repository contains centralized, reusable workflows that can be called from other repositories to standardize the deployment process for Docker Compose-based applications.

## Available Workflows

### 1. Lint Workflow (`lint.yml`)

Performs comprehensive linting and validation of Docker Compose configurations.

**Features:**
- GitGuardian secret scanning with 1Password integration
- YAML validation with yamllint
- Docker Compose syntax validation
- Matrix strategy for parallel stack testing
- Multi-repository support with configurable checkout
- Discord notifications with detailed results and status information

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
      target-repository: ${{ github.repository }}
      target-ref: ${{ github.sha }}
      github-event-before: ${{ github.event.before }}
      github-event-base: ${{ github.event.base }}
      github-pull-base-sha: ${{ github.event.pull_request.base.sha }}
      github-default-branch: ${{ github.event.repository.default_branch }}
      event-name: ${{ github.event_name }}
```

### 2. Deploy Workflow (`deploy.yml`)

Handles complete deployment pipeline including rollback capabilities.

**Features:**
- Smart deployment logic with commit detection
- Secure Tailscale connection for zero-trust networking
- Parallel stack deployment with detailed logging
- Comprehensive health checking with service monitoring
- Automatic rollback on failure with previous commit restoration
- Docker image cleanup after successful deployment
- Rich Discord notifications with deployment metrics
- Force deployment option for same-commit scenarios

**Usage:**
```yaml
name: Deploy Docker Compose
on:
  workflow_dispatch:
    inputs:
      args:
        description: "docker compose up -d arguments"
        type: "string"
      force-deploy:
        description: "Force deployment even if at target commit"
        type: "boolean"
        default: false
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
      target-ref: ${{ github.sha }}
      has-dockge: true
      force-deploy: ${{ inputs.force-deploy || false }}
```

## Input Parameters

### Lint Workflow

| Parameter | Description | Required | Type | Default |
|-----------|-------------|----------|------|---------|
| `stacks` | JSON array of stack names to lint | ✅ | string | |
| `webhook-url` | 1Password reference to Discord webhook URL | ✅ | string | |
| `repo-name` | Repository display name for notifications | ✅ | string | |
| `target-repository` | Target repository to checkout (owner/repo-name) | ✅ | string | |
| `target-ref` | Git reference to checkout from target repository | ❌ | string | main |
| `github-event-before` | GitHub event before SHA (github.event.before) | ❌ | string | '' |
| `github-event-base` | GitHub event base SHA (github.event.base) | ❌ | string | '' |
| `github-pull-base-sha` | GitHub pull request base SHA | ❌ | string | '' |
| `github-default-branch` | GitHub repository default branch | ❌ | string | main |
| `event-name` | GitHub event name (github.event_name) | ❌ | string | push |

### Deploy Workflow

| Parameter | Description | Required | Type | Default |
|-----------|-------------|----------|------|---------|
| `args` | docker compose up -d arguments | ❌ | string | |
| `stacks` | JSON array of stack names to deploy | ✅ | string | |
| `webhook-url` | 1Password reference to Discord webhook URL | ✅ | string | |
| `repo-name` | Repository display name for notifications | ✅ | string | |
| `target-ref` | Git reference to deploy | ✅ | string | |
| `has-dockge` | Whether this deployment includes Dockge | ❌ | boolean | false |
| `force-deploy` | Force deployment even if at target commit | ❌ | boolean | false |

## Required Secrets

The calling repositories must have the following secrets configured:

- `OP_SERVICE_ACCOUNT_TOKEN` - 1Password service account token for secret management
- `SSH_USER` - SSH username for deployment server
- `SSH_HOST` - SSH hostname for deployment server

Additional secrets required in 1Password:
- `GITGUARDIAN_API_KEY` - For secret scanning in lint workflow
- `TAILSCALE_OAUTH_CLIENT_ID` and `TAILSCALE_OAUTH_SECRET` - For secure deployment connections

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
- `op://Docker/discord-github-notifications/environment1_webhook_url`
- `op://Docker/discord-github-notifications/environment2_webhook_url`

## Examples

### Repository with Dockge
```yaml
with:
  stacks: '["dozzle", "portainer", "services"]'
  webhook-url: "op://Docker/discord-github-notifications/environment1_webhook_url"
  repo-name: "docker-environment1"
  has-dockge: true
```

### Repository without Dockge  
```yaml
with:
  stacks: '["app1", "app2", "logging", "media", "services", "monitoring"]'
  webhook-url: "op://Docker/discord-github-notifications/environment2_webhook_url"
  repo-name: "docker-environment2"
  has-dockge: false
```

## Benefits

- **Centralized Maintenance**: Update workflows in one place
- **Consistency**: Standardized deployment process across all repositories  
- **Reduced Duplication**: Eliminate repetitive workflow code
- **Enhanced Reliability**: Automatic rollback, comprehensive health checking, and detailed monitoring
- **Security Integration**: GitGuardian scanning, 1Password secret management, and Tailscale networking
- **Rich Notifications**: Detailed Discord notifications with deployment status and health metrics

## Contributing

When updating the reusable workflows, consider:
1. Backward compatibility with existing implementations
2. Comprehensive testing across different repository configurations
3. Clear documentation of any breaking changes
4. Semantic versioning for major changes