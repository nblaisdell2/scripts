#!/bin/bash

# Usage: ./create-project <project-name> <project-desc> <database-name> <db-password> <aws-account-id> <aws-region> <gh-actions-role-name>


#==========================
# 1. USER INPUT
#==========================
# Project name
if [ -n "$1" ]; then
  projectName="$1"
else
  read -p "Enter project name: " projectName
  
  while [ -z "$projectName" ]; do
    echo "Project name is required!"
    read -p "Enter project name: " projectName
  done
fi

# Project description
if [ -n "$2" ]; then
  projectDesc="$2"
else
  read -p "Enter project description: " projectDesc
  
  while [ -z "$projectDesc" ]; do
    echo "project description is required!"
    read -p "Enter project description: " projectDesc
  done
fi

# Database name
if [ -n "$3" ]; then
  dbName="$3"
else
  read -p "Enter database name: " dbName
  
  while [ -z "$dbName" ]; do
    echo "database name is required!"
    read -p "Enter database name: " dbName
  done
fi

# Database name
if [ -n "$4" ]; then
  dbPass="$4"
else
  read -p "Enter database password: " dbPass
  
  while [ -z "$dbPass" ]; do
    echo "database password is required!"
    read -p "Enter database password: " dbPass
  done
fi

# AWS Account ID
defaultAwsAccountID="387815262971"
if [ -n "$5" ]; then
  awsAccountID="$5"
else
  # Prompt user with default value in parentheses
  read -p "Enter AWS Account ID (default: $defaultAwsAccountID): " userInput
  # Use user input if provided, otherwise use default value
  awsAccountID="${userInput:-$defaultAwsAccountID}"
fi

# AWS Region
defaultAwsRegion="us-east-1"
if [ -n "$6" ]; then
  awsRegion="$6"
else
  # Prompt user with default value in parentheses
  read -p "Enter AWS Region (default: $defaultAwsRegion): " userInput
  # Use user input if provided, otherwise use default value
  awsRegion="${userInput:-$defaultAwsRegion}"
fi

# AWS Region
defaultAwsGHActionRoleName="github-actions-create-site-role"
if [ -n "$7" ]; then
  awsGHActionRole="$7"
else
  # Prompt user with default value in parentheses
  read -p "Enter AWS GH Actions Role Name (default: $defaultAwsGHActionRoleName): " userInput
  # Use user input if provided, otherwise use default value
  awsGHActionRole="${userInput:-$defaultAwsGHActionRoleName}"
fi

echo ""
echo "Project name       : $projectName"
echo "Project description: $projectDesc"
echo "Database name      : $dbName"
echo "Database password  : $dbPass"
echo "AWS Account ID     : $awsAccountID"
echo "AWS Region         : $awsRegion"
echo "AWS Role           : $awsGHActionRole"



#==========================
# 2. CREATE LOCAL REPO
#==========================

# Temp: Remove folder before creating during testing, for efficiency
if [ -d "$projectName" ]; then
  rm -rf $projectName
fi

# Create local repo for project
if [ -d "$projectName" ]; then
  echo "Error: A folder named '$projectName' already exists. Please choose a different name."
  # exit 1
else
  mkdir "$projectName"
  echo "Folder '$projectName' created successfully."
fi



#==========================
# 3. CREATE GITHUB REPO
#==========================
# Use GitHub CLI & git to create a new GitHub repo using the Fastify template
# and clone the new repo into the local repo folder we just created
gh repo create $projectName --public --template nblaisdell2/fastify-postgres-typescript-template --clone

# Move into the local directory for the rest of the steps
cd $projectName


#==========================
# 4. CREATE AWS INFRA
#==========================
echo ===================================
echo CONNECTING TO AWS ECR
echo ===================================
# login to ECR for Docker
echo "  Logging into ECR..."
aws ecr get-login-password --region $awsRegion | docker login --username AWS --password-stdin $awsAccountID.dkr.ecr.$awsRegion.amazonaws.com >/dev/null

echo "  Creating ECR Repository..."
aws ecr create-repository \
  --repository-name $projectName \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability MUTABLE >/dev/null

