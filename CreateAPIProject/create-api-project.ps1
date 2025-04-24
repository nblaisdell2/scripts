# Usage: ./create-project <project-name> <project-desc> <database-name> <db-password> <aws-account-id> <aws-region> <gh-actions-role-name>

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

###################################################################################################



#==========================
# 1. USER INPUT
#==========================
Write-Host "==================================="
Write-Host "GETTING USER INPUT"
Write-Host "==================================="

# First, move to my Project folder
Set-Location -Path 'C:\Personal\GitHub'

# Get User Input for the needed variables for the rest of the script
# Allow for default values for _some_ variables
Get-User-Input -var $projectName -label "Project name" 

## Remove folder before creating
# if (Test-Path -Path $projectName -PathType Container) {
#     Remove-Item -Path $projectName -Recurse -Force
# }

# If it does, exit here and allow the user to try again with another project name
if (Test-Path -Path $projectName -PathType Container) {
    Write-Host " ⚠️  Error: A folder named '$projectName' already exists. Please choose a different name."
    exit 1
}

Get-User-Input -var $projectDesc      -label "Project description" 
Get-User-Input -var $dbName           -label "Database name" 
Get-User-Input -var $dbPass           -label "Database password" 
Get-User-Input -var $dbInitPath       -label "Database init script path" 
Get-User-Input -var $awsAccountID     -label "AWS Account ID"            -defaultValue "387815262971"
Get-User-Input -var $awsRegion        -label "AWS Region"                -defaultValue "us-east-1"
Get-User-Input -var $awsGHActionRole  -label "GitHub Actions Role Name"  -defaultValue "github-actions-create-site-role"


# At this point in the script, all the necessary information has been gathered
# and the rest of the script will be fully automated and require no user input



#==========================
# 2. CREATE LOCAL REPO
#==========================
Write-Host "==================================="
Write-Host "CREATING LOCAL REPOSITORY"
Write-Host "==================================="

# Create folder for local repo
New-Item -ItemType Directory -Path $projectName | Out-Null
Write-Host " ✅  Folder '$projectName' created successfully."



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
    --template nblaisdell2/fastify-postgres-typescript-template `
    --public `
    --clone | Out-Null

# Move into the local directory for the rest of the steps
Write-Host " 📁  Moving into local project directory..."
Set-Location -Path $projectName

# Add necessary secrets for accessing CodeBuild via GitHub Actions
Write-Host " 🔐  Setting GitHub Secrets..."
gh secret set AWS_REGION -b $awsRegion | Out-Null
gh secret set AWS_ACCOUNT_ID -b $awsAccountID | Out-Null
gh secret set AWS_GHACTIONS_ROLENAME -b $awsGHActionRole | Out-Null



#==========================
# 4. CREATE AWS INFRA
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
Write-Host "     CREATING LAMBDA FUNCTION      "
Write-Host "-----------------------------------"

# Create a Lambda function as the backend for this API (sourced by our ECR/Docker image)
Write-Host " 🆕  Creating Lambda..."
$awsLambdaExecRoleArn = "arn:aws:iam::${awsAccountID}:role/service-role/GetStartedLambdaBasicExecutionRole"
aws lambda create-function `
    --function-name $projectName `
    --package-type Image `
    --code ImageUri="${awsAccountID}.dkr.ecr.${awsRegion}.amazonaws.com/${projectName}:latest" `
    --role $awsLambdaExecRoleArn | Out-Null

# Check to see if the Lambda has been provisioned before moving on
Write-Host " ⏳  Waiting for lambda '${projectName}' to become available..."
Wait-ForAWSResource -ResourceName $projectName -Command {
    $lambdaState = aws lambda get-function --function-name $projectName | ConvertFrom-Json | Select-Object -ExpandProperty Configuration | Select-Object -ExpandProperty State
    if ($lambdaState -eq "Pending") {
        cmd /c exit 20
    }
}

