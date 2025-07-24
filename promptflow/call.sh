#!/bin/bash

# Include functions
source ./functions.sh

# Variables
declare -A variables=(
  # Specifies the name of the Azure Resource Group that contains your resources.
  [resourceGroupName]="m2c-azure-bot"

  # Specifies the name of the Azure Machine Learning model used by the prompt flow.
  [endpointName]="M2c-bot-flow-endpoint"

  # Specifies the name of the project workspace.
  [projectWorkspaceName]="m2c-project-test"

  # Specifies the question to send to the chat prompt flow exposed via the online endpoint.
  [question]="List Resource Groups in my Azure Account?"

  # Specifies whether to retrieve the OpenAPI schema of the online endpoint.
  [retrieveOpenApiSchema]="true"

  # Specifies whether to enable debug mode (displays additional information during script execution).
  [debug]="true"
)

# Parse the arguments
parse_args variables $@

# Get a security token for the online endpoint
securityToken=$(az ml online-endpoint get-credentials \
  --name $endpointName \
  --resource-group $resourceGroupName \
  --workspace-name $projectWorkspaceName \
  --output tsv \
  --query accessToken \
  --only-show-errors)

if [ -z "$securityToken" ]; then
  echo "Failed to retrieve the security token to call the [$endpointName] online endpoint"
  exit 1
fi

echo "Successfully retrieved the security token to call the [$endpointName] online endpoint"

if [ "$retrieveOpenApiSchema" == "true" ]; then
  # Retrieve the OpenAPI URI and schema for the endpoint
  openApiUri=$(az ml online-endpoint show \
    --name $endpointName \
    --resource-group $resourceGroupName \
    --workspace-name $projectWorkspaceName \
    --query openapi_uri \
    --output tsv \
    --only-show-errors)

  if [ -n "$openApiUri" ]; then
    echo "Successfully retrieved the OpenAPI URI: $openApiUri"
    statuscode=$(curl --silent --request GET --url $openApiUri \
      --header "Authorization: Bearer $securityToken" \
      --header "Content-Type: application/json" \
      --header 'accept: application/json' \
      --write-out "%{http_code}" \
      --output >(cat >/tmp/curl_body)) || code="$?"
    body="$(cat /tmp/curl_body)"
    if [[ $statuscode == 200 ]]; then
      echo "OpenAPI schema successfully retrieved"
      echo $body | jq .
    else
      echo "Failed to retrieve the OpenAPI schema. Status code: $statuscode"
      echo $body
    fi
  else
    echo "Failed to retrieve the OpenAPI URI of the [$endpointName] online endpoint"
    exit 1
  fi
fi

# Get the scoring URI and primary key for the online endpoint
scoringUri=$(az ml online-endpoint show \
  --name $endpointName \
  --resource-group $resourceGroupName \
  --workspace-name $projectWorkspaceName \
  --query scoring_uri \
  --output tsv \
  --only-show-errors)

primaryKey=$(az ml online-endpoint get-credentials \
  --name $endpointName \
  --resource-group $resourceGroupName \
  --workspace-name $projectWorkspaceName \
  --query primaryKey \
  --output tsv \
  --only-show-errors)

if [ -z "$scoringUri" ] || [ -z "$primaryKey" ]; then
  echo "Failed to retrieve endpoint credentials."
  exit 1
fi

echo "Successfully retrieved endpoint credentials."

# Prepare the test payload
payload=$(cat <<EOF
{
    "question": "${question}",
    "chat_history": [],
    "TENANT_ID": "${TENANT_ID}",
    "SUBSCRIPTION_ID": "${SUBSCRIPTION_ID}",
    "CLIENT_SECRET": "${CLIENT_SECRET}",
    "CLIENT_ID": "${CLIENT_ID}"
}
EOF
)

# Test the endpoint with a POST request
response=$(curl -s -w "\n%{http_code}" -X POST "$scoringUri" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $primaryKey" \
    -d "$payload")

body=$(echo "$response" | head -n -1)
statuscode=$(echo "$response" | tail -n1)

if [[ $statuscode == 200 ]]; then
  echo "Successfully called the endpoint"
  echo "$body" | jq .
else
  echo "Failed to call the endpoint. Status code: $statuscode"
  echo "$body"
fi

# Output endpoint credentials for reference

echo "=============================================="
echo "Deployment Credentials:"
echo "REST Endpoint: $scoringUri"
echo "Primary Key:   $primaryKey"
echo "=============================================="
