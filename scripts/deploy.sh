#!/bin/bash

set -e

echo Active Subscription:
az account show -o table
SUBSCRIPTION_ID=$(az account show -o tsv --query "id")

CLUSTER_DEFINITION=./kubernetes.west.json
VNET_NAME=KubernetesCustomVNET
SUBNET_NAME=KubernetesSubnet
SUBNET_ADDRESS_PREFIX=10.1.0.0/16
#POD_CIDR=10.100.0.0/16
LOCATION_1=southcentralus
SERVICE_PRINCIPAL=""
SP_SECRET=""
DNS_PREFIX=""
SSH_PUBLIC_KEY=""

check_prereq()
{
    # if [[ -z ${GOPATH} ]];
    # then
    #     echo GOPATH not set. Are you able to build or run acs-engine?
    #     exit 1
    # fi

    if [[ -z ${CLUSTER_DEFINITION} ]];
    then
        echo CLUSTER_DEFINITION undefined. Exiting.
        exit 1
    fi

    if [[ -z ${RESOURCE_GROUP} ]];
    then
        echo RESOURCE_GROUP undefined. Exiting.
        exit 1
    fi

    if [[ -z ${SSH_PUBLIC_KEY} ]];
    then
        echo SSH_PUBLIC_KEY undefined. Exiting.
        exit 1
    fi

    if [[ -z ${SP_SECRET} ]];
    then
        echo SP_SECRET undefined. Exiting.
        exit 1
    fi
    
    if [[ -z ${SERVICE_PRINCIPAL} ]];
    then
        echo SERVICE_PRINCIPAL undefined. Exiting.
        exit 1
    fi

    if [[ -z ${DNS_PREFIX} ]];
    then
        echo DNS_PREFIX undefined. Exiting.
        exit 1
    fi

    
}

fixup_apimodel()
{
    tempfile="$(mktemp)"
    trap "rm -rf \"${tempfile}\"" EXIT

    echo fixing up API model template with subnetRef
    subnetRef=/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${SUBNET_NAME} 

    echo Updating API model ${CLUSTER_DEFINITION} with subscription id ${SUBSCRIPTION_ID} and vnet name ${VNET_NAME}
    jq ".properties.masterProfile.vnetSubnetId = \"${subnetRef}\"" ${CLUSTER_DEFINITION} > $tempfile && mv $tempfile ${CLUSTER_DEFINITION}

    echo fixing up API model with service principal and dnsPrefix
    jq ".properties.masterProfile.dnsPrefix = \"${DNS_PREFIX}\"" ${CLUSTER_DEFINITION} > $tempfile && mv $tempfile ${CLUSTER_DEFINITION}
    jq ".properties.linuxProfile.ssh.publicKeys[0].keyData = \"${SSH_PUBLIC_KEY}\"" ${CLUSTER_DEFINITION} > $tempfile && mv $tempfile ${CLUSTER_DEFINITION}
    jq ".properties.servicePrincipalProfile.clientId = \"${SERVICE_PRINCIPAL}\"" ${CLUSTER_DEFINITION} > $tempfile && mv $tempfile ${CLUSTER_DEFINITION}
    jq ".properties.servicePrincipalProfile.secret = \"${SP_SECRET}\"" ${CLUSTER_DEFINITION} > $tempfile && mv $tempfile ${CLUSTER_DEFINITION}
    #jq ".properties.orchestratorProfile.kubernetesConfig.clusterSubnet = \"${POD_CIDR}\"" ${CLUSTER_DEFINITION} > $tempfile && mv $tempfile ${CLUSTER_DEFINITION}
    firstIP=$(echo ${SUBNET_ADDRESS_PREFIX} | sed 's/\([0-9]*\).\([0-9]*\).*$/\1.\2.255.239/g')
    jq ".properties.masterProfile.firstConsecutiveStaticIP = \"${firstIP}\"" ${CLUSTER_DEFINITION} > $tempfile && mv $tempfile ${CLUSTER_DEFINITION}

    indx=0
    echo Updating agent pool definitions
    for poolname in `jq -r '.properties.agentPoolProfiles[].name' "${CLUSTER_DEFINITION}"`; do
        echo Updating $poolname in ${CLUSTER_DEFINITION}
        jq ".properties.agentPoolProfiles[$indx].vnetSubnetId = \"${subnetRef}\"" ${CLUSTER_DEFINITION} > $tempfile && mv $tempfile ${CLUSTER_DEFINITION}
        indx=$((indx+1))
    done
}

