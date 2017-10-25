#!/bin/bash
set -x

# make sure azure cli is logged in 
if az account show | grep -m 1 "login"; then 
  exit 1
fi

# make sure azure cli is installed
if ! [ -x "$(command -v az)" ]; then
  echo 'Error: Azure CLI 2.0 is not installed.  See: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli' >&2
  exit 1
fi

# make sure jq is installed (sudo apt-get install jq) 
if ! [ -x "$(command -v jq)" ]; then
  echo 'Error: jq package is not installed. On Ubuntu use "sudo apt-get install jq" or for other options see: https://stedolan.github.io/jq/download/' >&2
  exit 1
fi

if [[ ( -z "$1") || ( -z "$2") ]]
then
    echo "usage: validate.sh [image] [location]

    [image] may take the form of an alias, URN, resource ID, or URI. 

        Example Alias:
            RHEL, UbuntuLTS, CentOS, etc...
        Example URN:   (az vm image list --output table)
            Canonical:UbuntuServer:16.04-LTS:latest
        Example Custom Image Resource ID or Name: 
            /subscriptions/subscription-id/resourceGroups/MyResourceGroup/providers/Microsoft.Compute/images/MyImage
        Example URI: 
            http://<storageAccount>.blob.core.windows.net/vhds/osdiskimage.vhd

    [location] is the Azure region to use for all resources in the validation test
        Example regions: 
            westus, centralus, eastus, etc..
        To get a list of regions use:  
            az account list-locations

    To bypass creation of a new Active Directory application and KeyVault object
    for each run, it is possible to pre-create the following objects and specify
    their identifiers in the corresponding environment variables:
    
        ADE_ADAPP_NAME
        ADE_ADAPP_SECRET
        ADE_ADSP_APPID
        ADE_KV_ID
        ADE_KV_URI
        ADE_KEK_ID
        ADE_KEK_URI 
    "
    exit 1
fi

ADE_IMAGE="$1"
ADE_LOCATION="$2"

# initialize globals for use during the test
ADE_SUBSCRIPTION_ID="`az account show | jq -r '.id'`"
ADE_PREFIX="ade`cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1`";
ADE_RG="${ADE_PREFIX}rg"
ADE_VNET="${ADE_PREFIX}vnet"
ADE_SUBNET="${ADE_PREFIX}subnet"
ADE_PUBIP="${ADE_PREFIX}pubip"
ADE_NSG="${ADE_PREFIX}nsg"
ADE_NIC="${ADE_PREFIX}nic"
ADE_VM="${ADE_PREFIX}vm"

print_delete_instructions()
{
    echo "In case of test failure, resources can be deleted as follows:"
    if [ "${ADE_RG_CREATED}" = true ]; then
        echo "az group delete -n ${ADE_RG} --no-wait"
    fi
    if [ "${ADE_ADAPP_CREATED}" = true ]; then
        echo "az ad app delete --id ${ADE_ADSP_APPID}"
    fi
}

auto_delete_resources()
{
    # delete resources created by the script 
    if [ "${ADE_RG_CREATED}" = true ]; then
        az group delete -n "${ADE_RG}" --no-wait
    fi
    if [ "${ADE_ADAPP_CREATED}" = true ]; then
        az ad app delete --id "${ADE_ADSP_APPID}"
    fi
}

# create resource group which will contain all test resources (except for ad application and service principal)
az group create --name ${ADE_RG} --location ${ADE_LOCATION}
ADE_RG_CREATED=true

