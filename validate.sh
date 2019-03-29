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
    echo "usage: validate.sh [image] [location] [[volumetype]] [[--singlepass]] [[--encrypt-format-all]]

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

    [[volumetype]] is the volume type to encrypt (ie., DATA/OS/ALL)
        This value is optional, and will default to OS if not specified.

    [[--encrypt-format-all]] is an optional switch that may be used to switch over to encrypt-format-all mode.
	In this mode the disks are formatted and encrypted simultaneously. This speeds up DATA disk encryption as existing data doesn't need to be encrypted.

    [[--singlepass]] is an optional switch that may be used to switch over to the singlepass mode.
	In this mode the AAD credentials (NAME, SECRET, and APPID) will be ignored.
	
	[[--rhui]] is an optional switch to update RHUI certificate using Microsoft-provided RPM on RHEL 7.1+

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

# parse options
options=$@
idx=0
for argument in $options
  do
    case $argument in
        --rhui) ADE_RHUI_MODE=true;;	
        --singlepass) ADE_SP_MODE=true;;
        --encrypt-format-all) ADE_EFA_MODE=true;;
        *)
            idx=$(($idx + 1))
            case "$idx" in
                "1") ADE_IMAGE=$argument;;
                "2") ADE_LOCATION=$argument;;
                "3") ADE_VOLUME_TYPE=$argument;;
            esac

    esac
  done

if [[ ( -z "$ADE_VOLUME_TYPE") ]]; then
    ADE_VOLUME_TYPE=OS
fi

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
if [[ "$ADE_SP_MODE" == true ]]; then
    if [ -z "${ADE_KV_ID}" ] && \
	[ -z "${ADE_KV_URI}" ] && \
	[ -z "${ADE_KEK_ID}"] && \
	[ -z "${ADE_KEK_URI}"]; then

	ADE_KV_NAME="${ADE_PREFIX}kv"
	ADE_KEK_NAME="${ADE_PREFIX}kek"

	az keyvault create --name ${ADE_KV_NAME} --resource-group ${ADE_RG} --location ${ADE_LOCATION} --sku premium
	ADE_KV_URI="`az keyvault show --name ${ADE_KV_NAME} --resource-group ${ADE_RG} | jq -r '.properties.vaultUri'`"
	ADE_KV_ID="`az keyvault show --name ${ADE_KV_NAME} --resource-group ${ADE_RG} | jq -r '.id'`"
	az keyvault update --name "${ADE_KV_NAME}" --resource-group "${ADE_RG}" --enabled-for-deployment true --enabled-for-disk-encryption true
	az keyvault key create --vault-name ${ADE_KV_NAME} --name ${ADE_KEK_NAME} --protection HSM
	ADE_KEK_ID="${ADE_KV_ID}"
	ADE_KEK_URI="`az keyvault key show --name ${ADE_KEK_NAME} --vault-name ${ADE_KV_NAME} | jq -r '.key.kid'`"
    else
	echo "Using pre-created KV objects"
	print_delete_instructions
    fi
else
    if [ -z "${ADE_ADAPP_NAME}" ] && \
	[ -z "${ADE_ADAPP_SECRET}" ] && \
	[ -z "${ADE_ADSP_APPID}" ] && \
	[ -z "${ADE_KV_ID}" ] && \
	[ -z "${ADE_KV_URI}" ] && \
	[ -z "${ADE_KEK_ID}"] && \
	[ -z "${ADE_KEK_URI}"]; then

	ADE_ADAPP_NAME="${ADE_PREFIX}adapp"
	ADE_ADAPP_SECRET="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9_![]{}()&@#^+' | fold -w 32 | head -n 1)"
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
	    #print_delete_instructions
	    auto_delete_resources
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
fi

# create network resources
az network vnet create --resource-group ${ADE_RG} --name ${ADE_VNET} --subnet-name ${ADE_SUBNET}
az network public-ip create --resource-group ${ADE_RG} --name ${ADE_PUBIP}
az network nsg create --resource-group ${ADE_RG} --name ${ADE_NSG}
az network nic create --resource-group ${ADE_RG} --name ${ADE_NIC} --vnet-name ${ADE_VNET} --subnet ${ADE_SUBNET} --network-security-group ${ADE_NSG} --public-ip-address ${ADE_PUBIP}