# Publish an initial version of the lambda to point to the ECR image 
Write-Host " 🆕  Publishing new Lambda version..."
$initVersion = aws lambda publish-version --function-name $projectName --description "Initial Version" | ConvertFrom-Json | Select-Object -ExpandProperty Version

# Create a Lambda alias to match the tag given to the ECR image
Write-Host " 🆕  Creating new Lambda alias..."
aws lambda create-alias `
    --function-name $projectName `
    --name "latest" `
    --function-version $initVersion `
    --description "Latest version" | Out-Null


Write-Host "-----------------------------------"
Write-Host "    CREATING CODEBUILD PROJECT     "
Write-Host "-----------------------------------"

# Create the policy for allowing the usage of CodeBuild for GH Actions
$awsCodeBuildAssumeRolePolicy = @{
    Version   = "2012-10-17"
    Statement = @(
        @{
            Effect    = "Allow"
            Principal = @{ Service = "codebuild.amazonaws.com" }
            Action    = "sts:AssumeRole"
        }
    )
} | ConvertTo-Json -Depth 10 -Compress

# Create the policy for what the role is allowed to interact with
#   CodeDeploy/CodeBuild - allow to call deployments and builds
#   ECR - allow for reading images from ECR
#   Logs - Needed to write logs to CloudWatch
#   Lambda - Needed to update Lambda / create new lambda alias/version
$awsCodeBuildPolicy = @{
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
                "lambda:*"
            )
            Resource = "*"
        }
    )
} | ConvertTo-Json -Depth 10 -Compress

# Create the CodeBuild role with the AssumeRole policy created above
# and extract the ARN of the newly created role
Write-Host " 🆕  Creating CodeBuild role..."
$awsCodeBuildRoleName = "codebuild-${projectName}-role"
$awsCodeBuildRoleArn = aws iam create-role `
    --role-name $awsCodeBuildRoleName `
    --assume-role-policy-document $awsCodeBuildAssumeRolePolicy | ConvertFrom-Json | Select-Object -ExpandProperty Role | Select-Object -ExpandProperty Arn
  
# Use the role ARN we just obtained to attach the other policy defined above
aws iam put-role-policy `
    --role-name $awsCodeBuildRoleName `
    --policy-name "codebuild-${projectName}-policy" `
    --policy-document $awsCodeBuildPolicy | Out-Null

# Wait 10 seconds for the role to be propogated across services
Write-Host " 😴  Sleeping for 10 seconds..."
Start-Sleep -Seconds 10

# Define the source for a CodeBuild project, which will point to our newly created
# GitHub repo to integrate CodeBuild with our GitHub Actions script
$awsGitHubRepoURL = "https://github.com/nblaisdell2/${projectName}.git"
$source = @{
    type              = "GITHUB"
    location          = $awsGitHubRepoURL
    reportBuildStatus = $true
} | ConvertTo-Json -Compress

# Nothing will be generated from the builds, since the images are stored in ECR
# and its all that's needed
$artifacts = @{
    type = "NO_ARTIFACTS"
} | ConvertTo-Json -Compress

# Define the environment for the CodeBuild execution, as well as any environment
# variables needed for the "buildspec.yml" file
$environment = @{
    type                     = "LINUX_CONTAINER"
    image                    = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    computeType              = "BUILD_GENERAL1_SMALL"
    privilegedMode           = $true
    imagePullCredentialsType = "CODEBUILD"
    environmentVariables     = @(
        @{ name = "awsRegion"; value = $awsRegion; type = "PLAINTEXT" }
        @{ name = "awsAccountID"; value = $awsAccountID; type = "PLAINTEXT" }
        @{ name = "dockerContainerName"; value = $projectName; type = "PLAINTEXT" }
    )
} | ConvertTo-Json -Depth 10 -Compress

# Create the CodeBuild project, using the above parameters/configurations/roles
Write-Host " 🆕  Creating CodeBuild project..."
aws codebuild create-project `
    --name $projectName `
    --source $source `
    --artifacts $artifacts `
    --environment $environment `
    --service-role $awsCodeBuildRoleArn | Out-Null


