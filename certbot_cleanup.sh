#!/bin/bash
echo "Logging to Azure..."
az login --identity
az account show
echo "Received values from certbot:"
echo " - CERTBOT_VALIDATION: $CERTBOT_VALIDATION"
echo " - CERTBOT_DOMAIN:     $CERTBOT_DOMAIN"
DNS_ZONE_NAME=$(expr match "$CERTBOT_DOMAIN" '.*\.\(.*\..*\)')
echo "Finding out resource group for DNS zone $DNS_ZONE_NAME..."
DNS_ZONE_RG=$(az network dns zone list --query "[?name=='$DNS_ZONE_NAME'].resourceGroup" -o tsv)
echo " - DNS ZONE:           $DNS_ZONE_NAME"
echo " - DNS RG:             $DNS_ZONE_RG"
suffix=".${DNS_ZONE_NAME}"
RECORD_NAME=_acme-challenge.${CERTBOT_DOMAIN%"$suffix"}
echo "Deleting record $RECORD_NAME from DNS zone $DNS_ZONE_NAME..."
az network dns record-set txt delete -n "$RECORD_NAME" -z "$DNS_ZONE_NAME" -g "$DNS_ZONE_RG" -y
