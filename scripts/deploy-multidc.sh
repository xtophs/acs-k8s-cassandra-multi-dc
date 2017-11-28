#!/bin/bash

set -e

RESOURCE_GROUP_1=${1}
RESOURCE_GROUP_2=${2}

CLUSTER_DEFINITION_1=./templates/kubernetes.east.json
CLUSTER_DEFINITION_2=./templates/kubernetes.west.json

VNET_NAME=KubernetesCustomVNET
SUBNET_NAME=KubernetesSubnet
VNET_1_FIRST_TWO=10.140
VNET_2_FIRST_TWO=10.240

LOCATION_1=westcentralus
LOCATION_2=westus2

# variables that get set in keys.env
SERVICE_PRINCIPAL=
SP_SECRET=
SSH_PUBLIC_KEY=

. ./scripts/keys.env

# --- Auto populated values. Change at your own risk
VNET_1_ADDRESS_PREFIX_1=${VNET_1_FIRST_TWO}.0.0/16
VNET_2_ADDRESS_PREFIX_1=${VNET_2_FIRST_TWO}.0.0/16

SUBNET_ADDRESS_PREFIX_1=${VNET_1_FIRST_TWO}.0.0/16
SUBNET_ADDRESS_PREFIX_2=${VNET_2_FIRST_TWO}.0.0/16

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
    check_var_set "VNET_NAME"
    check_var_set "SUBNET_NAME"
    check_var_set "VNET_1_FIRST_TWO"
    check_var_set "VNET_2_FIRST_TWO"

    check_var_set "LOCATION_1"
    check_var_set "LOCATION_2"

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
    firstIP=$(echo ${ADDRESS_PREFIX} | sed 's/\([0-9]*\).\([0-9]*\).*$/\1.\2.255.239/g')
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
    local VNET_CIDR=${3}
    local SUBNET_CIDR=${4}

    echo Creating Resource Group ${RG} in ${LOCATION}
    az group create \
        -l ${LOCATION} \
        -n ${RG}
    
    echo Creating Virtual Network with VNET ${VNET_CIDR}, Subnet ${SUBNET_CIDR} 
    az group deployment create \
        -g ${RG} \
        --template-file templates/azuredeploy.vnet.json \
        --parameters "{ \"subnetCIDR\": { \"value\": \"${VNET_CIDR}\" } }"  
}

deploy_peering()
{
    local THIS_RG=${1}
    local OTHER_RG=${2}
    local VNET_NAME=${3}
    local OTHER_VNET_ID=$(az network vnet show \
      --resource-group ${OTHER_RG} \
      --name ${VNET_NAME} \
      --query id --out tsv)

    echo Peering ${THIS_VNET_ID} with ${OTHER_VNET_ID}

    # TODO: Make this an ARM template so we have a
    # tracked deployment
    az network vnet peering create \
      --name myVnet1ToMyVnet2 \
      --resource-group ${THIS_RG} \
      --vnet-name ${VNET_NAME} \
      --remote-vnet-id ${OTHER_VNET_ID} \
      --allow-vnet-access
}

wait_for_peering()
{
    local RG=${1}
    local VNET_NAME=${2}
    local i=0

    local status=$(az network vnet peering list \
        --resource-group ${RG} \
        --vnet-name ${VNET_NAME} \
        --output tsv --query [0].peeringState )

    echo Wating for VNet peering in Resource Group ${RG}
    # wait for 20 minutes
    while [  $i -le 60 ]
    do
        echo Status is ${status}
        if [ $status = "Connected" ];
        then 
            break
        fi

        sleep 20
        i=$[$i + 1]
        echo Waiting $i status is ${status}
        status=$(az network vnet peering list \
        --resource-group ${RG} \
        --vnet-name ${VNET_NAME} \
        --output tsv --query [0].peeringState )
    done

    echo Peering in RG ${RG} finished with status ${status}
        
}
 wait_for_cluster()
 {
    local RG=${1}
    local DEPLOYMENT_NAME=${2}
    local i=0

    local status=$(az group deployment show \
        -g ${RG} \
        -n ${DEPLOYMENT_NAME} \
        -o tsv --query properties.provisioningState)

    echo Wating for Cluster in Resource Group ${RG}
    # wait for 20 minutes
    while [  $i -le 60 ]
    do
        echo Status is ${status}
        if [ $status = "Succeeded" ];
        then 
            break
        fi

        sleep 20
        i=$[$i + 1]
        echo Waiting $i status is ${status}
        status=$(az group deployment show \
            -g ${RG} \
            -n ${DEPLOYMENT_NAME} \
            -o tsv --query properties.provisioningState)    
    done

    echo Cluster Deployment in RG ${RG} finished with status ${status}
}

