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