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

if [ ! -z "$1" ]; then
  PASSWORD="$1"
fi
if [ -z "${PASSWORD}" ]; then
  PASSWORD=$(openssl rand -base64 24)
  echo "No password specified. Generated one for registry access:"
  echo "${PASSWORD}"
  echo "Adding to .env"
  echo "" >> "${ENV_FILE}"
  echo "PASSWORD=${PASSWORD}" >> "${ENV_FILE}"
fi

if ! command -v docker-compose &>/dev/null; then
  echo "Need docker-compose; please install"
  exit 2
fi

cd "${PROJECT_DIR}"

REGISTRY_NAME="registry"
export DO_USERDATA="${PROJECT_DIR}/cloud-config.yml"
"${ROOT_DIR}/bin/create-do-docker-machine.sh" "${REGISTRY_NAME}" tukio,auto-generated,registry

USER="admin"
DOMAIN="registry.agilebrazil.com"
docker-machine ssh "${REGISTRY_NAME}" "mkdir -p ~/auth && htpasswd -b -c ~/auth/htpasswd ${USER} ${PASSWORD}"
docker-machine ssh "${REGISTRY_NAME}" "docker run -d -p 443:5000 --restart=always --name \"${REGISTRY_NAME}\" \
  -v /etc/letsencrypt/live/${DOMAIN}:/certs \
  -v /etc/letsencrypt/live/${DOMAIN}:/certs \
  -v /opt/docker-registry:/var/lib/registry \
  -v ${HOME}/auth:/auth \
  -e REGISTRY_AUTH=/auth/htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM='Registry Realm' \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
  registry:2"

echo "registry started at ${DOMAIN} with basic auth for user ${USER} as specified by env variable \$PASSWORD"
