#!/bin/bash

if [[ -z $EMAIL || -z $DOMAINS || -z $SECRETNAME ]]; then
	echo "EMAIL, DOMAINS and SECRETNAME env vars required"
	exit 1
fi

if [[ $DRY_RUN ]]; then
  echo "DRY_RUN is set, WILL NOT ACTUALLY CREATE CERTIFICATES"
fi

#python3 simple-server.py &
python3 -m http.server 80 &

NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)

echo "Requesting certificates for:"
echo "  EMAIL: $EMAIL"
echo "  DOMAINS: $DOMAINS"
echo "  NAMESPACE: $NAMESPACE"
echo "  PODS: $NGINX_PODS"
echo "  DRY_RUN: $DRY_RUN"

echo "Creating env file"
cat /hooks/.env-template | sed "s/ACME_SECRETNAME_TEMPLATE/${ACME_SECRETNAME}/" | sed "s/NAMESPACE_TEMPLATE/${NAMESPACE}/" > /hooks/.env

if [[ -z $DRY_RUN ]]; then
  echo "Requesting certificate"
  certbot certonly --manual --preferred-challenges http -n --agree-tos --email ${EMAIL} --no-self-upgrade -d ${DOMAINS} --manual-public-ip-logging-ok --manual-auth-hook /hooks/authenticator.sh
else
   echo "TESTING certificate requesting, DRY RUN IS ENABLED"
   certbot certonly --dry-run --manual --preferred-challenges http -n --agree-tos --email ${EMAIL} --no-self-upgrade -d ${DOMAINS} --manual-public-ip-logging-ok --manual-auth-hook /hooks/authenticator.sh
fi

echo "Verifying path to certificate exists"
tree /etc/letsencrypt

BASE_CERTPATH=/etc/letsencrypt/live
MAIN_DOMAIN=$(echo $DOMAINS | cut -f1 -d',')


CERTPATH="$BASE_CERTPATH/$MAIN_DOMAIN/fullchain.pem"
KEYPATH="$BASE_CERTPATH/$MAIN_DOMAIN/privkey.pem"

echo "CERTPATH IS " $CERTPATH
echo "KEYPATH IS " $KEYPATH
echo "sleeping 1500 before doing anything else. Make sure those files exist!"
sleep 1500

ls $CERTPATH $KEYPATH || exit 1

echo "Renewal config /etc/letsencrypt/renewal/$MAIN_DOMAIN.conf"
cat /etc/letsencrypt/renewal/$MAIN_DOMAIN.conf

ls /ssl-secret-patch-template.json || exit 1

echo "SSL secret patch file exists. Executing template"
cat /ssl-secret-patch-template.json | sed "s/SECRETNAMESPACE/${NAMESPACE}/" | sed "s/SECRETNAME/${SECRETNAME}/" | sed "s/TLSCERT/$(cat ${CERTPATH} | base64 | tr -d '\n')/" | sed "s/TLSKEY/$(cat ${KEYPATH} |  base64 | tr -d '\n')/" > /ssl-secret-patch.json

echo "Updating certificate secret '$SECRETNAME'"
curl -i --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" -k -XPATCH  -H "Accept: application/json, */*" -H "Content-Type: application/strategic-merge-patch+json" -d @/ssl-secret-patch.json https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/secrets/${SECRETNAME}

if [[ $NGINX_PODS != "" ]]; then
	echo "Waiting 30 seconds before restarting nginx pods"
	sleep 30

	NGINX_PODS=$(echo $NGINX_PODS | sed 's/,/ /')
	for NGINX_POD in $NGINX_PODS
	do
		echo "Restarting ${NGINX_POD} pod"
		curl -i --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" -k -XPOST  -H "Accept: */*" https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/pods/${NGINX_POD}/exec?command=service&command=nginx&command=restart
	done
fi
