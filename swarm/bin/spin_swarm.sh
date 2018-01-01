#!/bin/bash
set -e
set -o pipefail
# set -x # Uncomment to debug

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"

ENV_FILE="${ROOT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  export $(cat ${ENV_FILE} | xargs)
fi

usage() {
  echo "Usage: ${BASH_SOURCE[0]} <swarm_name> <node_count>"
  echo ""
  echo -e "<swarm_name> \t the name for this swarm cluster. Can also be set with env variable \$SWARM_NAME"
  echo -e "<node_count> \t a positive integer for the number of nodes in the swarm to spin. Can also be set with env variable \$NODE_COUNT"
}

if [ -z "${SWARM_NAME}" ]; then
  SWARM_NAME="$1"
fi
if [ -z "${SWARM_NAME}" ]; then
  usage
  exit 1
fi

if [ -z "${NODE_COUNT}" ]; then
  NODE_COUNT="$2"
fi
if [ -z "${NODE_COUNT}" ] || ! [[ "${NODE_COUNT}" =~ ^-?[0-9]+$ ]]; then
  usage
  exit 2
fi

cd "${PROJECT_DIR}"

NODES=()
MANAGERS=()
WORKERS=()
for i in $(seq 1 1 $NODE_COUNT); do
  NODE_NAME="${SWARM_NAME}-${i}"
  NODES+=("${NODE_NAME}")
  if [ "${NODE_COUNT}" -le "3" ]; then
    if [ "${i}" -eq "1" ]; then
      MANAGERS+=("${NODE_NAME}")
    else
      WORKERS+=("${NODE_NAME}")
    fi
  elif [ "${NODE_COUNT}" -le "7" ]; then
    if [ "${i}" -le "2" ]; then
      MANAGERS+=("${NODE_NAME}")
    else
      WORKERS+=("${NODE_NAME}")
    fi
  else
    if [ "${i}" -le "3" ]; then
      MANAGERS+=("${NODE_NAME}")
    else
      WORKERS+=("${NODE_NAME}")
    fi
  fi
done

LOG_FILE="${PROJECT_DIR}/tmp/swarm-${SWARM_NAME}.log"
mkdir -p "${PROJECT_DIR}/tmp"
cat /dev/null > "${LOG_FILE}"

function finish {
  echo "Something went wrong. Check ${LOG_FILE} for more details."
}
trap finish EXIT

echo "Creating swarm nodes..." | tee -a "${LOG_FILE}"
PIDS=()
for node in "${NODES[@]}"; do
  echo -e "\t Creating ${node}..." | tee -a "${LOG_FILE}"
  "${ROOT_DIR}/bin/create-do-docker-machine.sh" "${node}" tukio,auto-generated,swarm 2>&1 >>"${LOG_FILE}" &
  PIDS+=("$!")
done
ERRORED=0
for pid in ${PIDS[*]}; do
  if wait $pid; then
    echo -e "\t Node created." | tee -a "${LOG_FILE}"
  else
    let "ERRORED=1"
  fi
done
if [ "${ERRORED}" == "1" ]; then
  echo -e "\t Failed to create some nodes" | tee -a "${LOG_FILE}"
  tail -n50 "${LOG_FILE}"
  exit 4
fi

echo "Setting up firewalls..."
PIDS=()
for node in "${MANAGERS[@]}"; do
  docker-machine ssh "${node}" \
  "ufw allow 22/tcp &&\
    ufw allow 2376/tcp &&\
    ufw allow 2377/tcp &&\
    ufw allow 7946/tcp &&\
    ufw allow 7946/udp &&\
    ufw allow 4789/udp &&\
    ufw -f enable && ufw reload && systemctl restart docker" 2>&1 >>"${LOG_FILE}" &
  PIDS+=("$!")
