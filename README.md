# Compose Workflow

Reusable GitHub Actions workflows for Docker Compose deployments across multiple repositories.

## Overview

This repository provides centralized, reusable workflows for standardizing CI/CD processes across Docker Compose-based applications. The workflows eliminate code duplication while maintaining flexibility for environment-specific configurations.

## Key Features

- 🔒 **Security First**: Input validation, secret scanning, 1Password integration
- ⚡ **Performance Optimized**: Parallel execution, caching, SSH multiplexing
- 🔄 **Reliability**: Retry logic, health checks, automatic rollback
- 📊 **Observability**: Rich Discord notifications, detailed logging
- 🧪 **Testability**: Local testing scripts, validation tools

## Available Workflows

### 1. Compose Lint Workflow (`compose-lint.yml`)

Performs comprehensive validation of Docker Compose configurations with secret detection.

**Features:**
- **Parallel Execution**: All validation tasks run concurrently for speed
- **GitGuardian Integration**: Scans for leaked secrets (push events only)
- **YAML Validation**: Ensures proper formatting with yamllint
- **Docker Compose Validation**: Verifies syntax and configuration
- **Matrix Strategy**: Tests each stack independently
- **Multi-Repository Support**: Can validate any target repository
- **Discord Notifications**: Reports results with detailed status

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
    uses: owine/compose-workflow/.github/workflows/compose-lint.yml@main
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

Handles production deployments with comprehensive safety features and monitoring.

**Features:**
- **Input Validation**: Comprehensive security validation of all inputs
- **Smart Deployment**: Skip if already at target (unless forced)
- **Retry Mechanisms**: Exponential backoff for network operations
- **Parallel Deployment**: Deploy multiple stacks concurrently
- **Health Checking**: Stack-specific service monitoring
- **Automatic Rollback**: Revert on deployment failure
- **SSH Optimization**: Connection multiplexing for performance
- **Tailscale Integration**: Secure zero-trust networking
- **Docker Cleanup**: Remove unused images post-deployment
- **Rich Notifications**: Detailed Discord deployment reports

**Usage:**
```yaml
name: Deploy Docker Compose
on:
  workflow_run:
    workflows: ["Lint Docker Compose"]
    types: [completed]
    branches: [main]
  workflow_dispatch:
    inputs:
      force-deploy:
        description: 'Force deployment even if already at target'
        required: false
        type: boolean
        default: false

jobs:
  deploy:
    uses: owine/compose-workflow/.github/workflows/deploy.yml@main
    secrets: inherit
    with:
      stacks: '["stack1", "stack2", "stack3"]'
      webhook-url: "op://Docker/discord-github-notifications/webhook_url"
      repo-name: "my-docker-repo"
      target-ref: ${{ github.sha }}
      has-dockge: true
      force-deploy: ${{ inputs.force-deploy || false }}
      args: "--detach --remove-orphans"
```

## Required Configuration

### Repository Structure

Calling repositories must follow this structure:

```
├── .yamllint                    # YAML linting configuration
├── compose.env                  # Environment file with 1Password references
├── stack1/
│   └── compose.yaml            # Docker Compose file
├── stack2/
│   └── compose.yaml            # Docker Compose file
└── stack3/
    └── compose.yaml            # Docker Compose file
```

### Required Secrets

Configure these secrets in calling repositories:

- `OP_SERVICE_ACCOUNT_TOKEN` - 1Password service account token
- `SSH_USER` - SSH username for deployment server
- `SSH_HOST` - SSH hostname/IP for deployment server

### 1Password Configuration

Store sensitive data in 1Password with references like:
```
op://Vault/Item/field
op://Docker/discord-github-notifications/webhook_url
op://Docker/tailscale-oauth/client_id
op://Docker/gitguardian/api_key
```

## Testing and Development

### Local Testing

The repository includes testing scripts in `scripts/testing/`:

```bash
# Test workflow input validation
./scripts/testing/test-workflow.sh

# Validate Docker Compose files
./scripts/testing/validate-compose.sh
```

### Workflow Validation

```bash
# Validate workflow syntax
actionlint .github/workflows/compose-lint.yml
actionlint .github/workflows/workflow-lint.yml
actionlint .github/workflows/deploy.yml

# Check YAML formatting
yamllint --strict .github/workflows/*.yml
```

## Performance Optimizations

### Parallel Execution
- All lint validations run concurrently
- Stack deployments execute in parallel
- Matrix strategy for independent operations

### Caching Strategy
- **Tailscale State**: Cached per repository owner and run
- **Deployment Tools**: Version-based caching for reliability
- **SSH Connections**: Multiplexed for connection reuse

### Retry Logic
- SSH operations: 3 attempts with exponential backoff
- Health checks: 6 attempts with dynamic timing
- Deployment operations: Configurable timeouts

## Security Features

### Input Validation
- Stack names validated for safe characters
- Target refs checked for proper format
- Webhook URLs verified as 1Password references
- Repository names sanitized
- Compose arguments filtered for dangerous patterns

### Secret Management
- All secrets stored in 1Password
- Runtime secret loading only
- GitGuardian scanning prevents leaks
- Service account token isolation

### Network Security
- Tailscale zero-trust networking
- SSH key authentication only
- Connection multiplexing with ControlMaster
- Secure webhook communications

## Troubleshooting

### Common Issues

**GitGuardian Failures**
- Verify `OP_SERVICE_ACCOUNT_TOKEN` is set
- Check 1Password vault access
- Ensure API key exists in vault

**Deployment Connection Issues**
- Verify SSH secrets are configured
- Check Tailscale OAuth credentials
- Ensure server is Tailscale-accessible
- Review SSH retry logs

**Health Check Problems**
- Verify stack-specific compose files (`-f compose.yaml`)
- Check service startup times
- Review container logs
- Adjust retry attempts/timing

**Discord Notification Issues**
- Verify webhook URL format in 1Password
- Check service account permissions
- Test webhook manually

### Debug Mode

Enable detailed logging in workflow calls:
```yaml
env:
  ACTIONS_STEP_DEBUG: true
  ACTIONS_RUNNER_DEBUG: true
```

## Version Management

- **Latest**: Use `@main` for newest features
- **Stable**: Pin to tags like `@v1.0.0`
- **Testing**: Use branch references like `@feature-branch`

## Contributing

1. Test changes with `actionlint` and local scripts
2. Update documentation (README.md, CLAUDE.md)
3. Ensure backward compatibility
4. Test across multiple repositories
5. Create PR with detailed description

## License

This repository is private and for internal use only.

## Support

For issues or questions:
- Check troubleshooting guide above
- Review workflow logs for detailed errors
- Contact repository maintainers

## Recent Updates

- **Input Validation**: Comprehensive security validation
- **Retry Logic**: Exponential backoff for reliability
- **Health Checks**: Stack-specific service counting
- **Caching**: Optimized for performance
- **Parallel Execution**: All validations run concurrently
- **SSH Optimization**: Connection multiplexing
- **Testing Scripts**: Local validation capabilities