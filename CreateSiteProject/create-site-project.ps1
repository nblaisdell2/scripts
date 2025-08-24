# Usage: ./create-site-project <project-name> <project-desc> <database-name> <db-password> <db-init-path> <aws-account-id> <aws-region> <gh-actions-role-name>

param(
  [string]$projectName,
  [string]$projectDesc,
  [string]$dbName,
  [string]$dbPass,
  [string]$dbInitPath,
  [string]$awsAccountID,
  [string]$awsRegion,
  [string]$awsGHActionRole
)

# Function for accepting user input for the script
# disallows blank values - value must be entered
function Get-User-Input {
  param(
    [string]$var,
    [string]$label,
    [string]$defaultValue
  )

  $msg = "  Enter ${label}"
  if (-not $var) {
    if ($defaultValue) {            
      $userInput = Read-Host "${msg} (default: ${defaultValue})"
      $var = if ([string]::IsNullOrWhiteSpace($userInput)) { $defaultValue } else { $userInput }
    }
    else {
      $var = Read-Host $msg
    
      while ([string]::IsNullOrWhiteSpace($var)) {
        Write-Host " ⚠️  $label is required!"
        $var = Read-Host $msg
      }
    }
  }

  return $var
}

# Function for waiting for an AWS resource to be provisioned before moving on
function Wait-ForAWSResource {
  param(
    [string]$ResourceName,
    [ScriptBlock]$Command,
    [int]$DelaySeconds = 5
  )

  while ($true) {
    try {
      & $Command | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Write-Host " ✅  Resource '${ResourceName}' is now available!"
        break
      }
    }
    catch {
      # Optional: log or handle error
      Write-Host " ❌  Error finding resource ${ResourceName}!"
      exit 1
    }
    
    Write-Host " ⏳  Waiting for resource '${ResourceName}' to be ready..."
    Start-Sleep -Seconds $DelaySeconds
  }
}

# Function for generating a random string of characters, of varying lengths if needed
# Used for naming variables/cloud resources with a unique value every time
function New-Random-String {
  param(
    [int]$NumChars = 6
  )

  # Define possible characters
  $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'

  # Build a 6-character random string
  $randomString = -join ((1..6) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })

  return $randomString
}

function Get-JSON-Path {
    param(
        [hashtable]$JSON_In,
        [string]$FileName
    )

    $path = "$env:TEMP\$FileName"
    $json = $JSON_In | ConvertTo-Json -Depth 10 -Compress

    # Create UTF8NoBOM Encoding explicitly
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # Write file without BOM
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)

    return $path
}

###################################################################################################



#==========================
# 1. USER INPUT
#==========================
Write-Host "==================================="
Write-Host "GETTING USER INPUT"
Write-Host "==================================="

# First, move to my Project folder
Set-Location -Path 'C:\Users\nblai\Projects'

# Get User Input for the needed variables for the rest of the script
# Allow for default values for _some_ variables
$projectName = Get-User-Input -var $projectName -label "Project name" 

## Remove folder before creating
# if (Test-Path -Path $projectName -PathType Container) {
#     Remove-Item -Path $projectName -Recurse -Force
# }

# If it does, exit here and allow the user to try again with another project name
if (Test-Path -Path $projectName -PathType Container) {
  Write-Host " ⚠️  Error: A folder named '$projectName' already exists. Please choose a different name."
  exit 1
}

$projectDesc = Get-User-Input -var $projectDesc      -label "Project description" 
$dbName = Get-User-Input -var $dbName           -label "Database name" 
$dbPass = Get-User-Input -var $dbPass           -label "Database password" 
$dbInitPath = Get-User-Input -var $dbInitPath       -label "Database init script path" 
$awsAccountID = Get-User-Input -var $awsAccountID     -label "AWS Account ID"            -defaultValue "387815262971"
$awsRegion = Get-User-Input -var $awsRegion        -label "AWS Region"                -defaultValue "us-east-1"
$awsGHActionRole = Get-User-Input -var $awsGHActionRole  -label "GitHub Actions Role Name"  -defaultValue "github-actions-create-site-role"


# At this point in the script, all the necessary information has been gathered
# and the rest of the script will be fully automated and require no user input



#==========================
# 2. CREATE LOCAL REPO
#==========================
Write-Host "==================================="
Write-Host "CREATING LOCAL REPOSITORY"
Write-Host "==================================="

# Create a new project using Create-T3-app, providing a best-practice NextJS application
# https://create.t3.gg/
#   This project template will be using TypeScript, Tailwind (for CSS/styling), AppRouter (new layouts for NextJS)
#   and tRPC for end-to-end typescript support for APIs!
npx create-t3-app@latest $projectName --CI --trpc --tailwind --appRouter --dbProvider postgres
Write-Host " ✅  Folder '$projectName' created successfully."

# Move into the local directory for the rest of the steps
Write-Host " 📁  Moving into local project directory..."
Set-Location -Path $projectName

# Install extra npm libraries/packages
npm install @aws-sdk/client-secrets-manager @aws-sdk/client-s3 pg
npm install -D @types/pg

# Add the Dockerfile necessary for containerizing the application
# Sourced from: https://create.t3.gg/en/deployment/docker#3-create-dockerfile
@'
##### DEPENDENCIES

FROM --platform=linux/amd64 node:20-alpine AS deps
RUN apk add --no-cache libc6-compat openssl
WORKDIR /app

# Install dependencies based on the preferred package manager

COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml\* ./

RUN \
    if [ -f yarn.lock ]; then yarn --frozen-lockfile; \
    elif [ -f package-lock.json ]; then npm ci; \
    elif [ -f pnpm-lock.yaml ]; then npm install -g pnpm && pnpm i; \
    else echo "Lockfile not found." && exit 1; \
    fi

