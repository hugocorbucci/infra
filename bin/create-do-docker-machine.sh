#!/bin/bash
set -e
set -o pipefail
# set -x # Uncomment to debug

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

if [ ! -z "$1" ]; then
  DOCKER_MACHINE_NAME="$1"
fi
TAGS="$2"

if ! command -v docker-machine &>/dev/null; then
  echo "Need docker-machine; please install"
  exit 2
fi

if [ ! -z "$(docker-machine ls | grep "${DOCKER_MACHINE_NAME}")" ]; then
  echo "Docker machine \"${DOCKER_MACHINE_NAME}\" already exists. Just provisioning"
  docker-machine provision "${DOCKER_MACHINE_NAME}" 2>&1
  exit 0
fi

ENV_FILE="${ROOT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  export $(cat ${ENV_FILE} | xargs)
fi

if [ -z "${DO_ACCESS_TOKEN}" ]; then
  echo "Env variable DO_ACCESS_TOKEN is empty or not set. It is required to proceed."
  echo "Please make sure it is either set or in the .env file in the root folder of this project."
  exit 1
fi

ARGS=('create' '--driver' 'digitalocean' '--digitalocean-access-token' "${DO_ACCESS_TOKEN}")
if [ ! -z "${DO_SSH_KEY_FINGERPRINT}" ]; then
  ARGS+=('--digitalocean-ssh-key-fingerprint' "${DO_SSH_KEY_FINGERPRINT}")
fi
if [ ! -z "${DO_IMAGE}" ]; then
  ARGS+=('--digitalocean-image' "${DO_IMAGE}")
fi
if [ ! -z "${DO_REGION}" ]; then
  ARGS+=('--digitalocean-region' "${DO_REGION}")
fi
if [ ! -z "${DO_SIZE}" ]; then
  ARGS+=('--digitalocean-size' "${DO_SIZE}")
fi
if [ ! -z "${TAGS}" ]; then
  ARGS+=('--digitalocean-tags' "${TAGS}")
fi
if [ ! -z "${DO_USERDATA}" ]; then
  ARGS+=('--digitalocean-userdata' "${DO_USERDATA}")
fi
docker-machine ${ARGS[@]} "${DOCKER_MACHINE_NAME}" 2>&1

echo "Docker machine \"${DOCKER_MACHINE_NAME}\" created. Please make sure to run the following command to set it up as your default machine"
echo "eval \$(docker-machine env ${DOCKER_MACHINE_NAME})"
