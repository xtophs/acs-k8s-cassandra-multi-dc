# Distributed Cassandra

Building 2 clusters with non-overlapping address space

1. West Cluster
- Agent Subnet: `10.1.0.0/16`
- POD address space: `10.100.0.0/16`

1. East Cluster
- Agent Subnet: `10.2.0.0/16`
- POD address space: `10.200.0.0/16`



## West Cluster

### acs-engine API model

```
    "orchestratorProfile": {
      "orchestratorType": "Kubernetes",
      "kubernetesConfig": {
        "clusterSubnet": "10.100.0.0/16"
      }
    },
    "masterProfile": {
      "count": 1,
      "dnsPrefix": "xtoph-c-west",
      "vmSize": "Standard_D2_v2",
      "firstConsecutiveStaticIP": "10.1.255.5"    
    },
```

Note: firstConsecutiveStaticIP in the apimodel doesn't seem to work. Needs to be fixed up in the parameters file.

### azuredeploy changes

Changes to `azuredeploy.json`



Changes to `azuredeploy.parameters.json` file

```
    "agentSubnet": {
      "value": "10.1.0.0/16"
    },
    "masterSubnet": {
      "value": "10.1.0.0/16"
    },
    "firstConsecutiveStaticIP": {
      "value": "10.1.255.5"
    },
```

```
$ az network route-table route list -g $RESOURCE_GROUP --route-table-name k8s-master-11325921-routetable -o table
AddressPrefix    Name                     NextHopIpAddress    NextHopType       ProvisioningState    ResourceGroup
---------------  -----------------------  ------------------  ----------------  -------------------  ---------------------
10.100.0.0/24    k8s-master-11325921-0    10.1.255.239        VirtualAppliance  Succeeded            xtoph-delete-from-arm
10.100.1.0/24    k8s-agentpri-11325921-1  10.1.0.4            VirtualAppliance  Succeeded            xtoph-delete-from-arm
10.100.2.0/24    k8s-agentpri-11325921-0  10.1.0.5            VirtualAppliance  Succeeded            xtoph-delete-from-arm
```

