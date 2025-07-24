#!/bin/bash

set -e
# set -x  # Uncomment only for debugging

# Load helper functions
source ./functions.sh

# Activate the environment with Azure CLI
source ./pf/bin/activate

export AZURE_EXTENSION_USE_PYTHON=$(which python)

# Main deployment variables
declare -A variables=(
  [resourceGroupName]="m2c-azure-bot"
  [location]="westeurope"
  [storageAccountName]="m2cdatastorebot"
  [aiServicesName]="m2c-ai-services-bot"
  [hubWorkspaceName]="m2c-hub-bot"
  [projectWorkspaceName]="m2c-project-bot"
  [logAnalyticsName]="m2c-log-analytics-bot"
  [logAnalyticsSku]="PerGB2018"
  [promptFlowDirectory]="${SCRIPT_DIR}/flow"
  [promptFlowName]="m2c-bot"
  [createPromptFlowInAzureAIFoundry]="true"
  [useExistingConnection]="true"
  [aoaiConnectionName]="m2c-ai-services-bot-connection_aoai"
  [aoaiDeploymentName]="gpt-4"
  [updateExistingEndpoint]="true"
  [updateExistingDeployment]="true"
  [endpointName]="M2c-bot-endpoint"
  [modelName]="M2c-bot-model"
  [modelDescription]="Azure Machine Learning model for the m2c-bot chat prompt flow."
  [modelVersion]="1"
  [environmentName]="promptflow-runtime"
  [environmentVersion]="20240619.v2"
  [environmentImage]="mcr.microsoft.com/azureml/promptflow/promptflow-runtime:20240619.v2"
  [environmentDescription]="Environment created via Azure CLI."
  [deploymentName]="m2c-bot-deployment"
  [deploymentInstanceType]="Standard_D2as_v4"
  [deploymentInstanceCount]=1
  [maxConcurrentRequestsPerInstance]=5
  [applicationInsightsEnabled]="false"
  [diagnosticSettingName]="default"
  [debug]="true"
  [tempDirectory]="temp"
)

parse_args variables $@

# Ensure Azure CLI is authenticated
if ! az account show &>/dev/null; then
  echo "Azure CLI is not authenticated. Please log in."
  az login
fi

subscriptionId=$(az account show --query id --output tsv | tr -d '\r')

# Set up Python environment and required tools
activate_venv
install_promptflow
install_ml_extension

# Prepare temporary directory for prompt flow deployment
create_new_directory "${variables[tempDirectory]}"

echo "Current directory: $(pwd)"
echo "Prompt flow directory path: ${variables[promptFlowDirectory]}"

if [ ! -d "${variables[promptFlowDirectory]}" ]; then
  echo "Error: Prompt flow directory ${variables[promptFlowDirectory]} does not exist."
  exit 1
fi
cp -r "${variables[promptFlowDirectory]}" "${variables[tempDirectory]}/${variables[promptFlowName]}"

# Update flow.dag.yaml with correct connection and deployment names if needed
yamlFileName="${variables[tempDirectory]}/${variables[promptFlowName]}/flow.dag.yaml"

if [ "${variables[useExistingConnection]}" == "true" ]; then
  connectionName=$(yq '.nodes[] | select(.provider == "AzureOpenAI") | .connection' "$yamlFileName")
  if [ -n "$connectionName" ]; then
    echo "[$connectionName] found in the prompt flow."
    yq eval '(.nodes[] | select(.provider == "AzureOpenAI") | .connection) = "'${variables[aoaiConnectionName]}'"' -i "$yamlFileName"
    yq eval '(.nodes[] | select(.provider == "AzureOpenAI") | .inputs.deployment_name) = "'${variables[aoaiDeploymentName]}'"' -i "$yamlFileName"
  else
    echo "No Azure OpenAI connection found in the prompt flow."
  fi
fi

# (Continue with the rest of the script, keeping only necessary comments for major steps or non-obvious logic)

