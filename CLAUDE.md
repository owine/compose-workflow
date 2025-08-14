# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Centralized Docker Compose Workflow Management

This repository contains **reusable GitHub Actions workflows** that provide centralized CI/CD automation for Docker Compose environments. The goal is to eliminate code duplication while maintaining environment-specific configurations.

### Repository Purpose

**compose-workflow** serves as a centralized workflow hub providing reusable CI/CD workflows for Docker Compose deployments across multiple repositories.

### Workflow Architecture

This repository provides two main reusable workflows:

#### 1. Lint Workflow (`/.github/workflows/lint.yml`)
- **Purpose**: Validates Docker Compose files and detects secrets
- **Features**: GitGuardian scanning, YAML linting, Docker Compose validation, Discord notifications
- **Key Input Parameters**: 
  - `stacks`: JSON array of stack names to lint
  - `webhook-url`: 1Password reference to Discord webhook
  - `repo-name`: Repository name for notifications
  - `target-repository`: Target repository to checkout
  - `target-ref`: Git reference to checkout (default: main)
  - Various GitHub event parameters for context

#### 2. Deploy Workflow (`/.github/workflows/deploy.yml`)  
- **Purpose**: Handles deployment, health checks, rollback, and cleanup with comprehensive monitoring
- **Features**: 
  - Parallel stack deployment with detailed logging
  - Comprehensive health checking with service status monitoring
  - Automatic rollback on failure
  - Docker image cleanup
  - Tailscale integration for secure connections
  - Discord notifications with rich deployment status information
- **Key Input Parameters**:
  - `stacks`: JSON array of stack names to deploy
  - `webhook-url`: 1Password reference to Discord webhook  
  - `repo-name`: Repository name for notifications
  - `target-ref`: Git reference to deploy
  - `has-dockge`: Boolean for Dockge deployment
  - `force-deploy`: Force deployment even if at target commit
  - `args`: Additional docker compose up arguments

### Benefits of Centralization

1. **Reduced Duplication**: Single workflow definitions shared across repositories
2. **Consistent Behavior**: Standardized deployment patterns and error handling  
3. **Centralized Maintenance**: Updates apply to all environments simultaneously
4. **Enhanced Reliability**: Automatic rollback, health checking, and comprehensive monitoring
5. **Security Integration**: GitGuardian scanning, 1Password secret management, Tailscale networking

## Workflow Configuration

### Required Secrets

Calling repositories must have the following secrets configured:

- `OP_SERVICE_ACCOUNT_TOKEN` - 1Password service account token for secret management
- `SSH_USER` - SSH username for deployment server
- `SSH_HOST` - SSH hostname for deployment server

### Repository Structure Requirements

For the workflows to function properly, calling repositories must have:

```
├── .yamllint                    # yamllint configuration
├── compose.env                  # Environment file with 1Password references
├── stack1/
│   └── compose.yaml            # Docker Compose file
├── stack2/
│   └── compose.yaml            # Docker Compose file
└── stack3/
    └── compose.yaml            # Docker Compose file
```

### Discord Webhook Configuration

Webhook URLs should be stored in 1Password with references like:
- `op://Docker/discord-github-notifications/webhook_url`

Example Discord notification configuration:
```yaml
webhook-url: "op://Docker/discord-github-notifications/environment_webhook_url"
```

## Development Commands

### Workflow Development

```bash
# Test workflow syntax
actionlint .github/workflows/lint.yml
actionlint .github/workflows/deploy.yml

# Validate workflow YAML formatting
yamllint --strict .github/workflows/lint.yml
yamllint --strict .github/workflows/deploy.yml
```

### Testing Workflows

For testing these workflows, calling repositories should implement them with proper parameters and secrets configured.

### Deployment Validation

```bash
# Validate Docker Compose configurations in calling repositories
yamllint --strict --config-file .yamllint stack/compose.yaml
docker compose -f stack/compose.yaml config
```

## Workflow Features

### Lint Pipeline Features

The lint workflow (`lint.yml`) provides:

1. **GitGuardian Scanning** - Secret detection with 1Password integration (push events only)
2. **YAML Linting** - Validates compose file formatting using yamllint  
3. **Docker Compose Config** - Validates syntax and configuration
4. **Matrix Strategy** - Tests each stack independently
5. **Discord Notifications** - Reports results with detailed status information
6. **Multi-repository Support** - Can checkout and lint any target repository

### Deploy Pipeline Features  

The deploy workflow (`deploy.yml`) provides:

