# ArgoCD Deployment Buildkite Plugin

A Buildkite plugin for deploying and rolling back ArgoCD applications with comprehensive health monitoring, log collection, and notification capabilities.

## Prerequisites

### Required CLI Tools

The plugin requires the following tools to be pre-installed on your Buildkite agents:

- **ArgoCD CLI** (`argocd`) - [Installation Guide](https://argo-cd.readthedocs.io/en/stable/cli_installation/)
- **jq** - JSON processor

## Authentication

The plugin requires ArgoCD authentication via environment variables. You must set these before your ArgoCD plugin steps:

### Required Environment Variables

- `ARGOCD_SERVER` - ArgoCD server URL (can be set in the plugin step)
- `ARGOCD_USERNAME` - ArgoCD username (can be set in the plugin step)
- `ARGOCD_PASSWORD` - ArgoCD password (use your desired 3rd party secret management solution and fetched before the ArgoCD plugin steps)

```yaml
steps:
  # Fetch secrets once for entire pipeline
  - label: "🔐 Fetch ArgoCD Credentials"
    key: "fetch-argocd-secrets"
    plugins:
      # Choose your secret management solution:
      - secrets#v1.0.2:                    # Buildkite Secrets
          env:
            ARGOCD_PASSWORD: your-secret-key
      # OR
      - vault-secrets#v2.3.1:              # HashiCorp Vault
          server: "https://my-vault-server"
          secrets:
            - path: secret/argocd/password
              field: ARGOCD_PASSWORD
      # OR  
      - seek-oss/aws-sm#v2.3.3:             # AWS Secrets Manager
          secrets:
            - name: ARGOCD_PASSWORD
              key: argocd/password
            
  # All ArgoCD steps use the fetched credentials
  - label: "🚀 Deploy Application"
    depends_on: "fetch-argocd-secrets"
    plugins:
      - argocd-deployment#v1.0.0:
          app: "my-app"
          argocd_server: "https://argocd.example.com" # if not set in environment variables
          argocd_username: "admin" # if not set in environment variables
```

## Features

- 🚀 **Deploy and Rollback**: Support for both deployment and rollback operations
- 🏥 **Health Monitoring**: Real-time application health checks via ArgoCD API
- 📋 **Log Collection**: Automatic collection of ArgoCD application and pod logs
- 📤 **Artifact Upload**: Upload deployment logs and artifacts to Buildkite
- 🔔 **Notifications**: Slack notifications via Buildkite integration
- 🚧 **Manual Rollback Workflow**: Interactive block steps for manual rollback decisions
- ⚡ **Auto Rollback**: Automatic rollback on deployment failures
- 🎯 **Smart Rollback Logic**: Temporarily disables auto-sync during rollbacks to prevent conflicts
- 📊 **Comprehensive Annotations**: Beautiful success/failure annotations with detailed information

## Workflow

### Deploy Mode

1. **Validation**: Plugin validates ArgoCD connectivity and application existence
2. **Pre-deployment**: Captures current application state and revision for rollback
3. **Deployment**: Executes ArgoCD sync operation
   - **Auto mode**: Completes full health check cycle, then automatic rollback to a previous deployment on failure
   - **Manual mode**: Fails immediately on first health check failure to save time, then interactive block step
4. **Log Collection**: Collects ArgoCD app logs and pod logs (if enabled)
5. **Artifact Upload**: Uploads logs and deployment artifacts to Buildkite
6. **Notifications**: Sends Slack notifications on rollback events
7. **Annotations**: Creates beautiful success/failure annotations with detailed information

### Rollback Mode

1. **Validation**: Plugin validates ArgoCD connectivity and target revision
2. **Rollback Execution**:
   - **Auto mode**: Executes ArgoCD rollback to a previous deployment if auto mode is used
   - **Manual mode**: Executes ArgoCD rollback to specified revision if manual mode is used
3. **Log Collection**: Collects ArgoCD app logs and pod logs (if enabled)
4. **Artifact Upload**: Uploads logs and deployment artifacts to Buildkite
5. **Notifications**: Sends Slack notifications on rollback events
6. **Annotations**: Creates beautiful success/failure annotations with detailed information

## Configuration Options

### Required

#### `app` (string)

The name of the ArgoCD application to deploy or rollback.

### Optional

#### `mode` (string)

Operation mode. Defaults to `"deploy"`.

- `deploy`: Deploy the application
- `rollback`: Rollback the application

#### `rollback_mode` (string)

Rollback mode for handling deployment failures.

- **For `mode: "deploy"`**: Defaults to `"auto"`
  - `auto`: Automatic rollback to previous version on health check failure
  - `manual`: Manual rollback with interactive block step for user decision
- **For `mode: "rollback"`**: Required, no default
  - `auto`: Rollback to previous version
  - `manual`: Rollback to specific revision with user confirmation

#### `timeout` (number)

Timeout in seconds for ArgoCD operations. Defaults to `300`. Must be between 30 and 3600 seconds.

#### `argocd_server` (string)

ArgoCD server URL. Can also be set via `ARGOCD_SERVER` environment variable. Supports:

- Full URL: `https://argocd.example.com`
- ELB DNS name: `a84b3c9fe815e4047a19a04966cc5ff1-2002834036.us-east-1.elb.amazonaws.com:443`
- ELB IP address: `52.206.16.12:443`
- Kubernetes service: `argocd-server.argocd.svc.cluster.local:443`

#### TLS certificate verification and private CAs

Login and generated manual rollback commands verify the ArgoCD server certificate
and hostname. Older versions of this plugin unconditionally used `--insecure`;
this was a pre-existing verification bypass, not a CA-specific regression.
Servers with self-signed, untrusted, expired, or wrong-host certificates will now
fail authentication. Fix the certificate or configure trust rather than disabling
verification. This plugin does not provide an insecure compatibility mode.

For a private CA, provision its PEM CA bundle on the agent and configure the
ArgoCD CLI's system trust before running the plugin. For example, on Linux agents
using the standard Go certificate verifier:

```yaml
env:
  SSL_CERT_FILE: "/etc/company/argocd-ca-bundle.pem"
```

The bundle must contain the required trust anchors; use a combined public/private
bundle if other clients need public roots. Trust-store behavior varies by OS and
ArgoCD build: validate it with your installed CLI. On macOS, configure the system
trust store instead. The CLI also has a `--server-crt` option, but do not assume
that every CLI version applies it to `login`; verify your version's behavior.
Do not set `ARGOCD_OPTS` or other CLI configuration to disable TLS verification
or use plaintext transport.

Generated manual rollback runs in a separate Buildkite step. Provision the same
CA trust and required environment on every eligible agent, and make the CA bundle
available at the same path in the rollback step (for example, through pipeline
level environment and agent provisioning). Step-local environment is not
necessarily inherited by the generated step.

Both login paths use `--skip-test-tls` to bypass ArgoCD's interactive TLS detection
probe, which can offer an insecure/plaintext downgrade and does not consistently
honor custom trust. This flag **does not disable certificate verification** on
the actual authenticated connection. Login has no interactive stdin, fails closed
on trust errors, and never retries with `--insecure`.

#### `argocd_username` (string)

ArgoCD username. Can also be set via `ARGOCD_USERNAME` environment variable.

#### `target_revision` (string)

Target revision for rollback operations. Accepts ArgoCD History IDs or Git commit SHAs.

> **💡 Important**: ArgoCD only returns the last 10 deployment history entries by default. For manual rollbacks, use recent History IDs (visible in `argocd app history <app-name>`) or commit SHAs from recent deployments. Older deployments may not be available for rollback.

#### `health_check_interval` (number)

Health check interval in seconds. Defaults to `30`. Must be between 10 and 300 seconds.

#### `health_check_timeout` (number)

Health check timeout in seconds. Defaults to `300`. Must be between 60 and 1800 seconds.

#### `collect_logs` (boolean)

Collect application logs on deployment. Defaults to `false`.

#### `log_lines` (number)

Number of log lines to collect. Defaults to `1000`. Must be between 100 and 10000.

#### `upload_artifacts` (boolean)

Upload logs and deployment artifacts. Defaults to `false`.

#### `notifications` (object)

Notification settings for rollback events.

##### `notifications.slack_channel` (string, optional)

Slack channel, username, or user ID for notifications using Buildkite's native Slack integration. Supports:

- Channel names: `#deployments`, `#alerts`
- Usernames: `@username`, `@devops-team`
- User IDs: `U123ABC456`

## Usage Patterns

### Production: Auto-rollback (Recommended)

Safe deployments with automatic rollback on health check failures:

```yaml
steps:
  - label: "🚀 Deploy Application"
    plugins:
      - secrets#v1.0.2:
          variables:
            ARGOCD_PASSWORD: argocd_password
      - argocd-deployment#v1.0.0:
          app: "my-app"
          argocd_server: "https://argocd.example.com"
          argocd_username: "admin"
          mode: "deploy"
          rollback_mode: "auto"  # Default: also enabled if unset
          collect_logs: true
          upload_artifacts: true
```

### Development: Manual Rollback Control

Manual rollback workflow with interactive block steps for user decision:

```yaml
steps:
  - label: "🚫 Deploy with Manual Rollback"
    plugins:
      - secrets#v1.0.2:
          variables:
            ARGOCD_PASSWORD: argocd_password
      - argocd-deployment#v1.0.0:
          app: "my-app"
          argocd_server: "https://argocd.example.com"
          argocd_username: "admin"
          mode: "deploy"
          rollback_mode: "manual"  # Interactive rollback decision
          collect_logs: true
          upload_artifacts: true
          notifications:
            slack_channel: "#deployments"
```

### Manual Rollback Operation

Explicit rollback to a specific revision:

```yaml
steps:
  - label: "🔄 Manual Rollback"
    plugins:
      - secrets#v1.0.2:
          variables:
            ARGOCD_PASSWORD: argocd_password
      - argocd-deployment#v1.0.0:
          app: "my-app"
          argocd_server: "https://argocd.example.com"
          argocd_username: "admin"
          mode: "rollback"
          rollback_mode: "manual"
          target_revision: "370"  # Recent ArgoCD History ID 
          collect_logs: true
          upload_artifacts: true
```

## Compatibility

| Elastic Stack | Agent Stack K8s | Local Agents (Mac/Linux) | Hosted Agents (Mac/Linux) |
| :-----------: | :-------------: | :----: | :----: |
| ✅ | ✅ | ✅ | ✅ |

- ✅ **Fully supported** - Tested and verified; all agent types require the ArgoCD CLI to be pre-installed. Hosted Agents may require installation via pipeline.

## Developing

To run linting and shellchecks, use `bk run` with the [Buildkite CLI](https://github.com/buildkite/cli):

### TLS regression tests

Run `bats tests` for command construction and fail-closed login/rollback tests.
The optional local-only verifier fixture requires Python 3, OpenSSL, and an
ArgoCD CLI with gRPC-web support:

```sh
python3 tests/tls-integration.py --argocd /path/to/argocd
```

It uses temporary certificates, isolated CLI configuration, and fake credentials
against a loopback TLS server; it never contacts a deployment. It checks trusted
login and rejection of untrusted/wrong-host certificates before credentials are
sent. The fixture was exercised with Linux ArgoCD v2.8.0 and v3.5.6; it does not
qualify every agent's installed CLI or trust store. The local fixture is optional
and is not run by the plugin-tester Bats job.

## Contributing

We welcome contributions! Please follow these guidelines:

1. **Fork the repository** and create a feature branch
2. **Write tests** for any new functionality
3. **Run linting** with `bk run` before submitting
4. **Follow shell best practices** - use shellcheck-compliant code
5. **Update documentation** - keep README and CHANGELOG current
6. **Submit a pull request** with a clear description of changes

For bug reports and feature requests, please [open an issue](https://github.com/buildkite-plugins/argocd-deployment-buildkite-plugin/issues).

## 📜 License

The package is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