deploy_cluster()
{
    local RG=${1}
    local LOCATION=$2
    local DNS=$3

    echo Deploying into ${RG} with DNS Prefix ${DNS} 
    az group deployment create -g ${RG} \
        --template-file _output/${DNS}/azuredeploy.json \
        --parameters @_output/${DNS}/azuredeploy.parameters.json \
        -n deploy-${DNS} \
        --no-wait

    echo cluster deploying into ${RG}
}

ensure_acsengine()
{
    # We currently need acs-engine because the k8s cluster
    # needs CNI to manage container IPs
    # When CNI is the default for az acs create ... then any 
    # ACS/AKS cluster will do
    echo Checking for acs-engine
    command -v acs-engine >/dev/null 2>&1 || { echo "acs-engine is not available.  Aborting." >&2; exit 1; }
}

rebuild_armtemplates()
{
    local CLUSTER_DEF=${1}
    acs-engine generate ${CLUSTER_DEF}    
}

set_ssh_exec()
{
    local RG=${1}

    local IP_NAME=$(az resource list -g ${RG} \
        --resource-type Microsoft.Network/publicIPAddresses \
        --query "[?contains(name,'master')].name" \
        --out tsv) 
    echo Found IP address ${IP_NAME}
    local IP_ADDRESS=$(az resource show -g ${RG} \
        --resource-type Microsoft.Network/publicIPAddresses \
        -n ${IP_NAME} \
        --query properties.ipAddress \
        --out tsv)
    echo Address is ${IP_ADDRESS}
    # Parameters to suppress the The authenticity of host 'hostname' can't be established prompt.
    # ok here since we jsut created the server
    SSH_EXEC="ssh -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no azureuser@${IP_ADDRESS} "
}

wait_for_k8s()
{
    local status=$(${SSH_EXEC} kubectl version --short | grep -i "Server Version")

    local i=0

    echo Waiting for k8s

    # wait for 20 minutes
    while [  $i -le 60 ]
    do
        echo Status is ${status}
        if [[  -z $status ]];
        then 
            break
        fi

        sleep 20
        i=$[$i + 1]
        echo Waiting $i status is ${status}
        status=$(${SSH_EXEC} kubectl version --short | grep -i "Server Version") 
    done    

    if [[ -z $status ]];
    then 
        echo Kubernetes not running
        exit 1
    fi
}


install_helm()
{
    ${SSH_EXEC} "curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get | bash"
    ${SSH_EXEC} "echo export HELM_HOME=/home/azureuser/ >> .bashrc"
    ${SSH_EXEC} "kubectl cluster-info"
    ${SSH_EXEC} "helm init --upgrade"


    echo Tiller Pod ready?

    local i=0

    echo Waiting for tiller pod 
    local itemCount=$(${SSH_EXEC} kubectl get pod \
        --selector=name=tiller \
        --namespace=kube-system \
        -o jsonpath='{.items}' | jq -R -r '. | length' | head -n 1)

    echo itemCount is $itemCount
    # wait for 20 minutes
    while [  $itemCount -le 2 ]
    do
        echo Waiting for tiller pod $i

        sleep 20
        i=$[$i + 1]
        if [[ $i -eq 60 ]];
        then
            echo Tiller pod didnt come up 
            exit 1
        fi

        itemCount=$(${SSH_EXEC} kubectl get pod \
            --selector=name=tiller \
            --namespace=kube-system \
            -o jsonpath='{.items}' | jq -r -R '. | length' | head -n 1)
    done

    echo Tiller Container ready?
    ${SSH_EXEC} kubectl get pod \
        --selector=name=tiller \
        --namespace=kube-system \
        -o jsonpath='{.items[0].status}'

    local status=$(${SSH_EXEC} kubectl get pod \
        --selector=name=tiller \
        --namespace=kube-system \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}')

    local i=0

    echo 

    # wait for 20 minutes
    while [  $i -le 60 ]
    do
        echo Status is ${status}
        if [ $status = "true" ];
        then 
            break
        fi

        sleep 20
        i=$[$i + 1]
        echo Waiting $i status is ${status}
        status=$(${SSH_EXEC} kubectl get pod \
            --selector=name=tiller \
            --namespace=kube-system \
            -o jsonpath='{.items[0].status.containerStatuses[0].ready}') 
    done    

    if [ $status = "false" ];
    then 
        echo Tiller not running
        exit 1
    fi
    ${SSH_EXEC} "kubectl cluster-info"
}