# Check if the prompt flow already exists in the project workspace
echo "Checking if the [${variables[promptFlowName]}] prompt flow already exists in the [${variables[projectWorkspaceName]}] project workspace..."
result=$(pfazure flow list \
  --subscription $subscriptionId \
  --resource-group "${variables[resourceGroupName]}" \
  --workspace-name "${variables[projectWorkspaceName]}" |
  jq --arg display_name "${variables[promptFlowName]}" '[.[] | select(.display_name == $display_name)] | length > 0')

if [ "$result" == "true" ]; then
  echo "The [${variables[promptFlowName]}] prompt flow already exists in the [${variables[projectWorkspaceName]}] project workspace."
else
  # Create the prompt flow on Azure
  echo -e "Creating the [${variables[promptFlowName]}] prompt flow in the [${variables[projectWorkspaceName]}] project workspace..."
  echo "Attempting to create prompt flow with these parameters:"
  echo "Subscription: $subscriptionId"
  echo "Resource Group: ${variables[resourceGroupName]}"
  echo "Workspace: ${variables[projectWorkspaceName]}"
  echo "Flow Path: ${variables[tempDirectory]}/${variables[promptFlowName]}"
  result=$(pfazure flow create \
    --flow "${variables[tempDirectory]}/${variables[promptFlowName]}" \
    --subscription "$subscriptionId" \
    --resource-group "${variables[resourceGroupName]}" \
    --workspace-name "${variables[projectWorkspaceName]}" \
    --set display_name="${variables[promptFlowName]}" 2>&1)

  if [ $? -eq 0 ]; then
    echo "The [${variables[promptFlowName]}] prompt flow was created successfully in the [${variables[projectWorkspaceName]}] project workspace."
    echo "Flow created successfully"
  else
    echo "An error occurred while creating the [${variables[promptFlowName]}] prompt flow in the [${variables[projectWorkspaceName]}] project workspace."
    echo "Failed to create flow. Error details:"
    echo "$result"
    exit 1
  fi
fi

# Create a YAML file with the definition of the Azure Machine Learning online endpoint used to expose the prompt flow
yamlFileName="${variables[tempDirectory]}/endpoint.yaml"
cat <<EOL >$yamlFileName
\$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineEndpoint.schema.json
auth_mode: Key 
EOL

if [ "${variables[debug]}" == "true" ]; then
  cat "$yamlFileName"
fi

# Check whether the Azure Machine Learning online endpoint already exists in the resource group
echo "Checking whether the [${variables[endpointName]}] Azure Machine Learning online endpoint already exists in the [${variables[resourceGroupName]}] resource group..."
if az ml online-endpoint show \
  --name "${variables[endpointName]}" \
  --resource-group "${variables[resourceGroupName]}" \
  --workspace-name "${variables[projectWorkspaceName]}" \
  --only-show-errors > /dev/null 2>&1; then

  # Update the Azure Machine Learning online endpoint to trigger the prompt flow execution
  echo "The [${variables[endpointName]}] Azure Machine Learning online endpoint already exists in the [${variables[resourceGroupName]}] resource group."

  if [ "${variables[updateExistingEndpoint]}" == "true" ]; then
    echo "Updating the [${variables[endpointName]}] Azure Machine Learning online endpoint in the [${variables[resourceGroupName]}] resource group..."
    az ml online-endpoint update \
      --name "${variables[endpointName]}" \
      --resource-group "${variables[resourceGroupName]}" \
      --workspace-name "${variables[projectWorkspaceName]}" \
      --file $yamlFileName \
      --only-show-errors 1>/dev/null
    if [ $? -eq 0 ]; then
      echo "The [${variables[endpointName]}] Azure Machine Learning online endpoint was updated successfully in the [${variables[resourceGroupName]}] resource group."
    else
      echo "An error occurred while updating the [${variables[endpointName]}] Azure Machine Learning online endpoint in the [${variables[resourceGroupName]}] resource group."
      exit 1
    fi
  fi