deploy_cluster()
{
    echo Creating Resource Group ${RESOURCE_GROUP} in ${LOCATION_1}
    az group create -l ${LOCATION_1} -n ${RESOURCE_GROUP}
    echo Creating Virtual Network
    out=$(az group deployment create -g ${RESOURCE_GROUP} --template-file templates/azuredeploy.vnet.json )

    vnetId=$(echo $out | jq .properties.outputs.vnetId.value -r) 
    subnetRef=$(echo $out | jq .properties.outputs.subnetRef.value -r) 

    echo TODO: Deploying the whole shebang
    echo Deploying into ${RESOURCE_GROUP} with DNS Prefix ${DNS_PREFIX} 
    az group deployment create -g ${RESOURCE_GROUP} --template-file _output/${DNS_PREFIX}/azuredeploy.json --parameters @_output/${DNS_PREFIX}/azuredeploy.parameters.json

    #echo cluster deployed. Checking route-table
    #routeTableName=$(az resource list -g ${RESOURCE_GROUP} --resource-type Microsoft.Network/routeTables --query [0].name -o tsv) 
    #echo Found route table $routeTableName
    #table=$(az network route-table route list -g ${RESOURCE_GROUP{} --route-table-name $routeTableName -o table)

    #if [[ -z $table ]];
    #then
    #    echo Route table should not be empty (but sometimes is)
    #    echo to fix try: 
    #    echo az network vnet subnet update -n ${SUBNET_NAME} -g ${RESOURCE_GROUP} --vnet-name ${VNET_NAME} --route-table $routeTableName
    #    exit 1
    #else
    #    echo $table
    #fi

    echo cluster deployed
}

ensure_acsengine()
{
    echo Checking for acs-engine

    if [ ! -d "acs-engine" ]
    then
        echo Cloning
        git clone https://github.com/Azure/acs-engine.git 
    fi

    if [[ ! -e ./acs-engine/bin/acs-engine ]];
    then
        pushd .
        cd ./acs-engine
        make build
        popd
    fi
}

rebuild_armtemplates()
{
    acs-engine/bin/acs-engine generate ${CLUSTER_DEFINITION}    
}

install_helm()
{
    ${SSH_EXEC} "curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash"
    ${SSH_EXEC} "echo export HELM_HOME=/home/azureuser/ >> .bashrc"
    ${SSH_EXEC} "helm init"
    sleep 10
}


install_cassandra()
{
    echo Fetching charts
    ${SSH_EXEC} "rm -rf ./charts"
    ${SSH_EXEC} "git clone https://github.com/xtophs/charts.git"
    ${SSH_EXEC} "cd charts && git checkout cassandra-multi-dc"
    echo installing cassandra
    ${SSH_EXEC} "helm install charts/incubator/cassandra"
}

check_prereq
fixup_apimodel
ensure_acsengine
rebuild_armtemplates
deploy_cluster

ipName=$(az resource list -g ${RESOURCE_GROUP} --resource-type Microsoft.Network/publicIPAddresses --query [0].name --out tsv) 
echo Found IP address $ipName
ipAddress=$(az resource show -g ${RESOURCE_GROUP} --resource-type Microsoft.Network/publicIPAddresses -n $ipName --query properties.ipAddress --out tsv)
echo Address is $ipAddress
SSH_EXEC="ssh azureuser@${ipAddress} "

install_helm
install_cassandra




