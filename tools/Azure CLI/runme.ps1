param(
	[Alias("var-file")]
    [string]$envArgument
)

# Check if the parameter has been passed and is not empty
if ([string]::IsNullOrWhiteSpace($envArgument)) {
    Write-Output "No valid string parameter provided. Exiting script.";
    exit;
}

# Ensure the parameter has a .env extension
if (-not $envArgument.EndsWith('.env')) {
    $envArgument += '.env';
}

# Check if the file exists
if (-not (Test-Path $envArgument)) {
    Write-Output "The file '$envArgument' does not exist. Exiting script.";
    exit;
}

$envFileContent = Get-Content -Path $envArgument;
$envVariables = @{}
foreach ($line in $envFileContent) {
    $parts = $line.Split('=', 2)
    if ($parts.Length -eq 2) {
        $key = $parts[0].Trim()
        $value = $parts[1].Trim().TrimStart('"').TrimEnd('"')
        $envVariables[$key] = $value
    }
}

# # # === -=[INITIALS]=-
# # az account clear;
# # az login;
# az account list --output table;
# az account set --subscription "Visual Studio Enterprise Subscription";
# az config set extension.use_dynamic_install=yes_without_prompt;
# az extension add --name containerapp --upgrade;
# az provider register --namespace Microsoft.App;
# az provider register --namespace Microsoft.OperationalInsights;


$resource_group_name = "$($envVariables.app_code_name)-$($envVariables["environment"])";
$service_principal_name = "$($envVariables.app_code_name)-$($envVariables["environment"])";
$envVariables.environmentAsTitleCase = (Get-Culture).TextInfo.ToTitleCase($envVariables.environment.ToLower());
$container_app_api = "$($envVariables.app_code_name)-$($envVariables.container_app_suffix_api)";

# === -=[RESOURCES]=-
$SUBSCRIPTION_ID = az account show --query id --output tsv;


# === RESOURCE GROUP
az group create --location $envVariables.location --name $resource_group_name;


# === SERVICE PRINCIPAL
$SERVICE_PRINCIPAL_JSON = az ad sp create-for-rbac --role contributor --name $service_principal_name --scopes "$(az group show --name $resource_group_name --query id --output tsv)";
$SERVICE_PRINCIPAL = $SERVICE_PRINCIPAL_JSON | ConvertFrom-Json;
$markdownContent = @"
# GITHUB


## VARIABLES

### CONTAINER_APP_NAME_PREFIX
``$($envVariables.app_code_name)``


## SECRETS

### AZURE_CONTAINERREGISTRY

``$($envVariables.container_registry)``

### AZURE_CREDENTIALS

``````json
{
  "clientId": "$($SERVICE_PRINCIPAL.appId)",
  "clientSecret": "$($SERVICE_PRINCIPAL.password)",
  "subscriptionId": "$SUBSCRIPTION_ID",
  "tenantId": "$($SERVICE_PRINCIPAL.tenant)"
}
``````
"@
$markdownContent | Out-File -FilePath "output.md"


# === IDENTITY
az identity create --resource-group $resource_group_name --name $envVariables.user_assigned_identity_dapr;
$DAPR_IDENTITY_ID = az identity show --resource-group $resource_group_name --name $envVariables.user_assigned_identity_dapr --query id --output tsv;
$DAPR_CLIENT_ID = az identity show --resource-group $resource_group_name --name $envVariables.user_assigned_identity_dapr --query clientId --output tsv;
$DAPR_PRINCIPAL_ID = az identity show --resource-group $resource_group_name --name $envVariables.user_assigned_identity_dapr --query principalId --output tsv;


# === LOG-ANALYTICS
az monitor log-analytics workspace create -l $envVariables.location -g $resource_group_name -n $envVariables.log_analytics_workspace --ingestion-access "Enabled" --query-access "Enabled" --quota "0.1" --retention-time "30";