Write-Host "-----------------------------------"
Write-Host "    CREATING CODEDEPLOY PROJECT    "
Write-Host "-----------------------------------"
# Create the policy for allowing the usage of CodeDeploy for GH Actions
$awsCodeDeployAssumeRolePolicyDocument = @{
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
} | ConvertTo-Json -Depth 3

# Create the CodeDeploy role using the assume role policy above and Extract the role ARN
$awsCodeDeployRoleName = "codedeploy-${projectName}-role"
Write-Host " 🆕  Creating CodeDeploy role..."
$awsCodeDeployRoleArn = aws iam create-role `
    --role-name $awsCodeDeployRoleName `
    --assume-role-policy-document $awsCodeDeployAssumeRolePolicyDocument | ConvertFrom-Json | Select-Object -ExpandProperty Role | Select-Object -ExpandProperty Arn

# Attach two managed AWS policies to the newly created CodeDeploy role 
# for interacting with ECR and CodeDeploy (specifically for Lambda)
aws iam attach-role-policy `
    --role-name $awsCodeDeployRoleName `
    --policy-arn "arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicFullAccess" | Out-Null
aws iam attach-role-policy `
    --role-name $awsCodeDeployRoleName `
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRoleForLambda" | Out-Null

# Wait 10 seconds for the role to be propogated across services
Write-Host " 😴  Sleeping for 10 seconds..."
Start-Sleep -Seconds 10

# Create the CodeDeploy application, which will be executed via a Lambda function
Write-Host " 🆕  Creating CodeDeploy application..."
aws deploy create-application `
    --application-name "${projectName}-deploy" `
    --compute-platform "Lambda" | Out-Null

# Define a deployment group for the CodeDeploy project
$awsCodeBuildDeployStyle = @{
    deploymentType   = "BLUE_GREEN"
    deploymentOption = "WITH_TRAFFIC_CONTROL"
} | ConvertTo-Json
Write-Host " 🆕  Creating CodeDeploy deployment group..."
aws deploy create-deployment-group `
    --application-name "${projectName}-deploy" `
    --deployment-group-name "${projectName}-deploy-group" `
    --service-role-arn $awsCodeDeployRoleArn `
    --deployment-style $awsCodeBuildDeployStyle | Out-Null


Write-Host "-----------------------------------"
Write-Host "       CREATING API GATEWAY        "
Write-Host "-----------------------------------"

