#!/bin/bash

# Load helper functions
source ./functions.sh

# Set deployment variables
declare -A variables=(
  [template]="main.bicep"
  [parameters]="parameters.json"
  [resourceGroupName]="m2c-azure-bot"
  [location]="westeurope"
  [validateTemplate]=1
  [useWhatIf]=0
)

# Get subscription ID
subscriptionId=$(az account show --query id --output tsv | tr -d '\r')
subscriptionName=$(az account show --query name --output tsv)

parse_args variables $@

# Ensure user is logged in
az account show 1>/dev/null
if [[ $? != 0 ]]; then
  echo "Please login to Azure first: az login"
  exit 1
fi

# Check if the resource group exists, create if not
echo "Checking if [$resourceGroupName] resource group exists in the [$subscriptionName] subscription..."
az group show --name $resourceGroupName --subscription $subscriptionId &>/dev/null

if [[ $? != 0 ]]; then
  echo "No [$resourceGroupName] resource group exists in the [$subscriptionName] subscription"
  echo "Creating [$resourceGroupName] resource group in the [$subscriptionName] subscription..."

  # Create the resource group
  az group create --name $resourceGroupName --location $location --subscription $subscriptionId 1>/dev/null

  if [[ $? == 0 ]]; then
    echo "[$resourceGroupName] resource group successfully created in the [$subscriptionName] subscription"
  else
    echo "Failed to create [$resourceGroupName] resource group in the [$subscriptionName] subscription"
    exit 1
  fi
else
  echo "[$resourceGroupName] resource group already exists in the [$subscriptionName] subscription"
fi

# Deploy the Bicep template
echo "Deploying [$template] Bicep template..."
deploymentOutputs=$(az deployment group create \
  --resource-group $resourceGroupName \
  --subscription $subscriptionId \
  --only-show-errors \
  --template-file $template \
  --parameters $parameters \
  --parameters location=$location \
  --query 'properties.outputs' -o json)

if [[ $? == 0 ]]; then
  echo "Successfully deployed [$template] Bicep template"
  echo $deploymentOutputs
else
  echo "Failed to deploy [$template] Bicep template"
  exit 1
fi