# === APP-CONFIGURATION
az appconfig create -l $envVariables.location -g $resource_group_name --name $envVariables.app_configuration --sku "Free";
az role assignment create --role "App Configuration Data Reader" --scope $(az appconfig show -g $resource_group_name -n $envVariables.app_configuration --query id --output tsv) --assignee $DAPR_PRINCIPAL_ID;
$APPCONFIG_ENDPOINT = az appconfig show -g $resource_group_name -n $envVariables.app_configuration --query endpoint --output tsv;
az appconfig kv set --name $envVariables.app_configuration --key "Test" --value "T123" --content-type "text/plain" --label "common" --yes;


# === CONTAINER-REGISTRY
az acr create -l $envVariables.location -g $resource_group_name -n $envVariables.container_registry --sku "Basic" --admin-enabled;
$ACR_LOGIN_SERVER = az acr show -g $resource_group_name -n $envVariables.container_registry --query loginServer --output tsv;
$ACR_ADMIN_USERNAME=az acr credential show -g $resource_group_name -n $envVariables.container_registry --query username --output tsv;
$ACR_ADMIN_PASSWORD=az acr credential show -g $resource_group_name -n $envVariables.container_registry --query passwords[0].value --output tsv;


# === DEFAULT CONTAINER IMAGE
$IMAGE = "nginx:alpine";
az acr login --name $ACR_LOGIN_SERVER;
$exists = az acr repository show --name $ACR_LOGIN_SERVER --image $IMAGE --output tsv;
if (-not $exists) {
	docker pull $IMAGE;
	docker tag $IMAGE $ACR_LOGIN_SERVER/$IMAGE;
	docker push $ACR_LOGIN_SERVER/$IMAGE;
}


# === CONTAINER-APP-ENVIRONMENT
az containerapp env create -l $envVariables.location -g $resource_group_name -n $envVariables.container_app_environment --logs-destination "log-analytics" --logs-workspace-id=$(az monitor log-analytics workspace show -g $resource_group_name -n $envVariables.log_analytics_workspace --query customerId --output tsv) --logs-workspace-key=$(az monitor log-analytics workspace get-shared-keys -g $resource_group_name -n $envVariables.log_analytics_workspace --query "primarySharedKey" --output tsv);


# === DAPR COMPONENT DEFINITION
$yamlContent = @"
componentType: configuration.azure.appconfig
version: v1
metadata:
  - name: azureClientId
    value: "$DAPR_CLIENT_ID"
  - name: host
    value: "$APPCONFIG_ENDPOINT"
scopes:
  - $($envVariables.container_app_suffix_api)
"@;
$yamlContent | Out-File -FilePath "configuration.yaml";
az containerapp env dapr-component set -g $resource_group_name -n $envVariables.container_app_environment --dapr-component-name "configuration" --yaml configuration.yaml;
Remove-Item -Path "configuration.yaml";


# === CONTAINER-APP
az containerapp create -n $container_app_api -g $resource_group_name `
    --environment $envVariables.container_app_environment `
    --image "$ACR_LOGIN_SERVER/$IMAGE" `
    --ingress "external" --target-port 80 `
    --registry-server $ACR_LOGIN_SERVER --registry-username $ACR_ADMIN_USERNAME --registry-password $ACR_ADMIN_PASSWORD `
    --cpu 0.25 --memory 0.5Gi `
    --min-replicas 1 --max-replicas 1 `
    --env-vars "$($envVariables.environment_variable_name)=$($envVariables.environmentAsTitleCase)" `
    --tags "stack=dotnetcore" ;
    # --user-assigned $DAPR_IDENTITY_ID;

az containerapp dapr enable -n $container_app_api -g $resource_group_name --dapr-app-id $envVariables.container_app_suffix_api --dapr-app-port 80 --dapr-app-protocol "http" --dapr-log-level "debug" --dapr-enable-api-logging;