# Create an API for this project within API Gateway
Write-Host " 🆕  Creating REST API..."
$restApiID = (aws apigateway create-rest-api `
        --name $projectName `
        --description "$projectDesc" `
        --endpoint-configuration '{ "types": ["REGIONAL"] }' | ConvertFrom-Json).id

# Create two "ANY" (HTTP verb) resources for our API, the combination of which 
# will handle *all* requests coming into our API
#    ANY /         - base URL of API
#    ANY /{proxy+} - placeholder for _any_ URL of our API (handles *all* other requests)
Write-Host " 🆕  Creating REST API Resources..."
$resource1ID = (aws apigateway get-resources --rest-api-id $restApiID | ConvertFrom-Json).items[0].id
$resource2ID = (aws apigateway create-resource --rest-api-id $restApiID --parent-id $resource1ID --path-part "{proxy+}" | ConvertFrom-Json).id

# Create the ANY method for both resources
Write-Host " 🆕  Creating REST API Methods..."
aws apigateway put-method `
    --rest-api-id $restApiID `
    --resource-id $resource1ID `
    --http-method "ANY" `
    --authorization-type "NONE" `
    --request-parameters '{}' | Out-Null
aws apigateway put-method `
    --rest-api-id $restApiID `
    --resource-id $resource2ID `
    --http-method "ANY" `
    --authorization-type "NONE" `
    --request-parameters '{}' | Out-Null

# Create Lambda integration for Resource 1
Write-Host " 🆕  Creating Resource/Method Integration for 'ANY /'..."
aws apigateway put-integration `
    --region $awsRegion `
    --rest-api-id $restApiID `
    --resource-id $resource1ID `
    --http-method "ANY" `
    --type "AWS_PROXY" `
    --content-handling "CONVERT_TO_TEXT" `
    --integration-http-method "POST" `
    --uri "arn:aws:apigateway:${awsRegion}:lambda:path/2015-03-31/functions/arn:aws:lambda:${awsRegion}:${awsAccountID}:function:${projectName}/invocations" | Out-Null
aws apigateway put-integration-response `
    --rest-api-id $restApiID `
    --resource-id $resource1ID `
    --http-method "ANY" `
    --status-code 200 `
    --response-templates '{}' | Out-Null
aws apigateway put-method-response `
    --rest-api-id $restApiID `
    --resource-id $resource1ID `
    --http-method "ANY" `
    --status-code 200 `
    --response-models '{"application/json": "Empty"}' | Out-Null

# Create Lambda integration for Resource 2
Write-Host " 🆕  Creating Resource/Method Integration for 'ANY /{proxy+}'..."
aws apigateway put-integration `
    --region $awsRegion `
    --rest-api-id $restApiID `
    --resource-id $resource2ID `
    --http-method "ANY" `
    --type "AWS_PROXY" `
    --content-handling "CONVERT_TO_TEXT" `
    --integration-http-method "POST" `
    --uri "arn:aws:apigateway:${awsRegion}:lambda:path/2015-03-31/functions/arn:aws:lambda:${awsRegion}:${awsAccountID}:function:${projectName}/invocations" | Out-Null
aws apigateway put-integration-response `
    --rest-api-id $restApiID `
    --resource-id $resource2ID `
    --http-method "ANY" `
    --status-code 200 `
    --response-templates '{}' | Out-Null
aws apigateway put-method-response `
    --rest-api-id $restApiID `
    --resource-id $resource2ID `
    --http-method "ANY" `
    --status-code 200 `
    --response-models '{"application/json": "Empty"}' | Out-Null

# Create a deployment for our API
Write-Host " 🆕  Creating API Gateway deployment..."
aws apigateway create-deployment `
    --rest-api-id $restApiID `
    --stage-name "dev" | Out-Null

# Add permissions to our Lambda function (created earlier) to allow for our
# new API to be able to call our Lambda function via the Lambda integration
#    (one for each resource)
Write-Host " ➕  Adding API Gateway permissions to Lambda..."
aws lambda add-permission `
    --function-name $projectName `
    --statement-id "stmt_invoke_1" `
    --action "lambda:InvokeFunction" `
    --principal "apigateway.amazonaws.com" `
    --source-arn "arn:aws:execute-api:${awsRegion}:${awsAccountID}:${restApiID}/*/*/" | Out-Null
aws lambda add-permission `
    --function-name $projectName `
    --statement-id "stmt_invoke_2" `
    --action "lambda:InvokeFunction" `
    --principal "apigateway.amazonaws.com" `
    --source-arn "arn:aws:execute-api:${awsRegion}:${awsAccountID}:${restApiID}/*/*/*" | Out-Null


Write-Host "-----------------------------------"
Write-Host "     CREATING SECRETS MANAGER      "
Write-Host "-----------------------------------"

# Create a secrets repository within Secrets Manager to house our environment variables
# for the project, rather than storing them in plaintext on the Lambda itself
Write-Host " 🆕  Creating new secret in Secrets Manager..."
$secretID = "${projectName}/secrets24"
aws secretsmanager create-secret `
    --name $secretID `
    --description "Environment variables for ${projectName}" `
    --secret-string '{}' | Out-Null

# Wait until the secret is available
Write-Host " ⏳  Waiting for secret '$secretID' to become available..."
Wait-ForAWSResource -ResourceName $secretID -Command {
    aws secretsmanager describe-secret --secret-id $secretID 2>$null | Out-Null
}

# Create an object whose only key is the name of our Secret key we just created
$envVars = @{
    SECRET_ID = $SecretID
} | ConvertTo-Json -Compress

# Update the Lambda function to include this single environment variable, so that
# it has access to Secrets Manager at runtime
Write-Host " 🚀  Updating Lambda Configuration (timeout + env vars)..."
aws lambda update-function-configuration `
    --function-name $projectName `
    --timeout 900 `
    --environment "{ `"Variables`": $envVars }" | Out-Null



