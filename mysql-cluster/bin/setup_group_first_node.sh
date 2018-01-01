#!/bin/bash
set -e
set -o pipefail
# set -x # Uncomment to debug

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"

if [ -z "${1}" ] || [ -z "${2}" ] || [ -z "${3}" ]; then
  echo "Usage: ${__FILE__} <cluster_name> <root_mysql_user_password> <replication_user_password>"
  echo ""
  echo "\t<cluster_name>\t\tName of the mysql cluster to create"
  echo "\t<root_mysql_user_password>\t\tPassword for the root user for mysql"
  echo "\t<replication_user_password>\t\Password for the group replication user for mysql"
  exit 2
fi

CLUSTER_NAME="${1}"
ROOT_USER_PASSWORD="${2}"
REPL_USER_PASSWORD="${3}"

ENV_FILE="${ROOT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  export $(cat ${ENV_FILE} | xargs)
fi

if [ -z "${DO_ACCESS_TOKEN}" ]; then
  echo "Env variable DO_ACCESS_TOKEN is empty or not set. It is required to proceed."
  echo "Please make sure it is either set or in the .env file in the root folder of this project."
  exit 1
fi

CLUSTER_UUID=$(uuidgen)
CLOUD_CONFIG_PATH=$(mktemp)
sed -e "s/<GROUP_NAME>/${CLUSTER_UUID}/g"\
  -e "s/<root_password>/${ROOT_USER_PASSWORD}/g"\
  -e "s/<repl_password>/${REPL_USER_PASSWORD}/g"\
  "${PROJECT_DIR}/first-node-cloud-config.yml" > "${CLOUD_CONFIG_PATH}"

export DO_USERDATA_FILE="${CLOUD_CONFIG_PATH}"
if [ -z "${DO_SIZE}" ]; then
  DO_SIZE="2gb"
fi
export DO_SIZE
if [ -z "${DO_REGION}" ]; then
  DO_REGION="nyc3"
fi
export DO_REGION
if [ -z "${DO_IMAGE}" ]; then
  DO_IMAGE="ubuntu-16-04-x64"
fi
export DO_IMAGE

export DO_PRIVATE_NETWORKING="true"

DROPLET_OUTPUT_PATH=$(mktemp)

"${ROOT_DIR}/bin/create-droplets.sh" "mysql-cluster-00" 1 "tukio,auto-generated,mysql,${CLUSTER_NAME}" > "${DROPLET_OUTPUT_PATH}"
ID=$(cat "${DROPLET_OUTPUT_PATH}" | jq '.[].id')

RESULT_PATH=$(mktemp)
while [ -z "${IP}" ]; do
    sleep 5
    (doctl compute droplet get "${ID}" -t "${DO_ACCESS_TOKEN}" -o json 2>&1 || echo "{\"errors\":[{\"detail\":\"not ready yet\"}]}") > "${RESULT_PATH}"
    IP=$(cat "${RESULT_PATH}" |  jq '.[].networks.v4'| jq -r '.[] | select(.type == "public") | .ip_address')
done

while [ "${MESSAGE}" != "success" ]; do
  sleep 5
  MESSAGE=$(ssh -o ConnectTimeout=5 -o "StrictHostKeyChecking=no" "mysql@${IP}" "[ ! -z \"\$(ps xau | grep mysqld | grep -v grep)\" ] && echo 'success'" 2>/dev/null || echo "not yet")
done

cat "${RESULT_PATH}"
