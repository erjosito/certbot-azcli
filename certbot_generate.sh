#!/bin/bash
# Create certificate (optionally using the staging server)
if [[ "$STAGING" == "yes" ]]
then
    echo "Generating cert in staging server..."
    certbot certonly -n -d "$DOMAIN" --manual -m "$EMAIL" --preferred-challenges=dns \
        --staging --manual-public-ip-logging-ok --agree-tos \
        --manual-auth-hook /home/certbot_auth.sh --manual-cleanup-hook /home/certbot_cleanup.sh
else
    echo "Generating cert in production server..."
    certbot certonly -n -d "$DOMAIN" --manual -m "$EMAIL" --preferred-challenges=dns \
        --manual-public-ip-logging-ok --agree-tos \
        --manual-auth-hook /home/certbot_auth.sh --manual-cleanup-hook /home/certbot_cleanup.sh
fi
# If debugging, show created certificates
if [[ "$DEBUG" == "yes" ]]
then
    ls -al "/etc/letsencrypt/live/${DOMAIN}/"
    cat "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    cat "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    cat "/var/log/letsencrypt/letsencrypt.log"
fi
# Variables to create AKV cert
pem_file="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
key_file="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
cert_name=$(echo $DOMAIN | tr -d '.')
# Combine PEM and key in one pfx file (pkcs#12)
pfx_file=".${pem_file}.pfx"
openssl pkcs12 -export -in $pem_file -inkey $key_file -out $pfx_file -passin pass:$key_password -passout pass:$key_password
# Add certificate
az keyvault certificate import --vault-name "$AKV" -n "$cert_name" -f $pfx_file
