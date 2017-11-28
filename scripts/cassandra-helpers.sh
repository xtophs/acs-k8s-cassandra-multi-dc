get_charts()
{
    local BRANCH=${1}
    echo Fetching charts
    ${SSH_EXEC} "rm -rf ./charts && git clone https://github.com/xtophs/charts.git && cd charts && git checkout ${BRANCH}"
}

install_cassandra()
{
    echo installing cassandra
    ${SSH_EXEC} "helm install charts/incubator/cassandra"
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