else
  # Create an Azure Machine Learning online endpoint to trigger the prompt flow execution
  echo "Creating the [${variables[endpointName]}] Azure Machine Learning online endpoint in the [${variables[resourceGroupName]}] resource group..."
  az ml online-endpoint create \
    --name "${variables[endpointName]}" \
    --resource-group "${variables[resourceGroupName]}" \
    --workspace-name "${variables[projectWorkspaceName]}" \
    --file $yamlFileName \
    --only-show-errors 1>/dev/null
  if [ $? -eq 0 ]; then
    echo "The [${variables[endpointName]}] Azure Machine Learning online endpoint was created successfully in the [${variables[resourceGroupName]}] resource group."
  else
    echo "An error occurred while creating the [${variables[endpointName]}] Azure Machine Learning online endpoint in the [${variables[resourceGroupName]}] resource group."
    exit 1
  fi
fi

# Retrieve the Azure Machine Learning online endpoint information
echo "Retrieving the [${variables[endpointName]}] Azure Machine Learning online endpoint information..."
endpoint=$(az ml online-endpoint show \
  --name "${variables[endpointName]}" \
  --resource-group "${variables[resourceGroupName]}" \
  --workspace-name "${variables[projectWorkspaceName]}" \
  --only-show-errors)

if [ $? -eq 0 ]; then
  echo "The [${variables[endpointName]}] Azure Machine Learning online endpoint information was retrieved successfully."
  endpointResourceId=$(echo "$endpoint" | jq -r '.id')
  endpointPrincipalId=$(echo "$endpoint" | jq -r '.identity.principal_id')
  endpointScoringUri=$(echo "$endpoint" | jq -r '.scoring_uri')
  echo "- id: $endpointResourceId"
  echo "- name: ${variables[endpointName]}"
  echo "- principal_id: $endpointPrincipalId"
  echo "- scoring_uri: $endpointScoringUri"

  # Retrieve the resource id of the Azure AI Services account
  aiServicesId=$(az cognitiveservices account show \
    --name "${variables[aiServicesName]}" \
    --resource-group "${variables[resourceGroupName]}" \
    --query id \
    --output tsv | tr -d '\r')

  if [ -n "$aiServicesId" ]; then
    echo "The resource id of the [${variables[aiServicesName]}] Azure AI Services account is [$aiServicesId]."
  else
    echo "An error occurred while retrieving the resource id of the [${variables[aiServicesName]}] Azure AI Services account."
    exit 1
  fi

  # Assign the Cognitive Services OpenAI User role on the Azure AI Services account to the managed identity of the Azure Machine Learning online endpoint
  role="Cognitive Services OpenAI User"
  echo "Verifying if the endpoint managed identity has been assigned the role [$role] with the [${variables[aiServicesName]}] Azure AI Services account as a scope..."
  current=$(az role assignment list \
    --assignee-object-id "$endpointPrincipalId" \
    --assignee-principal-type ServicePrincipal \
    --scope "$aiServicesId" \
    --query "[?roleDefinitionName=='$role'].roleDefinitionName" \
    --output tsv 2>/dev/null | tr -d '\r')

  if [[ $current == $role ]]; then
    echo "The [${variables[endpointName]}] Azure Machine Learning online endpoint managed identity is already assigned the ["$current"] role with the [${variables[aiServicesName]}] Azure AI Services account as a scope"
  else
    echo "The [${variables[endpointName]}] Azure Machine Learning online endpoint managed identity is not assigned the [$role] role with the [${variables[aiServicesName]}] Azure AI Services account as a scope"
    echo "Assigning the [$role] role to the [${variables[endpointName]}] Azure Machine Learning online endpoint managed identity with the [${variables[aiServicesName]}] Azure AI Services account as a scope..."

    az role assignment create \
      --assignee-object-id "$endpointPrincipalId" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" \
      --scope $aiServicesId \
      --only-show-errors 1>/dev/null

    if [[ $? == 0 ]]; then
      echo "The [${variables[endpointName]}] Azure Machine Learning online endpoint managed identity has been successfully assigned the [$role] role with the [${variables[aiServicesName]}] Azure AI Services account as a scope"
    else
      echo "Failed to assign the [$role] role to the [${variables[endpointName]}] Azure Machine Learning online endpoint managed identity with the [${variables[aiServicesName]}] Azure AI Services account as a scope"
      exit 1
    fi
  fi

  # Retrieve the resource id of the project workspace
  projectWorkspaceId=$(az ml workspace show \
    --name "${variables[projectWorkspaceName]}" \
    --resource-group "${variables[resourceGroupName]}" \
    --query id \
    --output tsv | tr -d '\r')

  if [ -n "$projectWorkspaceId" ]; then
    echo "The resource id of the [${variables[projectWorkspaceName]}] project workspace is [$projectWorkspaceId]."
  else
    echo "An error occurred while retrieving the resource id of the [${variables[projectWorkspaceName]}] project workspace."
    exit 1
  fi

  # Assign the Azure Machine Learning Workspace Connection Secrets Reader role on the project workspace to the managed identity of the Azure Machine Learning online endpoint
  role="Azure Machine Learning Workspace Connection Secrets Reader"
  echo "Verifying if the endpoint managed identity has been assigned the role [$role] with the [${variables[projectWorkspaceName]}] project workspace as a scope..."
  current=$(az role assignment list \
    --assignee $endpointPrincipalId \
    --scope $projectWorkspaceId \
    --query "[?roleDefinitionName=='$role'].roleDefinitionName" \
    --output tsv \
    --only-show-errors 2>/dev/null)

  if [[ $current == $role ]]; then
    echo "The [${variables[endpointName]}] Azure Machine Learning online endpoint managed identity is already assigned the ["$current"] role with the [${variables[projectWorkspaceName]}] project workspace as a scope"
  else
    echo "The [${variables[endpointName]}] Azure Machine Learning online endpoint managed identity is not assigned the [$role] role with the [${variables[projectWorkspaceName]}] project workspace as a scope"
    echo "Assigning the [$role] role to the [${variables[endpointName]}] Azure Machine Learning online endpoint managed identity with the [${variables[projectWorkspaceName]}] project workspace as a scope..."

    az role assignment create \
      --assignee $endpointPrincipalId \
      --role "$role" \
      --scope $projectWorkspaceId \
      --only-show-errors 1>/dev/null

    if [[ $? == 0 ]]; then
      echo "The [${variables[endpointName]}] Azure Machine Learning online endpoint managed identity has been successfully assigned the [$role] role with the [${variables[projectWorkspaceName]}] project workspace as a scope"
    else
      echo "Failed to assign the [$role] role to the [${variables[endpointName]}] Azure Machine Learning online endpoint managed identity with the [${variables[projectWorkspaceName]}] project workspace as a scope"
      exit 1
    fi
  fi

  # Check if log analytics workspace exists
  echo "Checking whether ["${variables[logAnalyticsName]}"] Log Analytics already exists..."
  az monitor log-analytics workspace show \
    --name "${variables[logAnalyticsName]}" \
    --resource-group "${variables[resourceGroupName]}" \
    --query id \
    --output tsv \
    --only-show-errors 2>/dev/null

  if [[ $? != 0 ]]; then
    echo "No ["${variables[logAnalyticsName]}"] log analytics workspace actually exists in the ["${variables[resourceGroupName]}"] resource group"
    echo "Creating ["${variables[logAnalyticsName]}"] log analytics workspace in the ["${variables[resourceGroupName]}"] resource group..."

    # Create the log analytics workspace
    az monitor log-analytics workspace create \
      --name "${variables[logAnalyticsName]}" \
      --resource-group "${variables[resourceGroupName]}" \
      --identity-type SystemAssigned \
      --sku "${variables[logAnalyticsSku]}" \
      --location "${variables[location]}" \
      --only-show-errors

    if [[ $? == 0 ]]; then
      echo "["${variables[logAnalyticsName]}"] log analytics workspace successfully created in the ["${variables[resourceGroupName]}"] resource group"
    else
      echo "Failed to create ["${variables[logAnalyticsName]}"] log analytics workspace in the ["${variables[resourceGroupName]}"] resource group"
      exit 1
    fi
  else
    echo "["${variables[logAnalyticsName]}"] log analytics workspace already exists in the ["${variables[resourceGroupName]}"] resource group"
  fi

  # Retrieve the log analytics workspace id
  echo "Retrieving resource ID for [${variables[logAnalyticsName]}] Log Analytics workspace..."
  workspaceResourceId=$(az monitor log-analytics workspace show \
    --name "${variables[logAnalyticsName]}" \
    --resource-group "${variables[resourceGroupName]}" \
    --query id \
    --output tsv \
    --only-show-errors 2>&1  | tr -d '\r')

  if [[ -n "$workspaceResourceId" && "$workspaceResourceId" =~ ^/subscriptions/.*/resourceGroups/.*/providers/Microsoft\.OperationalInsights/workspaces/.*$ ]]; then
    echo "Successfully retrieved resource ID for [${variables[logAnalyticsName]}] workspace"
  else
    echo "ERROR: Failed to retrieve valid workspace ID. Output: $workspaceResourceId" >&2
    exit 1
  fi
