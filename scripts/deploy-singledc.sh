#!/bin/bash

set -e

RESOURCE_GROUP_1=${1}

CLUSTER_DEFINITION_1=./templates/kubernetes.east.json

VNET_NAME=KubernetesCustomVNET
SUBNET_NAME=KubernetesSubnet
VNET_1_FIRST_TWO=10.140

LOCATION_1=westcentralus

# variables that get set in keys.env
SERVICE_PRINCIPAL=
SP_SECRET=
SSH_PUBLIC_KEY=

. ./scripts/keys.env

# --- Auto populated values. Change at your own risk
VNET_1_ADDRESS_PREFIX_1=${VNET_1_FIRST_TWO}.0.0/16

SUBNET_ADDRESS_PREFIX_1=${VNET_1_FIRST_TWO}.0.0/17

DNS_PREFIX_1=${RESOURCE_GROUP_1}

# --------------
. ./scripts/general-helpers.sh
. ./scripts/acs-helpers.sh 
. ./scripts/network-helpers.sh 
. ./scripts/cluster-helpers.sh
. ./scripts/peering-helpers.sh
. ./scripts/cassandra-helpers.sh

check_prereq()
{
    check_var_set "VNET_NAME"
    check_var_set "SUBNET_NAME"
    check_var_set "VNET_1_FIRST_TWO"

    check_var_set "LOCATION_1"

    check_var_set "SUBSCRIPTION_ID"
    check_var_set "RESOURCE_GROUP_1" 

    check_var_set "CLUSTER_DEFINITION_1" 

    check_var_set "SSH_PUBLIC_KEY" 
    check_var_set "SP_SECRET"
    check_var_set "SERVICE_PRINCIPAL"

    check_var_set "DNS_PREFIX_1"
    
    check_var_set "SUBNET_ADDRESS_PREFIX_1"
}

echo Active Subscription:
az account show -o table
SUBSCRIPTION_ID=$(az account show -o tsv --query "id")

check_prereq

fixup_apimodel ${RESOURCE_GROUP_1} ${DNS_PREFIX_1} ${SUBNET_ADDRESS_PREFIX_1} ${CLUSTER_DEFINITION_1}

ensure_acsengine

rebuild_armtemplates ${CLUSTER_DEFINITION_1}

echo VNET SPACES ${VNET_1_ADDRESS_PREFIX_1} ${SUBNET_ADDRESS_PREFIX_1} 
create_rg_and_vnet ${RESOURCE_GROUP_1} ${LOCATION_1} ${VNET_1_ADDRESS_PREFIX_1} ${SUBNET_ADDRESS_PREFIX_1}

deploy_cluster ${RESOURCE_GROUP_1} ${LOCATION_1} ${DNS_PREFIX_1}

wait_for_cluster ${RESOURCE_GROUP_1} deploy-${DNS_PREFIX_1}

set_ssh_exec ${RESOURCE_GROUP_1}

install_helm
branchName=cassandra-multi-dc
get_charts ${branchName}

install_cassandra 

echo Final status
${SSH_EXEC} 'kubectl exec -it $(kubectl get pods -o jsonpath="{ .items[0].metadata.name }") /usr/local/apache-cassandra-3.11.0/bin/nodetool status'