##### BUILDER

FROM --platform=linux/amd64 node:20-alpine AS builder
ARG DATABASE_URL
ARG NEXT_PUBLIC_CLIENTVAR
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# ENV NEXT_TELEMETRY_DISABLED 1

RUN \
    if [ -f yarn.lock ]; then SKIP_ENV_VALIDATION=1 yarn build; \
    elif [ -f package-lock.json ]; then SKIP_ENV_VALIDATION=1 npm run build; \
    elif [ -f pnpm-lock.yaml ]; then npm install -g pnpm && SKIP_ENV_VALIDATION=1 pnpm run build; \
    else echo "Lockfile not found." && exit 1; \
    fi

##### RUNNER

FROM --platform=linux/amd64 gcr.io/distroless/nodejs20-debian12 AS runner
WORKDIR /app

ENV NODE_ENV production

# ENV NEXT_TELEMETRY_DISABLED 1

COPY --from=builder /app/next.config.js ./
COPY --from=builder /app/public ./public
COPY --from=builder /app/package.json ./package.json

# Copying node_modules folder, so we have access to @aws-sdk/client-secrets-manager
# during build/runtime
COPY --from=builder /app/node_modules ./node_modules

COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static

EXPOSE 3000
ENV PORT 3000

CMD ["server.js"]
'@ | Set-Content -Path "Dockerfile"

# Add the .dockerignore necessary for containerizing the application
# Sourced from: https://create.t3.gg/en/deployment/docker#2-create-dockerignore-file
@'
.env
Dockerfile
.dockerignore
node_modules
npm-debug.log
README.md
.next
.git
'@ | Set-Content -Path ".dockerignore"

# Add the "standalone" property to the NextJS configuration for the application,
# necessary for the Dockerfile, created above
Remove-Item "next.config.js"
@'
/**
 * Run `build` or `dev` with `SKIP_ENV_VALIDATION` to skip env validation. This is especially useful
 * for Docker builds.
 */
import "./src/env.js";

/** @type {import("next").NextConfig} */
const config = {
  reactStrictMode: true,
  transpilePackages: ["geist"],
  output: "standalone",
};

export default config;
'@ | Set-Content -Path "next.config.js"

# Add utils/db.ts file for working with PostgreSQL from NextJS (backend)
# Ensure the folder structure exists
$folderPath = "src/utils"
if (-not (Test-Path $folderPath)) {
  New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
}

@'
import type { QueryResultRow } from "pg";
import { Pool } from "pg";
import { env } from "../env";
import fs from "fs";

import path from "path";
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { Readable } from "stream";

const pemFilePath = path.join("/tmp", "rds-combined-ca-bundle.pem");

async function downloadPemIfNeeded(): Promise<void> {
  // Already downloaded
  if (fs.existsSync(pemFilePath)) {
    return;
  }

  const s3 = new S3Client({ region: env.AWS_REGION });
  const command = new GetObjectCommand({
    Bucket: env.SSL_PEM_BUCKET,
    Key: env.SSL_PEM_KEY,
  });

  const response = await s3.send(command);

  const streamToString = (stream: Readable): Promise<string> =>
    new Promise((resolve, reject) => {
      const chunks: any[] = [];
      stream.on("data", (chunk) => chunks.push(chunk));
      stream.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
      stream.on("error", reject);
    });

  const pemContent = await streamToString(response.Body as Readable);
  fs.writeFileSync(pemFilePath, pemContent);
}

async function getConnection() {
  if (env.NODE_ENV == "development") {
    return {
      host: env.DB_HOST as string,
      database: env.DB_DATABASE as string,
      port: env.DB_PORT as unknown as number,
      user: env.DB_USER as string,
      password: env.DB_PASS as string,
    };
  } else {
    await downloadPemIfNeeded();
    return {
      host: env.DB_HOST as string,
      database: env.DB_DATABASE as string,
      port: env.DB_PORT as unknown as number,
      user: env.DB_USER as string,
      password: env.DB_PASS as string,
      ssl: {
        require: true,
        rejectUnauthorized: true,
        ca: fs.readFileSync(pemFilePath).toString(),
      },
    };
  }
}

let pool: Pool;

async function getConnectionPool() {
  if (!pool) {
    const dbConn = await getConnection();
    pool = new Pool(dbConn);
  }
  return pool;
}

function getFunctionSQL(
  functionName: string,
  ...params: any[]
): { sql: string; params: any[] } {
  const paramList = [...Array(params.length).keys()]
    .map((v) => "$" + (v + 1))
    .join(", ");

  return { sql: `SELECT * FROM ${functionName}(${paramList});`, params };
}

function getProcedureSQL(
  procedureName: string,
  ...params: any[]
): { sql: string; params: any[] } {
  const paramList = [...Array(params.length).keys()]
    .map((v) => "$" + (v + 1))
    .join(", ");
  return { sql: `CALL ${procedureName}(${paramList});`, params };
}

export async function querySQL<TResult extends QueryResultRow>(sql: string) {
  const conn = await getConnectionPool();
  const result = await conn.query<TResult>(sql);
  return result;
}

export async function query<TResult extends QueryResultRow>(
  functionName: string,
  ...functionParams: any[]
) {
  const { sql, params } = getFunctionSQL(functionName, ...functionParams);
  let result;
  try {
    const conn = await getConnectionPool();
    result = await conn.query<TResult>(sql, params);
  } catch (ex) {
    console.log(ex);
  }

  return result;
}