# Build the Docker container and set it up (tag the container) 
# to get ready to be uploaded to ECR. Then, push to ECR.
echo ===================================
echo BUILDING DOCKER CONTAINER
echo ===================================
echo "  Building container..."
docker build -t $projectName:latest .
echo "  Tagging container..."
docker tag $projectName:latest $awsAccountID.dkr.ecr.$awsRegion.amazonaws.com/$projectName:latest
echo "  Pushing container to ECR..."
docker push $awsAccountID.dkr.ecr.$awsRegion.amazonaws.com/$projectName:latest





echo ===================================
echo CREATING LAMBDA FUNCTION
echo ===================================
awsLambdaExecRoleArn="arn:aws:iam::$awsAccountID:role/service-role/GetStartedLambdaBasicExecutionRole"
echo "  Creating Lambda..."
aws lambda create-function \
  --function-name $projectName \
  --package-type Image \
  --code ImageUri=$awsAccountID.dkr.ecr.$awsRegion.amazonaws.com/$projectName:latest \
  --role $awsLambdaExecRoleArn >/dev/null

sleep 60

echo "  Publishing new Lambda version..."
initVersion=$(aws lambda publish-version --function-name $projectName --description "Initial Version" | jq -r .Version)
echo "  Creating new Lambda alias..."
aws lambda create-alias \
  --function-name $projectName \
  --name latest \
  --function-version $initVersion \
  --description "Latest version" >/dev/null





echo ===================================
echo CREATING CODEBUILD PROJECT
echo ===================================
# create codebuild service-role and get ARN here to be used in the next section
echo "  Creating CodeBuild role..."
awsCodeBuildRoleName="codebuild-$projectName-role"
awsCodeBuildRoleArn=$(aws iam create-role --role-name "$awsCodeBuildRoleName" --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"codebuild.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}" | jq -r .Role.Arn)
aws iam put-role-policy \
  --role-name "$awsCodeBuildRoleName" \
  --policy-name "codebuild-$projectName-policy" \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Auto0\",\"Effect\":\"Allow\",\"Action\":[\"codedeploy:*\",\"codebuild:*\",\"ecr:*\",\"logs:*\",\"lambda:*\"],\"Resource\":\"*\"}]}" >/dev/null

sleep 20

awsGitHubRepoURL="https://github.com/nblaisdell2/$projectName.git"
echo "  Creating CodeBuild project..."
aws codebuild create-project \
  --name $projectName \
  --source "{\"type\": \"GITHUB\", \"location\": \"$awsGitHubRepoURL\", \"reportBuildStatus\": true}" \
  --artifacts "{\"type\": \"NO_ARTIFACTS\"}" \
  --environment "{\"type\": \"LINUX_CONTAINER\", \"image\": \"aws/codebuild/amazonlinux2-x86_64-standard:5.0\", \"computeType\": \"BUILD_GENERAL1_SMALL\", \"privilegedMode\": true, \"imagePullCredentialsType\": \"CODEBUILD\", \"environmentVariables\": [{\"name\": \"awsRegion\", \"value\": \"$awsRegion\", \"type\": \"PLAINTEXT\"},{\"name\": \"awsAccountID\", \"value\": \"$awsAccountID\", \"type\": \"PLAINTEXT\"},{\"name\": \"projectName\", \"value\": \"$projectName\", \"type\": \"PLAINTEXT\"}]}" \
  --service-role "$awsCodeBuildRoleArn" >/dev/null



echo ===================================
echo CREATING CODEDEPLOY PROJECT
echo ===================================
echo "  Creating CodeDeploy role..."
awsCodeDeployRoleName="codedeploy-$projectName-role"
awsCodeDeployRoleArn=$(aws iam create-role --role-name "$awsCodeDeployRoleName" --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"codedeploy.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}" | jq -r .Role.Arn)
aws iam attach-role-policy \
  --role-name $awsCodeDeployRoleName \
  --policy-arn arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicFullAccess >/dev/null
aws iam attach-role-policy \
  --role-name $awsCodeDeployRoleName \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSCodeDeployRoleForLambda >/dev/null

sleep 20

