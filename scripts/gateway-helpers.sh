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

wait_for_vnet_gateway()
{
    local RG=${1}
    local GW_NAME=${2}
    local i=0

    local status=$(az group deployment show \
        -g ${RG} \
        -n azuredeploy.gw \
        | jq -r  .properties.provisioningState)

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
        status=$(az group deployment show \
            -g ${RG} \
            -n azuredeploy.gw \
            | jq -r  .properties.provisioningState)
    done

    echo VNet Gateway in RG ${RG} finished with status ${status}
}