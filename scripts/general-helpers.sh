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