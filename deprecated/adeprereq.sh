function print_help()
{
cat << EOM 
adeprereq.sh sets up prerequisites for Azure Disk Encryption using Azure CLI 

Usage
~~~~~

adeprereq.sh [options]


Options
~~~~~~~

-h, --help 
Displays this help text. 

--ade-subscription-id <subid>
Subscription ID that will own the KeyVault and target VM(s). If not specified, the currently logged in default subscription will be used. 

--ade-location <location>
Regional datacenter location of the KeyVault and target VM(s).  Make sure the KeyVault and VM(s) to be encrypted are in the same regional location.  The Azure CLI command "azure location list" will provide a list of supported locations in the current environment.  If not specified, the first result in the list from the current environment will be used as the default location. For more information on Azure regions, see https://azure.microsoft.com/en-us/regions/ . 

---ade-rg-name <resourcegroupname>
Name of the resource group the KeyVault and target VM(s) belong to.  A new resource group with this name will be created if it does not already exist. If this option is not specified, a resource group with a unique random name will be created and used.

--ade-kv-name <keyvaultname>
Name of the KeyVault in which encryption keys are to be placed.  A new KeyVault with this name will be created if it does not already exist. If this option is not specified, a KeyVault with a unique random name will be created and used.

--ade-adapp-name <appname>
Name of the AAD application that will be used to write secrets to KeyVault. A new application with this name and a new corresponding client secret will be created if one doesn't exist. If the app already exists, the --ade-adapp-secret must also be specified. If this option is not specified, a new Azure Active Directory application with a unique name and client secret will be created and used.

--ade-adapp-cps-name
Certificate policy subject name to use for creating the self-signed certificate. If not specified, a default value of "CN=www.contoso.com" will be used. 

--ade-adapp-cert-name 
Name that the self-signed certificate to be used for encryption is referred to in keyvault. If not specified, a new name will be created for the certificate. When the thumbprint of this certificate is provided to the enable encryption command, and the certificate already resides on the VM, encryption can be enabled by certificate thumbprint instead of having to pass a client secret. 

--ade-adapp-secret <clientsecret>
Client secret to use for a new AD application.  This is an optional parameter that can be used if a specific client secret is desired when creating a new ad application.  If not specified, a new random client secret will be created during ad application creation. 

--ade-kek-name <kekname>
Optional - this specifies the name of a key encryption key in KeyVault if a key encryptino key is to be used.  A new key with this name will be created if one doesn't exist. 

--ade-prefix <prefix>
Optional - this prefix will be used when auto-generating any missing components such as a resource group, keyvault, etc. to make identification easier.  If this is omitted the prefix 'ade' will be used. 

--ade-log-dir <dir>
Optional - this specifies the full path to a directory to be used to log intermediate JSON files.  If not specified, a log dir will be created using a unique name in the current directory.

Notes
~~~~~

This script requires the Azure CLI and jq (for parsing JSON output of CLI commands) to be installed prior to execution.

A powershell script with similar functionality is available at https://github/com/Azure/azure-powershell https://raw.githubusercontent.com/Azure/azure-powershell/dev/src/ResourceManager/Compute/Commands.Compute/Extension/AzureDiskEncryption/Scripts/AzureDiskEncryptionPreRequisiteSetup.ps1 
EOM

exit
}

# parse options 
options=$@
arguments=($options)
index=0
for argument in $options
  do
    i=$(( $i + 1 ))
    case $argument in
	-h) ;&
	--help) print_help;;
	--ade-rg-name) ADE_RG_NAME="${arguments[i]}";;
	--ade-kv-name) ADE_KV_NAME="${arguments[i]}";;
	--ade-location) ADE_LOCATION="${arguments[i]}";;
	--ade-adapp-name) ADE_ADAPP_NAME="${arguments[i]}";;
	--ade-adapp-cps-name) ADE_ADAPP_CPS_NAME="${arguments[i]}";;
	--ade-adapp-cert-name) ADE_ADAPP_CERT_NAME="${arguments[i]}";;
	--ade-adapp-secret) ADE_ADAPP_SECRET="${arguments[i]}";;
	--ade-subscription-id) ADE_SUBSCRIPTION_ID="${arguments[i]}";;
	--ade-kek-name) ADE_KEK_NAME="${arguments[i]}";;
	--ade-prefix) ADE_PREFIX="${arguments[i]}";;
	--ade-log-dir) ADE_LOG_DIR="${arguments[i]}";;
	--json) ADE_JSON_OUTPUT=TRUE;;
    esac
  done

