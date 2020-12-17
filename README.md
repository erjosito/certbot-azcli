# Docker image for LetsEncrypt cert generation and import to Azure Key Vault

You might have been confronted with the challenge that certificate management sometimes presents. Your website should be secure, but digital certificates can be expensive. Not only in terms of money, but they increase complexity. Luckily there are two technologies that can help you to overcome both challenges:

- [LetsEncrypt](https://letsencrypt.org/) is a non-profit Certificate Authority (CA) that issues certificates at no cost.
- Secret vaults such as [Azure Key Vault](https://docs.microsoft.com/azure/key-vault/general/basic-concepts) can alleviate the overhead of certificate management: a centralized repository for your certificates, and the source where other Azure services will take their certificates from.

You can automate the creation and renewal of certificates with LetsEncrypt using the [ACME](https://en.wikipedia.org/wiki/Automated_Certificate_Management_Environment) protocol. Luckily you don't need to understand anything of it, since many ACME clients exist out there that can help with this task. One of the most popular ones is [certbot](https://certbot.eff.org/), a command-line application that allows to send certificate requests to LetsEncrypt.

When you run certbot to generate a digital certificate, LetsEncrypt will return a challenge to validate that the domain actually belongs to your. This challenge can be either HTTP-based (uploading a certain file in your web server) or DNS-based (creating a certain TXT record in your domain). Since we are trying to generate a certificate to put it into Azure Key Vault, potentially we don't have any web site yet. So we will take the DNS challenge. The rest of this document assumes that your domain is hosted in [Azure DNS](https://docs.microsoft.com/azure/dns/dns-overview).

OK, that was a lot of new terms. In short, this is the sequence of events we want to achieve:

1. Use certbot to send a certificate request to LetsEncrypt
1. Create TXT record in Azure DNS to fulfill the challenge
1. Get generated certificate and put it into Azure Key Vault
1. Now you can use that certificate anywhere else in Azure

As you can see, from step 2 onwards you need to run operations on Azure, for which you can use a number of different frameworks. In this example we will use the Azure CLI. Container images offer a great way of packaging the requirements we need. As you can see in the Dockerfile of this repo, I am taking the image `mcr.microsoft.com/azure-cli` with the latest Azure CLI version, and I am adding certbot to it. That's it. Now we need to run it!

In Azure there are multiple platforms that can run Docker containers, for our purpose [Azure Container Instances](https://docs.microsoft.com/azure/container-instances/container-instances-overview) are ideal. When you need to generate or renew a certificate, you can spin up an ACI, and when it finishes you will have the new certificate in your Azure Key Vault.

There is one more hurdle we need to jump: how will the Azure Container Instance authenticate to Azure? [Managed Identities](https://docs.microsoft.com/azure/active-directory/managed-identities-azure-resources/overview). We can create a Managed Identity, and give it enough privilege for Azure DNS (to solve the LetsEncrypt challenge) and to Azure Key Vault (to create the certificate). This code will create the identity in a new resource group and assign those permissions:

```bash
# Variables
rg=acicertbot
location=westeurope
id_name=certbotid
akv_name=your_vault_name
dns_zone=yourdomain.com
# Create RG and user identity
az group create -n $rg -l $location
id_resid=$(az identity show -n $id_name -g $rg --query id -o tsv)
if [[ -z "$id_resid" ]]
then
    echo "Creating user identity ${id_name}..."
    az identity create -n $id_name -g $rg
    id_spid=$(az identity show -n $id_name -g $rg --query principalId -o tsv)
    id_resid=$(az identity show -n $id_name -g $rg --query id -o tsv)
    # Assign permissions to AKV
    az keyvault set-policy -n $akv_name --object-id $id_spid \
        --secret-permissions get list set \
        --certificate-permissions create import list setissuers update \
        --key-permissions create get import sign verify
    # Assign permisses to Azure DNS Zone
    dns_zone_id=$(az network dns zone list --query "[?name=='$dns_zone'].id" -o tsv)
    if [[ -n "$dns_zone_id" ]]
    then
        echo "DNS zone $dns_zone found, resource ID $dns_zone_id, creating role assignment..."
        az role assignment create --scope $dns_zone_id --assignee $id_spid --role "DNS Zone Contributor"
    else
        echo "DNS zone $dns_zone not found"
    fi
else
    echo "User identity ${id_name} found, ID is $id_resid"
fi
```

You can build the image with the files in this repository, and push it to your favorite container registry:

```bash
# Build and push image
docker build -t yourdockerusername/certbot-azcli:1.0 .
docker push yourdockerusername/certbot-azcli:1.0
```

Or you can use my image if you prefer: `erjosito/certbot-azcli:1.0`.

And that's it, you can now run the container now:

```bash
# Run ACI to generate certificate
akv_name=erjositoKeyvault
aci_name=certbot
image=erjosito/certbot-azcli:1.0
dns_hostname=certbot
domain="${dns_hostname}.${dns_zone}"
email_address=youremail@contoso.com
az container create -n $aci_name -g $rg -l $location --image $image --assign-identity $id_resid \
  -e "DOMAIN=$domain" "EMAIL=$email_address" "AKV=$akv_name"
```

And you are done! If you go to your Azure Key Vault, you will find your certificate there. If you want to see an end to end example of how to use this with Azure Web Apps, I have this code for you:

```bash
# Variables
rg=certtest                              # Resource group where the web app will be created
location=westeurope                      # Location where the web app will be created
akv_name=your_vault_name                 # Here is where the certificate will be stored
svcplan_name=webappplan                  # Not too original name for our service plan
app_name=web$RANDOM                      # Random name for the app
image=gcr.io/kuar-demo/kuard-amd64:blue  # I love this image for testing
tcp_port=8080                            # Port where the previous image is listening to
dns_zone_name=yourdomain.com             # You should own this DNS zone, that should be hosted in Azure DNS
app_dns_name=$app_name                   # You could have a different DNS name, but I default to the app name
domain="${app_dns_name}.${dns_zone}"     # Full domain name of our app
email_address=youremail@contoso.com      # It will be used in the cert creation
id_name=certbotid                        # Name of managed identity with permissions to AzDNS and AKV
id_rg=acicertbot                         # Resource Group of managed identity with permissions to AzDNS and AKV

# Create cert with ACI
id_resid=$(az identity show -n $id_name -g $id_rg --query id -o tsv)
az container create -n certbot -g $rg -l $location --image erjosito/certbot-azcli:1.0 --assign-identity $id_resid \
  -e "DOMAIN=$domain" "EMAIL=$email_address" "AKV=$akv_name"
cert_name=$(echo $domain | tr -d '.')  # the container will create a cert with the domain name removing the dots (.)

# Create Web App
az group create -n $rg -l $location
az appservice plan create -n $svcplan_name -g $rg --sku B1 --is-linux
az webapp create -n $app_name -g $rg -p $svcplan_name --deployment-container-image-name $image
az webapp config appsettings set -n $app_name -g $rg --settings "WEBSITES_PORT=${tcp_port}"
az keyvault set-policy -n $akv_name --spn abfa0a7c-a6b6-4736-8310-5855508787cd \
    --secret-permissions get \
    --key-permissions get \
    --certificate-permissions get
az webapp config ssl import -n $app_name -g $rg --key-vault $akv_name --key-vault-certificate-name $cert_name
cert_thumbprint=$(az webapp config ssl list -g $rg --query '[0].thumbprint' -o tsv)
az webapp restart -n $app_name -g $rg
app_hostname=$(az webapp show -n $app_name -g $rg --query defaultHostName -o tsv)

# Update DNS name
dns_zone_rg=$(az network dns zone list --query "[?name=='$dns_zone_name'].resourceGroup" -o tsv)
echo "Adding CNAME record ${app_dns_name}.${dns_zone_name} for Webapp $app_hostname"
az network dns record-set cname set-record -z $dns_zone_name -g $dns_zone_rg -n $app_dns_name -c $app_hostname
app_fqdn="${app_dns_name}.${dns_zone_name}"

# Add custom domain to web app
az webapp config hostname add --webapp-name $app_name -g $rg --hostname $app_fqdn
az webapp config ssl bind -n $app_name -g $rg --certificate-thumbprint $cert_thumbprint --ssl-type SNI
az webapp update -n $app_name -g $rg --https-only true

# Test
echo "Visit with your browser the URL https://${app_fqdn}"
```