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