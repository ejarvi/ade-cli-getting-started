#!/usr/bin/env bash
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

if [[ ( -z "$1") || ( -z "$2") ]]; then 
    echo "usage: validate.sh [image] [location] [optional:volumetype]

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

    [volumetype] is the volume type to encrypt (ie., DATA/OS/ALL)
        This value is optional, and will default to OS if not specified.
    
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

if [[ ( -z "$3") ]]; then
    ADE_VOLUME_TYPE=OS
else
    ADE_VOLUME_TYPE=$3
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
        az group delete -n "${ADE_RG}" --no-wait --yes
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

# create virtual machine with at least 7GB RAM and two 1GB data disks
# https://docs.microsoft.com/en-us/azure/virtual-machines/windows/sizes-general 
az vm create --resource-group ${ADE_RG} --name ${ADE_VM} --size Standard_DS2_v2 --nics ${ADE_NIC} --image ${ADE_IMAGE} --generate-ssh-keys --data-disk-sizes-gb 1 1
#az vm open-port --port 22 --resource-group ${ADE_RG} --name ${ADE_VM}

# mount and format the data disks if volume type was ALL or DATA
if [ ADE_VOLUME_TYPE != "OS" ]; then
# creates a storage account within resource group for use by custom script extension
ADE_STG="${ADE_PREFIX}stg"
ADE_CNT=container
az storage account create --name "${ADE_STG}" --resource-group "${ADE_RG}" --sku Standard_LRS
ADE_STG_KEY="`az storage account keys list --account-name ${ADE_STG} --resource-group ${ADE_RG} | jq -r '.[0] | .value'`"
az storage container create --name "${ADE_CNT}" --account-name "${ADE_STG}" --account-key "${ADE_STG_KEY}"

# generate a randomly named disk setup script, upload it, and generate SAS URL to give to custom script extension
ADE_SCRIPT_PREFIX="`cat /dev/urandom | tr -dc 'a-z' | fold -w 12 | head -n 1`"
ADE_SCRIPT_NAME="${ADE_SCRIPT_PREFIX}.sh"
ADE_SCRIPT_PATH="/tmp/${ADE_SCRIPT_NAME}"
cat > "${ADE_SCRIPT_PATH}" << 'EOF'
#!/usr/bin/env bash
set -x
if ! [ -x "$(command -v curl)" ]; then
  echo 'Error: curl not installed, script cannot run' >&2
  exit 1
fi
if [ -z "$1" ]; then
  echo 'SAS URL missing, script cannot run' >&2
  exit 1
fi 
echo "y" | mkfs.ext4 /dev/disk/azure/scsi1/lun0
echo "y" | mkfs.ext4 /dev/disk/azure/scsi1/lun1
UUID0="$(blkid -s UUID -o value /dev/disk/azure/scsi1/lun0)"
UUID1="$(blkid -s UUID -o value /dev/disk/azure/scsi1/lun1)"
mkdir /data0
mkdir /data1
echo "UUID=$UUID0 /data0 ext4 defaults,nofail 0 0" >>/etc/fstab
echo "UUID=$UUID1 /data1 ext4 defaults,nofail 0 0" >>/etc/fstab
mount -a
lsblk > /tmp/lsblk.txt
curl -X PUT $1 -T /tmp/lsblk.txt -H "x-ms-blob-type: BlockBlob"
EOF
az storage blob upload --account-name "${ADE_STG}" --account-key "${ADE_STG_KEY}" --container-name "${ADE_CNT}" --file "${ADE_SCRIPT_PATH}" --name "${ADE_SCRIPT_NAME}"
# cleanup local copy of script 
rm "${ADE_SCRIPT_PATH}"
ADE_SAS_EXPIRY="`date -d tomorrow --iso-8601 --utc`T23:59Z"
ADE_SCRIPT_URL=`az storage blob url --account-name "${ADE_STG}" --account-key "${ADE_STG_KEY}" --container-name "${ADE_CNT}" --name "${ADE_SCRIPT_NAME}"`
ADE_SCRIPT_SAS_TOKEN=`az storage blob generate-sas --account-name "${ADE_STG}" --account-key "${ADE_STG_KEY}" --container-name "${ADE_CNT}" --name "${ADE_SCRIPT_NAME}" --permissions r --expiry ${ADE_SAS_EXPIRY}`
ADE_SCRIPT_SAS_URL="${ADE_SCRIPT_URL//\"}?${ADE_SCRIPT_SAS_TOKEN//\"}"

# create temporary storage blob SAS URL that will be used by the remote machine to post result output
ADE_BLOB_URL=`az storage blob url --account-name "${ADE_STG}" --account-key "${ADE_STG_KEY}" --container-name "${ADE_CNT}" --name output`
ADE_BLOB_SAS_TOKEN=`az storage blob generate-sas --account-name "${ADE_STG}" --account-key "${ADE_STG_KEY}" --container-name "${ADE_CNT}" --name output --permissions wracd --expiry ${ADE_SAS_EXPIRY}`
ADE_BLOB_SAS_URL="${ADE_BLOB_URL//\"}?${ADE_BLOB_SAS_TOKEN//\"}"