fi 
# Check if the diagnostic setting for the Azure Machine Learning online endpoint already exists
echo "Checking if the [${variables[diagnosticSettingName]}] diagnostic setting for the [${variables[endpointName]}] Azure Machine Learning online endpoint actually exists..."
result=$(az monitor diagnostic-settings show \
  --name "${variables[diagnosticSettingName]}" \
  --resource "$endpointResourceId" \
  --query name \
  --output tsv 2>/dev/null || true)

if [[ -z "$result" ]]; then
  echo "[${variables[diagnosticSettingName]}] diagnostic setting for the [${variables[endpointName]}] Azure Machine Learning online endpoint does not exist"
  echo "Creating [${variables[diagnosticSettingName]}] diagnostic setting..."

  if ! az monitor diagnostic-settings create \
    --name "${variables[diagnosticSettingName]}" \
    --resource "$endpointResourceId" \
    --logs '[{"categoryGroup": "allLogs", "enabled": true}]' \
    --metrics '[{"category": "Traffic", "enabled": true}]' \
    --workspace "$workspaceResourceId" \
    --only-show-errors; then

    echo "Failed to create diagnostic setting"
    exit 1
  fi
  echo "[${variables[diagnosticSettingName]}] diagnostic setting successfully created"
else
  echo "[${variables[diagnosticSettingName]}] diagnostic setting already exists for [${variables[endpointName]}]"