export async function exec<TResult extends QueryResultRow>(
  procName: string,
  ...procParams: any[]
) {
  const { sql, params } = getProcedureSQL(procName, ...procParams);
  const conn = await getConnectionPool();
  const result = await conn.query<TResult>(sql, params);
  return result;
}
'@ | Set-Content -Path "$folderPath/db.ts"

Write-Host " 📁  Moving into project src directory..."
Set-Location -Path "src"

Remove-Item "env.js"
@'
import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

export const env = createEnv({
  /**
   * Specify your server-side environment variables schema here. This way you can ensure the app
   * isn't built with invalid env vars.
   */
  server: {
    NODE_ENV: z.enum(["development", "test", "production"]),
    DB_HOST: z.string().optional(),
    DB_DATABASE: z.string().optional(),
    DB_PORT: z.string().optional(),
    DB_USER: z.string().optional(),
    DB_PASS: z.string().optional(),
    AWS_REGION: z.string().optional(),
    SSL_PEM_BUCKET: z.string().optional(),
    SSL_PEM_KEY: z.string().optional(),
  },

  /**
   * Specify your client-side environment variables schema here. This way you can ensure the app
   * isn't built with invalid env vars. To expose them to the client, prefix them with
   * `NEXT_PUBLIC_`.
   */
  client: {
    // NEXT_PUBLIC_CLIENTVAR: z.string(),
  },

  /**
   * You can't destruct `process.env` as a regular object in the Next.js edge runtimes (e.g.
   * middlewares) or client-side so we need to destruct manually.
   */
  runtimeEnv: {
    NODE_ENV: process.env.NODE_ENV,
    // NEXT_PUBLIC_CLIENTVAR: process.env.NEXT_PUBLIC_CLIENTVAR,
    DB_HOST: process.env.DB_HOST,
    DB_DATABASE: process.env.DB_DATABASE,
    DB_PORT: process.env.DB_PORT,
    DB_USER: process.env.DB_USER,
    DB_PASS: process.env.DB_PASS,
    AWS_REGION: process.env.AWS_REGION,
    SSL_PEM_BUCKET: process.env.SSL_PEM_BUCKET,
    SSL_PEM_KEY: process.env.SSL_PEM_KEY,
  },
  /**
   * Run `build` or `dev` with `SKIP_ENV_VALIDATION` to skip env validation. This is especially
   * useful for Docker builds.
   */
  skipValidation: !!process.env.SKIP_ENV_VALIDATION,
  /**
   * Makes it so that empty strings are treated as undefined. `SOME_VAR: z.string()` and
   * `SOME_VAR=''` will throw an error.
   */
  emptyStringAsUndefined: true,
});
'@ | Set-Content -Path "env.js"

Write-Host " 📁  Moving back into project directory..."
Set-Location ..



#==========================
# 3. CREATE GITHUB REPO
#==========================
Write-Host "==================================="
Write-Host "CREATING GITHUB REPOSITORY"
Write-Host "==================================="

# Use GitHub CLI to create a new GitHub repo using the Fastify template
# and clone the new repo into the local repo folder we just created
Write-Host " 🆕  Creating GitHub Repo..."
gh repo create $projectName `
  --description $projectDesc `
  --public | Out-Null

# Since we're not cloning a repo, we'll need to add the remote directly here
# so that we can add the secrets in the next step
$awsGitHubRepoURL = "https://github.com/nblaisdell2/${projectName}.git"
git remote add origin $awsGitHubRepoURL

# Add necessary secrets for accessing CodeBuild via GitHub Actions
Write-Host " 🔐  Setting GitHub Secrets..."
gh secret set AWS_REGION -b $awsRegion | Out-Null
gh secret set AWS_ACCOUNT_ID -b $awsAccountID | Out-Null
gh secret set AWS_GHACTIONS_ROLENAME -b $awsGHActionRole | Out-Null



#==========================
# 4. SETUP TERRAFORM
#==========================
Write-Host "==================================="
Write-Host "SETTING UP TERRAFORM"
Write-Host "==================================="

# Create "/.terraform" folder
Write-Host " 🆕  Creating '/.terraform' folder..."
New-Item -ItemType Directory -Path '.terraform' | Out-Null

# Move into the "/.terraform" folder to perform Terraform actions for the project
Write-Host " 📁  Moving into Terraform directory..."
Set-Location -Path ".terraform"

# NOTE: 
#   The pattern below takes slightly more time, but makes startup of a new project much simpler.
#   If I define a snapshot for a database instance that's never existed, Terraform will give an error
#   So, to fix this, I'll create the instance *without* the snapshot, immediately destroy the instance,
#   which will trigger RDS to create a snapshot before destruction, and then I'll immedidately re-create
#   the instance using the snapshot.
#   That way, the user can start immediately and will be able to destroy the instance on their own behalf
#   without worrying about losing data

# Create main.tf file (*without* data resource for snapshot)
Write-Host " 🆕  Creating main.tf folder (defining PostgreSQL RDS instance)..."
@'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.94.1"
    }
  }
}

data "aws_db_snapshot" "latest" {
  count                  = var.use_latest_snapshot ? 1 : 0
  db_instance_identifier = var.db_identifier
  most_recent            = true
  snapshot_type          = "manual"
  # optional: add `depends_on` to ensure snapshots exist before reading
}

resource "aws_db_instance" "postgres" {
  identifier                = var.db_identifier
  instance_class            = "db.t3.micro"
  allocated_storage         = 100
  engine                    = "postgres"
  engine_version            = "17.4"
  port                      = var.db_port
  username                  = var.db_user
  password                  = var.db_pass
  db_name                   = var.db_database_name
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.db_identifier}-final-snapshot-${formatdate("YYYYMMDD-HHmmss", timestamp())}"
  publicly_accessible       = true

  # Conditionally use snapshot
  snapshot_identifier = var.use_latest_snapshot && length(data.aws_db_snapshot.latest) > 0 ? data.aws_db_snapshot.latest[0].id : null
  # snapshot_identifier = null // var.use_latest_snapshot ? data.aws_db_snapshot.latest.id : null

  # Optional tags
  tags = {
    Name        = "DevPostgresDB"
    Environment = "Dev"
  }

  lifecycle {
    ignore_changes = [
      snapshot_identifier # Prevent re-creation if a newer snapshot appears
    ]
  }
}

