# Usage: ./create-site-project <projects-path> <project-name> <project-desc> <database-name> <db-password> <db-init-path> <aws-account-id> <aws-region> <gh-actions-role-name> [-Force]
# -Force: Recreate existing AWS resources instead of reusing them

param(
  [string]$projectsPath,
  [string]$projectName,
  [string]$projectDesc,
  [string]$dbName,
  [string]$dbPass,
  [string]$dbInitPath,
  [string]$awsAccountID,
  [string]$awsRegion,
  [string]$awsGHActionRole,
  [switch]$Force,
  [switch]$Delete
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
        Write-LogMessage -Icon ⚠️ -Message "$label is required!"
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
        Write-LogMessage -Icon ✅ -Message "Resource '${ResourceName}' is now available!"
        break
      }
    }
    catch {
      # Optional: log or handle error
      Write-LogMessage -Icon ❌ -Message "Error finding resource ${ResourceName}!"
      exit 1
    }

    Write-LogMessage -Icon ⏳ -Message "Waiting for resource '${ResourceName}' to be ready..."
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

# Function for checking if an AWS resource already exists
# Returns $true if resource exists, $false otherwise
function Test-AWSResourceExists {
  param(
    [string]$ResourceType,
    [string]$ResourceName,
    [ScriptBlock]$CheckCommand
  )

  try {
    $result = & $CheckCommand 2>$null
    if ($LASTEXITCODE -eq 0 -and $result) {
      Write-LogMessage -Icon ℹ️ -Message "$ResourceType '$ResourceName' already exists"
      return $true
    }
    return $false
  }
  catch {
    return $false
  }
}

# Function to check if Docker daemon is running
function Test-DockerRunning {
  try {
    docker info 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
  }
}

# Function to start Docker Desktop and wait for it to be ready
function Start-DockerDesktop {
  $dockerPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
  if (Test-Path $dockerPath) {
    Write-LogMessage -Icon 🐳 -Message "Starting Docker Desktop..."
    Start-Process $dockerPath

    # Wait for Docker to be ready (up to 60 seconds)
    $timeout = 60
    $elapsed = 0
    while (-not (Test-DockerRunning) -and $elapsed -lt $timeout) {
      Start-Sleep -Seconds 5
      $elapsed += 5
      Write-LogMessage -Icon ⏳ -Message "Waiting for Docker to start... ($elapsed/$timeout seconds)"
    }

    return Test-DockerRunning
  }
  return $false
}

function Write-LogMessage {
  param(
    [string]$Icon,
    [string]$Message
  )

  Write-Host " $Icon  $Message"
}

###################################################################################################



#==========================
# 1. USER INPUT
#==========================
Write-Host "==================================="
Write-Host "GETTING USER INPUT"
Write-Host "==================================="

# First, move to my Project folder
Write-LogMessage -Icon 📁 -Message "Moving into local project directory: '$projectsPath'"
Set-Location -Path $projectsPath

# Get User Input for the needed variables for the rest of the script
# Allow for default values for _some_ variables
$projectName = Get-User-Input -var $projectName -label "Project name" 

## Remove folder before creating
# if (Test-Path -Path $projectName -PathType Container) {
#     Remove-Item -Path $projectName -Recurse -Force
# }