fi

# Check whether the Azure Machine Learning model already exists in the project workspace
echo "Checking whether the [${variables[modelName]}] Azure Machine Learning model already exists in the [${variables[projectWorkspaceName]}] project workspace..."
if ! az ml model show \
  --name "${variables[modelName]}" \
  --version "${variables[modelVersion]}" \
  --workspace-name "${variables[projectWorkspaceName]}" \
  --resource-group "${variables[resourceGroupName]}" \
  --only-show-errors 2>/dev/null; then

  echo "The [${variables[modelName]}] Azure Machine Learning model does not exist in the [${variables[projectWorkspaceName]}] project workspace."
  echo "Creating the [${variables[modelName]}] Azure Machine Learning model in the [${variables[projectWorkspaceName]}] project workspace..."

  # Create a YAML file for the Azure Machine Learning model
  yamlFileName="${variables[tempDirectory]}/model.yaml"
  cat <<EOF >"$yamlFileName"
\$schema: https://azuremlschemas.azureedge.net/latest/model.schema.json
name: ${variables[modelName]}
version: ${variables[modelVersion]}
path: ${variables[promptFlowName]}
description: ${variables[modelDescription]}
properties:
  azureml.promptflow.dag_file: flow.dag.yaml
EOF

  if [ "${variables[debug]}" == "true" ]; then
    cat "$yamlFileName"
  fi

  # Create the Azure Machine Learning model
  if ! az ml model create \
    --file $yamlFileName \
    --workspace-name "${variables[projectWorkspaceName]}" \
    --resource-group "${variables[resourceGroupName]}" \
    --only-show-errors; then

    echo "An error occurred while creating the [${variables[modelName]}] Azure Machine Learning model in the [${variables[projectWorkspaceName]}] project workspace."
    exit 1
  fi
  echo "The [${variables[modelName]}] Azure Machine Learning model was created successfully in the [${variables[projectWorkspaceName]}] project workspace."