# initialize script variables
ADE_UID=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
ADE_LOG_SUFFIX=".json"
if [ -z "$ADE_PREFIX" ]; then 
	ADE_PREFIX="ade";
fi

if [ -z "$ADE_LOG_DIR" ]; then 
	ADE_LOG_DIR=$ADE_PREFIX$ADE_UID
fi

if [ ! -d "$ADE_LOG_DIR" ]; then 
	mkdir $ADE_LOG_DIR
fi
echo "ADE_LOG_DIR ${ADE_LOG_DIR}"

# initialize azure environment
azure config mode arm --json > $ADE_LOG_DIR/config_mode_arm.json 
azure account list --json > $ADE_LOG_DIR/account_list.json 

# if unable to retrieve list of subscriptions, try again after login
if [ $? -ne 0 ]; then 
	azure login
	azure account list --json > $ADE_LOG_DIR/account_list.json 
	if [ $? -ne 0 ]; then 
		echo "Unable to login and list subscriptions"
		exit
	fi
fi

if [ -z "$ADE_SUBSCRIPTION_ID" ]; then 
	ADE_SUBSCRIPTION_ID="$(jq -r '.[] | select(.isDefault==true) | .id' $ADE_LOG_DIR/account_list.json)"
fi
echo "ADE_SUBSCRIPTION_ID $ADE_SUBSCRIPTION_ID"

if [ -z "$ADE_LOCATION" ]; then
	azure location list --json > $ADE_LOG_DIR/locations.json
	ADE_LOCATION="$(jq -r '.[0] | .name' $ADE_LOG_DIR/locations.json)"
fi 	
echo "ADE_LOCATION $ADE_LOCATION" 

# initialize resource group name variable
if [ -z "$ADE_RG_NAME" ]; then 
	ADE_RG_SUFFIX="rg"
	ADE_RG_NAME=$ADE_PREFIX$ADE_UID$ADE_RG_SUFFIX
fi
echo "ADE_RG_NAME $ADE_RG_NAME"

# create resource group if needed
if ! azure group show $ADE_RG_NAME > /dev/null 2>&1; then 
	azure group create --name $ADE_RG_NAME --location $ADE_LOCATION --subscription $ADE_SUBSCRIPTION_ID --json > $ADE_LOG_DIR/rg.json 2>&1
fi

# create AD application client secret if needed
if [ -z "$ADE_ADAPP_SECRET" ]; then 
	ADE_ADAPP_SECRET="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
fi
echo "ADE_ADAPP_SECRET $ADE_ADAPP_SECRET"

#create AD application certificate policy name if needed using sample domain
if [ -z "$ADE_ADAPP_CPS_NAME" ]; then 
	ADE_ADAPP_CPS_NAME="CN=www.contoso.com"
fi

#create AD application certificate name that keyvault uses for identification
if [ -z "$ADE_ADAPP_CERT_NAME" ]; then
	ADE_CERT_SUFFIX="cert"
	ADE_ADAPP_CERT_NAME=$ADE_PREFIX$ADE_UID$ADE_CERT_SUFFIX
fi

# initialize AD application name if needed 
if [ -z "$ADE_ADAPP_NAME" ]; then 
	ADE_ADAPP_SUFFIX="adapp"
	ADE_ADAPP_NAME="$ADE_PREFIX$ADE_UID$ADE_ADAPP_SUFFIX"
fi
echo "ADE_ADAPP_NAME $ADE_ADAPP_NAME"

# create AD application from application name if needed
azure ad app show --search "$ADE_ADAPP_NAME" --json > "$ADE_LOG_DIR/adapp.json" 2>&1
if ! jq '' $ADE_LOG_DIR/adapp.json > /dev/null 2>&1; then 
	until azure ad sp create --name "$ADE_ADAPP_NAME" --password "$ADE_ADAPP_SECRET" --json >> "$ADE_LOG_DIR/adspcreate.json" 2>&1
	do 
		# break creation loop if it failed at first for some other reason 
		# and is now failing because first attempt now succeeded and is failing
		# because it already exists
		azure ad app show --search "$ADE_ADAPP_NAME" --json > "$ADE_LOG_DIR/adapp.json"
		if jq '' "$ADE_LOG_DIR/adapp.json" > /dev/null 2>&1; 
		then
			break; 
		fi
		echo '- retrying ad app creation'
		sleep 5
	done

	azure ad app show --search "$ADE_ADAPP_NAME" --json > "$ADE_LOG_DIR/adapp.json"
	until jq '' "$ADE_LOG_DIR/adapp.json" > /dev/null 2>&1 
	do 	
		azure ad app show --search "$ADE_ADAPP_NAME" --json > "$ADE_LOG_DIR/adapp.json"
		echo '- waiting for ad app visibility' 
		sleep 5
	done
	ADE_ADSP_APPID="$(jq -r '.[0].appId' $ADE_LOG_DIR/adapp.json)"