# If it does, exit here and allow the user to try again with another project name
if ((Test-Path -Path $projectName -PathType Container) -and -not $Delete) {
  Write-LogMessage -Icon ⚠️ -Message "Error: A folder named '$projectName' already exists. Please choose a different name."
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

# Check if local project folder already exists
$localRepoExists = Test-Path -Path $projectName -PathType Container

if ($localRepoExists) {
  if (-not $Force -and -not $Delete) {
    Write-LogMessage -Icon ℹ️ -Message "Local folder '$projectName' already exists, reusing..."
    Write-LogMessage -Icon 📁 -Message "Moving into local project directory..."
    Set-Location -Path $projectName
  } else {
    Write-LogMessage -Icon 🗑️ -Message "Force/Delete flag set - Deleting local repository/folder"
    Remove-Item -Recurse -Force -Path $projectName
  }
} elseif (-not $Delete) {
  # Create a new project using Create-T3-app, providing a best-practice NextJS application
  # https://create.t3.gg/
  #   This project template will be using TypeScript, Tailwind (for CSS/styling), AppRouter (new layouts for NextJS)
  #   and tRPC for end-to-end typescript support for APIs!
  npx create-t3-app@latest $projectName --CI --trpc --tailwind --appRouter --dbProvider postgres
  Write-LogMessage -Icon ✅ -Message "Folder '$projectName' created successfully."

  # Move into the local directory for the rest of the steps
  Write-LogMessage -Icon 📁 -Message "Moving into local project directory..."
  Set-Location -Path $projectName

  # Install extra npm libraries/packages
  Write-LogMessage -Icon "  🛠️" -Message "Installing additionall npm packages..."
  npm install @aws-sdk/client-secrets-manager @aws-sdk/client-s3 pg | Out-Null
  npm install -D @types/pg | Out-Null
}

# Only create project files if this is a new project
if (-not $localRepoExists -and -not $Delete) {

# Add the Dockerfile necessary for containerizing the application
# Sourced from: https://create.t3.gg/en/deployment/docker#3-create-dockerfile
Write-LogMessage -Icon "  🆕" -Message "Creating 'Dockerfile' file"
@'
##### DEPENDENCIES

ARG TARGETPLATFORM=linux/amd64

FROM --platform=$TARGETPLATFORM node:20-alpine AS deps
RUN apk add --no-cache libc6-compat openssl
WORKDIR /app

# Install dependencies based on the preferred package manager

COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* ./

RUN \
    if [ -f yarn.lock ]; then yarn --frozen-lockfile; \
    elif [ -f package-lock.json ]; then npm ci; \
    elif [ -f pnpm-lock.yaml ]; then npm install -g pnpm && pnpm i; \
    else echo "Lockfile not found." && exit 1; \
    fi

##### BUILDER

FROM --platform=$TARGETPLATFORM node:20-alpine AS builder
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

FROM --platform=$TARGETPLATFORM gcr.io/distroless/nodejs20-debian12 AS runner
WORKDIR /app

ENV NODE_ENV=production

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
ENV PORT=3000

CMD ["server.js"]
'@ | Set-Content -Path "Dockerfile"

# Add the .dockerignore necessary for containerizing the application
# Sourced from: https://create.t3.gg/en/deployment/docker#2-create-dockerignore-file
Write-LogMessage -Icon "  🆕" -Message "Creating '.dockerignore' file"
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
Write-LogMessage -Icon "  🆕" -Message "Creating 'next.config.js' file"
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

Write-LogMessage -Icon "  🆕" -Message "Creating '$folderPath/db.ts' file"
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

Write-LogMessage -Icon 📁 -Message "Moving into project 'src' directory..."
Set-Location -Path "src"

Write-LogMessage -Icon "  🆕" -Message "Creating 'env.js' file"
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

Write-LogMessage -Icon 📁 -Message "Moving back into project directory..."
Set-Location ..

} # End of if (-not $localRepoExists)



#==========================
# 3. CREATE GITHUB REPO
#==========================
Write-Host "==================================="
Write-Host "CREATING GITHUB REPOSITORY"
Write-Host "==================================="

$awsAccount = gh api user -q ".login" 2>$null
$awsProject = "${awsAccount}/${projectName}"
$awsGitHubRepoURL = "https://github.com/${awsProject}.git"

# Check if GitHub repo already exists
$ghRepoExists = $false
try {
  gh repo view $awsProject 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $ghRepoExists = $true
    Write-LogMessage -Icon ℹ️ -Message "GitHub repo '${awsProject}' already exists"
  }
} catch { }

if ($ghRepoExists -and ($Force -or $Delete)) {
  Write-LogMessage -Icon 🗑️ -Message "Deleting GitHub repo '${awsProject}'..."
  gh repo delete $awsProject --yes | Out-Null
  $ghRepoExists = $false
}

if (-not $ghRepoExists -and -not $Delete) {
  # Use GitHub CLI to create a new GitHub repo
  Write-LogMessage -Icon 🆕 -Message "Creating GitHub Repo..."
  gh repo create $projectName `
    --description $projectDesc `
    --public | Out-Null
}