echo "  Creating CodeBuild application..."
aws deploy create-application \
  --application-name $projectName-deploy \
  --compute-platform Lambda >/dev/null
echo "  Creating CodeBuild deployment group..."
aws deploy create-deployment-group \
  --application-name $projectName-deploy \
  --deployment-group-name $projectName-deploy-group \
  --service-role-arn $awsCodeDeployRoleArn \
  --deployment-style "{\"deploymentType\": \"BLUE_GREEN\", \"deploymentOption\": \"WITH_TRAFFIC_CONTROL\"}" >/dev/null





echo ===================================
echo CREATING API GATEWAY
echo ===================================
echo "  Creating REST API..."
restApiID=$(aws apigateway create-rest-api --name $projectName --description "$projectDesc" --endpoint-configuration '{"types": ["REGIONAL"]}' | jq -r .id)

echo "  Creating REST API Resources..."
resource1ID=$(aws apigateway get-resources --rest-api-id $restApiID | jq -r .items[0].id)
resource2ID=$(aws apigateway create-resource --rest-api-id $restApiID --parent-id $resource1ID --path-part {proxy+} | jq -r .id)

echo "  Creating REST API Methods..."
aws apigateway put-method \
  --rest-api-id $restApiID \
  --resource-id $resource1ID \
  --http-method ANY \
  --authorization-type NONE \
  --request-parameters '{}' >/dev/null
aws apigateway put-method \
  --rest-api-id $restApiID \
  --resource-id $resource2ID \
  --http-method ANY \
  --authorization-type NONE \
  --request-parameters '{}' >/dev/null

echo "  Creating Resource/Method Integration for 'ANY /'..."
aws apigateway put-integration \
  --region $awsRegion \
  --rest-api-id $restApiID \
  --resource-id $resource1ID \
  --http-method ANY \
  --type AWS_PROXY \
  --content-handling CONVERT_TO_TEXT \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$awsRegion:lambda:path/2015-03-31/functions/arn:aws:lambda:$awsRegion:$awsAccountID:function:$projectName/invocations" >/dev/null
aws apigateway put-integration-response \
  --rest-api-id $restApiID \
  --resource-id $resource1ID \
  --http-method ANY \
  --status-code 200 \
  --response-templates '{}' >/dev/null
aws apigateway put-method-response \
  --rest-api-id $restApiID \
  --resource-id $resource1ID \
  --http-method ANY \
  --status-code 200 \
  --response-models '{"application/json": "Empty"}' >/dev/null

echo "  Creating Resource/Method Integration for 'ANY /{proxy+}'..."
aws apigateway put-integration \
  --region $awsRegion \
  --rest-api-id $restApiID \
  --resource-id $resource2ID \
  --http-method ANY \
  --type AWS_PROXY \
  --content-handling CONVERT_TO_TEXT \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:$awsRegion:lambda:path/2015-03-31/functions/arn:aws:lambda:$awsRegion:$awsAccountID:function:$projectName/invocations" >/dev/null
aws apigateway put-integration-response \
  --rest-api-id $restApiID \
  --resource-id $resource2ID \
  --http-method ANY \
  --status-code 200 \
  --response-templates '{}' >/dev/null
aws apigateway put-method-response \
  --rest-api-id $restApiID \
  --resource-id $resource2ID \
  --http-method ANY \
  --status-code 200 \
  --response-models '{"application/json": "Empty"}' >/dev/null

echo "  Adding API Gateway permissions to Lambda..."
aws lambda add-permission \
  --function-name $projectName \
  --statement-id stmt_invoke_1 \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn arn:aws:execute-api:$awsRegion:$awsAccountID:$restApiID/*/*/ >/dev/null
aws lambda add-permission \
  --function-name $projectName \
  --statement-id stmt_invoke_2 \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn arn:aws:execute-api:$awsRegion:$awsAccountID:$restApiID/*/*/* >/dev/null

echo "  Adding API Gateway deployment..."
aws apigateway create-deployment \
  --rest-api-id $restApiID \
  --stage-name dev >/dev/null