# create ad application and keyvault resources if not provided in environment
if [ -z "${ADE_ADAPP_NAME}" ] && \
    [ -z "${ADE_ADAPP_SECRET}" ] && \
    [ -z "${ADE_ADSP_APPID}" ] && \
    [ -z "${ADE_KV_ID}" ] && \
    [ -z "${ADE_KV_URI}" ] && \
    [ -z "${ADE_KEK_ID}"] && \
    [ -z "${ADE_KEK_URI}"]; then
    
    ADE_ADAPP_NAME="${ADE_PREFIX}adapp"
    ADE_ADAPP_SECRET="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
    ADE_ADAPP_NAME="${ADE_PREFIX}adapp"
    ADE_ADAPP_URI="https://localhost/${ADE_ADAPP_NAME}"
    ADE_KV_NAME="${ADE_PREFIX}kv"
    ADE_KEK_NAME="${ADE_PREFIX}kek"

    az ad app create --display-name $ADE_ADAPP_NAME --homepage $ADE_ADAPP_URI --identifier-uris $ADE_ADAPP_URI --password $ADE_ADAPP_SECRET
    ADE_ADSP_APPID="`az ad app list --display-name ${ADE_ADAPP_NAME} | jq -r '.[0] | .appId'`"
    ADE_ADAPP_CREATED=true

    # print delete instructions to stdout (if script fails early they are still available)
    print_delete_instructions

    # create service principal for ad application 
    az ad sp create --id "${ADE_ADSP_APPID}"
    ADE_ADSP_OID="`az ad sp list --display-name ${ADE_ADAPP_NAME} | jq -r '.[0] | .objectId'`"

    # create role assignment for ad app (retry until AD SP OID is visible in directory or time threshold is exceeded)
    SLEEP_CYCLES=0
    MAX_SLEEP=8
    until az role assignment create --assignee $ADE_ADSP_OID --role Reader --scope "/subscriptions/${ADE_SUBSCRIPTION_ID}/" || [ $SLEEP_CYCLES -eq $MAX_SLEEP ]; do
    sleep 15
    (( SLEEP_CYCLES++ ))
    done
    if [ $SLEEP_CYCLES -eq $MAX_SLEEP ]
    then
        echo "test script failure - default timeout threshold exceeded for az role assignment"
        print_delete_instructions
        exit 1
    fi

    # create keyvault and set policy (premium sku offers HSM support which will be used later)
    az keyvault create --name ${ADE_KV_NAME} --resource-group ${ADE_RG} --location ${ADE_LOCATION} --sku premium 
    ADE_KV_URI="`az keyvault show --name ${ADE_KV_NAME} --resource-group ${ADE_RG} | jq -r '.properties.vaultUri'`"
    ADE_KV_ID="`az keyvault show --name ${ADE_KV_NAME} --resource-group ${ADE_RG} | jq -r '.id'`"
    az keyvault set-policy --name "${ADE_KV_NAME}" --resource-group "${ADE_RG}" --spn "${ADE_ADSP_APPID}" --key-permissions "wrapKey" --secret-permissions "set"
    az keyvault update --name "${ADE_KV_NAME}" --resource-group "${ADE_RG}" --enabled-for-deployment true --enabled-for-disk-encryption true

    # create key encryption key
    az keyvault key create --vault-name ${ADE_KV_NAME} --name ${ADE_KEK_NAME} --protection HSM 
    ADE_KEK_ID="${ADE_KV_ID}"
    ADE_KEK_URI="`az keyvault key show --name ${ADE_KEK_NAME} --vault-name ${ADE_KV_NAME} | jq -r '.key.kid'`"
else
    echo "Using pre-created ADAPP and KV objects"
    print_delete_instructions
fi

# create network resources
az network vnet create --resource-group ${ADE_RG} --name ${ADE_VNET} --subnet-name ${ADE_SUBNET}
az network public-ip create --resource-group ${ADE_RG} --name ${ADE_PUBIP}
az network nsg create --resource-group ${ADE_RG} --name ${ADE_NSG}
az network nic create --resource-group ${ADE_RG} --name ${ADE_NIC} --vnet-name ${ADE_VNET} --subnet ${ADE_SUBNET} --network-security-group ${ADE_NSG} --public-ip-address ${ADE_PUBIP}

# create virtual machine 
az vm create --resource-group ${ADE_RG} --name ${ADE_VM} --nics ${ADE_NIC} --image ${ADE_IMAGE} --generate-ssh-keys
#az vm open-port --port 22 --resource-group ${ADE_RG} --name ${ADE_VM}

# encrypt virtual machine 
az vm encryption enable --name "${ADE_VM}" --resource-group "${ADE_RG}" --aad-client-id "${ADE_ADSP_APPID}" --aad-client-secret "${ADE_ADAPP_SECRET}" --disk-encryption-keyvault "${ADE_KV_ID}" --key-encryption-key "${ADE_KEK_URI}" --key-encryption-keyvault "${ADE_KEK_ID}" --volume-type ALL

# check status once every 5 minutes for 6 hours
SECONDS=0
SLEEP_CYCLES=0
MAX_SLEEP=72
until az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "VMRestartPending" || [ $SLEEP_CYCLES -eq $MAX_SLEEP ]; do
   date
   # display current progress while waiting for the VMRestartPending message
   az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "progressMessage"
   sleep 5m
   (( SLEEP_CYCLES++ ))
done
printf 'Pre-reboot encryption time: %dh:%dm:%ds\n' $(($SECONDS/3600)) $(($SECONDS%3600/60)) $(($SECONDS%60))

if [ $SLEEP_CYCLES -eq $MAX_SLEEP ]
then
    echo "Test timeout threshold expired - OS disk encryption took more than 6 hours"
    print_delete_instructions
    exit 1
fi

# VMRestartPending message displayed, so restart the vm 
az vm restart --name "${ADE_VM}" --resource-group "${ADE_RG}"

# check status once every 30 seconds for 10 minutes  (after restart, the extension needs time to start up and mount the newly encrypted disk)
SLEEP_CYCLES=0
MAX_SLEEP=20
until az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "succeeded" || [ $SLEEP_CYCLES -eq $MAX_SLEEP ]; do
   date
   # display current progress while waiting for the succeeded message
   az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "osDisk"
   sleep 30
   (( SLEEP_CYCLES++ ))
done

if [ $SLEEP_CYCLES -eq $MAX_SLEEP ]
then
    echo "Test timeout threshold expired - OS disk encryption success message not observed after restart"
    print_delete_instructions
    exit 1
fi

printf 'Total encryption time: %dh:%dm:%ds\n' $(($SECONDS/3600)) $(($SECONDS%3600/60)) $(($SECONDS%60))

#cleanup
auto_delete_resources