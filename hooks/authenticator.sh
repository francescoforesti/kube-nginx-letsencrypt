#/bin/bash
# Script to put the challenge in the gce secret.
# This script is called by certbot before attempting to verify the
# http acme challenge and passes control to certbot after it's finished.
# For more info: https://certbot.eff.org/docs/using.html#pre-and-post-validation-hooks

source /hooks/.env

echo "ACME_SECRETNAME: '$ACME_SECRETNAME' | NAMESPACE: '$NAMESPACE'"

if [[ -z $ACME_SECRETNAME || -z $NAMESPACE ]]; then
	echo "ACME_SECRETNAME or NAMESPACE not set, exiting"
    exit 1
fi

echo "ACME authenticator: preparing patch to update the challenge secret"
CERTBOT_VALIDATION_B64=$(echo $CERTBOT_VALIDATION | base64 | tr -d '\n')

ls /challenge-secret-patch-template.json || exit 1

echo "ACME authenticator: patch template exists, executing template replacements"
cat /challenge-secret-patch-template.json | sed "s/ACME_SECRETNAME/${ACME_SECRETNAME}/g" | sed "s/ACME_NAMESPACE/${NAMESPACE}/g" | sed "s/ACME_TOKEN_NAME/${CERTBOT_TOKEN}/g" | sed "s/ACME_TOKEN_CONTENT/${CERTBOT_VALIDATION_B64}/g" > /challenge-secret-patch.json

ls /challenge-secret-patch.json || exit 1

echo "ACME authenticator: updating challenge secret '${ACME_SECRETNAME}' with token '${CERTBOT_TOKEN}'"
curl -i --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" -k -XPATCH  -H "Accept: application/json, */*" -H "Content-Type: application/strategic-merge-patch+json" -d @/challenge-secret-patch.json https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/secrets/${ACME_SECRETNAME}

mkdir -p /.well-known/acme-challenge
echo "saving '${CERTBOT_VALIDATION}' to file $CERTBOT_TOKEN"
echo $CERTBOT_VALIDATION > /.well-known/acme-challenge/$CERTBOT_TOKEN

CHALLENGE_URL="http://${CERTBOT_DOMAIN}/.well-known/acme-challenge/${CERTBOT_TOKEN}"
echo "ACME authenticator: Attempting to verify the challenge at '$CHALLENGE_URL' before passing control to certbot again"

# Before passing control to certbot, this loops checks when we get a 200 OK for the challenge.
# This is needed because gce usually takes some time to update the volumes with the new secret value.
# If we pass control to certbot too soon it will try to check the challenge immediately and
# it will most likely fail, even though the secret itself has the correct value.
for i in {1..50}
do
    RES=$(curl -i $CHALLENGE_URL | head -n1)
    echo "`date`: Attempt $i: $RES"
    if [[ $RES == *"200 OK"* ]]; then
        exit 0
    fi

    if [[ $i == 50 ]]; then
        echo "ACME authenticator: max attempts reached to get the callenge. Quitting."
        exit 1
    fi

    sleep 5
done


