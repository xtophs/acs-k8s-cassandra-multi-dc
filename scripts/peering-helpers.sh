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
