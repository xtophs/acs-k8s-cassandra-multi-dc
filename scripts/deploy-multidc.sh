#!/bin/bash

set -e

RESOURCE_GROUP_1=${1}
RESOURCE_GROUP_2=${2}

CLUSTER_DEFINITION_1=./templates/kubernetes.east.json
CLUSTER_DEFINITION_2=./templates/kubernetes.west.json

VNET_NAME=KubernetesCustomVNET
SUBNET_NAME=KubernetesSubnet
VNET_1_FIRST_TWO=10.1
VNET_2_FIRST_TWO=10.2

LOCATION_1=eastus
LOCATION_2=southcentralus

SERVICE_PRINCIPAL=
SP_SECRET=

SSH_PUBLIC_KEY=

# --- Auto populated values. Change at your own risk
VNET_ADDRESS_PREFIX_1=${VNET_1_FIRST_TWO}.0.0/16
VNET_ADDRESS_PREFIX_2=${VNET_2_FIRST_TWO}.0.0/16

SUBNET_ADDRESS_PREFIX_1=${VNET_1_FIRST_TWO}.0.0/17
SUBNET_ADDRESS_PREFIX_2=${VNET_2_FIRST_TWO}.0.0/17

GWSUBNET_ADDRESS_PREFIX_1=${VNET_1_FIRST_TWO}.128.0/29
GWSUBNET_ADDRESS_PREFIX_2=${VNET_2_FIRST_TWO}.128.0/29

GATEWAY_1=GW-${LOCATION_1}
GATEWAY_2=GW-${LOCATION_2}

DNS_PREFIX_1=${RESOURCE_GROUP_1}
DNS_PREFIX_2=${RESOURCE_GROUP_2}
# --------------

check_var_set()
{
    s=$1
    if [[ -z ${!s} ]];
    then
        echo ${s} undefined. Exiting.
        exit 1
    else
        echo ${s} is ${!s}
    fi
}

check_prereq()
{
    check_var_set "SUBSCRIPTION_ID"
    check_var_set "RESOURCE_GROUP_1" 
    check_var_set "RESOURCE_GROUP_2" 

    check_var_set "CLUSTER_DEFINITION_1" 
    check_var_set "CLUSTER_DEFINITION_2" 

    check_var_set "SSH_PUBLIC_KEY" 
    check_var_set "SP_SECRET"
    check_var_set "SERVICE_PRINCIPAL"

    check_var_set "DNS_PREFIX_1"
    check_var_set "DNS_PREFIX_2"
    
    check_var_set "SUBNET_ADDRESS_PREFIX_1"
    check_var_set "SUBNET_ADDRESS_PREFIX_2"
}

fixup_apimodel()
{
    local RG=${1}
    local DNS=${2}
    local ADDRESS_PREFIX=${3}
    local CLUSTER_DEF=${4}

    tempfile="$(mktemp)"
    trap "rm -rf \"${tempfile}\"" EXIT

    echo fixing up API model template with subnetRef
    subnetRef=/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${SUBNET_NAME} 

    echo Updating API model ${CLUSTER_DEF} with subscription id ${SUBSCRIPTION_ID} and vnet name ${VNET_NAME}
    jq ".properties.masterProfile.vnetSubnetId = \"${subnetRef}\"" ${CLUSTER_DEF} > $tempfile && mv $tempfile ${CLUSTER_DEF}

    echo fixing up API model with service principal and dnsPrefix
    jq ".properties.masterProfile.dnsPrefix = \"${DNS}\"" ${CLUSTER_DEF} > $tempfile && mv $tempfile ${CLUSTER_DEF}
    jq ".properties.linuxProfile.ssh.publicKeys[0].keyData = \"${SSH_PUBLIC_KEY}\"" ${CLUSTER_DEF} > $tempfile && mv $tempfile ${CLUSTER_DEF}
    jq ".properties.servicePrincipalProfile.clientId = \"${SERVICE_PRINCIPAL}\"" ${CLUSTER_DEF} > $tempfile && mv $tempfile ${CLUSTER_DEF}
    jq ".properties.servicePrincipalProfile.secret = \"${SP_SECRET}\"" ${CLUSTER_DEF} > $tempfile && mv $tempfile ${CLUSTER_DEF}
    firstIP=$(echo ${ADDRESS_PREFIX} | sed 's/\([0-9]*\).\([0-9]*\).*$/\1.\2.127.250/g')
    jq ".properties.masterProfile.firstConsecutiveStaticIP = \"${firstIP}\"" ${CLUSTER_DEF} > $tempfile && mv $tempfile ${CLUSTER_DEF}
    jq ".properties.masterProfile.vnetCidr = \"${ADDRESS_PREFIX}\"" ${CLUSTER_DEF} > $tempfile && mv $tempfile ${CLUSTER_DEF}

    indx=0
    echo Updating agent pool definitions
    for poolname in `jq -r '.properties.agentPoolProfiles[].name' "${CLUSTER_DEF}"`; do
        echo Updating $poolname in ${CLUSTER_DEF}
        jq ".properties.agentPoolProfiles[$indx].vnetSubnetId = \"${subnetRef}\"" ${CLUSTER_DEF} > $tempfile && mv $tempfile ${CLUSTER_DEF}
        indx=$((indx+1))
    done
}