else
	echo '- found application $ADE_ADAPP_NAME' 
	# retrieve AD application ID from app info
	ADE_ADSP_APPID="$(jq -r '.appId' $ADE_LOG_DIR/adapp.json)"
fi
echo "ADE_ADSP_APPID $ADE_ADSP_APPID"
	
#create service principal if needed
azure ad sp show --spn "$ADE_ADSP_APPID" --json > $ADE_LOG_DIR/adsp.json 
if ! jq '' $ADE_LOG_DIR/adsp.json > /dev/null 2>&1; then 
#create a new service principal associated with the ad application
	until azure ad sp create --applicationId "$ADE_ADSP_APPID" --json > $ADE_LOG_DIR/adspcreate.json 2>&1
	do 
		# keep trying until service principal is visible
		azure ad sp show --spn "$ADE_ADSP_APPID" --json > $ADE_LOG_DIR/adsp.json 2>&1
		if jq '' $ADE_LOG_DIR/adsp.json >/dev/null 2>&1
		then
			#valid json so adsp.json now contains the service principal information
			break;
		fi
		echo '- retrying service principal creation'
		sleep 5
	done
fi

#ensure service principal can be found in system 
azure ad sp show --spn "$ADE_ADSP_APPID" --json > $ADE_LOG_DIR/adsp.json 2>&1
until jq '' $ADE_LOG_DIR/adsp.json > /dev/null 2>&1
do
	azure ad sp show --spn "$ADE_ADSP_APPID" --json > $ADE_LOG_DIR/adsp.json 2>&1
	echo '- waiting for service principal availability'
	sleep 5
done
ADE_ADSP_OID="$(jq -r '.[0].objectId' $ADE_LOG_DIR/adsp.json)"
echo "ADE_ADSP_OID $ADE_ADSP_OID" 

# create role assignment 
azure role assignment create --objectId $ADE_ADSP_OID --roleName Reader -c "/subscriptions/$ADE_SUBSCRIPTION_ID/" --json > $ADE_LOG_DIR/rolestatus.json 2>&1

# to get the role assignment object (might be useful to check to see if it already exists) 
# azure role assignment list --objectId $ADE_ADSP_OID --json 

# initialize keyvault name if needed
if [ -z "$ADE_KV_NAME" ]; then 
	ADE_KV_SUFFIX="kv"
	ADE_KV_NAME=$ADE_PREFIX$ADE_UID$ADE_KV_SUFFIX
fi 
echo "ADE_KV_NAME $ADE_KV_NAME"

# create keyvault if needed 
if ! azure keyvault show --vault-name "$ADE_KV_NAME" --json > "$ADE_LOG_DIR/$ADE_KV_NAME$ADE_LOG_SUFFIX" 2>&1; then 
	azure keyvault create --vault-name $ADE_KV_NAME --resource-group $ADE_RG_NAME --location $ADE_LOCATION --json > $ADE_LOG_DIR/$ADE_KV_NAME$ADE_LOG_SUFFIX
fi
#retrieve kv url and id 
ADE_KV_URL=$(jq -r '.properties.vaultUri' $ADE_LOG_DIR/$ADE_KV_NAME$ADE_LOG_SUFFIX)
ADE_KV_ID=$(jq -r '.id' $ADE_LOG_DIR/$ADE_KV_NAME$ADE_LOG_SUFFIX)
echo "ADE_KV_URL $ADE_KV_URL"
echo "ADE_KV_ID $ADE_KV_ID"