#==========================
# 5. SETUP TERRAFORM
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



#==========================
# 6. INITIALIZE DATABASE
#==========================
Write-Host "==================================="
Write-Host "INITIALIZING DATABASE"
Write-Host "==================================="

# Wait 10 seconds to give the RDS instance some time when coming online
Write-Host " 😴  Sleeping for 10 seconds..."
Start-Sleep -Seconds 10

# Initialize the database with a SQL initialization script, for defining tables/functions/etc.
Write-Host " 🎬  Initializing database..."
$env:PGPASSWORD = $dbPass
psql -h $rdsHost -p 5432 -U $rdsUser -d $dbName -f $dbInitPath
Remove-Item Env:PGPASSWORD



#==========================
# 7. SETUP LOCAL REPO
#==========================
Write-Host "==================================="
Write-Host "SETTING UP LOCAL REPO"
Write-Host "==================================="

# Move back into the project's root directory for the rest of the project setup
Write-Host " 📁  Moving back to project root directory..."
Set-Location ..

# Install npm dependencies for the project
Write-Host " 💻  Installing NPM dependencies..." | Out-Null
npm install

# Create LOCAL .env file (connects to local PostgreSQL instance, for development/testing)
Write-Host " 🆕  Creating .env file..."
@"
# Port for the Fastify API to run on
SERVER_PORT="3000"

## AWS Secrets Manager secret ID (for environment variables)
#SECRET_ID="$secretID"

# PostgreSQL database connection details
DB_HOST="localhost"
DB_DATABASE="$dbName"
DB_PORT="5432"
DB_USER="$rdsUser"
DB_PASS="Super!345Q"
"@ | Set-Content -Path ".env"

# Create PROD .env file (connects to RDS PostgreSQL instance, for production)
Write-Host " 🆕  Creating .env.prod file..."
@"
# Port for the Fastify API to run on
SERVER_PORT="3000"

# AWS Secrets Manager secret ID (for environment variables)
SECRET_ID="$secretID"

# PostgreSQL database connection details
DB_HOST="$rdsHost"
DB_DATABASE="$dbName"
DB_PORT="$rdsPort"
DB_USER="$rdsUser"
DB_PASS="$dbPass"
"@ | Set-Content -Path ".env.prod"

# Create 'update-secrets.sh' file
Write-Host " 🆕  Creating update-secrets.sh file..."
$hereStringSecret = @'
set -e

SECRET_ID="{{MY_SECRET}}"
ENV_FILE="${1:-.env}"  # Default to .env in current dir

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found at: $ENV_FILE"
  exit 1
fi

# Fetch existing secret value
echo "🔍 Fetching current secrets from AWS Secrets Manager..."
CURRENT_SECRET=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text 2>/dev/null || echo "{}")

# Use jq to parse existing secret JSON
TMP_FILE=$(mktemp)
echo "$CURRENT_SECRET" | jq '.' > "$TMP_FILE"