create_rg_and_vnet()
{
    local RG=${1}
    local LOCATION=${2}
    local GW_NAME=${3}
    local VNET_CIDR=${4}
    local SUBNET_CIDR=${5}
    local GW_CIDR=${6}

    echo Creating Resource Group ${RG} in ${LOCATION}
    az group create -l ${LOCATION} -n ${RG}
    echo Creating Virtual Network with VNET ${VNET_CIDR}, Subnet ${SUBNET_CIDR} GatewaySubnet ${GW_CIDR}

    # Kick off async deployment of the gateway
    az group deployment create -g ${RG} --template-file templates/azuredeploy.gw.json --parameters @templates/azuredeploy.gw.parameters.json --parameters "{ \"gwName\": {\"value\": \"${GW_NAME}\"}, \"vnetCidr\": { \"value\": \"${VNET_CIDR}\"}, \"subnetCidr\": { \"value\": \"${SUBNET_CIDR}\" }, \"gatewaySubnetCidr\": { \"value\": \"${GW_CIDR}\" } }"  --no-wait
}

deploy_cluster()
{
    local RG=${1}
    local LOCATION=$2
    local DNS=$3

    echo Deploying into ${RG} with DNS Prefix ${DNS} 
    az group deployment create -g ${RG} --template-file _output/${DNS}/azuredeploy.json --parameters @_output/${DNS}/azuredeploy.parameters.json 

    echo cluster deployed in ${RG}
}

deploy_connection()
{
    local THIS_RG=${1}
    local THIS_GW=${2}
    local OTHER_RG=${3}
    local OTHER_GW=${4}

    echo Connection for gateway ${THIS_GW} into ${THIS_RG} 
    az group deployment create -g ${THIS_RG} --template-file templates/azuredeploy.conn.json --parameters "{ \"gwName\": { \"value\": \"${THIS_GW}\" }, \"gw2resourceGroup\" : { \"value\": \"${OTHER_RG}\" }, \"gw2Name\" : { \"value\": \"${OTHER_GW}\" }, \"connName\" : { \"value\": \"${THIS_GW}-conn\" } }" 

    echo Connection deployed in ${THIS_RG}   
}

ensure_acsengine()
{
    # We currently need acs-engine because the k8s cluster
    # needs CNI to manage container IPs
    # When CNI is the default for az acs create ... then any 
    # ACS cluster will do
    echo Checking for acs-engine
    command -v acs-engine >/dev/null 2>&1 || { echo "acs-engine is not available.  Aborting." >&2; exit 1; }
}

rebuild_armtemplates()
{
    local CLUSTER_DEF=${1}
    acs-engine/bin/acs-engine generate ${CLUSTER_DEF}    
}

set_ssh_exec()
{
    local RG=${1}

    local IP_NAME=$(az resource list -g ${RG} --resource-type Microsoft.Network/publicIPAddresses --query "[?contains(name,'master')].name" --out tsv) 
    echo Found IP address ${IP_NAME}
    local IP_ADDRESS=$(az resource show -g ${RG} --resource-type Microsoft.Network/publicIPAddresses -n ${IP_NAME} --query properties.ipAddress --out tsv)
    echo Address is ${IP_ADDRESS}
    # Parameters to suppress the The authenticity of host 'hostname' can't be established prompt.
    # ok here since we jsut created the server
    SSH_EXEC="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no azureuser@${IP_ADDRESS} "
}

install_helm()
{
    ${SSH_EXEC} "curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash"
    ${SSH_EXEC} "echo export HELM_HOME=/home/azureuser/ >> .bashrc"
    ${SSH_EXEC} "helm init"
    sleep 10
}

get_charts()
{
    echo Fetching charts
    ${SSH_EXEC} "rm -rf ./charts && git clone https://github.com/xtophs/charts.git && cd charts && git checkout cassandra-multi-dc"
}

install_cassandra()
{
    echo installing cassandra
    ${SSH_EXEC} "helm install charts/incubator/cassandra"
}

