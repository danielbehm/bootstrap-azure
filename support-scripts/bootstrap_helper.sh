#!/usr/bin/env bash

# Due to various limitations, testing only

set -x

# GET PARAMS

DNS_PARAMS="${1:?Missing dns configuration}"
BASE_DOMAIN="${2:?Missing entity domain}"
ANSIBLE_KEY="${3:?Missing ansible key}"
ANSIBLE_HOST="${4:?Missing ansible host}"
ANSIBLE_ID="${5:?Missing ansible template id}"
EMERGENCY_KEY="${6:?Missing Emergency Key}"

DNS_API=$(awk -F\: '{print $1}' <<<"$DNS_PARAMS")
DNS_API_PORT=$(awk -F\: '{print $2}' <<<"$DNS_PARAMS")
DNS_KEY=$(awk -F\: '{print $3}' <<<"$DNS_PARAMS")
DNS_ZONE=$(awk -F\: '{print $4}' <<<"$DNS_PARAMS")
DNS_TTL=$(awk -F\: '{print $5}' <<<"$DNS_PARAMS")


# ADDING DEBUG EMERG KEY

[ -d /root/.ssh ] || mkdir /root/.ssh
cat > /root/.ssh/authorized_keys <<- EOM
$EMERGENCY_KEY
EOM


# UPGRADE FAILS, AZURE WALINUXAGENT BUG


apt-mark hold walinuxagent

# updating the system via apt, installing required packages
# We decided to use --force-confdef & --force-confold as we do not want to lose
# changes done by RackSpace (disabling UUID root device for grub for instance).
# Grub ignores --force-confdef and --force-confold, though, so additional steps
# are required.



unset UCF_FORCE_CONFFNEW
export UCF_FORCE_CONFFOLD='YES'
export DEBIAN_FRONTEND='noninteractive'
apt-get update
apt-get -y --force-yes -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
apt-get -y --force-yes -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install curl git jq

export DEBIAN_FRONTEND='noninteractive'

apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install curl jq


apt-mark unhold walinuxagent


# SET HOSTNAME, DOMAIN,  RESOLVCONF

META_OUT=$(curl $CURL_OPTS -H Metadata:true http://169.254.169.254/metadata/instance?api-version=2017-03-01)
INSTANCE_NAME=$(jq -r .compute.name <<<"$META_OUT")
HOSTNAME=$(sed "s/\..*//g" <<<$INSTANCE_NAME)
DOMAIN=$(sed "s/$HOSTNAME.//g" <<<$INSTANCE_NAME)

GATEWAY=$(ip r | grep default | cut -d ' '  -f 3)
ADDR_LINE="$(ip addr show | grep "${GATEWAY%.*}." | grep -v secondary | awk 'NR==1')"
PRIMARY_IF="$(awk '{print $NF}' <<<"$ADDR_LINE")"
PRIMARY_IP="$(awk '{print $2}' <<<"$ADDR_LINE" | sed 's/\/.*//')"

HOSTNAME="$HOSTNAME"
FQDN="$HOSTNAME.$DOMAIN"

hostname $HOSTNAME
echo $HOSTNAME > /etc/hostname
echo $DOMAIN > /etc/domainname

echo "$PRIMARY_IP       $FQDN $HOSTNAME" >> /etc/hosts


# REGISTER_DNS
# azure DNS has a lot of bugs and lost our dns records frequently, we using our own solution right now



function add_record {
  local TYPE="${1:?Missing Type}"
  local NAME="${2:?Missing Name}"
  local DATA="${3:?Missing Data}"
  local TTL="${4:?Missing TTL}"
  local ZONE="${5:?Missing Zone}"

  if [ "$TYPE" == "CNAME" ]; then
    DATA="$DATA."
  fi

  RECORD='{"rrsets": [
              {
                  "name": "'"$NAME"'.",
                  "type": "'"$TYPE"'",
                  "ttl": "'"$TTL"'",
                  "changetype": "REPLACE",
                  "records": [
                       { "content": "'"$DATA"'",
                         "disabled": false
                       } ]
                }
              ]
            }'

  curl $CURL_OPTS --request 'PATCH' \
    --header 'X-API-Key: '"$DNS_KEY"'' \
    --data ''"$RECORD"'' \
    $DNS_API/api/v1/servers/localhost/zones/$ZONE.
}

add_record "A" "$FQDN" "$PRIMARY_IP" "$DNS_TTL" "$DNS_ZONE"


# END REGISTER_DNS


# ANSIBLE CALLBACK


echo "hello from init-ansible"

CURL_OPTS=" -s -k"
EXTRA_VARS='"autoconf": "true"'

[ -z "$ANSIBLE_HOST" ]  && exit 1
[ -z "$ANSIBLE_ID" ]    && exit 1
[ -z "$ANSIBLE_KEY" ]   && exit 1

min_ok=3
max_err=50

wait_time=20


function call_ansible {
  curl $CURL_OPTS -X POST \
     --data 'host_config_key='"$ANSIBLE_KEY"'' \
     --data '{"extra_vars": '"$EXTRA_VARS"' }' \
     https://$ANSIBLE_HOST/api/v1/job_templates/$ANSIBLE_ID/callback/
}


function check_for_status {
   test -r /etc/cloud-init.vars && . /etc/cloud-init.vars
   if [ "$ANSIBLESTATUS" == 'complete' ]; then
     return 0
   else
     return 1
   fi
}

call_ansible

ok_cnt=0
err_cnt=0

while [ $ok_cnt -lt $min_ok -a $err_cnt -lt $max_err ]
do
  check_for_status
  status=$?
  echo ">>> Agent Status: $status"
  if [ $status -eq 0 -o $status -eq 2 ]
  then
    (( ok_cnt++ ))
  else
    ok_cnt=0
    (( err_cnt++ ))
    sleep $wait_time
  fi
done

if [ $ok_cnt -lt $min_ok ]
then
  echo "ansible configuration failed $(( $max_err * $wait_time )) seconds."
else
  echo "ansible configuration successfully applied."
  echo 'Checking host status on monitoring server ...'
  exit 0
fi