if (-not $Delete) {
  # Ensure remote is set up (add if not exists, or skip if already there)
  $existingRemote = git remote get-url origin 2>$null
  if (-not $existingRemote) {
    Write-LogMessage -Icon 🔗 -Message "Adding git remote origin..."
    git remote add origin $awsGitHubRepoURL
  } else {
    Write-LogMessage -Icon ℹ️ -Message "Git remote origin already configured"
  }
  
  # Add necessary secrets for accessing CodeBuild via GitHub Actions
  # (gh secret set is idempotent - it will update if exists)
  Write-LogMessage -Icon 🔐 -Message "Setting GitHub Secrets..."
  gh secret set AWS_REGION -b $awsRegion | Out-Null
  gh secret set AWS_ACCOUNT_ID -b $awsAccountID | Out-Null
  gh secret set AWS_GHACTIONS_ROLENAME -b $awsGHActionRole | Out-Null
}



#==========================
# 4. SETUP TERRAFORM
#==========================
Write-Host "==================================="
Write-Host "SETTING UP TERRAFORM"
Write-Host "==================================="

# Check if RDS instance already exists
$dbInstanceIdentifier = "postgres-${projectName}"
$rdsUser = "postgres"

$rdsInstanceExists = Test-AWSResourceExists -ResourceType "RDS Instance" -ResourceName $dbInstanceIdentifier -CheckCommand {
  aws rds describe-db-instances --db-instance-identifier $dbInstanceIdentifier
}