wait_for_vnet_gateway()
{
    local RG=${1}
    local GW_NAME=${2}
    local i=0

    local status=$(az group deployment show -g ${RG} -n azuredeploy.gw | jq -r  .properties.provisioningState)

    echo Wating for VNet Gateway ${GW_NAME} in Resource Group ${RG}
    # wait for 20 minutes
    while [  $i -le 60 ]
    do
        if [ $status = "Succeeded" ];
        then 
            break
        fi

        sleep 20
        i=$[$i + 1]
        echo Waiting $i status is ${status}
        status=$(az group deployment show -g ${RG} -n azuredeploy.gw | jq -r  .properties.provisioningState)
    done

    echo VNet Gateway in RG ${RG} finished with status ${status}
}

set_seed_ip()
{
    # This is a hack for now. 
    # Getting the IP of the first cassandra container as the Seed IP
    # We should think about a more robust and more appropriate algorithm for that.

    local i=0
    local status=$(${SSH_EXEC} kubectl get pods -o jsonpath='{.items[0].status.containerStatuses[0].ready}')
    # wait for 20 minutes
   while [  $i -le 60 ]
    do
        if [ $status = "true" ];
        then 
            break
        fi
        
        echo Wating for container to be ready $i  
        sleep 20
        i=$[$i + 1]
        status=$(${SSH_EXEC} kubectl get pods -o jsonpath='{.items[0].status.containerStatuses[0].ready}')
    done

    if [[ $status = "true" ]];
    then
        SEED_IP=$( ${SSH_EXEC} kubectl get pods -o jsonpath='{.items[0].status.podIP}')
    fi

    echo found container IP: ${SEED_IP}
}

update_seeds()
{
    echo Updating values.yaml with Seed IP ${SEED_IP}
    ${SSH_EXEC} 'sed -i "s/^cassandra:/cassandra:\n  Seeds: \"'${SEED_IP}'\"/" charts/incubator/cassandra/values.yaml'
    ${SSH_EXEC} 'sed -i "s/\".*\.local\"/\"{{.Values.cassandra.Seeds}}\"/" charts/incubator/cassandra/templates/statefulset.yaml'
}

echo Active Subscription:
az account show -o table
SUBSCRIPTION_ID=$(az account show -o tsv --query "id")

check_prereq

fixup_apimodel ${RESOURCE_GROUP_1} ${DNS_PREFIX_1} ${SUBNET_ADDRESS_PREFIX_1} ${CLUSTER_DEFINITION_1}
fixup_apimodel ${RESOURCE_GROUP_2} ${DNS_PREFIX_2} ${SUBNET_ADDRESS_PREFIX_2} ${CLUSTER_DEFINITION_2}

ensure_acsengine

rebuild_armtemplates ${CLUSTER_DEFINITION_1}
rebuild_armtemplates ${CLUSTER_DEFINITION_2}

create_rg_and_vnet ${RESOURCE_GROUP_1} ${LOCATION_1} ${GATEWAY_1} ${VNET_ADDRESS_PREFIX_1} ${SUBNET_ADDRESS_PREFIX_1} ${GWSUBNET_ADDRESS_PREFIX_1}
create_rg_and_vnet ${RESOURCE_GROUP_2} ${LOCATION_2} ${GATEWAY_2} ${VNET_ADDRESS_PREFIX_2} ${SUBNET_ADDRESS_PREFIX_2} ${GWSUBNET_ADDRESS_PREFIX_2}

deploy_cluster ${RESOURCE_GROUP_1} ${LOCATION_1} ${DNS_PREFIX_1}
deploy_cluster ${RESOURCE_GROUP_2} ${LOCATION_2} ${DNS_PREFIX_2}

wait_for_vnet_gateway ${RESOURCE_GROUP_1} ${GATEWAY_1}
wait_for_vnet_gateway ${RESOURCE_GROUP_2} ${GATEWAY_2}

deploy_connection ${RESOURCE_GROUP_1} ${GATEWAY_1} ${RESOURCE_GROUP_2} ${GATEWAY_2}
deploy_connection ${RESOURCE_GROUP_2} ${GATEWAY_2} ${RESOURCE_GROUP_1} ${GATEWAY_1}

set_ssh_exec ${RESOURCE_GROUP_1}

install_helm
get_charts
install_cassandra 

set_seed_ip

set_ssh_exec ${RESOURCE_GROUP_2}
install_helm 
get_charts
update_seeds
install_cassandra   

echo Final status
set_ssh_exec ${RESOURCE_GROUP_1}
${SSH_EXEC} 'kubectl exec -it $(kubectl get pods -o jsonpath="{ .items[0].metadata.name }") /usr/local/apache-cassandra-3.11.0/bin/nodetool status'