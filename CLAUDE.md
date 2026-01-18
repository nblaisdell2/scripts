# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains PowerShell automation scripts for bootstrapping full-stack web projects with AWS infrastructure.

## Scripts

### CreateAPIProject (`create-api-project.ps1`)

Creates a Fastify API project with:
- GitHub repo (from `nblaisdell2/fastify-postgres-typescript-template`)
- AWS Lambda + API Gateway backend
- ECR container registry
- CodeBuild/CodeDeploy CI/CD pipeline
- RDS PostgreSQL database (via Terraform)
- AWS Secrets Manager for environment variables

```powershell
# Interactive mode
.\CreateAPIProject\create-api-project.ps1

# With arguments
.\CreateAPIProject\create-api-project.ps1 <project-name> <project-desc> <database-name> <db-password> <db-init-path> [aws-account-id] [aws-region] [gh-actions-role-name]
```

### CreateSiteProject (`create-site-project.ps1`)

Creates a NextJS T3 app with:
- GitHub repo (using Create T3 App with tRPC, Tailwind, AppRouter)
- AWS AppRunner hosting
- ECR container registry
- CodeBuild CI/CD pipeline
- RDS PostgreSQL database (via Terraform)
- S3 bucket for SSL certificates
- AWS Secrets Manager for environment variables

```powershell
# Interactive mode
.\CreateSiteProject\create-site-project.ps1

# With arguments
.\CreateSiteProject\create-site-project.ps1 <project-name> <project-desc> <database-name> <db-password> <db-init-path> [aws-account-id] [aws-region] [gh-actions-role-name]
```

## Dependencies

Both scripts require:
- GitHub CLI (`gh`)
- AWS CLI (`aws`)
- Docker
- Terraform
- PostgreSQL (`psql`)
- npm
- git
- VS Code

CreateSiteProject additionally requires:
- Create T3 App (`npx create-t3-app@latest`)

## Architecture Pattern

Both scripts follow the same execution flow:
1. Gather user input (project name, DB credentials, AWS config)
2. Create local repository
3. Create GitHub repository with secrets
4. Provision AWS infrastructure (ECR, compute, API, IAM roles, CI/CD)
5. Set up Terraform for RDS PostgreSQL (create/destroy/recreate pattern for snapshot support)
6. Initialize database with optional SQL script
7. Configure local development environment (.env files)
8. Push to GitHub (triggers CI/CD)
9. Output URLs and open VS Code

## Key Helper Functions

Both scripts share these utility functions:
- `Get-User-Input`: Interactive input with optional defaults
- `Wait-ForAWSResource`: Poll until AWS resource is available
- `New-Random-String`: Generate random suffixes for unique resource names
- `Get-JSON-Path`: Write JSON to temp file for AWS CLI `file://` parameters