echo ===================================
echo CREATING SECRETS MANAGER
echo ===================================
echo "  Creating new secret in Secrets Manager..."
secretID="$projectName/secrets5"
aws secretsmanager create-secret \
  --name $secretID \
  --description "Environment variables for $projectName" >/dev/null

sleep 120

echo ===================================
echo CREATING RDS PostgreSQL DATABASE
echo ===================================
echo "  Creating new PostgreSQL database in RDS..."
dbInstanceIdentifier="postgres-$projectName"
aws rds create-db-instance \
  --db-instance-identifier $dbInstanceIdentifier \
  --db-instance-class "db.t3.micro" \
  --allocated-storage 100 \
  --engine "postgres" \
  --engine-version "17.4" \
  --master-username "postgres" \
  --master-user-password $dbPass \
  --db-name $dbName \
  --publicly-accessible >/dev/null

echo "  ⏳ Waiting for RDS instance '$dbInstanceIdentifier' to become available..."
aws rds wait db-instance-available --db-instance-identifier "$dbInstanceIdentifier"

read -r rdsHost rdsPort rdsUser < <(
  aws rds describe-db-instances --db-instance-identifier "$dbInstanceIdentifier" \
  | jq -r '.DBInstances[0] | "\(.Endpoint.Address) \(.Endpoint.Port) \(.MasterUsername)"'
)



#==========================
# 5. SETUP LOCAL REPO
#==========================
# Install npm dependencies for the project
npm install

# Create LOCAL .env file
cat <<EOF > .env
# Port for the Fastify API to run on
SERVER_PORT="3000"

## AWS Secrets Manager secret ID (for environment variables)
#secretID="$secretID"

# PostgreSQL database connection details
DB_HOST="localhost"
DB_DATABASE="$dbName"
DB_PORT="5432"
DB_USER="postgres"
DB_PASS="Super!345Q"

EOF

# Create PROD .env file
cat <<EOF > .env.prod
# Port for the Fastify API to run on
SERVER_PORT="3000"

# AWS Secrets Manager secret ID (for environment variables)
secretID="$secretID"

# PostgreSQL database connection details
DB_HOST="$rdsHost"
DB_DATABASE="$dbName"
DB_PORT="$rdsPort"
DB_USER="$rdsUser"
DB_PASS="$dbPass"

EOF

# Add the default environment variables to the Secrets Manager
##################################################################
ENV_FILE=".env.prod"  # Default to .env in current dir

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env file not found at: $ENV_FILE"
  exit 1
fi

# Fetch existing secret value
echo "🔍 Fetching current secrets from AWS Secrets Manager..."
CURRENT_SECRET=$(aws secretsmanager get-secret-value --secret-id "$secretID" --query SecretString --output text 2>/dev/null || echo "{}")

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
    # echo "🟡 Key '$key' already exists, skipping..."
    : # NO-OP command
  else
    echo "➕ Adding new key '$key'"
    jq --arg k "$key" --arg v "$value" '. + {($k): $v}' "$TMP_FILE" > "${TMP_FILE}.tmp" && mv "${TMP_FILE}.tmp" "$TMP_FILE"
  fi
done < "$ENV_FILE"

# Update secret in AWS
echo "🚀 Updating secret in AWS Secrets Manager..."
aws secretsmanager update-secret \
  --secret-id "$secretID" \
  --secret-string "$(cat "$TMP_FILE")" >> /dev/null

# Clean up
rm "$TMP_FILE"

echo "✅ Secret updated successfully."
##################################################################


#==========================
# 6. PUSH LOCAL REPO TO GITHUB
#==========================
# Push the code to GitHub, triggering a GitHub actions build
git push -u origin main


#==========================
# 7. OUTPUTS
#==========================
echo "New Project Name : $projectName"
echo "GitHub Repo URL  : https://github.com/nblaisdell2/$projectName"
echo "API Gateway URL  : https://$restApiID.execute-api.$awsRegion.amazonaws.com/dev"
echo "Database Endpoint: $rdsHost"

read -n 1 -p "Once the values have been copied/noted, press any key to open project in VS Code..."


#==========================
# 8. OPEN PROJECT IN VS CODE
#==========================
code .

exit 0
