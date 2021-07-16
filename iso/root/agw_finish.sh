#!/usr/bin/env bash
set -e

PROVISION_SERVER_URL=${SERVER:=https://provision.freedomfi.com}
PROVISION_SERVER_SSH_HOST=${SSH_HOST:=provision.freedomfi.com}
PROVISION_SERVER_SSH_PORT=${SSH_PORT:=2222}
PROVISIONING_FILE_NAME="freedomfi.lic"
PROVISIONING_FILE_PATH="/etc/freedomfi.lic"

function error_beep(){
  beep -f 1000 -l 500 -D 200 -r 1 \
    -n -f 1000 -l 100 -D 200 -r $1
}

function catch() {
  echo "Error code $1 occurred on line $2"
  echo "Failed to perform provision process"
  error_beep 1 && sleep 0.2 && error_beep 1
  exit 1
}

trap 'catch $? $LINENO' ERR

#=============================================================================
#                        TEST NETWORK CONNECTIVITY
#=============================================================================
function test_network() {
  WAN_INTERFACE=eth0
  TEST_DOMAIN=freedomfi.com

  WAN_LINK_STATE=$(cat /sys/class/net/${WAN_INTERFACE}/operstate)
  if [ "${WAN_LINK_STATE}" != "up" ]
  then
    error_beep 2
    echo "${WAN_INTERFACE} link DOWN"
    exit 2
  else
    echo "Interface ${WAN_INTERFACE} link state: ${WAN_LINK_STATE}"
  fi

  WAN_IP=$(ip -4 addr show ${WAN_INTERFACE} | grep -oP '(?<=inet\s)\d+(\.\d+){3}(\/\d+)?' | tr '\n' ' ')
  if [ -z "${WAN_IP}" ]
  then
    error_beep 3
    echo "${WAN_INTERFACE} has no IP address"
    exit 3
  else
    echo "Interface ${WAN_INTERFACE} IP: ${WAN_IP}"
  fi

  DEFAULT_ROUTE=$(ip r | grep -oP "(?<=default via\s)\d+(\.\d+){3}")
  if [ -z "${DEFAULT_ROUTE}" ]
  then
    error_beep 4
    echo "No default route"
    exit 4
  else
    echo "Default route: ${DEFAULT_ROUTE}"
  fi

  DNS_ANSWER=$(dig +short -4 A ${TEST_DOMAIN})
  if [ -z "${DNS_ANSWER}" ]
  then
    error_beep 5
    echo "DNS resolution problem"
    exit 5
  else
    echo "Domain ${TEST_DOMAIN} resolved to ${DNS_ANSWER}"
  fi

  if ! ping -c 1 ${TEST_DOMAIN} > /dev/null;
  then
    error_beep 6
    echo "Can not ping ${TEST_DOMAIN}"
    exit 6
  else
    echo "Ping ${TEST_DOMAIN} succeed"
  fi
}
#=============================================================================
#                        TEST NETWORK CONNECTIVITY
#=============================================================================


SUCCEED=false
rm -f /tmp/provision_output

FILES=$(find /media -maxdepth 2 -type f -name "${PROVISIONING_FILE_NAME}")
if [ ! -f "${FILES}" ] && [ -f "${PROVISIONING_FILE_PATH}" ]; then
  FILES=$PROVISIONING_FILE_PATH
fi

if [ -z "${FILES}" ]
then
  echo "No provisioning file found"
  exit 1
fi

set +e
test_network
set -e

if [ ! -f ~/.ssh/id_rsa ]
then
  echo "No id_rsa ssh key found. Creating new"
  ssh-keygen -t rsa -N "" -h -q -f ~/.ssh/id_rsa
fi
ssh_key_contents=$(cat ~/.ssh/id_rsa.pub)


if [ ! -f /etc/snowflake ]
then
  echo "No snowflake found. Creating new"
  uuidgen > /etc/snowflake
fi
hardware_id=$(cat /etc/snowflake)

for PROV in ${FILES}
do
  prov_contents=$(cat "${PROV}")
  prov_payload=$(gpg --output - "${PROV}" || true)

  prov_server=$(echo "${prov_payload}" | grep -oP '(?<=server: ).*' | tr -d '\r')
  prov_server=${prov_server:=${PROVISION_SERVER_URL}}

  json_contents=$(jq -n --arg hardware_id "${hardware_id}" \
                        --arg ssh_key "${ssh_key_contents}" \
                        --arg provision_file "${prov_contents}" \
                        '{hardware_id: $hardware_id, ssh_key: $ssh_key, provision_file: $provision_file}')

  status_code=$(IFS=$',' curl -s -L --header "Content-Type: application/json" \
                --request POST \
                --data "${json_contents}" \
                -o /tmp/provision_output \
                -w "%{http_code}\n" \
                ${prov_server}/agw \
                )
  if [ "${status_code}" == "200" ]
  then
    echo "Succeed provision request with key file ${PROV}"
    SUCCEED=true
    if [ "${PROV}" != "${PROVISIONING_FILE_PATH}" ]
    then
      cp -f ${PROV} ${PROVISIONING_FILE_PATH}
    fi
    break
  fi
  echo "Failed to perform provision request with key file: ${PROV}"
  echo "Server response: $(cat /tmp/provision_output)"
done

[ "${SUCCEED}" == "true" ]

ssh_pubkey=$(jq -r .ssh.pubkey < /tmp/provision_output)
if ! grep -Fxq "${ssh_pubkey}" ~magma/.ssh/authorized_keys
then
  echo "Adding ssh pubkey to authorized_keys"
  echo "${ssh_pubkey}" >> ~magma/.ssh/authorized_keys
fi

echo "Attempting to establish SSH connection"

username="${hardware_id//-/}"

remote_port=$(jq .ssh.port < /tmp/provision_output)
ssh_host=$(jq -r --arg HOST "${PROVISION_SERVER_SSH_HOST}" '.ssh.server_host // $HOST' < /tmp/provision_output)
ssh_port=$(jq -r --arg PORT "${PROVISION_SERVER_SSH_PORT}" '.ssh.server_port // $PORT' < /tmp/provision_output)

beep

ssh -o ConnectTimeout=5 \
    -o ConnectionAttempts=100 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ExitOnForwardFailure=yes \
    -R "${remote_port}":127.0.0.1:22 \
    -N -p "${ssh_port}" \
    "${username}"@"${ssh_host}"
