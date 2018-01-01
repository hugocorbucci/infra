#!/bin/bash
set -e
set -o pipefail
# set -x # Uncomment to debug

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

if [ -z "$1" ]; then
  echo "Usage: ${__FILE__} <droplet-name> [<droplet-count> <tags>] "
  echo ""
  echo "\tdroplet-name: name of the droplet to create or based name if droplet-count is specified"
  echo "\tdroplet-count (optional): number of droplets to create. Defaults to 1"
  echo "\ttags (optional): tags to created droplets"
  exit 1
fi

if [ -z "${DO_ACCESS_TOKEN}" ]; then
  echo "Env variable DO_ACCESS_TOKEN is empty or not set. It is required to proceed."
  echo "Please make sure it is either set or in the .env file in the root folder of this project."
  exit 2
fi

if [ -z "${DO_IMAGE}" ] || [ -z "${DO_REGION}" ] || [ -z "${DO_SIZE}" ]; then
  echo "Variables \$DO_IMAGE, \$DO_REGION and \$DO_SIZE are mandatory. Ensure they are set and try again"
  exit 3
fi

DROPLET_BASE_NAME="$1"
DROPLET_COUNT=1
TAGS=""
if [ ! -z "$2" ]; then
  DROPLET_COUNT="$2"
  TAGS="$3"
fi

ENV_FILE="${ROOT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  export $(cat ${ENV_FILE} | xargs)
fi

WITHOUT_NUMBERS=$(echo ${DROPLET_BASE_NAME} | sed -e 's/\(.*\)-[0-9]\{1,\}$/\1/g')
if [ "${DROPLET_BASE_NAME}" == "${WITHOUT_NUMBERS}" ]; then
  if [ "${DROPLET_COUNT}" == 1 ]; then
    NAMES=("${DROPLET_BASE_NAME}")
  else
    NAMES=()
    for i in $(seq 1 "${DROPLET_COUNT}"); do
      NAMES+=("${DROPLET_BASE_NAME}-$(printf "%02d" "${i}")")
    done
  fi
else
  NAME_PATTERN=$(echo ${DROPLET_BASE_NAME} | sed -e 's/\(.*\)-[0-9]\{1,\}$/\1/g' )
  LAST_COUNT=$(echo ${DROPLET_BASE_NAME} | sed -e 's/.*-\([0-9]\{1,\}\)$/\1/g' )
  NAMES=()
  for i in $(seq 1 "${DROPLET_COUNT}"); do
    NAMES+=("${NAME_PATTERN}-$(printf "%02d" "$(( i + LAST_COUNT ))")")
  done
fi

ARGS=('compute' 'droplet' 'create' ${NAMES} '--enable-monitoring')
if [ ! -z "${DO_SSH_KEY_FINGERPRINT}" ]; then
  ARGS+=('--ssh-keys' "${DO_SSH_KEY_FINGERPRINT}")
fi
if [ ! -z "${DO_IMAGE}" ]; then
  ARGS+=('--image' "${DO_IMAGE}")
fi
if [ ! -z "${DO_REGION}" ]; then
  ARGS+=('--region' "${DO_REGION}")
fi
if [ ! -z "${DO_SIZE}" ]; then
  ARGS+=('--size' "${DO_SIZE}")
fi
if [ ! -z "${TAGS}" ]; then
  ARGS+=('--tag-names' "${TAGS}")
fi
if [ ! -z "${DO_USERDATA_FILE}" ]; then
  ARGS+=('--user-data-file' "${DO_USERDATA_FILE}")
fi
if [ ! -z "${DO_PRIVATE_NETWORKING}" ]; then
  ARGS+=('--enable-private-networking')
fi

doctl ${ARGS[@]} -o json -t "${DO_ACCESS_TOKEN}" 2>&1
