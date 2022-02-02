!/bin/bash

set -e

# az extension remove -n containerapp
# EXTENSION=$(az extension list --query "[?contains(name, 'containerapp')].name" -o tsv)
# if [ "$EXTENSION" = "" ]; then
    #az extension add --source https://workerappscliextension.blob.core.windows.net/azure-cli-extension/containerapp-0.2.2-py2.py3-none-any.whl -y
# fi


# infrastructure deployment properties
DEPLOYMENT_NAME="$1" # here enter unique deployment name (ideally short and with letters for global uniqueness)

SUBSCRIPTION_ID=$(az account show --query id -o tsv) 
AZURE_CORE_ONLY_SHOW_ERRORS="True"
ACA_ENV_NAME="env-$DEPLOYMENT_NAME" # Name of the ContainerApp Environment
REDIS_NAME="rds-env-$DEPLOYMENT_NAME"
ACA_VNET_NAME="vnet-$DEPLOYMENT_NAME"
RESOURCE_GROUP=$DEPLOYMENT_NAME # here enter the resources group
LOG_ANALYTICS_WORKSPACE_NAME="logs-$ACA_ENV_NAME"
AI_INSTRUMENTATION_KEY=""
LOCATION="canadacentral"

if [ $(az group exists --name $RESOURCE_GROUP) = false ]; then
    echo "creating resource group $RESOURCE_GROUP..."
    az group create -n $RESOURCE_GROUP -l $LOCATION -o none
    echo "resource group $RESOURCE_GROUP created"
else   
    echo "resource group $RESOURCE_GROUP already exists"
fi


echo "setting up vnet"

VNET_RESOURCE_ID=$(az network vnet list -g $RESOURCE_GROUP --query "[?contains(name, '$ACA_VNET_NAME')].id" -o tsv)
if [ "$VNET_RESOURCE_ID" == "" ]; then
    echo "creating vnet $ACA_VNET_NAME..."
    az network vnet create  --address-prefixes "10.0.0.0/19"  -g $RESOURCE_GROUP -n $ACA_VNET_NAME -o none
    az network vnet subnet create -g $RESOURCE_GROUP --vnet-name $ACA_VNET_NAME -n gateway --address-prefix 10.0.0.0/24   -o none
    az network vnet subnet create -g $RESOURCE_GROUP --vnet-name $ACA_VNET_NAME -n jumpbox --address-prefix 10.0.1.0/24  -o none
    az network vnet subnet create -g $RESOURCE_GROUP --vnet-name $ACA_VNET_NAME -n apim --address-prefix 10.0.2.0/24   -o none
    az network vnet subnet create -g $RESOURCE_GROUP --vnet-name $ACA_VNET_NAME -n AzureFirewallSubnet --address-prefix 10.0.3.0/24   -o none
    az network vnet subnet create -g $RESOURCE_GROUP --vnet-name $ACA_VNET_NAME -n aca-control --address-prefix 10.0.8.0/21  -o none
    az network vnet subnet create -g $RESOURCE_GROUP --vnet-name $ACA_VNET_NAME -n aca-apps --address-prefix 10.0.16.0/21  -o none
    VNET_RESOURCE_ID=$(az network vnet show -g $RESOURCE_GROUP -n $ACA_VNET_NAME --query id -o tsv)
    echo "created $VNET_RESOURCE_ID"
else
    echo "vnet $VNET_RESOURCE_ID already exists"
fi

ACA_CONTROL_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $ACA_VNET_NAME -n aca-control --query id -o tsv)
ACA_APPS_SUBNET_ID=$(az network vnet subnet show -g $RESOURCE_GROUP --vnet-name $ACA_VNET_NAME -n aca-apps --query id -o tsv)

echo "setting up azure monitor"

WORKSPACE_RESOURCE_ID=$(az monitor log-analytics workspace list --resource-group $RESOURCE_GROUP --query "[?contains(name, '$LOG_ANALYTICS_WORKSPACE_NAME')].id" -o tsv)
if [ "$WORKSPACE_RESOURCE_ID" == "" ]; then
    echo "creating workspace $LOG_ANALYTICS_WORKSPACE_NAME in $RESOURCE_GROUP"
    az monitor log-analytics workspace create --resource-group $RESOURCE_GROUP --workspace-name $LOG_ANALYTICS_WORKSPACE_NAME --location $LOCATION -o none
    WORKSPACE_RESOURCE_ID=$(az monitor log-analytics workspace show --resource-group $RESOURCE_GROUP --workspace-name $LOG_ANALYTICS_WORKSPACE_NAME -o json | jq '.id' -r)

    az monitor app-insights component create --app $LOG_ANALYTICS_WORKSPACE_NAME-ai --location $LOCATION --resource-group $RESOURCE_GROUP --application-type web --kind web --workspace $WORKSPACE_RESOURCE_ID
    