# create virtual machine with at least 7GB RAM and two 1GB data disks
# https://docs.microsoft.com/en-us/azure/virtual-machines/windows/sizes-general
az vm create --resource-group ${ADE_RG} --name ${ADE_VM} --size Standard_D2S_v3 --nics ${ADE_NIC} --image ${ADE_IMAGE} --generate-ssh-keys --data-disk-sizes-gb 1 1
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

if [[ "$ADE_RHUI_MODE" == true ]]; then
# use custom script extension to update the RHUI certificate using the Microsoft-provided RPM
# https://access.redhat.com/solutions/3167021
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
curl -o azureclient.rpm https://rhui-1.microsoft.com/pulp/repos/microsoft-azure-rhel7/rhui-azure-rhel7-2.2-74.noarch.rpm 2>&1 | tee -a /tmp/rhui.txt
rpm -U azureclient.rpm 2>&1 | tee -a /tmp/rhui.txt
yum clean all 2>&1 | tee -a /tmp/rhui.txt
curl -X PUT $1 -T /tmp/rhui.txt -H "x-ms-blob-type: BlockBlob"
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

# use custom script extension to run script
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

ADE_EXTRA_PARAMS=""
if [[ "$ADE_SP_MODE" != true ]]; then
    ADE_EXTRA_PARAMS="$ADE_EXTRA_PARAMS --aad-client-id $ADE_ADSP_APPID --aad-client-secret $ADE_ADAPP_SECRET"
fi

if [[ "$ADE_EFA_MODE" == true ]]; then
    ADE_EXTRA_PARAMS="$ADE_EXTRA_PARAMS --encrypt-format-all"
fi

# enable encryption
az vm encryption enable --name "${ADE_VM}" --resource-group "${ADE_RG}" --disk-encryption-keyvault "${ADE_KV_ID}" --key-encryption-key "${ADE_KEK_URI}" --key-encryption-keyvault "${ADE_KEK_ID}" --volume-type "${ADE_VOLUME_TYPE}" $ADE_EXTRA_PARAMS
# check status once every 10 minutes for a max of 6 hours
SECONDS=0
SLEEP_CYCLES=0
MAX_SLEEP=36

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
		#print_delete_instructions
		auto_delete_resources
		exit 1
	fi

	if [[ "$ADE_SP_MODE" == true ]]; then
		# for single pass, check the metadata
		if [[ `az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | jq .disks[1].encryptionSettings[0].enabled | grep -m 1 "false"` ]]
		then
			echo "Data disk did not get stamped even though extension reports success."
			#print_delete_instructions
			auto_delete_resources
			exit 1
		fi

		# disable to check if metadata clearing works
		az vm encryption disable --name "${ADE_VM}" --resource-group "${ADE_RG}" --volume-type "${ADE_VOLUME_TYPE}"

		# check if it got clered. Error out if it didn't
		if [[ `az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | jq .disks[1].encryptionSettings[0].enabled | grep -m 1 "true"` ]]
		then
			echo "Data disk did not get un-stamped even though extension reports success."
			#print_delete_instructions
			auto_delete_resources
			exit 1
		fi
	fi
else

    SLEEP_TIME=10m

    SLEEP_CYCLES=0
    until [[ $SLEEP_CYCLES -eq $MAX_SLEEP ]]; do
        # exit early if success criteria has been met
        if [[ "$ADE_SP_MODE" == true ]] && [[ `az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | jq '.status, .substatus' | grep -m 1 'os\\\": \\\"Encrypted'` ]] && [[ `az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" | jq .disks[0].encryptionSettings[0].enabled | grep -m 1 "true"` ]]; then
            break
        elif [[ "$ADE_SP_MODE" != true ]] && [[ `az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}" |  grep -m 1 'Encryption succeeded for all volumes\|Encryption succeeded for OS volume'` ]]; then
            break
        fi

        # success criteria wasn't met, report status and wait
        date
        az vm encryption show --name "${ADE_VM}" --resource-group "${ADE_RG}"
        sleep $SLEEP_TIME
        (( SLEEP_CYCLES++ ))
    done

    if [ $SLEEP_CYCLES -eq $MAX_SLEEP ]
    then
        echo "Test timeout threshold expired - OS disk encryption success message not observed after restart"
        #print_delete_instructions
        auto_delete_resources
        exit 1
    fi
fi

printf 'Total encryption time: %dh:%dm:%ds\n' $(($SECONDS/3600)) $(($SECONDS%3600/60)) $(($SECONDS%60))

#cleanup
auto_delete_resources