# create self-signed certificate if needed, note that some server side delay is required before the certificate will available 
if ! azure keyvault certificate show --vault-name $ADE_KV_NAME --certificate-name $ADE_ADAPP_CERT_NAME > "$ADE_LOG_DIR/$ADE_KV_NAME$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX" 2>&1; then 
	azure keyvault certificate policy create --issuer-name Self --subject-name $ADE_ADAPP_CPS_NAME --file $ADE_LOG_DIR/policy.json --validity-in-months 12 >> "$ADE_LOG_DIR/$ADE_KV_NAME$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX" 2>&1
	azure keyvault certificate create --vault-name $ADE_KV_NAME --certificate-name $ADE_ADAPP_CERT_NAME --certificate-policy-file $ADE_LOG_DIR/policy.json >> "$ADE_LOG_DIR/$ADE_KV_NAME$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX" 2>&1
fi 

# wait for self signed certificate to be created  
azure keyvault certificate show --vault-name $ADE_KV_NAME --certificate-name $ADE_ADAPP_CERT_NAME --json > $ADE_LOG_DIR/$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX 2>&1
until jq -e '.x509Thumbprint' $ADE_LOG_DIR/$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX > /dev/null 2>&1
do
	azure keyvault certificate show --vault-name $ADE_KV_NAME --certificate-name $ADE_ADAPP_CERT_NAME --json > $ADE_LOG_DIR/$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX 2>&1
        # wait for self signed certificate to be created 
        sleep 5
done
ADE_KV_CERT_THUMB=$(jq -r '.x509Thumbprint' $ADE_LOG_DIR/$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX )
echo "ADE_KV_CERT_THUMB $ADE_KV_CERT_THUMB"

# set keyvault policy to allow access from the self-signed certificate
ADE_KV_CERT_START_DATE=$(jq -r '.attributes.created' $ADE_LOG_DIR/$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX )
ADE_KV_CERT_END_DATE=$(jq -r '.attributes.expires' $ADE_LOG_DIR/$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX )
ADE_KV_CERT_B64=$(jq -r '.cer' $ADE_LOG_DIR/$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX )
azure ad sp set -o $ADE_ADSP_OID -n $ADE_ADAPP_NAME --cert-value $ADE_KV_CERT_B64 --start-date $ADE_KV_CERT_START_DATE --end-date $ADE_KV_CERT_END_DATE --json > $ADE_LOG_DIR/$ADE_KV_NAME$ADE_CERT_THUMB$ADE_LOG_SUFFIX

# get the keyvault certificate secret id for later use in adding that certificate to the vm 
ADE_KV_CERT_SID=$(jq -r '.sid' $ADE_LOG_DIR/$ADE_ADAPP_CERT_NAME$ADE_LOG_SUFFIX )
echo "ADE_KV_CERT_SID $ADE_KV_CERT_SID"

# set keyvault policy to allow cert deployment (enabled-for-deployment allows self-signed certificate to be added to target vm's)
azure keyvault set-policy --vault-name $ADE_KV_NAME --spn $ADE_ADSP_APPID --perms-to-keys '["wrapKey"]' --perms-to-secrets '["set"]' --enabled-for-deployment true --enabled-for-disk-encryption true --resource-group $ADE_RG_NAME --subscription $ADE_SUBSCRIPTION_ID --json > "$ADE_LOG_DIR/$ADE_KV_NAME$ADE_ADAPP_NAME$ADE_LOG_SUFFIX"

# create key encryption key
if [ -z "$ADE_KEK_NAME" ]; then 
	ADE_KEK_SUFFIX="kek"
	ADE_KEK_NAME=$ADE_PREFIX$ADE_UID$ADE_KEK_SUFFIX 
	until azure keyvault key create --vault-name $ADE_KV_NAME --key-name $ADE_KEK_NAME --destination Software --json >> $ADE_LOG_DIR/$ADE_KEK_NAME$ADE_LOG_SUFFIX
	do
        	echo '-retrying...'
	        sleep 5
	done
else
	azure keyvault key show --vault-name $ADE_KV_NAME --key-name $ADE_KEK_NAME --json >> $ADE_LOG_DIR/$ADE_KEK_NAME$ADE_LOG_SUFFIX
fi
ADE_KEK_URL="$(jq -r '.key.kid' $ADE_LOG_DIR/$ADE_KEK_NAME$ADE_LOG_SUFFIX)"
echo "ADE_KEK_NAME $ADE_KEK_NAME"
echo "ADE_KEK_URL $ADE_KEK_URL"

# save values so they can be restored later if desired ("source ade_env.sh") 
compgen -v | grep ADE_ | while read var; do printf "%s=%q\n" "$var" "${!var}"; done > $ADE_LOG_DIR/ade_env.sh