done
for node in "${WORKERS[@]}"; do
  docker-machine ssh "${node}" \
  "ufw allow 22/tcp &&\
    ufw allow 2376/tcp &&\
    ufw allow 7946/tcp &&\
    ufw allow 7946/udp &&\
    ufw allow 4789/udp &&\
    ufw -f enable && ufw reload && systemctl restart docker" 2>&1 >>"${LOG_FILE}" &
  PIDS+=("$!")
done

ERRORED=0
for pid in ${PIDS[*]}; do
  if wait $pid; then
    echo -e "\t Firewall rule applied." | tee -a "${LOG_FILE}"
  else
    let "ERRORED=1"
  fi
done
if [ "${ERRORED}" == "1" ]; then
  echo -e "\t Failed to apply firewall rules to some nodes" | tee -a "${LOG_FILE}"
  tail -n50 "${LOG_FILE}"
  exit 8
fi

echo "Initializing cluster..." | tee -a "${LOG_FILE}"
FIRST_MANAGER=( "${MANAGERS[@]:0:1}" )
OTHER_MANAGERS=( "${MANAGERS[@]:1}" )

WORKER_LOG_FILE="${PROJECT_DIR}/tmp/swarm-${SWARM_NAME}-workers-initialization.log"
MANAGER_LOG_FILE="${PROJECT_DIR}/tmp/swarm-${SWARM_NAME}-managers-initialization.log"

NODE_IP="$(docker-machine ip "${FIRST_MANAGER}")"
if [ ! -f "${WORKER_LOG_FILE}" ]; then
  echo "Starting swarm..."
  docker-machine ssh "${FIRST_MANAGER}" \
    "docker swarm init --advertise-addr ${NODE_IP} 2>&1" | tee -a "${LOG_FILE}" > "${WORKER_LOG_FILE}"
fi
if [ ! -f "${MANAGER_LOG_FILE}" ]; then
  echo "Getting manager token..."
  docker-machine ssh "${FIRST_MANAGER}" \
    "docker swarm join-token manager 2>&1" | tee -a "${LOG_FILE}" > "${MANAGER_LOG_FILE}"
fi

SWARM_WORKER_TOKEN="$(grep -e '--token' "${WORKER_LOG_FILE}" | sed -e 's/^.*--token \([^[:space:]]*\)[[:space:]].*$/\1/g')"
SWARM_MANAGER_TOKEN="$(grep -e '--token' "${MANAGER_LOG_FILE}" | sed -e 's/^.*--token \([^[:space:]]*\)[[:space:]].*$/\1/g')"

PIDS=()
for node in "${OTHER_MANAGERS[@]}"; do
  echo "${node} joining swarm as manager..." | tee -a "${LOG_FILE}"
  docker-machine ssh "${node}" \
  "docker swarm join --token ${SWARM_MANAGER_TOKEN} ${NODE_IP}:2377 2>&1" 2>&1 >>"${LOG_FILE}" &
  PIDS+=("$!")
done

for node in "${WORKERS[@]}"; do
  echo "${node} joining swarm as worker..." | tee -a "${LOG_FILE}"
  docker-machine ssh "${node}" \
  "docker swarm join --token ${SWARM_WORKER_TOKEN} ${NODE_IP}:2377 2>&1" 2>&1 >>"${LOG_FILE}" &
  PIDS+=("$!")
done

ERRORED=0
for pid in ${PIDS[*]}; do
  if wait $pid; then
    echo -e "\t Node joined swarm" | tee -a "${LOG_FILE}"
  else
    let "ERRORED=1"
  fi
done
if [ "${ERRORED}" == "1" ]; then
  echo -e "\t Some node(s) failed to join the swarm" | tee -a "${LOG_FILE}"
  tail -n50 "${LOG_FILE}"
  exit 12
fi

trap - EXIT

echo "Swarm created! Status:" | tee -a "${LOG_FILE}"
docker-machine ssh "${FIRST_MANAGER}" "docker node ls 2>&1" | tee -a "${LOG_FILE}"
