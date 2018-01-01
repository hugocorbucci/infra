#!/bin/bash
set -e
set -o pipefail
set -x # Uncomment to debug

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"

if [ -z "${1}" ] || [ -z "${2}" ] || [ -z "${3}" ] || [ -z "${4}" ]; then
  echo "Usage: ${__FILE__} <cluster_name> <new_members_count> <root_mysql_user_password> <replication_user_password>"
  echo ""
  echo "\t<cluster_name>\t\tName of the mysql cluster to create"
  echo "\t<new_members_count>\t\Number of new members to create and add to the cluster"
  echo "\t<root_mysql_user_password>\t\tPassword for the root user for mysql"
  echo "\t<replication_user_password>\t\Password for the group replication user for mysql"
  exit 2
fi

CLUSTER_NAME="${1}"
NEW_MEMBERS_COUNT="${2}"
ROOT_USER_PASSWORD="${3}"
REPL_USER_PASSWORD="${4}"

ENV_FILE="${ROOT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  export $(cat ${ENV_FILE} | xargs)
fi

if [ -z "${DO_ACCESS_TOKEN}" ]; then
  echo "Env variable DO_ACCESS_TOKEN is empty or not set. It is required to proceed."
  echo "Please make sure it is either set or in the .env file in the root folder of this project."
  exit 1
fi


EXISTING_MEMBERS_PATH=$(mktemp)

doctl compute droplet list --tag-name "${CLUSTER_NAME}" -t "${DO_ACCESS_TOKEN}" -o json > "${EXISTING_MEMBERS_PATH}"
MEMBER_NAMES=()
NAME_PATTERN="${CLUSTER_NAME}"
LAST_COUNT="01"
for name in $(cat "${EXISTING_MEMBERS_PATH}" | jq -r '.[].name'); do
  MEMBER_NAMES+=($name)
done

if [ "${#MEMBER_NAMES[@]}" == "1" ]; then
  NAME_PATTERN=$(echo ${MEMBER_NAMES[0]} | sed -e 's/\(.*\)-[0-9]\{1,\}$/\1/g' )
  LAST_COUNT=$(echo ${MEMBER_NAMES[0]} | sed -e 's/.*-\([0-9]\{1,\}\)$/\1/g' )
else
  NAME_PATTERN_SUGGESTION=$(echo ${MEMBER_NAMES[0]} | sed -e 's/\(.*\)-[0-9]\{1,\}$/\1/g' )
  for name in ${MEMBER_NAMES[@]}; do
    if ! (echo $name | grep -q "${NAME_PATTERN_SUGGESTION}"); then
      NAME_PATTERN_SUGGESTION=""
      break
    else
      NEW_COUNT=$(echo ${name} | sed -e 's/.*-\([0-9]\{1,\}\)$/\1/g' )
      if [ "${LAST_COUNT}" -lt "${NEW_COUNT}" ]; then
        LAST_COUNT=${NEW_COUNT}
      fi
    fi
  done
  if [ ! -z "${NAME_PATTERN_SUGGESTION}" ]; then
    NAME_PATTERN="${NAME_PATTERN_SUGGESTION}"
  fi
fi

FIRST_NODE_IP=$(cat "${EXISTING_MEMBERS_PATH}" | jq -r '.[0].networks.v4' | jq -r '.[] | select(.type == "public") | .ip_address')
CLUSTER_UUID=$(ssh "mysql@${FIRST_NODE_IP}" "grep loose-group_replication_group_name /etc/mysql/my.cnf" | sed -e 's/ *loose-group_replication_group_name = "\(.*\)"/\1/g')

CLOUD_CONFIG_PATH=$(mktemp)
sed -e "s/<GROUP_NAME>/${CLUSTER_UUID}/g"\
  -e "s/<root_password>/${ROOT_USER_PASSWORD}/g"\
  -e "s/<repl_password>/${REPL_USER_PASSWORD}/g"\
  "${PROJECT_DIR}/new-node-cloud-config.yml" > "${CLOUD_CONFIG_PATH}"

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

NAME="${NAME_PATTERN}-$(printf "%02d" "${LAST_COUNT}")"
DROPLET_OUTPUT_PATH=$(mktemp)

"${ROOT_DIR}/bin/create-droplets.sh" "${NAME}" "${NEW_MEMBERS_COUNT}" "tukio,auto-generated,mysql,${CLUSTER_NAME}" > "${DROPLET_OUTPUT_PATH}"
IDS=$(cat "${DROPLET_OUTPUT_PATH}" | jq '.[].id')