else
  echo "The [${variables[modelName]}] Azure Machine Learning model already exists in the [${variables[projectWorkspaceName]}] project workspace."
fi

# Check if the Azure Machine Learning environment already exists
echo "Checking if the [${variables[environmentName]}] Azure Machine Learning environment with [${variables[environmentName]}] version already exists in the [${variables[projectWorkspaceName]}] project workspace..."
if ! az ml environment show \
  --name "${variables[environmentName]}" \
  --version "${variables[environmentVersion]}" \
  --resource-group "${variables[resourceGroupName]}" \
  --workspace-name "${variables[projectWorkspaceName]}" \
  --only-show-errors 2>/dev/null; then

  echo "The [${variables[environmentName]}] Azure Machine Learning environment with [${variables[environmentName]}] version already exists in the [${variables[projectWorkspaceName]}] project workspace."

  echo "Creating the [${variables[environmentName]}] Azure Machine Learning environment with [${variables[environmentName]}] version in the [${variables[projectWorkspaceName]}] project workspace..."

  # Create a YAML file for the Azure Machine Learning environment
  yamlFileName="${variables[tempDirectory]}/environment.yaml"
  cat <<EOF >"$yamlFileName"
\$schema: https://azuremlschemas.azureedge.net/latest/environment.schema.json
name: ${variables[environmentName]}
version: ${variables[environmentVersion]}
image: ${variables[environmentImage]}
description: ${variables[environmentDescription]}
# conda_file:
#  name: conda.yaml
#  content: |
#    name: custom-pf-runtime
#    channels:
#      - defaults
#    dependencies:
#      - python=3.11
#      - pip
#      - pip:
#        - promptflow-tools
#        - azure-mgmt-compute
#        - azure-mgmt-network 
#        - azure-mgmt-resource 
#        - azure-identity 
#        - azure-ai-ml 
#        - promptflow-sdk 
#        - promptflow-azure 
#        - azure-ai-ml
inference_config:
  liveness_route:
    path: /health
    port: 8080
  readiness_route:
    path: /health
    port: 8080
  scoring_route:
    path: /score
    port: 8080

EOF

  if [ "${variables[debug]}" == "true" ]; then
    cat "$yamlFileName"
  fi

  # Create the Azure Machine Learning environment
  if ! az ml environment create \
    --file $yamlFileName \
    --name "${variables[environmentName]}" \
    --version "${variables[environmentVersion]}" \
    --resource-group "${variables[resourceGroupName]}" \
    --workspace-name "${variables[projectWorkspaceName]}" \
    --only-show-errors; then

    echo "An error occurred while creating the [${variables[environmentName]}] Azure Machine Learning environment with [${variables[environmentName]}] version in the [${variables[projectWorkspaceName]}] project workspace."
    exit 1
  fi
  echo "The [${variables[environmentName]}] Azure Machine Learning environment with [${variables[environmentVersion]}] version was created successfully in the [${variables[projectWorkspaceName]}] project workspace."
else
  echo "The [${variables[environmentName]}] Azure Machine Learning environment with [${variables[environmentVersion]}] version already exists in the [${variables[projectWorkspaceName]}] project workspace."