# create temporary json config files with the newly created SAS urls to send to custom script extension 
ADE_PUB_CONFIG="/tmp/${ADE_SCRIPT_PREFIX}_public_config.json"
ADE_PRO_CONFIG="/tmp/${ADE_SCRIPT_PREFIX}_protected_config.json"
echo '{"fileUris": ["'${ADE_SCRIPT_SAS_URL}'"]}' > "${ADE_PUB_CONFIG}"
echo '{"commandToExecute": "./'${ADE_SCRIPT_NAME}' '"'"${ADE_BLOB_SAS_URL}"'"'"}' > "${ADE_PRO_CONFIG}" 

# use custom script extension to run disk setup script 
az vm extension set --resource-group "${ADE_RG}" --vm-name "${ADE_VM}" --name customScript --publisher Microsoft.Azure.Extensions --settings "${ADE_PUB_CONFIG}" --protected-settings "${ADE_PRO_CONFIG}"

# cleanup temp json files
rm "${ADE_PUB_CONFIG}"
rm "${ADE_PRO_CONFIG}" 

# check once a minute for 10 minutes or until the remote vm creates the output blob to signal that disks are formatted and mounted 
SLEEP_CYCLES=0
MAX_SLEEP=10
until az storage blob exists --account-name "${ADE_STG}" --account-key "${ADE_STG_KEY}" --container-name "${ADE_CNT}" --name output | grep -m 1 "true" || [ $SLEEP_CYCLES -eq $MAX_SLEEP ]; do
   date
   sleep 1m
   (( SLEEP_CYCLES++ ))
done

# print the result provided by the remote vm to console, then cleanup the temporary file 
az storage blob download --account-name "${ADE_STG}" --account-key "${ADE_STG_KEY}" --container-name "${ADE_CNT}" --name output --file "/tmp/${ADE_SCRIPT_PREFIX}.log"
cat "/tmp/${ADE_SCRIPT_PREFIX}.log"
rm "/tmp/${ADE_SCRIPT_PREFIX}.log"
fi

# enable encryption
az vm encryption enable --name "${ADE_VM}" --resource-group "${ADE_RG}" --aad-client-id "${ADE_ADSP_APPID}" --aad-client-secret "${ADE_ADAPP_SECRET}" --disk-encryption-keyvault "${ADE_KV_ID}" --key-encryption-key "${ADE_KEK_URI}" --key-encryption-keyvault "${ADE_KEK_ID}" --volume-type "${ADE_VOLUME_TYPE}" --encrypt-format-all

# check status once every 10 minutes for a max of 20 hours
SECONDS=0
SLEEP_CYCLES=0
MAX_SLEEP=120

if [ "${ADE_VOLUME_TYPE,,}" = "data" ]; then
	# DATA volume type
	until az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "Encryption succeeded for data volumes" || [ $SLEEP_CYCLES -eq $MAX_SLEEP ]; do
	   date
	   # display current progress while waiting 
	   az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "progressMessage"
	   sleep 1m
	   (( SLEEP_CYCLES++ ))
	done

	if [ $SLEEP_CYCLES -eq $MAX_SLEEP ]
	then
		echo "Test timeout threshold expired - data volume encryption took more than 2 hours"
		print_delete_instructions
		exit 1
	fi
else
	# wait for presence of "VMRestartPending" in status message to signal that OS disk encryption is complete
	until az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "VMRestartPending" || [ $SLEEP_CYCLES -eq $MAX_SLEEP ]; do
	   date
	   # display current progress while waiting for the VMRestartPending message
	   az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "progressMessage"
	   sleep 10m
	   (( SLEEP_CYCLES++ ))
	done
	printf 'Pre-reboot encryption time: %dh:%dm:%ds\n' $(($SECONDS/3600)) $(($SECONDS%3600/60)) $(($SECONDS%60))

	if [ $SLEEP_CYCLES -eq $MAX_SLEEP ]
	then
		echo "Test timeout threshold expired - OS disk encryption took more than 20 hours"
		print_delete_instructions
		exit 1
	fi

	# reboot vm 
    SLEEP_CYCLES=0
    MAX_SLEEP=12
    while az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "VMRestartPending" && [ $SLEEP_CYCLES -lt $MAX_SLEEP ]; do
	    az vm restart --name "${ADE_VM}" --resource-group "${ADE_RG}" --debug
        sleep 5m
        (( SLEEP_CYCLES++ ))
    done

    if az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "VMRestartPending" && [ $SLEEP_CYCLES -ge $MAX_SLEEP ];
	then
		echo "VM restart threshold expired - unable to reboot VM after multiple vm restart attempts"
		print_delete_instructions
		exit 1
	fi

	# verify that 'succeeded' status message is displayed
	SLEEP_CYCLES=0
	MAX_SLEEP=20
	until az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "succeeded" || [ $SLEEP_CYCLES -eq $MAX_SLEEP ]; do
	   date
	   # display current progress while waiting for the succeeded message
	   az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | grep -m 1 "osDisk"
	   sleep 1m
	   (( SLEEP_CYCLES++ ))
	done

	if [ $SLEEP_CYCLES -eq $MAX_SLEEP ]
	then
		echo "Test timeout threshold expired - OS disk encryption success message not observed after restart"
		print_delete_instructions
		exit 1
	fi
fi

printf 'Total encryption time: %dh:%dm:%ds\n' $(($SECONDS/3600)) $(($SECONDS%3600/60)) $(($SECONDS%60))

#cleanup
auto_delete_resources