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