fi

# Check whether the hub workspace is configured to use a managed virtual network 
echo "Checking whether the [${variables[hubWorkspaceName]}] hub workspace is configured to use a managed virtual network..."
isolationMode=$(az ml workspace show \
  --name "${variables[hubWorkspaceName]}" \
  --resource-group "${variables[resourceGroupName]}" \
  --query managed_network.isolation_mode \
  --output tsv \
  --only-show-errors)

if [ $? -eq 0 ]; then 
  if [ "$isolationMode" != "disabled" ]; then
    echo "[${variables[hubWorkspaceName]}] hub workspace has [$isolationMode] isolation mode"
    echo "Checking whether managed virtual network for the [${variables[hubWorkspaceName]}] hub workspace has been provisioned successfully..."

    status=$(az ml workspace show \
      --name "${variables[hubWorkspaceName]}" \
      --resource-group "${variables[resourceGroupName]}" \
      --query managed_network.status.status \
      --output tsv \
      --only-show-errors)
    
    if [ "$status" == "Inactive" ]; then
      echo "Provisioning the managed virtual network for the [${variables[hubWorkspaceName]}] hub workspace..."
      az ml workspace provision-network \
        --name "${variables[hubWorkspaceName]}" \
        --resource-group "${variables[resourceGroupName]}" \
        --only-show-errors 1>/dev/null
      
      if [ $? -eq 0 ]; then 
        echo "The managed virtual network for the [${variables[hubWorkspaceName]}] hub workspace has been successfully provisioned"
      else
        echo "An error occurred while provisioning the managed virtual network for the [${variables[hubWorkspaceName]}] hub workspace"
        exit 1
      fi
    else
      echo "A managed virtual network already exists for the [${variables[hubWorkspaceName]}] hub workspace"
    fi
  else
    echo "[${variables[hubWorkspaceName]}] hub workspace has [$isolationMode] isolation mode, hence it's not configured to use a managed virtual network"
  fi
else
  echo "An error occurred while retrieving data of the [${variables[hubWorkspaceName]}] hub workspace"
  exit 1
fi

# Create a YAML file for the Azure Machine Learning managed online deployment
yamlFileName="${variables[tempDirectory]}/deployment.yaml"
lowercaseLocation=$(echo "${variables[location]}" | tr '[:upper:]' '[:lower:]')
cat <<EOF >"$yamlFileName"
\$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineDeployment.schema.json
name: ${variables[deploymentName]}
endpoint_name: ${variables[endpointName]}
model: azureml:${variables[modelName]}:${variables[modelVersion]}
environment: azureml:${variables[environmentName]}:${variables[environmentVersion]}
instance_type: ${variables[deploymentInstanceType]}
instance_count: ${variables[deploymentInstanceCount]}
environment_variables:
  # When there are multiple fields in the response, using this env variable will filter the fields to expose in the response.
  # For example, if there are 2 flow outputs: "answer", "context", and I only want to have "answer" in the endpoint response, I can set this env variable to '["answer"]'
  # PROMPTFLOW_RESPONSE_INCLUDED_FIELDS: '["analysisOutputBlobUri"]'

  # if you want to deploy to serving mode, you need to set this env variable to "serving"
  PROMPTFLOW_RUN_MODE: "serving"
  RUN_MODE: "serving"
  PRT_CONFIG_OVERRIDE: "storage.storage_account=${variables[storageAccountName]},deployment.subscription_id=$subscriptionId,deployment.resource_group=${variables[resourceGroupName]},deployment.workspace_name=${variables[projectWorkspaceName]},deployment.endpoint_name=${variables[endpointName]},deployment.deployment_name=${variables[deploymentName]},deployment.mt_service_endpoint=https://${lowercaseLocation}.api.azureml.ms"
  PROMPTFLOW_MDC_ENABLE: "True"
  AZURE_ACTIVE_DIRECTORY: "https://login.microsoftonline.com"
  AZURE_RESOURCE_MANAGER: "https://management.azure.com"