# If RDS exists and not forcing, get endpoint and skip Terraform
if ($rdsInstanceExists -and -not ($Force -or $Delete)) {
  Write-LogMessage -Icon ⏭️ -Message "Skipping Terraform setup - RDS instance already exists"

  # Get endpoint from existing instance
  $existingDb = aws rds describe-db-instances --db-instance-identifier $dbInstanceIdentifier | ConvertFrom-Json
  $rdsHost = $existingDb.DBInstances[0].Endpoint.Address
  $rdsPort = $existingDb.DBInstances[0].Endpoint.Port

  Write-LogMessage -Icon ℹ️ -Message "Using existing RDS endpoint: ${rdsHost}:${rdsPort}"
} else {
  # If forcing and exists, delete the existing RDS instance first
  if ($rdsInstanceExists -and ($Force -or $Delete)) {
    Write-LogMessage -Icon 🗑️ -Message "Force/Delete flag set - Deleting existing RDS instance..."
    # Delete the RDS instance (skip final snapshot to speed up deletion)
    aws rds delete-db-instance `
      --db-instance-identifier $dbInstanceIdentifier `
      --skip-final-snapshot `
      --delete-automated-backups | Out-Null

    # Wait for the instance to be fully deleted
    Write-LogMessage -Icon ⏳ -Message "Waiting for RDS instance to be deleted (this may take several minutes)..."
    aws rds wait db-instance-deleted --db-instance-identifier $dbInstanceIdentifier | Out-Null

    Write-LogMessage -Icon ✅ -Message "RDS instance deleted successfully"
  }

  if (-not $Delete) {
    # Create "/.terraform" folder
    if (-not (Test-Path '.terraform')) {
      Write-LogMessage -Icon 🆕 -Message "Creating '/.terraform' folder..."
      New-Item -ItemType Directory -Path '.terraform' | Out-Null
    }
  
    # Move into the "/.terraform" folder to perform Terraform actions for the project
    Write-LogMessage -Icon 📁 -Message "Moving into Terraform directory..."
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
Write-LogMessage -Icon "  🆕" -Message "Creating 'main.tf' file (defining PostgreSQL RDS instance)..." 
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
Write-LogMessage -Icon "  🆕" -Message "Creating terraform.tfvars file..."
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
Write-LogMessage -Icon 🎬 -Message "Initializing Terraform..."
terraform init | Out-Null
Write-LogMessage -Icon 🆕 -Message "Creating PostgreSQL instance..."
terraform apply -auto-approve | Out-Null 

# Obtain output variables for RDS db
$terraformOutput = terraform output -json | ConvertFrom-Json
$endpoint = $terraformOutput.out_db_endpoint.value

# Split endpoint into host & port
#   value is returned in format: "{host}:{port}"
$parts = $endpoint -split ":"
$rdsHost = $parts[0]
$rdsPort = $parts[1]

# Run terraform destroy to remove the newly created instance, 
# which will also trigger RDS to generate a snapshot for us
Write-LogMessage -Icon ❌ -Message "Destroying PostgreSQL instance..."
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
Write-LogMessage -Icon ⬆️ -Message "Re-creating PostgreSQL instance..."
terraform apply -auto-approve | Out-Null

# Move back into the project's root directory for the rest of the project setup
Write-LogMessage -Icon 📁 -Message "Moving back to project root directory..."
Set-Location ..
} # End of else block for (-not $Delete)
  } # End of else block for Terraform setup
  



#==========================
# 5. INITIALIZE DATABASE
#==========================
Write-Host "==================================="
Write-Host "INITIALIZING DATABASE"
Write-Host "==================================="

if (-not $Delete) {
  # Only initialize database if RDS was newly created (not reusing existing)
  if ($rdsInstanceExists -and -not $Force) {
    Write-LogMessage -Icon ⏭️ -Message "Skipping database initialization - using existing RDS instance"
  } elseif (-not (Test-Path $dbInitPath)) {
    Write-LogMessage -Icon 🤷 -Message "No database init script found at '$dbInitPath'. Skipping..."
  } else {
    # Wait 10 seconds to give the RDS instance some time when coming online
    Write-LogMessage -Icon 😴 -Message "Sleeping for 10 seconds..."
    Start-Sleep -Seconds 10
  
    # Initialize the database with a SQL initialization script, for defining tables/functions/etc.
    Write-LogMessage -Icon 🎬 -Message "Initializing database..."
    $env:PGPASSWORD = $dbPass
    psql -h $rdsHost -p 5432 -U $rdsUser -d $dbName -f $dbInitPath
    Remove-Item Env:PGPASSWORD
  }
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
Write-LogMessage -Icon 🔑 -Message "Logging into ECR..."
cmd /c "aws ecr get-login-password --region $awsRegion | docker login --username AWS --password-stdin ${awsAccountID}.dkr.ecr.${awsRegion}.amazonaws.com" | Out-Null
# aws ecr get-login-password --region $awsRegion | docker login --username "AWS" --password-stdin "${awsAccountID}.dkr.ecr.${awsRegion}.amazonaws.com" | Out-Null

# Create a new repository within ECR for this new project's Docker images
$ecrExists = Test-AWSResourceExists -ResourceType "ECR Repository" -ResourceName $projectName -CheckCommand {
  aws ecr describe-repositories --repository-names $projectName
}

if ($ecrExists -and ($Force -or $Delete)) {
  Write-LogMessage -Icon 🗑️ -Message "Deleting ECR repository '$projectName'..."
  aws ecr delete-repository --repository-name $projectName --force | Out-Null
  $ecrExists = $false
}

if (-not $ecrExists -and -not $Delete) {
  Write-LogMessage -Icon 🆕 -Message "Creating ECR Repository..."
  aws ecr create-repository `
    --repository-name $projectName `
    --image-scanning-configuration "scanOnPush=true" `
    --image-tag-mutability "MUTABLE" | Out-Null
}


Write-Host "-----------------------------------"
Write-Host "     BUILDING DOCKER CONTAINER     "
Write-Host "-----------------------------------"

if (-not $Delete) {
  # Check if Docker is running, attempt to start if not
  if (-not (Test-DockerRunning)) {
    Write-LogMessage -Icon ⚠️ -Message "Docker is not running. Attempting to start Docker Desktop..."
  
    if (-not (Start-DockerDesktop)) {
      Write-LogMessage -Icon ❌ -Message "Failed to start Docker. Please start Docker Desktop manually and re-run the script."
      exit 1
    }

    Write-LogMessage -Icon ✅ -Message "Docker is now running!"
  }
  
  # Build the Docker container and set it up (tag the container)
  # to get ready to be uploaded to ECR. Then, push to ECR.
  Write-LogMessage -Icon 🛠️ -Message "Building container..."
  docker build -t "${projectName}:latest" . | Out-Null
  Write-LogMessage -Icon 🏷️ -Message "Tagging container..."
  docker tag "${projectName}:latest" "${awsAccountID}.dkr.ecr.${awsRegion}.amazonaws.com/${projectName}:latest" | Out-Null
  Write-LogMessage -Icon 🚀 -Message "Pushing container to ECR..."
  docker push "${awsAccountID}.dkr.ecr.${awsRegion}.amazonaws.com/${projectName}:latest" | Out-Null

  # Clean up local Docker images to save space and 
  # release any handles for clean deletion of local repo later
  Write-LogMessage -Icon 🧹 -Message "Cleaning up local Docker images..."
  docker system prune -f | Out-Null
}


Write-Host "-----------------------------------"
Write-Host "        CREATING S3 BUCKET         "
Write-Host "-----------------------------------"

if (-not $Delete) {
  # Download RDS certificate for connecting to instance via SSL
  $pemFileName = "${awsRegion}-bundle.pem"
  $pemSource = "https://truststore.pki.rds.amazonaws.com/${awsRegion}/${pemFileName}"
  
  Write-LogMessage -Icon 🛠️ -Message "Downloading RDS certificate..."
  Invoke-WebRequest -Uri $pemSource -OutFile $pemFileName
  
  # Create S3 bucket for project and place the .pem file in the bucket
  $bucketName = "${projectName}-$(New-Random-String)"
  aws s3api create-bucket `
    --bucket $bucketName `
    --region $awsRegion | Out-Null
    
  Write-LogMessage -Icon 🆕 -Message "Creating S3 bucket..."
  aws s3 cp $pemFileName s3://$bucketName/ | Out-Null
  
  Remove-Item $pemFileName
}

Write-Host "-----------------------------------"
Write-Host "     CREATING SECRETS MANAGER      "
Write-Host "-----------------------------------"

# Create a secrets repository within Secrets Manager to house our environment variables
# for the project, rather than storing them in plaintext on the Lambda itself

# Check if a secret with the project prefix already exists
$existingSecret = aws secretsmanager list-secrets `
  --query "SecretList[?starts_with(Name, '${projectName}/secrets-')] | [0]" `
  --output json 2>$null | ConvertFrom-Json

$secretExists = $null -ne $existingSecret -and $existingSecret -ne "null"

if ($secretExists) {
  $secretID = $existingSecret.Name
  $secretARN = $existingSecret.ARN
  Write-LogMessage -Icon ℹ️ -Message "Secrets Manager secret '$secretID' already exists"
}

if ($secretExists -and ($Force -or $Delete)) {
  Write-LogMessage -Icon 🗑️ -Message "Deleting secret '$secretID'..."
  aws secretsmanager delete-secret --secret-id $secretID --force-delete-without-recovery | Out-Null
  Start-Sleep -Seconds 2
  $secretExists = $false
  $secretID = "${projectName}/secrets-$(New-Random-String)"
}

if (-not $Delete) {
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
  
  if (-not $secretExists) {
    # Generate a name for the secrets
    if (-not $secretID) {
      $secretID = "${projectName}/secrets-$(New-Random-String)"
    }

    Write-LogMessage -Icon 🆕 -Message "Creating new secret in Secrets Manager..."
    # Create the secret in Secrets Manager, using the key/value pairs above
    $secretARN = aws secretsmanager create-secret `
      --name $secretID `
      --description "Environment variables for ${projectName}" `
      --secret-string file://$secretString | ConvertFrom-Json | Select-Object -ExpandProperty ARN
  } else {
    # Update existing secret with new values
    Write-LogMessage -Icon 🔄 -Message "Updating existing secret..."
    aws secretsmanager update-secret `
      --secret-id $secretID `
      --secret-string file://$secretString | Out-Null
  }
}


Write-Host "-----------------------------------"
Write-Host "    CREATING APPRUNNER SERVICE     "
Write-Host "-----------------------------------"

$serviceName = "${projectName}-service"

# Check if AppRunner service already exists
$existingService = aws apprunner list-services `
  --query "ServiceSummaryList[?ServiceName=='${serviceName}'] | [0]" `
  --output json 2>$null | ConvertFrom-Json

$appRunnerExists = $null -ne $existingService -and $existingService -ne "null"

if ($appRunnerExists) {
  $serviceARN = $existingService.ServiceArn -replace '//', '/'
  $serviceURL = $existingService.ServiceUrl
  Write-LogMessage -Icon ℹ️ -Message "AppRunner service '$serviceName' already exists (${serviceARN})"

  if ($Force -or $Delete) {
    Write-LogMessage -Icon 🗑️ -Message "Deleting AppRunner service '$serviceName'..."
    aws apprunner delete-service --service-arn $serviceARN | Out-Null
    # Wait for service to be deleted
    Write-LogMessage -Icon ⏳ -Message "Waiting for service deletion..."
    Start-Sleep -Seconds 30
    $appRunnerExists = $false
  }
}

if (-not $appRunnerExists -and -not $Delete) {
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
  Write-LogMessage -Icon 🆕 -Message "Creating AppRunner service..."
  $serviceOutput = aws apprunner create-service `
    --service-name $serviceName `
    --source-configuration file://$sourceConfig `
    --instance-configuration file://$instanceConfig `
    --query '{OperationId: OperationId, ServiceUrl: Service.ServiceUrl, ServiceArn: Service.ServiceArn}' | ConvertFrom-Json

  $serviceARN = $serviceOutput.ServiceArn
  $serviceURL = $serviceOutput.ServiceUrl
}


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
$awsCodeBuildRoleName = "codebuild-${projectName}-role"

$codeBuildRoleExists = Test-AWSResourceExists -ResourceType "IAM Role" -ResourceName $awsCodeBuildRoleName -CheckCommand {
  aws iam get-role --role-name $awsCodeBuildRoleName
}

if ($codeBuildRoleExists) {
  $awsCodeBuildRoleArn = (aws iam get-role --role-name $awsCodeBuildRoleName | ConvertFrom-Json).Role.Arn
}

if ($codeBuildRoleExists -and ($Force -or $Delete)) {
  Write-LogMessage -Icon 🗑️ -Message "Deleting CodeBuild role '$awsCodeBuildRoleName'..."
  # Delete inline policies first
  aws iam delete-role-policy --role-name $awsCodeBuildRoleName --policy-name "codebuild-${projectName}-policy" 2>$null
  aws iam delete-role --role-name $awsCodeBuildRoleName | Out-Null
  $codeBuildRoleExists = $false
}

if (-not $codeBuildRoleExists -and -not $Delete) {
  Write-LogMessage -Icon 🆕 -Message "Creating CodeBuild role..."
  $awsCodeBuildRoleArn = aws iam create-role `
    --role-name $awsCodeBuildRoleName `
    --assume-role-policy-document file://$awsCodeBuildAssumeRolePolicy | ConvertFrom-Json | Select-Object -ExpandProperty Role | Select-Object -ExpandProperty Arn
    
  # Use the role ARN we just obtained to attach the other policy defined above
  # (put-role-policy is idempotent - it will update if exists)
  aws iam put-role-policy `
    --role-name $awsCodeBuildRoleName `
    --policy-name "codebuild-${projectName}-policy" `
    --policy-document file://$awsCodeBuildPolicy | Out-Null

  # Wait 10 seconds for the role to be propogated across services (only if newly created)
  Write-LogMessage -Icon 😴 -Message "Sleeping for 10 seconds..."
  Start-Sleep -Seconds 10
}

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
$codeBuildProjectExists = Test-AWSResourceExists -ResourceType "CodeBuild Project" -ResourceName $projectName -CheckCommand {
  $result = aws codebuild batch-get-projects --names $projectName | ConvertFrom-Json
  if ($result.projects.Count -gt 0) { return $true } else { return $null }
}

if ($codeBuildProjectExists -and ($Force -or $Delete)) {
  Write-LogMessage -Icon 🗑️ -Message "Deleting CodeBuild project '$projectName'..."
  aws codebuild delete-project --name $projectName | Out-Null
  $codeBuildProjectExists = $false
}

if (-not $Delete) {
  if (-not $codeBuildProjectExists) {
    Write-LogMessage -Icon 🆕 -Message "Creating CodeBuild project..."
    aws codebuild create-project `
      --name $projectName `
      --source file://$source `
      --artifacts file://$artifacts `
      --environment file://$environment `
      --service-role $awsCodeBuildRoleArn | Out-Null
  } else {
    Write-LogMessage -Icon 🔄 -Message "Updating CodeBuild project..."
    aws codebuild update-project `
      --name $projectName `
      --source file://$source `
      --artifacts file://$artifacts `
      --environment file://$environment `
      --service-role $awsCodeBuildRoleArn | Out-Null
  }
}


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

$codeDeployRoleExists = Test-AWSResourceExists -ResourceType "IAM Role" -ResourceName $awsCodeDeployRoleName -CheckCommand {
  aws iam get-role --role-name $awsCodeDeployRoleName
}

if ($codeDeployRoleExists) {
  $awsCodeDeployRoleArn = (aws iam get-role --role-name $awsCodeDeployRoleName | ConvertFrom-Json).Role.Arn
}

if ($codeDeployRoleExists -and ($Force -or $Delete)) {
  Write-LogMessage -Icon 🗑️ -Message "Deleting CodeDeploy role '$awsCodeDeployRoleName'..."
  # Detach managed policies first
  aws iam detach-role-policy --role-name $awsCodeDeployRoleName --policy-arn "arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicFullAccess" 2>$null
  # Delete inline policies
  aws iam delete-role-policy --role-name $awsCodeDeployRoleName --policy-name "codedeploy-${projectName}-apprunner-policy" 2>$null
  aws iam delete-role --role-name $awsCodeDeployRoleName | Out-Null
  $codeDeployRoleExists = $false
}

if (-not $codeDeployRoleExists -and -not $Delete) {
  Write-LogMessage -Icon 🆕 -Message "Creating CodeDeploy role..."
  $awsCodeDeployRoleArn = aws iam create-role `
    --role-name $awsCodeDeployRoleName `
    --assume-role-policy-document file://$awsCodeDeployAssumeRolePolicyDocument | ConvertFrom-Json | Select-Object -ExpandProperty Role | Select-Object -ExpandProperty Arn
    
  # Attach managed AWS policies to the CodeDeploy role
  # (attach-role-policy is idempotent)
  aws iam attach-role-policy `
    --role-name $awsCodeDeployRoleName `
    --policy-arn "arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicFullAccess" | Out-Null
  
  # Use the role ARN we just obtained to attach the other policy defined above
  # (put-role-policy is idempotent - it will update if exists)
  aws iam put-role-policy `
    --role-name $awsCodeDeployRoleName `
    --policy-name "codedeploy-${projectName}-apprunner-policy" `
    --policy-document file://$awsCodeDeployAppRunnerPolicyDocument | Out-Null

  # Wait 10 seconds for the role to be propagated across services (only if newly created)
  Write-LogMessage -Icon 😴 -Message "Sleeping for 10 seconds..."
  Start-Sleep -Seconds 10
}

# Create the CodeDeploy application, which will be executed via a Lambda function
$codeDeployAppName = "${projectName}-deploy"

$codeDeployAppExists = Test-AWSResourceExists -ResourceType "CodeDeploy Application" -ResourceName $codeDeployAppName -CheckCommand {
  aws deploy get-application --application-name $codeDeployAppName
}

if ($codeDeployAppExists -and ($Force -or $Delete)) {
  Write-LogMessage -Icon 🗑️ -Message "Deleting CodeDeploy application '$codeDeployAppName'..."
  aws deploy delete-application --application-name $codeDeployAppName | Out-Null
  $codeDeployAppExists = $false
}

if (-not $codeDeployAppExists -and -not $Delete) {
  Write-LogMessage -Icon 🆕 -Message "Creating CodeDeploy application..."
  aws deploy create-application `
    --application-name $codeDeployAppName `
    --compute-platform "Lambda" | Out-Null
}

# Define a deployment group for the CodeDeploy project
$codeDeployGroupName = "${projectName}-deploy-group"
$awsCodeBuildDeployStyle = Get-JSON-Path -FileName "codebuild-deploy-style.json" -JSON_In @{
  deploymentType   = "BLUE_GREEN"
  deploymentOption = "WITH_TRAFFIC_CONTROL"
}

$codeDeployGroupExists = Test-AWSResourceExists -ResourceType "CodeDeploy Deployment Group" -ResourceName $codeDeployGroupName -CheckCommand {
  aws deploy get-deployment-group --application-name $codeDeployAppName --deployment-group-name $codeDeployGroupName
}

if ($codeDeployGroupExists -and ($Force -or $Delete)) {
  Write-LogMessage -Icon 🗑️ -Message "Deleting CodeDeploy deployment group '$codeDeployGroupName'..."
  aws deploy delete-deployment-group --application-name $codeDeployAppName --deployment-group-name $codeDeployGroupName | Out-Null
  $codeDeployGroupExists = $false
}

if (-not $codeDeployGroupExists -and -not $Delete) {
  Write-LogMessage -Icon 🆕 -Message "Creating CodeDeploy deployment group..."
  aws deploy create-deployment-group `
    --application-name $codeDeployAppName `
    --deployment-group-name $codeDeployGroupName `
    --service-role-arn $awsCodeDeployRoleArn `
    --deployment-style file://$awsCodeBuildDeployStyle | Out-Null
}



#==========================
# 7. SETUP LOCAL REPO
#==========================
Write-Host "==================================="
Write-Host "SETTING UP LOCAL REPO"
Write-Host "==================================="

if (-not $Delete) {
  Write-LogMessage -Icon 🛠️ -Message "Finalizing local repo..."

# Add GitHub Actions workflow file
# Ensure the folder structure exists
$folderPath = ".github/workflows"
if (-not (Test-Path $folderPath)) {
  Write-LogMessage -Icon "  🆕" -Message "Creating .github/workflows folder..."
  New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
}

  Write-LogMessage -Icon "  🆕" -Message "Creating $folderPath/build.yml file..."
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
Write-LogMessage -Icon "  🆕" -Message "Creating $folderPath/buildspec.yml file..."
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
Write-LogMessage -Icon "  🆕" -Message "Creating $folderPath/patch-server.js file..."
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
Write-LogMessage -Icon "  🆕" -Message "Creating .env file..."
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
Write-LogMessage -Icon "  🆕" -Message "Creating .env.prod file..."
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
Write-LogMessage -Icon "  🆕" -Message "Creating update-secrets.ps1 file..."
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
Write-LogMessage -Icon "  🔄" -Message "Updating .gitignore file..."
@'

# Terraform
.terraform/

.env.prod
'@ | Add-Content -Path ".gitignore"

Write-LogMessage -Icon "  🔄" -Message "Updating .dockerignore file..."
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

Write-LogMessage -Icon "  🔄" -Message "Updating scripts in package.json file..."
# Convert back to JSON and save
$packageJson | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $packageJsonPath
} # End of -not $Delete



#==========================
# 8. PUSH REPO TO GITHUB
#==========================
Write-Host "==================================="
Write-Host "PUSHING CODE TO GITHUB"
Write-Host "==================================="

if (-not $Delete) {
  # Push the code to GitHub, triggering a GitHub actions build
  Write-LogMessage -Icon 🚀 -Message "Pushing code to GitHub..."
  git add . | Out-Null
  git commit -m "Initial commit" | Out-Null
  # Use force push if reusing an existing repo (local is freshly scaffolded)
  if ($ghRepoExists) {
    git push -u origin main --force | Out-Null
  }
  else {
    git push -u origin main | Out-Null
  }
}



#==========================
# 9. WAIT FOR APPRUNNER SERVICE
#==========================
Write-Host "==================================="
Write-Host "WAIT FOR APPRUNNER SERVICE"
Write-Host "==================================="

# Only wait if we created a new service (serviceOutput will be set)
# If reusing an existing service, it's already running
if ($Delete) {
  Write-LogMessage -Icon ℹ️ -Message "Deleted existing AppRunner service - skipping wait"
} elseif ($null -ne $serviceOutput) {
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
}
else {
  Write-LogMessage -Icon ℹ️ -Message "Reusing existing AppRunner service - skipping wait"
}


#==========================
# 10. OUTPUTS
#==========================
Write-Host "==================================="
Write-Host "OUTPUTS"
Write-Host "==================================="

if (-not $Delete) {
  # Print any useful outputs from the script for the user to note down or copy elsewhere
  Write-Host ""
  Write-Host "New Project Name : ${projectName}"
  Write-Host "GitHub Repo URL  : https://github.com/nblaisdell2/${projectName}"
  Write-Host "Site URL         : https://${serviceURL}"
  Write-Host "Database Endpoint: ${rdsHost}"
  Write-Host ""
} else {
  Write-Host ""
  Write-LogMessage -Icon ✅ -Message "Deletion process completed successfully."
  Write-Host ""
}

# Return to the projects directory
Set-Location -Path $projectsPath

# Exit the script successfully
exit 0
