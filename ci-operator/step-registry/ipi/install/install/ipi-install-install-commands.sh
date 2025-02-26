#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function populate_artifact_dir() {
  set +e
  echo "Copying log bundle..."
  cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"
  case "${CLUSTER_TYPE}" in
    aws|aws-arm64)
      grep -Po 'Instance ID: \Ki\-\w+' "${dir}/.openshift_install.log" > "${SHARED_DIR}/aws-instance-ids.txt";;
  *) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}' to collect machine IDs"
  esac
}

function prepare_next_steps() {
  set +e
  echo "Setup phase finished, prepare env for next steps"
  populate_artifact_dir
  echo "Copying required artifacts to shared dir"
  #Copy the auth artifacts to shared dir for the next steps
  cp \
      -t "${SHARED_DIR}" \
      "${dir}/auth/kubeconfig" \
      "${dir}/auth/kubeadmin-password" \
      "${dir}/metadata.json"

  # TODO: remove once BZ#1926093 is done and backported
  if [[ "${CLUSTER_TYPE}" == "ovirt" ]]; then
    cp -t "${SHARED_DIR}" "${dir}"/terraform.*
  fi
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'prepare_next_steps' EXIT TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

case "${CLUSTER_TYPE}" in
aws|aws-arm64) export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred;;
azure4) export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json;;
azurestack) export AZURE_AUTH_LOCATION=${SHARED_DIR}/osServicePrincipal.json;;
gcp) export GOOGLE_CLOUD_KEYFILE_JSON=${CLUSTER_PROFILE_DIR}/gce.json;;
ibmcloud)
    IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
    export IC_API_KEY
    ;;
kubevirt) export KUBEVIRT_KUBECONFIG=${HOME}/.kube/config;;
vsphere) export VSPHERE_PERSIST_SESSION=true;;
openstack-osuosl) ;;
openstack-ppc64le) ;;
openstack*) export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml ;;
ovirt) export OVIRT_CONFIG="${SHARED_DIR}/ovirt-config.yaml" ;;
*) >&2 echo "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

openshift-install --dir="${dir}" create manifests &
wait "$!"

sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"

echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \)

mkdir -p "${dir}/tls"
while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/tls/${manifest##tls_}"
done <   <( find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print0)

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
TF_LOG=debug openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &

wait "$!"
ret="$?"

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

if test "${ret}" -eq 0 ; then
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"
fi

exit "$ret"
