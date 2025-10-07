# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-10-07

### Added

- Initial release of ArgoCD Deployment Buildkite Plugin
- Deploy mode with auto and manual rollback options
- Rollback mode with auto and manual target revision options
- Real-time health monitoring via ArgoCD API
- Automatic log collection from ArgoCD applications and pods
- Artifact upload to Buildkite
- Slack notifications via Buildkite integration
- Interactive manual rollback workflow with block steps
- Smart rollback logic with auto-sync management
- Comprehensive annotations with detailed deployment information
- Support for Elastic CI Stack, Agent Stack K8s, and local/hosted agents

### Features

- **Deploy Operations**: Sync ArgoCD applications with health monitoring
- **Rollback Operations**: Rollback to previous or specific revisions
- **Auto Rollback**: Automatic rollback on deployment failures
- **Manual Rollback**: Interactive decision workflow with block steps
- **Health Checks**: Configurable health check intervals and timeouts
- **Log Collection**: Collect application and pod logs with configurable line limits
- **Notifications**: Slack notifications for deployment and rollback events
- **Artifacts**: Upload logs and deployment metadata to Buildkite

### Compatibility

- ✅ Elastic CI Stack for AWS
- ✅ Agent Stack for Kubernetes
- ✅ Local Agents (Mac/Linux)
- ✅ Hosted Agents (Mac/Linux)

[1.0.0]: https://github.com/buildkite-plugins/argocd-deployment-buildkite-plugin/releases/tag/v1.0.0
