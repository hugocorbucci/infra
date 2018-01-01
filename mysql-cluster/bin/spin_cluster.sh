#!/bin/bash
set -e
set -o pipefail
# set -x # Uncomment to debug

if [ -z "$(command -v jq)" ]; then
  echo "This requires jq. Please install via `apt-get install` jq or `brew install jq` and try again"
  exit 1
fi
if [ -z "$(command -v openssl)" ]; then
  echo "This requires openssl. Please install and try again"
  exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"

ENV_FILE="${ROOT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  export $(cat ${ENV_FILE} | xargs)
fi

if [ ! -z "$1" ]; then
  ROOT_USER_PASSWORD="$1"
fi
if [ -z "${REPL_USER_PASSWORD}" ]; then
  MYSQL_CLUSTER_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9!"#$%&()*+,-.:;<=>?@[\]^_`{|}~' </dev/urandom | head -c 32 ; echo)
  echo "No password specified. Generated one for cluster access:"
  echo "${REPL_USER_PASSWORD}"
  echo "Adding to .env"
  echo "" >> "${ENV_FILE}"
  echo "MYSQL_CLUSTER_PASSWORD=${REPL_USER_PASSWORD}" >> "${ENV_FILE}"
fi

cd "${PROJECT_DIR}"

CLUSTER_NAME="mysql"
CLUSTER_SIZE=3
export DO_SIZE="2gb"
export DO_REGION="nyc3"
export DO_IMAGE="ubuntu-16-04-x64"

"${PROJECT_DIR}/bin/setup_group_first_node.sh" "${CLUSTER_NAME}" "${ROOT_USER_PASSWORD}" "${REPL_USER_PASSWORD}" >> first.json
FIRST_NODE_ID=$(cat first.json | jq '.[].id')

"${PROJECT_DIR}/bin/add_group_members.sh" "${CLUSTER_NAME}" "$((CLUSTER_SIZE - 1))" "${ROOT_USER_PASSWORD}" "${REPL_USER_PASSWORD}" >> members.json
MEMBER_IDS=$(cat members.json | jq '.[].id')

CLUSTER_IDS=(FIRST_NODE_ID MEMBER_IDS[@])
echo "Cluster created with name ${CLUSTER_NAME} and root password \"${ROOT_USER_PASSWORD}\" replication password \"${REPL_USER_PASSWORD}\" on droplets with IDs: ${CLUSTER_IDS[@]}"