else
    echo "workspace $WORKSPACE_RESOURCE_ID already exists"
fi

ACA_APP_ENV_ID=$(az containerapp env list -g $RESOURCE_GROUP --query "[?contains(name, '$ACA_ENV_NAME')].id" -o tsv)
if [ "$ACA_APP_ENV_ID" == "" ]; then
    echo "creating worker app env $ACA_APP_ENV_ID"

    AI_INSTRUMENTATION_KEY=$(az monitor app-insights component show --app $LOG_ANALYTICS_WORKSPACE_NAME-ai -g $RESOURCE_GROUP --query "[instrumentationKey]" -o tsv)
    LOG_ANALYTICS_WORKSPACE_CLIENT_ID=`az monitor log-analytics workspace show --query customerId -g $RESOURCE_GROUP -n $LOG_ANALYTICS_WORKSPACE_NAME -o tsv`
    LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET=`az monitor log-analytics workspace get-shared-keys --query primarySharedKey -g $RESOURCE_GROUP -n $LOG_ANALYTICS_WORKSPACE_NAME -o tsv`
    echo "workspace id $LOG_ANALYTICS_WORKSPACE_CLIENT_ID"
    echo "secret $LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET"
    echo "ai key $AI_INSTRUMENTATION_KEY"

    az containerapp env create -n $ACA_ENV_NAME -g $RESOURCE_GROUP --location "$LOCATION"  \
     --platform-reserved-cidr 10.2.0.0/21  --platform-reserved-dns-ip 10.2.0.10 --docker-bridge-cidr 172.17.0.1/16 \
     --logs-workspace-id $LOG_ANALYTICS_WORKSPACE_CLIENT_ID --logs-workspace-key $LOG_ANALYTICS_WORKSPACE_CLIENT_SECRET --instrumentation-key $AI_INSTRUMENTATION_KEY   \
     --app-subnet-resource-id $ACA_APPS_SUBNET_ID --controlplane-subnet-resource-id $ACA_CONTROL_SUBNET_ID # --internal-only

    ACA_APP_ENV_ID=$(az containerapp env show -g $RESOURCE_GROUP -n $ACA_ENV_NAME -o tsv --query id)
    echo "created app env $ACA_APP_ENV_ID"
else
    echo "worker app env $ACA_APP_ENV_ID already exists"
    AI_INSTRUMENTATION_KEY=$(az monitor app-insights component show --app $LOG_ANALYTICS_WORKSPACE_NAME-ai -g $RESOURCE_GROUP --query "[instrumentationKey]" -o tsv)
fi

echo "application insights key $AI_INSTRUMENTATION_KEY"

ENVIRONMENT_DEFAULT_DOMAIN=`az containerapp env show --name ${ACA_ENV_NAME} --resource-group ${RESOURCE_GROUP} --query defaultDomain --out json | tr -d '"'`

ENVIRONMENT_STATIC_IP=`az containerapp env show --name ${ACA_ENV_NAME} --resource-group ${RESOURCE_GROUP} --query staticIp --out json | tr -d '"'`

VNET_ID=`az network vnet show --resource-group ${RESOURCE_GROUP} --name ${ACA_VNET_NAME} --query id --out json | tr -d '"'`


DNS_ZONE_ID=$(az network private-dns zone list -g $RESOURCE_GROUP --query "[?contains(name, '$ENVIRONMENT_DEFAULT_DOMAIN')].id" -o tsv)
if [ "$DNS_ZONE_ID" == "" ]; then
    az network private-dns zone create --resource-group $RESOURCE_GROUP --name $ENVIRONMENT_DEFAULT_DOMAIN
    az network private-dns link vnet create --resource-group $RESOURCE_GROUP --name $ACA_VNET_NAME --virtual-network $VNET_ID --zone-name $ENVIRONMENT_DEFAULT_DOMAIN -e true
    az network private-dns record-set a add-record --resource-group $RESOURCE_GROUP --record-set-name "*" --ipv4-address $ENVIRONMENT_STATIC_IP --zone-name $ENVIRONMENT_DEFAULT_DOMAIN
    DNS_ZONE_ID=$(az network private-dns zone show -g $RESOURCE_GROUP -n $KUBE_NAME --query id -o tsv)
    echo "created $DNS_ZONE_ID"
else
    echo "dns zone $DNS_ZONE_ID already exists"
fi
