ensure_acsengine()
{
    # We currently need acs-engine because the k8s cluster
    # needs CNI to manage container IPs
    # When CNI is the default for az acs create ... then any 
    # ACS/AKS cluster will do
    echo Checking for acs-engine
    command -v acs-engine >/dev/null 2>&1 || { echo "acs-engine is not available.  Aborting." >&2; exit 1; }
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

rebuild_armtemplates()
{
    local CLUSTER_DEF=${1}
    acs-engine generate ${CLUSTER_DEF}    
}