# Enable this will collect metrics such as latency/token/etc during inference time to workspace default Azure Application Insights
app_insights_enabled: ${variables[applicationInsightsEnabled]}
request_settings:
  request_timeout_ms: 180000
  max_concurrent_requests_per_instance: ${variables[maxConcurrentRequestsPerInstance]}
scale_settings:
  type: default
readiness_probe:
    failure_threshold: 30
    initial_delay: 10
    period: 10
    success_threshold: 1
    timeout: 2
liveness_probe:
    failure_threshold: 30
    initial_delay: 10
    period: 10
    success_threshold: 1
    timeout: 2
data_collector:
  sampling_rate: 1.0
  collections:
    app_traces:
      enabled: "True"
    model_inputs:
      enabled: "True"
    model_outputs:
      enabled: "True"
EOF

if [ "${variables[debug]}" == "true" ]; then
  cat "$yamlFileName"
fi

# Check if the Azure Machine Learning managed online deployment already exists
echo "Checking if the [${variables[deploymentName]}] Azure Machine Learning managed online deployment already exists..."
if az ml online-deployment show \
  --name "${variables[deploymentName]}" \
  --endpoint-name "${variables[endpointName]}" \
  --resource-group "${variables[resourceGroupName]}" \
  --workspace-name "${variables[projectWorkspaceName]}" \
  --only-show-errors &>/dev/null; then

  echo "The [${variables[deploymentName]}] Azure Machine Learning managed online deployment already exists."

  if [ "${variables[updateExistingDeployment]}" == "true" ]; then
    echo "Updating the [${variables[deploymentName]}] Azure Machine Learning managed online deployment in the [${variables[resourceGroupName]}] resource group..."
    if ! az ml online-deployment update \
      --name "${variables[deploymentName]}" \
      --endpoint-name "${variables[endpointName]}" \
      --workspace-name "${variables[projectWorkspaceName]}" \
      --resource-group "${variables[resourceGroupName]}" \
      --file $yamlFileName \
      --only-show-errors; then
      echo "Failed to update deployment"
      exit 1
      fi
      echo "Deployment updated successfully"
    fi
  else
    echo "The [${variables[deploymentName]}] deployment does not exist. Creating new deployment..."

  if ! az ml online-deployment create \
    --name "${variables[deploymentName]}" \
    --endpoint-name "${variables[endpointName]}" \
    --workspace-name "${variables[projectWorkspaceName]}" \
    --resource-group "${variables[resourceGroupName]}" \
    --file $yamlFileName \
    --only-show-errors; then
    echo "Failed to create deployment"
    echo "=== DEPLOYMENT LOGS ==="
    az ml online-deployment get-logs \
      --name "${variables[deploymentName]}" \
      --endpoint-name "${variables[endpointName]}" \
      --resource-group "${variables[resourceGroupName]}" \
      --workspace-name "${variables[projectWorkspaceName]}" \
      --lines 100
    exit 1
    
  fi
  echo "Deployment created successfully"
 
    # Configuraing the Azure Machine Learning manaed endpoint to send 100% traffic to the new deployment
    echo "Configuring the [${variables[endpointName]}] Azure Machine Learning managed endpoint to send 100% traffic to the [${variables[deploymentName]}] deployment..."
    if ! az ml online-endpoint update \
      --name "${variables[endpointName]}" \
      --resource-group "${variables[resourceGroupName]}" \
      --workspace-name "${variables[projectWorkspaceName]}" \
      --traffic ${variables[deploymentName]}=100 \
      --only-show-errors; then

    echo "Failed to update traffic routing"
    exit 1
  fi
  echo "Traffic successfully routed to new deployment"
fi  

# Remove the temporary directory
if ! remove_directory "${variables[tempDirectory]}"; then
  echo "Failed to remove temporary directory"
  exit 1
fi