variable "db_identifier" {
  description = "The identifier for the postgres db instance"
  sensitive   = true
  type        = string
}

variable "db_pass" {
  description = "The password for the postgres db"
  sensitive   = true
  type        = string
}

variable "db_user" {
  description = "The user for the postgres db"
  sensitive   = true
  type        = string
}

variable "db_port" {
  description = "The port for the postgres db"
  sensitive   = true
  type        = number
}

variable "db_database_name" {
  description = "The name of the primary database in the postgres db"
  sensitive   = true
  type        = string
}

variable "use_latest_snapshot" {
  description = "Whether to restore the DB from the latest snapshot"
  type        = bool
  default     = false
}

variable "aws_account_id" {
  description = "Account ID of AWS account, prepended to ECR repo name"
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS Region to deploy the resources into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project to be deployed"
  type        = string
}

output "out_db_endpoint" {
  value = aws_db_instance.postgres.endpoint
}
'@ | Set-Content -Path "main.tf"

# Create terraform.tfvars file to securely store variables for main.tf Terraform script
Write-Host " 🆕  Creating terraform.tfvars file..."
$dbInstanceIdentifier = "postgres-${projectName}"
@"
db_identifier       = "${dbInstanceIdentifier}"
db_pass             = "${dbPass}"
db_user             = "postgres"
db_port             = 5432
db_database_name    = "${dbName}"
use_latest_snapshot = false # set to false to create from scratch
aws_account_id      = "${awsAccountID}"
aws_region          = "${awsRegion}"
project_name    = "${projectName}"
"@ | Set-Content -Path "terraform.tfvars"

# Run Terraform commands to initialize and provision RDS database
Write-Host " 🎬  Initialize Terraform..."
terraform init | Out-Null
Write-Host " 🆕  Creating PostgreSQL instance..."
terraform apply -auto-approve | Out-Null

# Obtain output variables for RDS db
$terraformOutput = terraform output -json | ConvertFrom-Json
$endpoint = $terraformOutput.out_db_endpoint.value

# Split endpoint into host & port 
#   value is returned in format: "{host}:{port}"
$parts = $endpoint -split ":"
$rdsHost = $parts[0]
$rdsPort = $parts[1]
$rdsUser = "postgres"

# Run terraform destroy to remove the newly created instance, 
# which will also trigger RDS to generate a snapshot for us
Write-Host " ❌  Destroying PostgreSQL instance..."
terraform destroy -auto-approve | Out-Null

# Re-create terraform.tfvars file (use_latest_snapshot = true)
Remove-Item 'terraform.tfvars'
@"
db_identifier       = "${dbInstanceIdentifier}"
db_pass             = "${dbPass}"
db_user             = "${rdsUser}"
db_port             = 5432
db_database_name    = "${dbName}"
use_latest_snapshot = true # set to false to create from scratch
aws_account_id      = "${awsAccountID}"
aws_region          = "${awsRegion}"
project_name    = "${projectName}"
"@ | Set-Content -Path "terraform.tfvars"

# Re-run terraform apply to bring the database instance back, using the snapshot going forward
Write-Host " 🆕  Re-creating PostgreSQL instance..."
terraform apply -auto-approve | Out-Null

# Move back into the project's root directory for the rest of the project setup
Write-Host " 📁  Moving back to project root directory..."
Set-Location ..



#==========================
# 5. INITIALIZE DATABASE
#==========================
Write-Host "==================================="
Write-Host "INITIALIZING DATABASE"
Write-Host "==================================="

if (-not (Test-Path $dbInitPath)) {
  Write-Host "No database init script found at '$dbInitPath'. Skipping..."
}
else {
  # Wait 10 seconds to give the RDS instance some time when coming online
  Write-Host " 😴  Sleeping for 10 seconds..."
  Start-Sleep -Seconds 10
    
  # Initialize the database with a SQL initialization script, for defining tables/functions/etc.
  Write-Host " 🎬  Initializing database..."
  $env:PGPASSWORD = $dbPass
  psql -h $rdsHost -p 5432 -U $rdsUser -d $dbName -f $dbInitPath
  Remove-Item Env:PGPASSWORD
}



#==========================
# 6. CREATE AWS INFRA
#==========================
Write-Host "==================================="
Write-Host "CREATING AWS INFRASTRUCTURE"
Write-Host "==================================="
Write-Host "-----------------------------------"
Write-Host "      CONNECTING TO AWS ECR        "
Write-Host "-----------------------------------"

# login to ECR for Docker
Write-Host " 🔑  Logging into ECR..."
aws ecr get-login-password --region $awsRegion | docker login --username "AWS" --password-stdin "${awsAccountID}.dkr.ecr.${awsRegion}.amazonaws.com" | Out-Null