get_charts()
{
    echo Fetching charts
    ${SSH_EXEC} "rm -rf ./charts && git clone https://github.com/xtophs/charts.git && cd charts && git checkout ilb"
}

install_cassandra()
{
    echo installing cassandra
    ${SSH_EXEC} "helm install charts/incubator/cassandra"
}

set_seed_ip()
{
    local RG=${1}
    local i=0

    # Load balancer name defined in cassandra helm chart at
    # https://github.com/CatalystCode/charts/blob/master/incubator/cassandra/templates/svc.yaml#L22

    local ip=$(az resource show \
        -g ${RG} \
        --resource-type Microsoft.Network/loadBalancers \
        -n ${RG}-internal \
        --query properties.frontendIPConfigurations[0].properties.privateIPAddress -o tsv)

    # wait for up to 20 minutes
   while [  $i -le 60 ]
    do
        if [[ ! -z $ip ]];
        then 
            break
        fi
        
        echo Wating for ILB to be ready $i  
        sleep 20
        i=$[$i + 1]
        ip=$(az resource show \
            -g ${RG} \
            --resource-type Microsoft.Network/loadBalancers \
            -n ${RG}-internal \
            --query properties.frontendIPConfigurations[0].properties.privateIPAddress -o tsv)
    done

    if [[ ! -z $ip ]];
    then
        SEED_IP=${ip}
    fi

    echo found ILB IP: ${SEED_IP}
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

echo VNET SPACES ${VNET_1_ADDRESS_PREFIX_1} ${SUBNET_ADDRESS_PREFIX_1} 
create_rg_and_vnet ${RESOURCE_GROUP_1} ${LOCATION_1} ${VNET_1_ADDRESS_PREFIX_1} ${SUBNET_ADDRESS_PREFIX_1} 
create_rg_and_vnet ${RESOURCE_GROUP_2} ${LOCATION_2} ${VNET_2_ADDRESS_PREFIX_1} ${SUBNET_ADDRESS_PREFIX_2} 

deploy_peering ${RESOURCE_GROUP_1} ${RESOURCE_GROUP_2} ${VNET_NAME}
deploy_peering ${RESOURCE_GROUP_2} ${RESOURCE_GROUP_1} ${VNET_NAME}

deploy_cluster ${RESOURCE_GROUP_1} ${LOCATION_1} ${DNS_PREFIX_1}
deploy_cluster ${RESOURCE_GROUP_2} ${LOCATION_2} ${DNS_PREFIX_2}

wait_for_peering ${RESOURCE_GROUP_1} ${VNET_NAME}
wait_for_peering ${RESOURCE_GROUP_2} ${VNET_NAME}

wait_for_cluster ${RESOURCE_GROUP_1} deploy-${DNS_PREFIX_1}
wait_for_cluster ${RESOURCE_GROUP_1} deploy-${DNS_PREFIX_1}

set_ssh_exec ${RESOURCE_GROUP_1}

install_helm
get_charts
install_cassandra 

set_seed_ip ${RESOURCE_GROUP_1}

set_ssh_exec ${RESOURCE_GROUP_2}
install_helm 
get_charts
update_seeds
install_cassandra   

# problem is that the ILB currently doesn't work ith CNI clusters. 
# Need to revisit or manually configure the ILB

echo Final status
set_ssh_exec ${RESOURCE_GROUP_1}
${SSH_EXEC} 'kubectl exec -it $(kubectl get pods -o jsonpath="{ .items[0].metadata.name }") /usr/local/apache-cassandra-3.11.0/bin/nodetool status'