1. **Smart Deployment Logic** - Skips deployment if repository is already at target commit
2. **Parallel Stack Deployment** - Deploy all stacks concurrently with detailed logging
3. **Comprehensive Health Checks** - Verify all services are running with container status monitoring
4. **Automatic Rollback** - Roll back to previous commit on failure
5. **Docker Image Cleanup** - Remove unused images after successful deployment
6. **Tailscale Integration** - Secure connection to deployment servers
7. **Rich Discord Notifications** - Comprehensive deployment status with health metrics
8. **Force Deployment Option** - Override same-commit detection when needed

## Security Integration

### Secret Management

The workflows integrate with 1Password for secure secret management:

- All secrets use 1Password references (`op://Vault/Item/field`)  
- GitGuardian scanning prevents accidental secret commits
- Service account tokens provide CI/CD access to secrets
- Secrets are loaded at runtime, never stored in repositories

### Network Security

- **Tailscale Integration** - Secure zero-trust networking for deployment connections
- **SSH Key Management** - Secure SSH connections to deployment servers
- **1Password Integration** - Centralized secret management with vault isolation

## Workflow Maintenance

### Updating Workflows

When updating the reusable workflows in this repository:

1. **Test workflow syntax** - Use `actionlint` to validate workflow files
2. **Update documentation** - Reflect changes in `README.md` and `CLAUDE.md`
3. **Version workflows** - Consider using tags for major workflow changes
4. **Test with target repositories** - Verify changes work across calling repositories

### Version Management

- Target repositories reference workflows using `@main` for latest features
- For stability, repositories can pin to specific versions like `@v1.0.0`
- Breaking changes should be versioned and communicated to calling repositories

### Adding New Features

When adding new features to the workflows:

1. **Add input parameters** - Define new inputs in workflow files
2. **Update parameter documentation** - Document new parameters in README.md
3. **Test thoroughly** - Verify new features work across different repository configurations
4. **Maintain backward compatibility** - Ensure existing implementations continue to work

## Repository Structure

This repository contains:

```
├── .github/
│   └── workflows/
│       ├── lint.yml           # Reusable lint workflow
│       └── deploy.yml         # Reusable deploy workflow  
├── CLAUDE.md                  # This file - Claude Code guidance
├── README.md                  # Repository documentation
└── renovate.json              # Renovate configuration for dependency updates
```

### Dependency Management

The repository uses Renovate for automated dependency updates:
- GitHub Actions are automatically updated with minor/patch versions
- Major version updates are grouped separately for review

## Troubleshooting Workflows

### Common Workflow Issues

#### GitGuardian Scanning Failures

**Symptoms**: Lint workflow fails at GitGuardian step

**Solutions**:
1. Check `OP_SERVICE_ACCOUNT_TOKEN` is configured correctly
2. Verify GitGuardian API key exists in 1Password vault
3. Ensure 1Password service account has access to GitGuardian secrets

#### Deployment Connection Issues  

**Symptoms**: Deploy workflow fails to connect to deployment server

**Solutions**:
1. Verify `SSH_USER` and `SSH_HOST` secrets are configured
2. Check Tailscale OAuth credentials in 1Password
3. Ensure deployment server is accessible via Tailscale
4. Verify SSH key authentication is working

#### Discord Notification Failures

**Symptoms**: Workflow completes but no Discord notifications

**Solutions**:
1. Check webhook URL format in 1Password: `op://Vault/Item/field`
2. Verify 1Password service account has access to Discord webhook secrets  
3. Test webhook URL manually
4. Check Discord channel permissions

#### Health Check Failures

**Symptoms**: Deployment succeeds but health checks fail

**Solutions**:
1. Increase health check timeout in workflow
2. Verify services have proper health check configurations
3. Check Docker Compose service dependencies
4. Review container logs for startup issues

### Workflow Debugging

#### Enable Debug Logging

Add this to workflow calls for detailed logging:

```yaml
env:
  ACTIONS_STEP_DEBUG: true
  ACTIONS_RUNNER_DEBUG: true
```

#### Check Workflow Outputs

Monitor workflow outputs for troubleshooting:

```yaml
- name: Debug Outputs
  run: |
    echo "Deploy Status: ${{ needs.deploy.outputs.deploy_status }}"
    echo "Health Status: ${{ needs.deploy.outputs.health_status }}"
    echo "Healthy Stacks: ${{ needs.deploy.outputs.healthy_stacks }}"
```

# important-instruction-reminders
Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.