# Create a new repository within ECR for this new project's Docker images
Write-Host " 🆕  Creating ECR Repository..."
aws ecr create-repository `
  --repository-name $projectName `
  --image-scanning-configuration "scanOnPush=true" `
  --image-tag-mutability "MUTABLE" | Out-Null


Write-Host "-----------------------------------"
Write-Host "     BUILDING DOCKER CONTAINER     "
Write-Host "-----------------------------------"

# Build the Docker container and set it up (tag the container) 
# to get ready to be uploaded to ECR. Then, push to ECR.
Write-Host " 🛠️   Building container..."
docker build -t "${projectName}:latest" . | Out-Null
Write-Host " 🏷️   Tagging container..."
docker tag "${projectName}:latest" "${awsAccountID}.dkr.ecr.${awsRegion}.amazonaws.com/${projectName}:latest" | Out-Null
Write-Host " 🚀  Pushing container to ECR..."
docker push "${awsAccountID}.dkr.ecr.${awsRegion}.amazonaws.com/${projectName}:latest" | Out-Null


Write-Host "-----------------------------------"
Write-Host "        CREATING S3 BUCKET         "
Write-Host "-----------------------------------"

# Download RDS certificate for connecting to instance via SSL
$pemSource = "https://truststore.pki.rds.amazonaws.com/${awsRegion}/${awsRegion}-bundle.pem"
$pemFileName = "${awsRegion}-bundle.pem"

Invoke-WebRequest -Uri $pemSource -OutFile $pemFileName

# Create S3 bucket for project and place the .pem file in the bucket
$bucketName = "${projectName}-$(New-Random-String)"
aws s3api create-bucket `
  --bucket $bucketName `
  --region $awsRegion | Out-Null

aws s3 cp $pemFileName s3://$bucketName/ | Out-Null

Remove-Item $pemFileName

Write-Host "-----------------------------------"
Write-Host "     CREATING SECRETS MANAGER      "
Write-Host "-----------------------------------"

# Create a secrets repository within Secrets Manager to house our environment variables
# for the project, rather than storing them in plaintext on the Lambda itself
Write-Host " 🆕  Creating new secret in Secrets Manager..."

# Generate a name for the secrets
$secretID = "${projectName}/secrets-$(New-Random-String)"

# Define key-value pairs as a hashtable
$secretString = Get-JSON-Path -FileName "secret-string-vars.json" -JSON_In @{
  DB_HOST        = "${rdsHost}"
  DB_DATABASE    = "${dbName}"
  DB_PORT        = "${rdsPort}"
  DB_USER        = "${rdsUser}"
  DB_PASS        = "${dbPass}"
  AWS_REGION     = "${awsRegion}"
  SSL_PEM_BUCKET = "${bucketName}"
  SSL_PEM_KEY    = "${pemFileName}"
}

# Create the secret in Secrets Manager, using the key/value pairs above
$secretARN = aws secretsmanager create-secret `
  --name $secretID `
  --description "Environment variables for ${projectName}" `
  --secret-string file://$secretString | ConvertFrom-Json | Select-Object -ExpandProperty ARN


Write-Host "-----------------------------------"
Write-Host "    CREATING APPRUNNER SERVICE     "
Write-Host "-----------------------------------"

$sourceConfig = Get-JSON-Path -FileName "apprunner-source-config.json" -JSON_In @{
  ImageRepository             = @{
    ImageIdentifier     = "${awsAccountID}.dkr.ecr.${awsRegion}.amazonaws.com/${projectName}:latest"
    ImageConfiguration  = @{
      Port                        = "3000"
      RuntimeEnvironmentVariables = @{
        "HOSTNAME" = "0.0.0.0"
      }
      RuntimeEnvironmentSecrets   = @{
        "SECRET_ID" = "$secretARN"
      }
    }
    ImageRepositoryType = "ECR"
  }
  AutoDeploymentsEnabled      = $false
  AuthenticationConfiguration = @{
    AccessRoleArn = "arn:aws:iam::387815262971:role/service-role/AppRunnerECRAccessRole123"
  }
}
$instanceConfig = Get-JSON-Path -FileName "apprunner-instance-config.json" -JSON_In @{
  Cpu             = "1 vCPU"
  Memory          = "2 GB"
  InstanceRoleArn = "arn:aws:iam::387815262971:role/apprunner-secret-role"
}

# Create a new AppRunner service for hosting our site
$serviceName = "${projectName}-service"
$serviceOutput = aws apprunner create-service `
  --service-name $serviceName `
  --source-configuration file://$sourceConfig `
  --instance-configuration file://$instanceConfig `
  --query '{OperationId: OperationId, ServiceUrl: Service.ServiceUrl, ServiceArn: Service.ServiceArn}' | ConvertFrom-Json

$serviceARN = $serviceOutput.ServiceArn
$serviceURL = $serviceOutput.ServiceUrl


Write-Host "-----------------------------------"
Write-Host "    CREATING CODEBUILD PROJECT     "
Write-Host "-----------------------------------"