NEW_MEMBERS_IPS=()
for id in ${IDS[@]}; do
    RESULT_PATH=$(mktemp)
    IP=""
    while [ -z "${IP}" ]; do
        sleep 5
        (doctl compute droplet get "${id}" -t "${DO_ACCESS_TOKEN}" -o json 2>&1 || echo "{\"errors\":[{\"detail\":\"not ready yet\"}]}") > "${RESULT_PATH}"
        IP=$(cat "${RESULT_PATH}" |  jq '.[].networks.v4'| jq -r '.[] | select(.type == "public") | .ip_address')
    done
    NEW_MEMBERS_IPS+=(${IP})
done

NEW_IPS=""
NEW_GROUP_SEEDS=""
for ip in ${NEW_MEMBERS_IPS[@]}; do
  NEW_IPS="${NEW_IPS},${ip}"
  NEW_GROUP_SEEDS="${NEW_GROUP_SEEDS},${ip}:33061"
done

NEW_MY_CNF_PATH=$(mktemp)
ssh "mysql@${FIRST_NODE_IP}" "sed -e 's/^\(loose-group_replication_ip_whitelist = \"[^\"]*\)\"$/\1${NEW_IPS}\"/g' -e 's/^\(loose-group_replication_group_seeds = \"[^\"]*\)\"$/\1${NEW_GROUP_SEEDS}\"/g' /etc/mysql/my.cnf" > "${NEW_MY_CNF_PATH}"
scp "${NEW_MY_CNF_PATH}" "mysql@${FIRST_NODE_IP}:/tmp/new.my.cnf"
ssh "mysql@${FIRST_NODE_IP}" "sudo mv /tmp/new.my.cnf /etc/mysql/my.cnf && sudo systemctl restart mysql"
REPL_LIST_LINE=$(grep loose-group_replication_ip_whitelist "${NEW_MY_CNF_PATH}")
REPL_SEEDS_LINE=$(grep loose-group_replication_group_seeds "${NEW_MY_CNF_PATH}")

OLD_MEMBER_IPS=()
for ip in $(cat "${EXISTING_MEMBERS_PATH}" | jq -r '.[].networks.v4' | jq -r '.[] | select(.type == "public") | .ip_address'); do
  OLD_MEMBER_IPS+=($ip)
done

for ip in ${OLD_MEMBER_IPS[@]}; do
  ssh -o "StrictHostKeyChecking=no" "mysql@${ip}" "sed -e 's/^loose-group_replication_ip_whitelist = \"[^\"]*\"$/${REPL_LIST_LINE}/g' -e 's/^loose-group_replication_group_seeds = \"[^\"]*\"$/${REPL_SEEDS_LINE}/g' /etc/mysql/my.cnf > /tmp/new.my.cnf"
  ssh "mysql@${ip}" "sudo mv /tmp/new.my.cnf /etc/mysql/my.cnf && sudo systemctl restart mysql"
done

REPL_INITIALIZATION_PATH=$(mktemp)
cat > "${REPL_INITIALIZATION_PATH}" <<INITIALIZATION
SET SQL_LOG_BIN=0;
CREATE USER 'repl'@'%' IDENTIFIED BY '${REPL_USER_PASSWORD}' REQUIRE SSL;
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;
SET SQL_LOG_BIN=1;
CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='${REPL_USER_PASSWORD}' FOR CHANNEL 'group_replication_recovery';
INSTALL PLUGIN group_replication SONAME 'group_replication.so';
START GROUP_REPLICATION;
INITIALIZATION

for ip in ${NEW_MEMBERS_IPS[@]}; do
  COUNT=0
  while [ "${MESSAGE}" != "success" ]; do
    sleep 5
    MESSAGE=$(ssh -o ConnectTimeout=5 -o "StrictHostKeyChecking=no" "mysql@${ip}" "[ ! -z \"\$(ps xau | grep mysqld | grep -v grep)\" ] && echo 'success'" || echo "not yet")
    COUNT=$(( COUNT + 1 ))
  done
  sleep "$(( COUNT * 3 ))"
  ssh -o "StrictHostKeyChecking=no" "mysql@${ip}" "sed -e 's/^loose-group_replication_ip_whitelist = \"[^\"]*\"/${REPL_LIST_LINE}/g' -e 's/^loose-group_replication_group_seeds = \"[^\"]*\"/${REPL_SEEDS_LINE}/g' /etc/mysql/my.cnf > /tmp/new.my.cnf"
  scp "${REPL_INITIALIZATION_PATH}" "mysql@${ip}:/tmp/repl.sql"
  ssh "mysql@${ip}" "sudo mv /tmp/new.my.cnf /etc/mysql/my.cnf && sudo systemctl restart mysql"
  ssh "mysql@${ip}" "mysql < /tmp/repl.sql"
  ssh "mysql@${ip}" "sudo sed -i -e 's/^loose-group_replication_start_on_boot = OFF$/loose-group_replication_start_on_boot = ON/' /etc/mysql/my.cnf && rm /home/mysql/.my.cnf /tmp/repl.sql"
done

cat "${DROPLET_OUTPUT_PATH}"