# Read each line in the .env file
echo "📦 Reading from .env file..."
while IFS='=' read -r key value; do
  # Skip comments and empty lines
  [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue

  # Trim whitespace
  key=$(echo "$key" | xargs)
  value=$(echo "$value" | xargs)

  [[ "$key" = "" ]] && continue
  [[ "$value" = "" ]] && continue

  # Check if key exists in the current secret
  if jq -e --arg k "$key" '.[$k]' "$TMP_FILE" > /dev/null; then
    : # echo "🟡 Key '$key' already exists, skipping..."
  else
    echo "➕ Adding new key '$key'"
    jq --arg k "$key" --arg v "$value" '. + {($k): $v}' "$TMP_FILE" > "${TMP_FILE}.tmp" && mv "${TMP_FILE}.tmp" "$TMP_FILE"
  fi
done < "$ENV_FILE"

# Update secret in AWS
echo "🚀 Updating secret in AWS Secrets Manager..."
aws secretsmanager update-secret --secret-id "$SECRET_ID" --secret-string "$(cat "$TMP_FILE")" >> /dev/null

# Clean up
rm "$TMP_FILE"

echo "✅ Secret updated successfully."
'@ 
$hereStringSecret = $hereStringSecret.Replace("{{MY_SECRET}}", $secretID)
$hereStringSecret | Set-Content -Path "update-secrets.sh"

# Create empty README file for the project
Write-Host " 🆕  Creating README file..."
@"
# $projectName

"@ | Set-Content -Path "README.md"



#==========================
# 8. UPDATE SECRETS MANAGER
#==========================
Write-Host "==================================="
Write-Host "UPDATE SECRETS MANAGER"
Write-Host "==================================="

$envFile = ".env.prod"  # Default to .env.prod in current dir
$currentSecret = "{}"

Write-Host " 🔐  Adding environment variables from ${envFile} to AWS Secrets Manager..."

# Add the default environment variables to Secrets Manager


# Parse existing secret JSON
$tmpFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $tmpFile -Value ($currentSecret | ConvertFrom-Json | ConvertTo-Json -Depth 100)

Write-Host " 📦  Reading from ${envFile} file..."

# Read each line from the .env file
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()

    # Skip comments and empty lines
    if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
        return
    }

    # Split each env variable by the '=' sign, to separate the key and value
    $parts = $line -split '=', 2
    if ($parts.Count -ne 2) { return }

    # Extract the key & value
    $key = $parts[0].Trim()
    $value = $parts[1].Trim().Trim('"')  # Remove surrounding quotes if present

    # If either key/value is empty, skip
    if (-not $key -or -not $value) { return }

    $existing = Get-Content $tmpFile | ConvertFrom-Json
    if ($existing.PSObject.Properties.Name -contains $key) {
        # Key already exists, skip
        return
    }

    Write-Host " ➕  Adding new key '$key'"
    $existing | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
    $existing | ConvertTo-Json -Depth 100 | Set-Content -Path $tmpFile
}

# Update the secret in AWS
Write-Host " 🚀  Updating secret in AWS Secrets Manager..."
$updatedSecret = Get-Content $tmpFile -Raw
aws secretsmanager update-secret `
    --secret-id $secretID `
    --secret-string "$updatedSecret" | Out-Null

# Clean up
Remove-Item $tmpFile

Write-Host " ✅  Secret updated successfully."



#==========================
# 9. PUSH REPO TO GITHUB
#==========================
Write-Host "==================================="
Write-Host "PUSING CODE TO GITHUB"
Write-Host "==================================="

# Push the code to GitHub, triggering a GitHub actions build
Write-Host " 🚀  Pushing code to GitHub..."
git add . | Out-Null
git commit -m "initial project setup" | Out-Null
git push -u origin main | Out-Null



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
Write-Host "API Gateway URL  : https://${restApiID}.execute-api.${awsRegion}.amazonaws.com/dev"
Write-Host "Database Endpoint: ${rdsHost}"

# Wait for the user to enter any key at this point
Write-Host ""
Write-Host "Once the values have been copied/noted, press any key to open project in VS Code..."
$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null



#==========================
# 11. OPEN PROJECT IN VS CODE
#==========================
# Lastly, open the current directory (the project directory) in VS Code to start developing!
code .

# Exit the script successfully
exit 0