# Create the policy for allowing the usage of CodeBuild for GH Actions
$awsCodeBuildAssumeRolePolicy = Get-JSON-Path -FileName "codebuild-assume-role-policy.json" -JSON_In @{
  Version   = "2012-10-17"
  Statement = @(
    @{
      Effect    = "Allow"
      Principal = @{ Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }
  )
}

# Create the policy for what the role is allowed to interact with
#   CodeDeploy/CodeBuild - allow to call deployments and builds
#   ECR - allow for reading images from ECR
#   Logs - Needed to write logs to CloudWatch
#   Lambda - Needed to update Lambda / create new lambda alias/version
$awsCodeBuildPolicy = Get-JSON-Path -FileName "codebuild-policy.json" -JSON_In @{
  Version   = "2012-10-17"
  Statement = @(
    @{
      Sid      = "Auth0"
      Effect   = "Allow"
      Action   = @(
        "codedeploy:*"
        "codebuild:*"
        "ecr:*"
        "logs:*"
        "apprunner:*"
      )
      Resource = "*"
    }
  )
}

# Create the CodeBuild role with the AssumeRole policy created above
# and extract the ARN of the newly created role
Write-Host " 🆕  Creating CodeBuild role..."
$awsCodeBuildRoleName = "codebuild-${projectName}-role"
$awsCodeBuildRoleArn = aws iam create-role `
  --role-name $awsCodeBuildRoleName `
  --assume-role-policy-document file://$awsCodeBuildAssumeRolePolicy | ConvertFrom-Json | Select-Object -ExpandProperty Role | Select-Object -ExpandProperty Arn
  
# Use the role ARN we just obtained to attach the other policy defined above
aws iam put-role-policy `
  --role-name $awsCodeBuildRoleName `
  --policy-name "codebuild-${projectName}-policy" `
  --policy-document file://$awsCodeBuildPolicy | Out-Null

# Wait 10 seconds for the role to be propogated across services
Write-Host " 😴  Sleeping for 10 seconds..."
Start-Sleep -Seconds 10

# Define the source for a CodeBuild project, which will point to our newly created
# GitHub repo to integrate CodeBuild with our GitHub Actions script
$source = Get-JSON-Path -FileName "codebuild-project-source.json" -JSON_In @{
  type              = "GITHUB"
  location          = $awsGitHubRepoURL
  reportBuildStatus = $true
}

# Nothing will be generated from the builds, since the images are stored in ECR
# and its all that's needed
$artifacts = Get-JSON-Path -FileName "codebuild-project-artifacts.json" -JSON_In @{
  type = "NO_ARTIFACTS"
}

# Define the environment for the CodeBuild execution, as well as any environment
# variables needed for the "buildspec.yml" file
$environment = Get-JSON-Path -FileName "codebuild-project-env.json" -JSON_In @{
  type                     = "LINUX_CONTAINER"
  image                    = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
  computeType              = "BUILD_GENERAL1_SMALL"
  privilegedMode           = $true
  imagePullCredentialsType = "CODEBUILD"
  environmentVariables     = @(
    @{ name = "awsRegion"; value = $awsRegion; type = "PLAINTEXT" }
    @{ name = "awsAccountID"; value = $awsAccountID; type = "PLAINTEXT" }
    @{ name = "dockerContainerName"; value = $projectName; type = "PLAINTEXT" }
    @{ name = "serviceARN"; value = $serviceARN; type = "PLAINTEXT" }
  )
}

# Create the CodeBuild project, using the above parameters/configurations/roles
Write-Host " 🆕  Creating CodeBuild project..."
aws codebuild create-project `
  --name $projectName `
  --source file://$source `
  --artifacts file://$artifacts `
  --environment file://$environment `
  --service-role $awsCodeBuildRoleArn | Out-Null


Write-Host "-----------------------------------"
Write-Host "    CREATING CODEDEPLOY PROJECT    "
Write-Host "-----------------------------------"
# Create the policy for allowing the usage of CodeDeploy for GH Actions
$awsCodeDeployAssumeRolePolicyDocument = Get-JSON-Path -FileName "codedeploy-assume-role-policy.json" -JSON_In @{
  Version   = "2012-10-17"
  Statement = @(
    @{
      Effect    = "Allow"
      Principal = @{
        Service = "codedeploy.amazonaws.com"
      }
      Action    = "sts:AssumeRole"
    }
  )
}

$awsCodeDeployAppRunnerPolicyDocument = Get-JSON-Path -FileName "codedeploy-apprunner-policy.json" -JSON_In @{
  Version   = "2012-10-17"
  Statement = @(
    @{
      Effect   = "Allow"
      Action   = @(
        "apprunner:StartDeployment"
      )
      Resource = "${serviceARN}"
    }
  )
}

# Create the CodeDeploy role using the assume role policy above and Extract the role ARN
$awsCodeDeployRoleName = "codedeploy-${projectName}-role"
Write-Host " 🆕  Creating CodeDeploy role..."
$awsCodeDeployRoleArn = aws iam create-role `
  --role-name $awsCodeDeployRoleName `
  --assume-role-policy-document file://$awsCodeDeployAssumeRolePolicyDocument | ConvertFrom-Json | Select-Object -ExpandProperty Role | Select-Object -ExpandProperty Arn

# Attach two managed AWS policies to the newly created CodeDeploy role 
# for interacting with ECR and CodeDeploy (specifically for Lambda)
aws iam attach-role-policy `
  --role-name $awsCodeDeployRoleName `
  --policy-arn "arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicFullAccess" | Out-Null

# Use the role ARN we just obtained to attach the other policy defined above
aws iam put-role-policy `
  --role-name $awsCodeDeployRoleName `
  --policy-name "codedeploy-${projectName}-apprunner-policy" `
  --policy-document file://$awsCodeDeployAppRunnerPolicyDocument | Out-Null

# Wait 10 seconds for the role to be propogated across services
Write-Host " 😴  Sleeping for 10 seconds..."
Start-Sleep -Seconds 10

# Create the CodeDeploy application, which will be executed via a Lambda function
Write-Host " 🆕  Creating CodeDeploy application..."
aws deploy create-application `
  --application-name "${projectName}-deploy" `
  --compute-platform "Lambda" | Out-Null

# Define a deployment group for the CodeDeploy project
$awsCodeBuildDeployStyle = Get-JSON-Path -FileName "codebuild-deploy-style.json" -JSON_In @{
  deploymentType   = "BLUE_GREEN"
  deploymentOption = "WITH_TRAFFIC_CONTROL"
}
Write-Host " 🆕  Creating CodeDeploy deployment group..."
aws deploy create-deployment-group `
  --application-name "${projectName}-deploy" `
  --deployment-group-name "${projectName}-deploy-group" `
  --service-role-arn $awsCodeDeployRoleArn `
  --deployment-style file://$awsCodeBuildDeployStyle | Out-Null



#==========================
# 7. SETUP LOCAL REPO
#==========================
Write-Host "==================================="
Write-Host "SETTING UP LOCAL REPO"
Write-Host "==================================="

# Add GitHub Actions workflow file
# Ensure the folder structure exists
$folderPath = ".github/workflows"
if (-not (Test-Path $folderPath)) {
  New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
}

@'
# This workflow will do a clean installation of node dependencies, cache/restore them, build the source code and run tests across different versions of node
# For more information see: https://docs.github.com/en/actions/automating-builds-and-tests/building-and-testing-nodejs

name: Node.js CI

# Needed to work with AWS Credentials & AWS CodeBuild
permissions:
  id-token: write
  contents: read

on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["main"]

jobs:
  build:
    # 👇 Skip build if commit message contains [skip ci]
    if: ${{ github.event.head_commit.message != 'Initial commit' }}
    runs-on: ubuntu-latest

    strategy:
      matrix:
        node-version: [20.x]
        # See supported Node.js release schedule at https://nodejs.org/en/about/releases/

    steps:
      - name: Checking out source code
        uses: actions/checkout@v3
      - name: Use Node.js ${{ matrix.node-version }}
        uses: actions/setup-node@v3
        with:
          node-version: ${{ matrix.node-version }}
          cache: "npm"
      - name: Install Dependencies
        run: npm ci
      - name: Build the Application
        run: npm run build --if-present
      # - name: Test the Application
      #   run: npm test
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/${{ secrets.AWS_GHACTIONS_ROLENAME }}
          aws-region: ${{ secrets.AWS_REGION }}
      - name: Running AWS CodeBuild
        uses: aws-actions/aws-codebuild-run-build@v1.0.12
        with:
          project-name: ${{ github.event.repository.name }}
'@ | Set-Content -Path "$folderPath/build.yml"

# Add buildspec.yml file
@'
version: 0.2

phases:
  pre_build:
    commands:
      - echo "Logging in to Amazon ECR..."
      - aws ecr get-login-password --region $awsRegion | docker login --username AWS --password-stdin $awsAccountID.dkr.ecr.$awsRegion.amazonaws.com
  build:
    commands:
      - echo "Building the Docker image..."
      - docker build -t $dockerContainerName:latest .
      - docker tag $dockerContainerName:latest $awsAccountID.dkr.ecr.$awsRegion.amazonaws.com/$dockerContainerName:latest
  post_build:
    commands:
      - echo "Pushing container to ECR..."
      - docker push $awsAccountID.dkr.ecr.$awsRegion.amazonaws.com/$dockerContainerName:latest
      - aws apprunner start-deployment --service-arn $serviceARN
'@ | Set-Content -Path "buildspec.yml"

# Add "patch-server.js" script to add a block of code to the generated server.js file 
# (as part of the NextJS build process) to make sure app has access to secrets in AWS Secrets Manager
@"
import fs from "fs";
import path from "path";

const serverJsPath = path.resolve(".next/standalone/server.js");

// Load the existing content
let serverJs = fs.readFileSync(serverJsPath, "utf8");

// Prepare the patch code to inject at the top
const injectCode = `
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

const client = new SecretsManagerClient({ region: "${awsRegion}" });

async function loadSecrets() {
  const command = new GetSecretValueCommand({ SecretId: process.env.SECRET_ID });
  const response = await client.send(command);
  const secrets = JSON.parse(response.SecretString);
  for (const [key, value] of Object.entries(secrets)) {
    if (!process.env[key]) {
      process.env[key] = value;
    }
  }
}

// Block the app from starting until secrets are loaded
await loadSecrets();
`;

// Inject the code after the first import statements
// We'll find the first line that starts with a comment or executable code
const insertPoint = serverJs.indexOf("\n");

serverJs = serverJs.slice(0, insertPoint) + "\n" + injectCode + serverJs.slice(insertPoint);

// Write the modified file back
fs.writeFileSync(serverJsPath, serverJs);

console.log("✅ Patched server.js with AWS Secrets Manager bootstrap code");
"@ | Set-Content -Path "patch-server.js"

# Create LOCAL .env file (connects to local PostgreSQL instance, for development/testing)
Write-Host " 🆕  Creating .env file..."
Remove-Item ".env"
@"
# Port for the Fastify API to run on
PORT="3000"

## AWS Secrets Manager secret ID (for environment variables)
#SECRET_ID="$secretID"

# PostgreSQL database connection details
DB_HOST="localhost"
DB_DATABASE="$dbName"
DB_PORT="5432"
DB_USER="$rdsUser"
DB_PASS="Super!345Q"

## Uncomment to connect to RDS instance
#AWS_REGION="$awsRegion"
#SSL_PEM_BUCKET="$bucketName"
#SSL_PEM_KEY="$pemFileName"

"@ | Set-Content -Path ".env"

# Create PROD .env file (connects to RDS PostgreSQL instance, for production)
Write-Host " 🆕  Creating .env.prod file..."
@"
# Port for the Fastify API to run on
PORT="3000"

# AWS Secrets Manager secret ID (for environment variables)
SECRET_ID="$secretID"

# PostgreSQL database connection details
DB_HOST="$rdsHost"
DB_DATABASE="$dbName"
DB_PORT="$rdsPort"
DB_USER="$rdsUser"
DB_PASS="$dbPass"

AWS_REGION="$awsRegion"
SSL_PEM_BUCKET="$bucketName"
SSL_PEM_KEY="$pemFileName"
"@ | Set-Content -Path ".env.prod"

# Create 'update-secrets.ps1' file
Write-Host " 🆕  Creating update-secrets.ps1 file..."
$hereStringSecret = @'
$envFile = ".env.prod"
$secretID = "{{MY_SECRET}}"

Write-Host " 🔐  Syncing environment variables from '${envFile}' to AWS Secrets Manager secret '${secretID}'..."

# Get current secret from Secrets Manager (default to empty object if not found)
try {
    $currentSecretJson = aws secretsmanager get-secret-value --secret-id $secretID | ConvertFrom-Json
    $currentSecret = $currentSecretJson.SecretString | ConvertFrom-Json
}
catch {
    Write-Host " ⚠️  Secret not found or empty. Starting with a new one."
    $currentSecret = @{}
}

# Read and parse the .env file
$envVars = @{}

Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { return }

    $parts = $line -split '=', 2
    if ($parts.Count -ne 2) { return }

    $key = $parts[0].Trim()
    $value = $parts[1].Trim().Trim('"')  # Remove surrounding quotes if present
    if (-not $key -or -not $value) { return }

    $envVars[$key] = $value
}

# Merge missing or changed keys
$updated = $false

foreach ($key in $envVars.Keys) {
    $newValue = $envVars[$key]
    if ($currentSecret.PSObject.Properties.Name -notcontains $key) {
        Write-Host " ➕  Adding $key..."
        $currentSecret | Add-Member -NotePropertyName $key -NotePropertyValue $newValue -Force
        $updated = $true
    } elseif ($currentSecret.$key -ne $newValue) {
        Write-Host " 🔄  Updating $key..."
        $currentSecret | Add-Member -NotePropertyName $key -NotePropertyValue $newValue -Force
        $updated = $true
    }
}

if ($updated) {
    $updatedSecretJson = $currentSecret | ConvertTo-Json -Depth 100 -Compress
    Write-Host " 🚀  Updating secret in AWS..."
    aws secretsmanager update-secret `
        --secret-id $secretID `
        --secret-string "$updatedSecretJson" | Out-Null
    Write-Host " ✅  Secret updated successfully."
}
else {
    Write-Host " ✅  No changes needed. Secret is up-to-date."
}
'@ 
$hereStringSecret = $hereStringSecret.Replace("{{MY_SECRET}}", $secretID)
$hereStringSecret | Set-Content -Path "update-secrets.ps1"

# Update .gitignore/.dockerignore files
@'

# Terraform
.terraform/

.env.prod
'@ | Add-Content -Path ".gitignore"
@'

# Terraform
.terraform/

.env.prod
'@ | Add-Content -Path ".dockerignore"

# Load and parse package.json
$packageJsonPath = "package.json"
$packageJson = Get-Content $packageJsonPath -Raw | ConvertFrom-Json

# Ensure 'scripts' exists
if (-not $packageJson.PSObject.Properties['scripts']) {
  $packageJson | Add-Member -MemberType NoteProperty -Name scripts -Value ([PSCustomObject]@{})
}

# Convert scripts to a hashtable so we can add properties
$scripts = @{}

# Copy existing properties from JSON to the hashtable
$packageJson.scripts.PSObject.Properties | ForEach-Object {
  $scripts[$_.Name] = $_.Value
}

# Modify/add properties safely
$scripts['build'] = "next build && node patch-server.js"
$scripts['secrets'] = "pwsh -ExecutionPolicy Bypass -File ./update-secrets.ps1"

# Reassign modified scripts back to the packageJson object
$packageJson.scripts = [PSCustomObject]$scripts

# Convert back to JSON and save
$packageJson | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $packageJsonPath



#==========================
# 8. PUSH REPO TO GITHUB
#==========================
Write-Host "==================================="
Write-Host "PUSHING CODE TO GITHUB"
Write-Host "==================================="

# Push the code to GitHub, triggering a GitHub actions build
Write-Host " 🚀  Pushing code to GitHub..."
git add . | Out-Null
git commit -m "Initial commit" | Out-Null
git push -u origin main | Out-Null



#==========================
# 9. WAIT FOR APPRUNNER SERVICE
#==========================
Write-Host "==================================="
Write-Host "WAIT FOR APPRUNNER SERVICE"
Write-Host "==================================="

# Get the Service Operation ID from the creation of our AppRunner service
# from the earlier AWS Infrastructrue step, so we can determine if the service
# is up-and-running yet, or if it's still in progress
$serviceOpId = $serviceOutput.OperationId

# Wait for the AppRunner Service to be available before opening the project,
# so the user is able to navigate to the live site immediately upon development
Wait-ForAWSResource -ResourceName $serviceName -DelaySeconds 60 -Command {
  $serviceStatus = aws apprunner list-operations --service-arn $serviceARN | ConvertFrom-Json | Select-Object -ExpandProperty OperationSummaryList | Where-Object { $_.Id -eq $serviceOpId } | Select-Object -ExpandProperty Status
  if ($serviceStatus -ne "SUCCEEDED") {
    cmd /c exit 20
  }
}


#==========================
# 10. OUTPUTS
#==========================
Write-Host "==================================="
Write-Host "OUTPUTS"
Write-Host "==================================="

# Print any useful outputs from the script for the user to note down or copy elsewhere
Write-Host ""
Write-Host "New Project Name : ${projectName}"
Write-Host "GitHub Repo URL  : https://github.com/nblaisdell2/${projectName}"
Write-Host "Site URL         : ${serviceURL}"
Write-Host "Database Endpoint: ${rdsHost}"

# Wait for the user to enter any key at this point
Write-Host ""
Write-Host "Once the values have been copied/noted, press any key to open project in VS Code..."
$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null



#==========================
# 11. OPEN PROJECT
#==========================
# Lastly, open the current directory (the project directory) in VS Code to start developing!
code .

# Exit the script successfully
exit 0
