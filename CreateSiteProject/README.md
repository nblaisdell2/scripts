# Create API Project

Create a working NextJS application using Create T3 app, hosted on AWS, and powered by PostgreSQL!

For more details, see [Create New Site Project script](https://nblaisdell.atlassian.net/wiki/spaces/~701210f4b5f4c121e4cd5804ebc078dd6b379/pages/170196994/Create+New+Site+Project+script) in Confluence.

## Dependencies

- Create T3 app (https://create.t3.gg/)
- GitHub CLI (gh)
- AWS CLI (aws)
- PowerShell / Bash
- Docker
- Terraform
- PostgreSQL (psql)
- npm
- git
- VS Code

## Usage

```ps1
# Usage: ./create-site-project <project-name> <project-desc> <database-name> <db-password> <db-init-path> <aws-account-id> <aws-region> <gh-actions-role-name>

# Use interactively, enter all variables at runtime
.\create-site-project.ps1

# Add required variables, enter defaults at runtime
.\create-site-project.ps1 test-project "test-project desc" testdb Attack123 C:\Project\init.sql

# Add all required variables, running without user input
.\create-site-project.ps1 test-project "test-project desc" testdb Attack123 C:\Project\init.sql 123434564567 us-east-1 role-name
```
