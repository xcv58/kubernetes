#!/bin/bash

# Copyright 2014 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# A library of helper functions and constant for the local config.

# Use the config file specified in $KUBE_CONFIG_FILE, or default to
# config-default.sh.
KUBE_ROOT=$(dirname "${BASH_SOURCE}")/../..
source "${KUBE_ROOT}/cluster/gce/${KUBE_CONFIG_FILE-"config-default.sh"}"
source "${KUBE_ROOT}/cluster/common.sh"

if [[ "${OS_DISTRIBUTION}" == "debian" || "${OS_DISTRIBUTION}" == "coreos" || "${OS_DISTRIBUTION}" == "trusty" ]]; then
  source "${KUBE_ROOT}/cluster/gce/${OS_DISTRIBUTION}/helper.sh"
else
  echo "Cannot operate on cluster using os distro: ${OS_DISTRIBUTION}" >&2
  exit 1
fi

NODE_INSTANCE_PREFIX="${INSTANCE_PREFIX}-minion"

ALLOCATE_NODE_CIDRS=true

KUBE_PROMPT_FOR_UPDATE=y
KUBE_SKIP_UPDATE=${KUBE_SKIP_UPDATE-"n"}
# Suffix to append to the staging path used for the server tars. Useful if
# multiple versions of the server are being used in the same project
# simultaneously (e.g. on Jenkins).
KUBE_GCS_STAGING_PATH_SUFFIX=${KUBE_GCS_STAGING_PATH_SUFFIX-""}
# How long (in seconds) to wait for cluster initialization.
KUBE_CLUSTER_INITIALIZATION_TIMEOUT=${KUBE_CLUSTER_INITIALIZATION_TIMEOUT:-300}

function join_csv {
  local IFS=','; echo "$*";
}

# Verify prereqs
function verify-prereqs {
  local cmd
  for cmd in gcloud gsutil; do
    if ! which "${cmd}" >/dev/null; then
      local resp
      if [[ "${KUBE_PROMPT_FOR_UPDATE}" == "y" ]]; then
        echo "Can't find ${cmd} in PATH.  Do you wish to install the Google Cloud SDK? [Y/n]"
        read resp
      else
        resp="y"
      fi
      if [[ "${resp}" != "n" && "${resp}" != "N" ]]; then
        curl https://sdk.cloud.google.com | bash
      fi
      if ! which "${cmd}" >/dev/null; then
        echo "Can't find ${cmd} in PATH, please fix and retry. The Google Cloud " >&2
        echo "SDK can be downloaded from https://cloud.google.com/sdk/." >&2
        exit 1
      fi
    fi
  done
  if [[ "${KUBE_SKIP_UPDATE}" == "y" ]]; then
    return
  fi
  # update and install components as needed
  if [[ "${KUBE_PROMPT_FOR_UPDATE}" != "y" ]]; then
    gcloud_prompt="-q"
  fi
  local sudo_prefix=""
  if [ ! -w $(dirname `which gcloud`) ]; then
    sudo_prefix="sudo"
  fi
  ${sudo_prefix} gcloud ${gcloud_prompt:-} components install alpha || true
  ${sudo_prefix} gcloud ${gcloud_prompt:-} components install beta || true
  ${sudo_prefix} gcloud ${gcloud_prompt:-} components update || true
}

# Create a temp dir that'll be deleted at the end of this bash session.
#
# Vars set:
#   KUBE_TEMP
function ensure-temp-dir {
  if [[ -z ${KUBE_TEMP-} ]]; then
    KUBE_TEMP=$(mktemp -d -t kubernetes.XXXXXX)
    trap 'rm -rf "${KUBE_TEMP}"' EXIT
  fi
}

# Use the gcloud defaults to find the project.  If it is already set in the
# environment then go with that.
#
# Vars set:
#   PROJECT
#   PROJECT_REPORTED
function detect-project () {
  if [[ -z "${PROJECT-}" ]]; then
    PROJECT=$(gcloud config list project | tail -n 1 | cut -f 3 -d ' ')
  fi

  if [[ -z "${PROJECT-}" ]]; then
    echo "Could not detect Google Cloud Platform project.  Set the default project using " >&2
    echo "'gcloud config set project <PROJECT>'" >&2
    exit 1
  fi
  if [[ -z "${PROJECT_REPORTED-}" ]]; then
    echo "Project: ${PROJECT}" >&2
    echo "Zone: ${ZONE}" >&2
    PROJECT_REPORTED=true
  fi
}

function sha1sum-file() {
  if which shasum >/dev/null 2>&1; then
    shasum -a1 "$1" | awk '{ print $1 }'
  else
    sha1sum "$1" | awk '{ print $1 }'
  fi
}

function already-staged() {
  local -r file=$1
  local -r newsum=$2

  [[ -e "${file}.uploaded.sha1" ]] || return 1

  local oldsum
  oldsum=$(cat "${file}.uploaded.sha1")

  [[ "${oldsum}" == "${newsum}" ]]
}

# Copy a release tar, if we don't already think it's staged in GCS
function copy-if-not-staged() {
  local -r staging_path=$1
  local -r gs_url=$2
  local -r tar=$3
  local -r hash=$4

  if already-staged "${tar}" "${hash}"; then
    echo "+++ $(basename ${tar}) already staged ('rm ${tar}.uploaded.sha1' to force)"
  else
    echo "${hash}" > "${tar}.sha1"
    gsutil -m -q -h "Cache-Control:private, max-age=0" cp "${tar}" "${tar}.sha1" "${staging_path}"
    gsutil -m acl ch -g all:R "${gs_url}" "${gs_url}.sha1" >/dev/null 2>&1
    echo "${hash}" > "${tar}.uploaded.sha1"
    echo "+++ $(basename ${tar}) uploaded (sha1 = ${hash})"
  fi
}

# Prepare a tarball of kube-system manifests for trusty based cluster.
#
# Vars set:
#   KUBE_MANIFESTS_TAR_URL
#   KUBE_MANIFESTS_TAR_HASH
function prepare-manifests-tar() {
  KUBE_MANIFESTS_TAR_URL=
  KUBE_MANIFESTS_TAR_HASH=
  if [[ "${OS_DISTRIBUTION}" != "trusty" ]]; then
    return
  fi
  local tmp_dir="${KUBE_TEMP}/kube-manifests"
  mkdir -p ${tmp_dir}
  # The manifests used by nodes can be directly used on non-salt system.
  # We simply copy them from cluster/saltbase/salt.
  local salt_dir="${KUBE_ROOT}/cluster/saltbase/salt"
  cp -f "${salt_dir}/fluentd-es/fluentd-es.yaml" "${tmp_dir}"
  cp -f "${salt_dir}/fluentd-gcp/fluentd-gcp.yaml" "${tmp_dir}"
  cp -f "${salt_dir}/kube-registry-proxy/kube-registry-proxy.yaml" "${tmp_dir}"

  local kube_manifests_tar="${KUBE_TEMP}/kube-manifests.tar.gz"
  tar czf "${kube_manifests_tar}" -C "${KUBE_TEMP}" kube-manifests
  KUBE_MANIFESTS_TAR_HASH=$(sha1sum-file "${kube_manifests_tar}")
  local kube_manifests_gs_url="${staging_path}/${kube_manifests_tar##*/}"
  copy-if-not-staged "${staging_path}" "${kube_manifests_gs_url}" "${kube_manifests_tar}" "${KUBE_MANIFESTS_TAR_HASH}"
  # Convert from gs:// URL to an https:// URL
  KUBE_MANIFESTS_TAR_URL="${kube_manifests_gs_url/gs:\/\//https://storage.googleapis.com/}"
}


# Take the local tar files and upload them to Google Storage.  They will then be
# downloaded by the master as part of the start up script for the master.
# If running on Ubuntu trusty, we also pack the dir cluster/gce/trusty/kube-manifest
# and upload it to Google Storage.
#
# Assumed vars:
#   PROJECT
#   SERVER_BINARY_TAR
#   SALT_TAR
# Vars set:
#   SERVER_BINARY_TAR_URL
#   SERVER_BINARY_TAR_HASH
#   SALT_TAR_URL
#   SALT_TAR_HASH
function upload-server-tars() {
  SERVER_BINARY_TAR_URL=
  SERVER_BINARY_TAR_HASH=
  SALT_TAR_URL=
  SALT_TAR_HASH=

  local project_hash
  if which md5 > /dev/null 2>&1; then
    project_hash=$(md5 -q -s "$PROJECT")
  else
    project_hash=$(echo -n "$PROJECT" | md5sum | awk '{ print $1 }')
  fi

  # This requires 1 million projects before the probability of collision is 50%
  # that's probably good enough for now :P
  project_hash=${project_hash:0:10}

  local -r staging_bucket="gs://kubernetes-staging-${project_hash}"

  # Ensure the bucket is created
  if ! gsutil ls "$staging_bucket" > /dev/null 2>&1 ; then
    echo "Creating $staging_bucket"
    gsutil mb "${staging_bucket}"
  fi

  local -r staging_path="${staging_bucket}/devel${KUBE_GCS_STAGING_PATH_SUFFIX}"

  SERVER_BINARY_TAR_HASH=$(sha1sum-file "${SERVER_BINARY_TAR}")
  SALT_TAR_HASH=$(sha1sum-file "${SALT_TAR}")

  echo "+++ Staging server tars to Google Storage: ${staging_path}"
  local server_binary_gs_url="${staging_path}/${SERVER_BINARY_TAR##*/}"
  local salt_gs_url="${staging_path}/${SALT_TAR##*/}"
  copy-if-not-staged "${staging_path}" "${server_binary_gs_url}" "${SERVER_BINARY_TAR}" "${SERVER_BINARY_TAR_HASH}"
  copy-if-not-staged "${staging_path}" "${salt_gs_url}" "${SALT_TAR}" "${SALT_TAR_HASH}"

  # Convert from gs:// URL to an https:// URL
  SERVER_BINARY_TAR_URL="${server_binary_gs_url/gs:\/\//https://storage.googleapis.com/}"
  SALT_TAR_URL="${salt_gs_url/gs:\/\//https://storage.googleapis.com/}"

  # Create a tar for kube-system manifests files and stage it.
  # TODO(andyzheng0831): After finishing k8s master on trusty (issue #16702),
  # we will not need to stage the salt tar for trusty anymore.
  # TODO(andyzheng0831): Add release support for this tar, in case GKE will it.
  prepare-manifests-tar
}

# Detect minions created in the minion group
#
# Assumed vars:
#   NODE_INSTANCE_PREFIX
# Vars set:
#   NODE_NAMES
#   INSTANCE_GROUPS
function detect-node-names {
  detect-project
  INSTANCE_GROUPS=()
  INSTANCE_GROUPS+=($(gcloud compute instance-groups managed list --zone "${ZONE}" --project "${PROJECT}" | grep ${NODE_INSTANCE_PREFIX} | cut -f1 -d" "))
  NODE_NAMES=()
  if [[ -n "${INSTANCE_GROUPS[@]:-}" ]]; then
    for group in "${INSTANCE_GROUPS[@]}"; do
      NODE_NAMES+=($(gcloud compute instance-groups managed list-instances \
        "${group}" --zone "${ZONE}" --project "${PROJECT}" \
        --format=yaml | grep instance: | cut -d ' ' -f 2))
    done
    echo "INSTANCE_GROUPS=${INSTANCE_GROUPS[*]}" >&2
    echo "NODE_NAMES=${NODE_NAMES[*]}" >&2
  else 
    echo "INSTANCE_GROUPS=" >&2
    echo "NODE_NAMES=" >&2
  fi
}

# Detect the information about the minions
#
# Assumed vars:
#   ZONE
# Vars set:
#   NODE_NAMES
#   KUBE_NODE_IP_ADDRESSES (array)
function detect-nodes () {
  detect-project
  detect-node-names
  KUBE_NODE_IP_ADDRESSES=()
  for (( i=0; i<${#NODE_NAMES[@]}; i++)); do
    local node_ip=$(gcloud compute instances describe --project "${PROJECT}" --zone "${ZONE}" \
      "${NODE_NAMES[$i]}" --fields networkInterfaces[0].accessConfigs[0].natIP \
      --format=text | awk '{ print $2 }')
    if [[ -z "${node_ip-}" ]] ; then
      echo "Did not find ${NODE_NAMES[$i]}" >&2
    else
      echo "Found ${NODE_NAMES[$i]} at ${minion_ip}"
      KUBE_NODE_IP_ADDRESSES+=("${minion_ip}")
    fi
  done
  if [[ -z "${KUBE_NODE_IP_ADDRESSES-}" ]]; then
    echo "Could not detect Kubernetes minion nodes.  Make sure you've launched a cluster with 'kube-up.sh'" >&2
    exit 1
  fi
}

# Detect the IP for the master
#
# Assumed vars:
#   MASTER_NAME
#   ZONE
# Vars set:
#   KUBE_MASTER
#   KUBE_MASTER_IP
function detect-master () {
  detect-project
  KUBE_MASTER=${MASTER_NAME}
  if [[ -z "${KUBE_MASTER_IP-}" ]]; then
    KUBE_MASTER_IP=$(gcloud compute instances describe --project "${PROJECT}" --zone "${ZONE}" \
      "${MASTER_NAME}" --fields networkInterfaces[0].accessConfigs[0].natIP \
      --format=text | awk '{ print $2 }')
  fi
  if [[ -z "${KUBE_MASTER_IP-}" ]]; then
    echo "Could not detect Kubernetes master node.  Make sure you've launched a cluster with 'kube-up.sh'" >&2
    exit 1
  fi
  echo "Using master: $KUBE_MASTER (external IP: $KUBE_MASTER_IP)"
}

# Wait for background jobs to finish. Exit with
# an error status if any of the jobs failed.
function wait-for-jobs {
  local fail=0
  local job
  for job in $(jobs -p); do
    wait "${job}" || fail=$((fail + 1))
  done
  if (( fail != 0 )); then
    echo -e "${color_red}${fail} commands failed.  Exiting.${color_norm}" >&2
    # Ignore failures for now.
    # exit 2
  fi
}

# Robustly try to create a static ip.
# $1: The name of the ip to create
# $2: The name of the region to create the ip in.
function create-static-ip {
  detect-project
  local attempt=0
  local REGION="$2"
  while true; do
    if ! gcloud compute addresses create "$1" \
      --project "${PROJECT}" \
      --region "${REGION}" -q > /dev/null; then
      if (( attempt > 4 )); then
        echo -e "${color_red}Failed to create static ip $1 ${color_norm}" >&2
        exit 2
      fi
      attempt=$(($attempt+1)) 
      echo -e "${color_yellow}Attempt $attempt failed to create static ip $1. Retrying.${color_norm}" >&2
      sleep $(($attempt * 5))
    else
      break
    fi
  done
}

# Robustly try to create a firewall rule.
# $1: The name of firewall rule.
# $2: IP ranges.
# $3: Target tags for this firewall rule.
function create-firewall-rule {
  detect-project
  local attempt=0
  while true; do
    if ! gcloud compute firewall-rules create "$1" \
      --project "${PROJECT}" \
      --network "${NETWORK}" \
      --source-ranges "$2" \
      --target-tags "$3" \
      --allow tcp,udp,icmp,esp,ah,sctp; then
      if (( attempt > 4 )); then
        echo -e "${color_red}Failed to create firewall rule $1 ${color_norm}" >&2
        exit 2
      fi
      echo -e "${color_yellow}Attempt $(($attempt+1)) failed to create firewall rule $1. Retrying.${color_norm}" >&2
      attempt=$(($attempt+1))
      sleep $(($attempt * 5))
    else
        break
    fi
  done
}

# $1: version (required)
function get-template-name-from-version {
  # trim template name to pass gce name validation
  echo "${NODE_INSTANCE_PREFIX}-template-${1}" | cut -c 1-63 | sed 's/[\.\+]/-/g;s/-*$//g'
}

# Robustly try to create an instance template.
# $1: The name of the instance template.
# $2: The scopes flag.
# $3: The minion start script metadata from file.
# $4: The kube-env metadata.
# $5 and others: Additional user defined metadata.
function create-node-template {
  detect-project
  local template_name="$1"

  # First, ensure the template doesn't exist.
  # TODO(zmerlynn): To make this really robust, we need to parse the output and
  #                 add retries. Just relying on a non-zero exit code doesn't
  #                 distinguish an ephemeral failed call from a "not-exists".
  if gcloud compute instance-templates describe "$template_name" --project "${PROJECT}" &>/dev/null; then
    echo "Instance template ${1} already exists; deleting." >&2
    if ! gcloud compute instance-templates delete "$template_name" --project "${PROJECT}" &>/dev/null; then
      echo -e "${color_yellow}Failed to delete existing instance template${color_norm}" >&2
      exit 2
    fi
  fi

  local attempt=1
  local preemptible_minions=""
  if [[ "${PREEMPTIBLE_NODE}" == "true" ]]; then
    preemptible_minions="--preemptible --maintenance-policy TERMINATE"
  fi
  while true; do
    echo "Attempt ${attempt} to create ${1}" >&2
    if ! gcloud compute instance-templates create "$template_name" \
      --project "${PROJECT}" \
      --machine-type "${NODE_SIZE}" \
      --boot-disk-type "${NODE_DISK_TYPE}" \
      --boot-disk-size "${NODE_DISK_SIZE}" \
      --image-project="${NODE_IMAGE_PROJECT}" \
      --image "${NODE_IMAGE}" \
      --tags "${NODE_TAG}" \
      --network "${NETWORK}" \
      ${preemptible_minions} \
      $2 \
      --can-ip-forward \
      --metadata-from-file $(echo ${@:3} | tr ' ' ',') >&2; then
        if (( attempt > 5 )); then
          echo -e "${color_red}Failed to create instance template $template_name ${color_norm}" >&2
          exit 2
        fi
        echo -e "${color_yellow}Attempt ${attempt} failed to create instance template $template_name. Retrying.${color_norm}" >&2
        attempt=$(($attempt+1))
        sleep $(($attempt * 5))
    else
        break
    fi
  done
}

# Robustly try to add metadata on an instance.
# $1: The name of the instance.
# $2...$n: The metadata key=value pairs to add.
function add-instance-metadata {
  local -r instance=$1
  shift 1
  local -r kvs=( "$@" )
  detect-project
  local attempt=0
  while true; do
    if ! gcloud compute instances add-metadata "${instance}" \
      --project "${PROJECT}" \
      --zone "${ZONE}" \
      --metadata "${kvs[@]}"; then
        if (( attempt > 5 )); then
          echo -e "${color_red}Failed to add instance metadata in ${instance} ${color_norm}" >&2
          exit 2
        fi
        echo -e "${color_yellow}Attempt $(($attempt+1)) failed to add metadata in ${instance}. Retrying.${color_norm}" >&2
        attempt=$(($attempt+1))
        sleep $((5 * $attempt))
    else
        break
    fi
  done
}

# Robustly try to add metadata on an instance, from a file.
# $1: The name of the instance.
# $2...$n: The metadata key=file pairs to add.
function add-instance-metadata-from-file {
  local -r instance=$1
  shift 1
  local -r kvs=( "$@" )
  detect-project
  local attempt=0
  while true; do
    echo "${kvs[@]}"
    if ! gcloud compute instances add-metadata "${instance}" \
      --project "${PROJECT}" \
      --zone "${ZONE}" \
      --metadata-from-file "$(join_csv ${kvs[@]})"; then
        if (( attempt > 5 )); then
          echo -e "${color_red}Failed to add instance metadata in ${instance} ${color_norm}" >&2
          exit 2
        fi
        echo -e "${color_yellow}Attempt $(($attempt+1)) failed to add metadata in ${instance}. Retrying.${color_norm}" >&2
        attempt=$(($attempt+1))
        sleep $(($attempt * 5))
    else
        break
    fi
  done
}

# Quote something appropriate for a yaml string.
#
# TODO(zmerlynn): Note that this function doesn't so much "quote" as
# "strip out quotes", and we really should be using a YAML library for
# this, but PyYAML isn't shipped by default, and *rant rant rant ... SIGH*
function yaml-quote {
  echo "'$(echo "${@}" | sed -e "s/'/''/g")'"
}

function write-master-env {
  # If the user requested that the master be part of the cluster, set the
  # environment variable to program the master kubelet to register itself.
  if [[ "${REGISTER_MASTER_KUBELET:-}" == "true" ]]; then
    KUBELET_APISERVER="${MASTER_NAME}"
  fi

  build-kube-env true "${KUBE_TEMP}/master-kube-env.yaml"
}

function write-node-env {
  build-kube-env false "${KUBE_TEMP}/node-kube-env.yaml"
}

# Create certificate pairs for the cluster.
# $1: The public IP for the master.
#
# These are used for static cert distribution (e.g. static clustering) at
# cluster creation time. This will be obsoleted once we implement dynamic
# clustering.
#
# The following certificate pairs are created:
#
#  - ca (the cluster's certificate authority)
#  - server
#  - kubelet
#  - kubecfg (for kubectl)
#
# TODO(roberthbailey): Replace easyrsa with a simple Go program to generate
# the certs that we need.
#
# Assumed vars
#   KUBE_TEMP
#
# Vars set:
#   CERT_DIR
#   CA_CERT_BASE64
#   MASTER_CERT_BASE64
#   MASTER_KEY_BASE64
#   KUBELET_CERT_BASE64
#   KUBELET_KEY_BASE64
#   KUBECFG_CERT_BASE64
#   KUBECFG_KEY_BASE64
function create-certs {
  local -r cert_ip="${1}"

  local octets=($(echo "$SERVICE_CLUSTER_IP_RANGE" | sed -e 's|/.*||' -e 's/\./ /g'))
  ((octets[3]+=1))
  local -r service_ip=$(echo "${octets[*]}" | sed 's/ /./g')
  local -r sans="IP:${cert_ip},IP:${service_ip},DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.${DNS_DOMAIN},DNS:${MASTER_NAME}"

  # Note: This was heavily cribbed from make-ca-cert.sh
  (cd "${KUBE_TEMP}"
    curl -L -O --connect-timeout 20 --retry 6 --retry-delay 2 https://storage.googleapis.com/kubernetes-release/easy-rsa/easy-rsa.tar.gz > /dev/null 2>&1
    tar xzf easy-rsa.tar.gz > /dev/null 2>&1
    cd easy-rsa-master/easyrsa3
    ./easyrsa init-pki > /dev/null 2>&1
    ./easyrsa --batch "--req-cn=${cert_ip}@$(date +%s)" build-ca nopass > /dev/null 2>&1
    ./easyrsa --subject-alt-name="${sans}" build-server-full "${MASTER_NAME}" nopass > /dev/null 2>&1
    ./easyrsa build-client-full kubelet nopass > /dev/null 2>&1
    ./easyrsa build-client-full kubecfg nopass > /dev/null 2>&1) || {
    # If there was an error in the subshell, just die.
    # TODO(roberthbailey): add better error handling here
    echo "=== Failed to generate certificates: Aborting ===" >&2
    exit 2
  }
  CERT_DIR="${KUBE_TEMP}/easy-rsa-master/easyrsa3"
  # By default, linux wraps base64 output every 76 cols, so we use 'tr -d' to remove whitespaces.
  # Note 'base64 -w0' doesn't work on Mac OS X, which has different flags.
  CA_CERT_BASE64=$(cat "${CERT_DIR}/pki/ca.crt" | base64 | tr -d '\r\n')
  MASTER_CERT_BASE64=$(cat "${CERT_DIR}/pki/issued/${MASTER_NAME}.crt" | base64 | tr -d '\r\n')
  MASTER_KEY_BASE64=$(cat "${CERT_DIR}/pki/private/${MASTER_NAME}.key" | base64 | tr -d '\r\n')
  KUBELET_CERT_BASE64=$(cat "${CERT_DIR}/pki/issued/kubelet.crt" | base64 | tr -d '\r\n')
  KUBELET_KEY_BASE64=$(cat "${CERT_DIR}/pki/private/kubelet.key" | base64 | tr -d '\r\n')
  KUBECFG_CERT_BASE64=$(cat "${CERT_DIR}/pki/issued/kubecfg.crt" | base64 | tr -d '\r\n')
  KUBECFG_KEY_BASE64=$(cat "${CERT_DIR}/pki/private/kubecfg.key" | base64 | tr -d '\r\n')
}

# Instantiate a kubernetes cluster
#
# Assumed vars
#   KUBE_ROOT
#   <Various vars set in config file>
function kube-up {
  ensure-temp-dir
  detect-project

  load-or-gen-kube-basicauth
  load-or-gen-kube-bearertoken

  # Make sure we have the tar files staged on Google Storage
  find-release-tars
  upload-server-tars

  local running_in_terminal=false
  # May be false if tty is not allocated (for example with ssh -T).
  if [ -t 1 ]; then
    running_in_terminal=true
  fi

  if [[ ${running_in_terminal} == "true" || ${KUBE_UP_AUTOMATIC_CLEANUP} == "true" ]]; then
    if ! check-resources; then
      local run_kube_down="n"
      echo "${KUBE_RESOURCE_FOUND} found." >&2
      # Get user input only if running in terminal.
      if [[ ${running_in_terminal} == "true" && ${KUBE_UP_AUTOMATIC_CLEANUP} == "false" ]]; then
        read -p "Would you like to shut down the old cluster (call kube-down)? [y/N] " run_kube_down
      fi
      if [[ ${run_kube_down} == "y" || ${run_kube_down} == "Y" || ${KUBE_UP_AUTOMATIC_CLEANUP} == "true" ]]; then
        echo "... calling kube-down" >&2
        kube-down
      fi
    fi
  fi

  if ! gcloud compute networks --project "${PROJECT}" describe "${NETWORK}" &>/dev/null; then
    echo "Creating new network: ${NETWORK}"
    # The network needs to be created synchronously or we have a race. The
    # firewalls can be added concurrent with instance creation.
    gcloud compute networks create --project "${PROJECT}" "${NETWORK}" --range "10.240.0.0/16"
  fi

  if ! gcloud compute firewall-rules --project "${PROJECT}" describe "${NETWORK}-default-internal" &>/dev/null; then
    gcloud compute firewall-rules create "${NETWORK}-default-internal" \
      --project "${PROJECT}" \
      --network "${NETWORK}" \
      --source-ranges "10.0.0.0/8" \
      --allow "tcp:1-65535,udp:1-65535,icmp" &
  fi

  if ! gcloud compute firewall-rules describe --project "${PROJECT}" "${NETWORK}-default-ssh" &>/dev/null; then
    gcloud compute firewall-rules create "${NETWORK}-default-ssh" \
      --project "${PROJECT}" \
      --network "${NETWORK}" \
      --source-ranges "0.0.0.0/0" \
      --allow "tcp:22" &
  fi

  echo "Starting master and configuring firewalls"
  gcloud compute firewall-rules create "${MASTER_NAME}-https" \
    --project "${PROJECT}" \
    --network "${NETWORK}" \
    --target-tags "${MASTER_TAG}" \
    --allow tcp:443 &

  # We have to make sure the disk is created before creating the master VM, so
  # run this in the foreground.
  gcloud compute disks create "${MASTER_NAME}-pd" \
    --project "${PROJECT}" \
    --zone "${ZONE}" \
    --type "${MASTER_DISK_TYPE}" \
    --size "${MASTER_DISK_SIZE}"

  # Create disk for cluster registry if enabled
  if [[ "${ENABLE_CLUSTER_REGISTRY}" == true && -n "${CLUSTER_REGISTRY_DISK}" ]]; then
    gcloud compute disks create "${CLUSTER_REGISTRY_DISK}" \
      --project "${PROJECT}" \
      --zone "${ZONE}" \
      --type "${CLUSTER_REGISTRY_DISK_TYPE_GCE}" \
      --size "${CLUSTER_REGISTRY_DISK_SIZE}" &
  fi

  # Generate a bearer token for this cluster. We push this separately
  # from the other cluster variables so that the client (this
  # computer) can forget it later. This should disappear with
  # http://issue.k8s.io/3168
  KUBELET_TOKEN=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)
  KUBE_PROXY_TOKEN=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)

  # Reserve the master's IP so that it can later be transferred to another VM
  # without disrupting the kubelets. IPs are associated with regions, not zones,
  # so extract the region name, which is the same as the zone but with the final
  # dash and characters trailing the dash removed.
  local REGION=${ZONE%-*}
  create-static-ip "${MASTER_NAME}-ip" "${REGION}"
  MASTER_RESERVED_IP=$(gcloud compute addresses describe "${MASTER_NAME}-ip" \
    --project "${PROJECT}" \
    --region "${REGION}" -q --format yaml | awk '/^address:/ { print $2 }')

  create-certs "${MASTER_RESERVED_IP}"

  create-master-instance "${MASTER_RESERVED_IP}" &

  # Create a single firewall rule for all minions.
  create-firewall-rule "${NODE_TAG}-all" "${CLUSTER_IP_RANGE}" "${NODE_TAG}" &

  # Report logging choice (if any).
  if [[ "${ENABLE_NODE_LOGGING-}" == "true" ]]; then
    echo "+++ Logging using Fluentd to ${LOGGING_DESTINATION:-unknown}"
  fi

  # Wait for last batch of jobs
  wait-for-jobs

  echo "Creating minions."

  # TODO(zmerlynn): Refactor setting scope flags.
  local scope_flags=
  if [ -n "${NODE_SCOPES}" ]; then
    scope_flags="--scopes ${NODE_SCOPES}"
  else
    scope_flags="--no-scopes"
  fi

  write-node-env

  local template_name="${NODE_INSTANCE_PREFIX}-template"
  
  create-node-instance-template $template_name

  local defaulted_max_instances_per_mig=${MAX_INSTANCES_PER_MIG:-500}

  if [[ ${defaulted_max_instances_per_mig} -le "0" ]]; then
    echo "MAX_INSTANCES_PER_MIG cannot be negative. Assuming default 500"
    defaulted_max_instances_per_mig=500
  fi
  local num_migs=$(((${NUM_NODES} + ${defaulted_max_instances_per_mig} - 1) / ${defaulted_max_instances_per_mig}))
  local instances_per_mig=$(((${NUM_NODES} + ${num_migs} - 1) / ${num_migs}))
  local last_mig_size=$((${NUM_NODES} - (${num_migs} - 1) * ${instances_per_mig}))

  #TODO: parallelize this loop to speed up the process
  for i in $(seq $((${num_migs} - 1))); do
    gcloud compute instance-groups managed \
        create "${NODE_INSTANCE_PREFIX}-group-$i" \
        --project "${PROJECT}" \
        --zone "${ZONE}" \
        --base-instance-name "${NODE_INSTANCE_PREFIX}" \
        --size "${instances_per_mig}" \
        --template "$template_name" || true;
    gcloud compute instance-groups managed wait-until-stable \
        "${NODE_INSTANCE_PREFIX}-group-$i" \
	      --zone "${ZONE}" \
	      --project "${PROJECT}" || true;
  done

  # TODO: We don't add a suffix for the last group to keep backward compatibility when there's only one MIG.
  # We should change it at some point, but note #18545 when changing this.
  gcloud compute instance-groups managed \
      create "${NODE_INSTANCE_PREFIX}-group" \
      --project "${PROJECT}" \
      --zone "${ZONE}" \
      --base-instance-name "${NODE_INSTANCE_PREFIX}" \
      --size "${last_mig_size}" \
      --template "$template_name" || true;
  gcloud compute instance-groups managed wait-until-stable \
      "${NODE_INSTANCE_PREFIX}-group" \
      --zone "${ZONE}" \
      --project "${PROJECT}" || true;

  detect-node-names
  detect-master

  # Create autoscaler for nodes if requested
  if [[ "${ENABLE_NODE_AUTOSCALER}" == "true" ]]; then
    METRICS=""
    # Current usage
    METRICS+="--custom-metric-utilization metric=custom.cloudmonitoring.googleapis.com/kubernetes.io/cpu/node_utilization,"
    METRICS+="utilization-target=${TARGET_NODE_UTILIZATION},utilization-target-type=GAUGE "
    METRICS+="--custom-metric-utilization metric=custom.cloudmonitoring.googleapis.com/kubernetes.io/memory/node_utilization,"
    METRICS+="utilization-target=${TARGET_NODE_UTILIZATION},utilization-target-type=GAUGE "

    # Reservation
    METRICS+="--custom-metric-utilization metric=custom.cloudmonitoring.googleapis.com/kubernetes.io/cpu/node_reservation,"
    METRICS+="utilization-target=${TARGET_NODE_UTILIZATION},utilization-target-type=GAUGE "
    METRICS+="--custom-metric-utilization metric=custom.cloudmonitoring.googleapis.com/kubernetes.io/memory/node_reservation,"
    METRICS+="utilization-target=${TARGET_NODE_UTILIZATION},utilization-target-type=GAUGE "

    echo "Creating node autoscalers."

    local max_instances_per_mig=$(((${AUTOSCALER_MAX_NODES} + ${num_migs} - 1) / ${num_migs}))
    local last_max_instances=$((${AUTOSCALER_MAX_NODES} - (${num_migs} - 1) * ${max_instances_per_mig}))
    local min_instances_per_mig=$(((${AUTOSCALER_MIN_NODES} + ${num_migs} - 1) / ${num_migs}))
    local last_min_instances=$((${AUTOSCALER_MIN_NODES} - (${num_migs} - 1) * ${min_instances_per_mig}))

    for i in $(seq $((${num_migs} - 1))); do
      gcloud compute instance-groups managed set-autoscaling "${NODE_INSTANCE_PREFIX}-group-$i" --zone "${ZONE}" --project "${PROJECT}" \
          --min-num-replicas "${min_instances_per_mig}" --max-num-replicas "${max_instances_per_mig}" ${METRICS} || true
    done
    gcloud compute instance-groups managed set-autoscaling "${NODE_INSTANCE_PREFIX}-group" --zone "${ZONE}" --project "${PROJECT}" \
      --min-num-replicas "${last_min_instances}" --max-num-replicas "${last_max_instances}" ${METRICS} || true
  fi

  echo "Waiting up to ${KUBE_CLUSTER_INITIALIZATION_TIMEOUT} seconds for cluster initialization."
  echo
  echo "  This will continually check to see if the API for kubernetes is reachable."
  echo "  This may time out if there was some uncaught error during start up."
  echo

  # curl in mavericks is borked.
  secure=""
  if which sw_vers >& /dev/null; then
    if [[ $(sw_vers | grep ProductVersion | awk '{print $2}') = "10.9."* ]]; then
      secure="--insecure"
    fi
  fi

  local start_time=$(date +%s)
  until curl --cacert "${CERT_DIR}/pki/ca.crt" \
          -H "Authorization: Bearer ${KUBE_BEARER_TOKEN}" \
          ${secure} \
          --max-time 5 --fail --output /dev/null --silent \
          "https://${KUBE_MASTER_IP}/api/v1/pods"; do
      local elapsed=$(($(date +%s) - ${start_time}))
      if [[ ${elapsed} -gt ${KUBE_CLUSTER_INITIALIZATION_TIMEOUT} ]]; then
          echo -e "${color_red}Cluster failed to initialize within ${KUBE_CLUSTER_INITIALIZATION_TIMEOUT} seconds.${color_norm}" >&2
          exit 2
      fi
      printf "."
      sleep 2
  done

  echo "Kubernetes cluster created."

  export KUBE_CERT="${CERT_DIR}/pki/issued/kubecfg.crt"
  export KUBE_KEY="${CERT_DIR}/pki/private/kubecfg.key"
  export CA_CERT="${CERT_DIR}/pki/ca.crt"
  export CONTEXT="${PROJECT}_${INSTANCE_PREFIX}"
  (
   umask 077
   create-kubeconfig
  )

  # ensures KUBECONFIG is set
  get-kubeconfig-basicauth
  echo
  echo -e "${color_green}Kubernetes cluster is running.  The master is running at:"
  echo
  echo -e "${color_yellow}  https://${KUBE_MASTER_IP}"
  echo
  echo -e "${color_green}The user name and password to use is located in ${KUBECONFIG}.${color_norm}"
  echo

}

# Delete a kubernetes cluster. This is called from test-teardown.
#
# Assumed vars:
#   MASTER_NAME
#   NODE_INSTANCE_PREFIX
#   ZONE
# This function tears down cluster resources 10 at a time to avoid issuing too many
# API calls and exceeding API quota. It is important to bring down the instances before bringing
# down the firewall rules and routes.
function kube-down {
  detect-project
  detect-node-names # For INSTANCE_GROUPS

  echo "Bringing down cluster"
  set +e  # Do not stop on error

  # Delete autoscaler for nodes if present. We assume that all or none instance groups have an autoscaler
  local autoscaler
  autoscaler=( $(gcloud compute instance-groups managed list --zone "${ZONE}" --project "${PROJECT}" \
                 | grep "${NODE_INSTANCE_PREFIX}-group" \
                 | awk '{print $7}') )
  if [[ "${autoscaler:-}" == "yes" ]]; then
    for group in ${INSTANCE_GROUPS[@]}; do
      gcloud compute instance-groups managed stop-autoscaling "${group}" --zone "${ZONE}" --project "${PROJECT}"
    done
  fi

  # Get the name of the managed instance group template before we delete the
  # managed instange group. (The name of the managed instnace group template may
  # change during a cluster upgrade.)
  local template=$(get-template "${PROJECT}" "${ZONE}" "${NODE_INSTANCE_PREFIX}-group")

  # The gcloud APIs don't return machine parseable error codes/retry information. Therefore the best we can
  # do is parse the output and special case particular responses we are interested in.
  for group in ${INSTANCE_GROUPS[@]}; do 
    if gcloud compute instance-groups managed describe "${group}" --project "${PROJECT}" --zone "${ZONE}" &>/dev/null; then
      deleteCmdOutput=$(gcloud compute instance-groups managed delete --zone "${ZONE}" \
        --project "${PROJECT}" \
        --quiet \
        "${group}")
      if [[ "$deleteCmdOutput" != ""  ]]; then
        # Managed instance group deletion is done asynchronously, we must wait for it to complete, or subsequent steps fail
        deleteCmdOperationId=$(echo $deleteCmdOutput | grep "Operation:" | sed "s/.*Operation:[[:space:]]*\([^[:space:]]*\).*/\1/g")
        if [[ "$deleteCmdOperationId" != ""  ]]; then
          deleteCmdStatus="PENDING"
          while [[ "$deleteCmdStatus" != "DONE" ]]
          do
            sleep 5
            deleteCmdOperationOutput=$(gcloud compute instance-groups managed --zone "${ZONE}" --project "${PROJECT}" get-operation $deleteCmdOperationId)
            deleteCmdStatus=$(echo $deleteCmdOperationOutput | grep -i "status:" | sed "s/.*status:[[:space:]]*\([^[:space:]]*\).*/\1/g")
            echo "Waiting for MIG deletion to complete. Current status: " $deleteCmdStatus
          done
        fi
      fi
    fi
  done

  if gcloud compute instance-templates describe --project "${PROJECT}" "${template}" &>/dev/null; then
    gcloud compute instance-templates delete \
      --project "${PROJECT}" \
      --quiet \
      "${template}"
  fi

  # First delete the master (if it exists).
  if gcloud compute instances describe "${MASTER_NAME}" --zone "${ZONE}" --project "${PROJECT}" &>/dev/null; then
    gcloud compute instances delete \
      --project "${PROJECT}" \
      --quiet \
      --delete-disks all \
      --zone "${ZONE}" \
      "${MASTER_NAME}"
  fi

  # Delete the master pd (possibly leaked by kube-up if master create failed).
  if gcloud compute disks describe "${MASTER_NAME}"-pd --zone "${ZONE}" --project "${PROJECT}" &>/dev/null; then
    gcloud compute disks delete \
      --project "${PROJECT}" \
      --quiet \
      --zone "${ZONE}" \
      "${MASTER_NAME}"-pd
  fi

  # Delete disk for cluster registry if enabled
  if [[ "${ENABLE_CLUSTER_REGISTRY}" == true && -n "${CLUSTER_REGISTRY_DISK}" ]]; then
    if gcloud compute disks describe "${CLUSTER_REGISTRY_DISK}" --zone "${ZONE}" --project "${PROJECT}" &>/dev/null; then
      gcloud compute disks delete \
        --project "${PROJECT}" \
        --quiet \
        --zone "${ZONE}" \
        "${CLUSTER_REGISTRY_DISK}"
    fi
  fi

  # Find out what minions are running.
  local -a minions
  minions=( $(gcloud compute instances list \
                --project "${PROJECT}" --zone "${ZONE}" \
                --regexp "${NODE_INSTANCE_PREFIX}-.+" \
                | awk 'NR >= 2 { print $1 }') )
  # If any minions are running, delete them in batches.
  while (( "${#minions[@]}" > 0 )); do
    echo Deleting nodes "${minions[*]::10}"
    gcloud compute instances delete \
      --project "${PROJECT}" \
      --quiet \
      --delete-disks boot \
      --zone "${ZONE}" \
      "${minions[@]::10}"
    minions=( "${minions[@]:10}" )
  done

  # Delete firewall rule for the master.
  if gcloud compute firewall-rules describe --project "${PROJECT}" "${MASTER_NAME}-https" &>/dev/null; then
    gcloud compute firewall-rules delete  \
      --project "${PROJECT}" \
      --quiet \
      "${MASTER_NAME}-https"
  fi

  # Delete firewall rule for minions.
  if gcloud compute firewall-rules describe --project "${PROJECT}" "${NODE_TAG}-all" &>/dev/null; then
    gcloud compute firewall-rules delete  \
      --project "${PROJECT}" \
      --quiet \
      "${NODE_TAG}-all"
  fi

  # Delete routes.
  local -a routes
  # Clean up all routes w/ names like "<cluster-name>-<node-GUID>"
  # e.g. "kubernetes-12345678-90ab-cdef-1234-567890abcdef". The name is
  # determined by the node controller on the master.
  # Note that this is currently a noop, as synchronously deleting the node MIG
  # first allows the master to cleanup routes itself.
  local TRUNCATED_PREFIX="${INSTANCE_PREFIX:0:26}"
  routes=( $(gcloud compute routes list --project "${PROJECT}" \
    --regexp "${TRUNCATED_PREFIX}-.{8}-.{4}-.{4}-.{4}-.{12}" | awk 'NR >= 2 { print $1 }') )
  while (( "${#routes[@]}" > 0 )); do
    echo Deleting routes "${routes[*]::10}"
    gcloud compute routes delete \
      --project "${PROJECT}" \
      --quiet \
      "${routes[@]::10}"
    routes=( "${routes[@]:10}" )
  done

  # Delete the master's reserved IP
  local REGION=${ZONE%-*}
  if gcloud compute addresses describe "${MASTER_NAME}-ip" --region "${REGION}" --project "${PROJECT}" &>/dev/null; then
    gcloud compute addresses delete \
      --project "${PROJECT}" \
      --region "${REGION}" \
      --quiet \
      "${MASTER_NAME}-ip"
  fi

  export CONTEXT="${PROJECT}_${INSTANCE_PREFIX}"
  clear-kubeconfig
  set -e
}

# Gets the instance template for the managed instance group with the provided
# project, zone, and group name. It echos the template name so that the function
# output can be used.
#
# $1: project
# $2: zone
# $3: managed instance group name
function get-template {
  # url is set to https://www.googleapis.com/compute/v1/projects/$1/global/instanceTemplates/<template>
  local url=$(gcloud compute instance-groups managed describe --project="${1}" --zone="${2}" "${3}" | grep instanceTemplate)
  # template is set to <template> (the pattern strips off all but last slash)
  local template="${url##*/}"
  echo "${template}"
}


# Checks if there are any present resources related kubernetes cluster.
#
# Assumed vars:
#   MASTER_NAME
#   NODE_INSTANCE_PREFIX
#   ZONE
# Vars set:
#   KUBE_RESOURCE_FOUND
function check-resources {
  detect-project
  detect-node-names

  echo "Looking for already existing resources"
  KUBE_RESOURCE_FOUND=""

  if [[ -n "${INSTANCE_GROUPS[@]:-}" ]]; then
    KUBE_RESOURCE_FOUND="Managed instance groups ${INSTANCE_GROUPS[@]}"
    return 1
  fi

  if gcloud compute instance-templates describe --project "${PROJECT}" "${NODE_INSTANCE_PREFIX}-template" &>/dev/null; then
    KUBE_RESOURCE_FOUND="Instance template ${NODE_INSTANCE_PREFIX}-template"
    return 1
  fi

  if gcloud compute instances describe --project "${PROJECT}" "${MASTER_NAME}" --zone "${ZONE}" &>/dev/null; then
    KUBE_RESOURCE_FOUND="Kubernetes master ${MASTER_NAME}"
    return 1
  fi

  if gcloud compute disks describe --project "${PROJECT}" "${MASTER_NAME}"-pd --zone "${ZONE}" &>/dev/null; then
    KUBE_RESOURCE_FOUND="Persistent disk ${MASTER_NAME}-pd"
    return 1
  fi

  if gcloud compute disks describe --project "${PROJECT}" "${CLUSTER_REGISTRY_DISK}" --zone "${ZONE}" &>/dev/null; then
    KUBE_RESOURCE_FOUND="Persistent disk ${CLUSTER_REGISTRY_DISK}"
    return 1
  fi

  # Find out what minions are running.
  local -a minions
  minions=( $(gcloud compute instances list \
                --project "${PROJECT}" --zone "${ZONE}" \
                --regexp "${NODE_INSTANCE_PREFIX}-.+" \
                | awk 'NR >= 2 { print $1 }') )
  if (( "${#minions[@]}" > 0 )); then
    KUBE_RESOURCE_FOUND="${#minions[@]} matching matching ${NODE_INSTANCE_PREFIX}-.+"
    return 1
  fi

  if gcloud compute firewall-rules describe --project "${PROJECT}" "${MASTER_NAME}-https" &>/dev/null; then
    KUBE_RESOURCE_FOUND="Firewall rules for ${MASTER_NAME}-https"
    return 1
  fi

  if gcloud compute firewall-rules describe --project "${PROJECT}" "${NODE_TAG}-all" &>/dev/null; then
    KUBE_RESOURCE_FOUND="Firewall rules for ${MASTER_NAME}-all"
    return 1
  fi

  local -a routes
  routes=( $(gcloud compute routes list --project "${PROJECT}" \
    --regexp "${INSTANCE_PREFIX}-minion-.{4}" | awk 'NR >= 2 { print $1 }') )
  if (( "${#routes[@]}" > 0 )); then
    KUBE_RESOURCE_FOUND="${#routes[@]} routes matching ${INSTANCE_PREFIX}-minion-.{4}"
    return 1
  fi

  local REGION=${ZONE%-*}
  if gcloud compute addresses describe --project "${PROJECT}" "${MASTER_NAME}-ip" --region "${REGION}" &>/dev/null; then
    KUBE_RESOURCE_FOUND="Master's reserved IP"
    return 1
  fi

  # No resources found.
  return 0
}

# Prepare to push new binaries to kubernetes cluster
#  $1 - whether prepare push to node
function prepare-push() {
  #TODO(dawnchen): figure out how to upgrade coreos node
  if [[ "${OS_DISTRIBUTION}" != "debian" ]]; then
    echo "Updating a kubernetes cluster with ${OS_DISTRIBUTION} is not supported yet." >&2
    exit 1
  fi

  OUTPUT=${KUBE_ROOT}/_output/logs
  mkdir -p ${OUTPUT}

  ensure-temp-dir
  detect-project
  detect-master
  detect-node-names
  get-kubeconfig-basicauth
  get-kubeconfig-bearertoken

  # Make sure we have the tar files staged on Google Storage
  tars_from_version

  # Prepare node env vars and update MIG template
  if [[ "${1-}" == "true" ]]; then
    write-node-env

    # TODO(zmerlynn): Refactor setting scope flags.
    local scope_flags=
    if [ -n "${NODE_SCOPES}" ]; then
      scope_flags="--scopes ${NODE_SCOPES}"
    else
      scope_flags="--no-scopes"
    fi

    # Ugly hack: Since it is not possible to delete instance-template that is currently
    # being used, create a temp one, then delete the old one and recreate it once again.
    local tmp_template_name="${NODE_INSTANCE_PREFIX}-template-tmp"
    create-node-instance-template $tmp_template_name

    local template_name="${NODE_INSTANCE_PREFIX}-template"
    for group in ${INSTANCE_GROUPS[@]}; do
      gcloud compute instance-groups managed \
        set-instance-template "${group}" \
        --template "$tmp_template_name" \
        --zone "${ZONE}" \
        --project "${PROJECT}" || true;
    done

    gcloud compute instance-templates delete \
      --project "${PROJECT}" \
      --quiet \
      "$template_name" || true

    create-node-instance-template "$template_name"

    for group in ${INSTANCE_GROUPS[@]}; do
      gcloud compute instance-groups managed \
        set-instance-template "${group}" \
        --template "$template_name" \
        --zone "${ZONE}" \
        --project "${PROJECT}" || true;
    done

    gcloud compute instance-templates delete \
      --project "${PROJECT}" \
      --quiet \
      "$tmp_template_name" || true
  fi
}

# Push binaries to kubernetes master
function push-master {
  echo "Updating master metadata ..."
  write-master-env
  add-instance-metadata-from-file "${KUBE_MASTER}" "kube-env=${KUBE_TEMP}/master-kube-env.yaml" "startup-script=${KUBE_ROOT}/cluster/gce/configure-vm.sh"

  echo "Pushing to master (log at ${OUTPUT}/push-${KUBE_MASTER}.log) ..."
  cat ${KUBE_ROOT}/cluster/gce/configure-vm.sh | gcloud compute ssh --ssh-flag="-o LogLevel=quiet" --project "${PROJECT}" --zone "${ZONE}" "${KUBE_MASTER}" --command "sudo bash -s -- --push" &> ${OUTPUT}/push-"${KUBE_MASTER}".log
}

# Push binaries to kubernetes node
function push-node() {
  node=${1}

  echo "Updating node ${node} metadata... "
  add-instance-metadata-from-file "${node}" "kube-env=${KUBE_TEMP}/node-kube-env.yaml" "startup-script=${KUBE_ROOT}/cluster/gce/configure-vm.sh"

  echo "Start upgrading node ${node} (log at ${OUTPUT}/push-${node}.log) ..."
  cat ${KUBE_ROOT}/cluster/gce/configure-vm.sh | gcloud compute ssh --ssh-flag="-o LogLevel=quiet" --project "${PROJECT}" --zone "${ZONE}" "${node}" --command "sudo bash -s -- --push" &> ${OUTPUT}/push-"${node}".log
}

# Push binaries to kubernetes cluster
function kube-push {
  prepare-push true

  push-master

  for (( i=0; i<${#NODE_NAMES[@]}; i++)); do
    push-node "${NODE_NAMES[$i]}" &
  done
  wait-for-jobs

  # TODO(zmerlynn): Re-create instance-template with the new
  # node-kube-env. This isn't important until the node-ip-range issue
  # is solved (because that's blocking automatic dynamic nodes from
  # working). The node-kube-env has to be composed with the KUBELET_TOKEN
  # and KUBE_PROXY_TOKEN.  Ideally we would have
  # http://issue.k8s.io/3168
  # implemented before then, though, so avoiding this mess until then.

  echo
  echo "Kubernetes cluster is running.  The master is running at:"
  echo
  echo "  https://${KUBE_MASTER_IP}"
  echo
  echo "The user name and password to use is located in ~/.kube/config"
  echo
}

# -----------------------------------------------------------------------------
# Cluster specific test helpers used from hack/e2e-test.sh

# Execute prior to running tests to build a release if required for env.
#
# Assumed Vars:
#   KUBE_ROOT
function test-build-release {
  # Make a release
  "${KUBE_ROOT}/build/release.sh"
}

# Execute prior to running tests to initialize required structure. This is
# called from hack/e2e.go only when running -up (it is run after kube-up).
#
# Assumed vars:
#   Variables from config.sh
function test-setup {
  # Detect the project into $PROJECT if it isn't set
  detect-project

  # Open up port 80 & 8080 so common containers on minions can be reached
  # TODO(roberthbailey): Remove this once we are no longer relying on hostPorts.
  local start=`date +%s`
  gcloud compute firewall-rules create \
    --project "${PROJECT}" \
    --target-tags "${NODE_TAG}" \
    --allow tcp:80,tcp:8080 \
    --network "${NETWORK}" \
    "${NODE_TAG}-${INSTANCE_PREFIX}-http-alt" 2> /dev/null || true
  # As there is no simple way to wait longer for this operation we need to manually
  # wait some additional time (20 minutes altogether).
  until gcloud compute firewall-rules describe --project "${PROJECT}" "${NODE_TAG}-${INSTANCE_PREFIX}-http-alt" 2> /dev/null || [ $(($start + 1200)) -lt `date +%s` ]
  do sleep 5
  done
  # Check if the firewall rule exists and fail if it does not.
  gcloud compute firewall-rules describe --project "${PROJECT}" "${NODE_TAG}-${INSTANCE_PREFIX}-http-alt"

  # Open up the NodePort range
  # TODO(justinsb): Move to main setup, if we decide whether we want to do this by default.
  start=`date +%s`
  gcloud compute firewall-rules create \
    --project "${PROJECT}" \
    --target-tags "${NODE_TAG}" \
    --allow tcp:30000-32767,udp:30000-32767 \
    --network "${NETWORK}" \
    "${NODE_TAG}-${INSTANCE_PREFIX}-nodeports" 2> /dev/null || true
  # As there is no simple way to wait longer for this operation we need to manually
  # wait some additional time (20 minutes altogether).
  until gcloud compute firewall-rules describe --project "${PROJECT}" "${NODE_TAG}-${INSTANCE_PREFIX}-nodeports" 2> /dev/null || [ $(($start + 1200)) -lt `date +%s` ]
  do sleep 5
  done
  # Check if the firewall rule exists and fail if it does not.
  gcloud compute firewall-rules describe --project "${PROJECT}" "${NODE_TAG}-${INSTANCE_PREFIX}-nodeports"
}

# Execute after running tests to perform any required clean-up. This is called
# from hack/e2e.go
function test-teardown {
  detect-project
  echo "Shutting down test cluster in background."
  gcloud compute firewall-rules delete  \
    --project "${PROJECT}" \
    --quiet \
    "${NODE_TAG}-${INSTANCE_PREFIX}-http-alt" || true
  gcloud compute firewall-rules delete  \
    --project "${PROJECT}" \
    --quiet \
    "${NODE_TAG}-${INSTANCE_PREFIX}-nodeports" || true
  "${KUBE_ROOT}/cluster/kube-down.sh"
}

# SSH to a node by name ($1) and run a command ($2).
function ssh-to-node {
  local node="$1"
  local cmd="$2"
  # Loop until we can successfully ssh into the box
  for try in $(seq 1 5); do
    if gcloud compute ssh --ssh-flag="-o LogLevel=quiet" --project "${PROJECT}" --zone="${ZONE}" "${node}" --command "echo test > /dev/null"; then
      break
    fi
    sleep 5
  done
  # Then actually try the command.
  gcloud compute ssh --ssh-flag="-o LogLevel=quiet" --project "${PROJECT}" --zone="${ZONE}" "${node}" --command "${cmd}"
}

# Restart the kube-proxy on a node ($1)
function restart-kube-proxy {
  if [[ "${OS_DISTRIBUTION}" == "trusty" ]]; then
    ssh-to-node "$1" "sudo initctl restart kube-proxy"
  else
    ssh-to-node "$1" "sudo /etc/init.d/kube-proxy restart"
  fi
}

# Restart the kube-apiserver on a node ($1)
function restart-apiserver {
  ssh-to-node "$1" "sudo docker ps | grep /kube-apiserver | cut -d ' ' -f 1 | xargs sudo docker kill"
}

# Perform preparations required to run e2e tests
function prepare-e2e() {
  detect-project
}

# Builds the RUNTIME_CONFIG var from other feature enable options
function build-runtime-config() {
  if [[ "${ENABLE_DEPLOYMENTS}" == "true" ]]; then
      if [[ -z "${RUNTIME_CONFIG}" ]]; then
          RUNTIME_CONFIG="extensions/v1beta1/deployments=true"
      else
          if echo "${RUNTIME_CONFIG}" | grep -q -v "extensions/v1beta1/deployments=true"; then
            RUNTIME_CONFIG="${RUNTIME_CONFIG},extensions/v1beta1/deployments=true"
          fi
      fi
  fi
  if [[ "${ENABLE_DAEMONSETS}" == "true" ]]; then
      if [[ -z "${RUNTIME_CONFIG}" ]]; then
          RUNTIME_CONFIG="extensions/v1beta1/daemonsets=true"
      else
          if echo "${RUNTIME_CONFIG}" | grep -q -v "extensions/v1beta1/daemonsets=true"; then
            RUNTIME_CONFIG="${RUNTIME_CONFIG},extensions/v1beta1/daemonsets=true"
          fi
      fi
  fi
}

# $1: if 'true', we're building a master yaml, else a node
function build-kube-env {
  local master=$1
  local file=$2

  build-runtime-config

  rm -f ${file}
  cat >$file <<EOF
ENV_TIMESTAMP: $(yaml-quote $(date -u +%Y-%m-%dT%T%z))
INSTANCE_PREFIX: $(yaml-quote ${INSTANCE_PREFIX})
NODE_INSTANCE_PREFIX: $(yaml-quote ${NODE_INSTANCE_PREFIX})
CLUSTER_IP_RANGE: $(yaml-quote ${CLUSTER_IP_RANGE:-10.244.0.0/16})
SERVER_BINARY_TAR_URL: $(yaml-quote ${SERVER_BINARY_TAR_URL})
SERVER_BINARY_TAR_HASH: $(yaml-quote ${SERVER_BINARY_TAR_HASH})
SALT_TAR_URL: $(yaml-quote ${SALT_TAR_URL})
SALT_TAR_HASH: $(yaml-quote ${SALT_TAR_HASH})
SERVICE_CLUSTER_IP_RANGE: $(yaml-quote ${SERVICE_CLUSTER_IP_RANGE})
KUBERNETES_MASTER_NAME: $(yaml-quote ${MASTER_NAME})
ALLOCATE_NODE_CIDRS: $(yaml-quote ${ALLOCATE_NODE_CIDRS:-false})
ENABLE_CLUSTER_MONITORING: $(yaml-quote ${ENABLE_CLUSTER_MONITORING:-none})
ENABLE_L7_LOADBALANCING: $(yaml-quote ${ENABLE_L7_LOADBALANCING:-none})
ENABLE_CLUSTER_LOGGING: $(yaml-quote ${ENABLE_CLUSTER_LOGGING:-false})
ENABLE_CLUSTER_UI: $(yaml-quote ${ENABLE_CLUSTER_UI:-false})
ENABLE_NODE_LOGGING: $(yaml-quote ${ENABLE_NODE_LOGGING:-false})
LOGGING_DESTINATION: $(yaml-quote ${LOGGING_DESTINATION:-})
ELASTICSEARCH_LOGGING_REPLICAS: $(yaml-quote ${ELASTICSEARCH_LOGGING_REPLICAS:-})
ENABLE_CLUSTER_DNS: $(yaml-quote ${ENABLE_CLUSTER_DNS:-false})
ENABLE_CLUSTER_REGISTRY: $(yaml-quote ${ENABLE_CLUSTER_REGISTRY:-false})
CLUSTER_REGISTRY_DISK: $(yaml-quote ${CLUSTER_REGISTRY_DISK})
CLUSTER_REGISTRY_DISK_SIZE: $(yaml-quote ${CLUSTER_REGISTRY_DISK_SIZE})
DNS_REPLICAS: $(yaml-quote ${DNS_REPLICAS:-})
DNS_SERVER_IP: $(yaml-quote ${DNS_SERVER_IP:-})
DNS_DOMAIN: $(yaml-quote ${DNS_DOMAIN:-})
KUBELET_TOKEN: $(yaml-quote ${KUBELET_TOKEN:-})
KUBE_PROXY_TOKEN: $(yaml-quote ${KUBE_PROXY_TOKEN:-})
ADMISSION_CONTROL: $(yaml-quote ${ADMISSION_CONTROL:-})
MASTER_IP_RANGE: $(yaml-quote ${MASTER_IP_RANGE})
RUNTIME_CONFIG: $(yaml-quote ${RUNTIME_CONFIG})
CA_CERT: $(yaml-quote ${CA_CERT_BASE64:-})
KUBELET_CERT: $(yaml-quote ${KUBELET_CERT_BASE64:-})
KUBELET_KEY: $(yaml-quote ${KUBELET_KEY_BASE64:-})
NETWORK_PROVIDER: $(yaml-quote ${NETWORK_PROVIDER:-})
OPENCONTRAIL_TAG: $(yaml-quote ${OPENCONTRAIL_TAG:-})
OPENCONTRAIL_KUBERNETES_TAG: $(yaml-quote ${OPENCONTRAIL_KUBERNETES_TAG:-})
OPENCONTRAIL_PUBLIC_SUBNET: $(yaml-quote ${OPENCONTRAIL_PUBLIC_SUBNET:-})
E2E_STORAGE_TEST_ENVIRONMENT: $(yaml-quote ${E2E_STORAGE_TEST_ENVIRONMENT:-})
KUBE_IMAGE_TAG: $(yaml-quote ${KUBE_IMAGE_TAG:-})
KUBE_DOCKER_REGISTRY: $(yaml-quote ${KUBE_DOCKER_REGISTRY:-})
EOF
  if [ -n "${KUBELET_PORT:-}" ]; then
    cat >>$file <<EOF
KUBELET_PORT: $(yaml-quote ${KUBELET_PORT})
EOF
  fi
  if [ -n "${KUBE_APISERVER_REQUEST_TIMEOUT:-}" ]; then
    cat >>$file <<EOF
KUBE_APISERVER_REQUEST_TIMEOUT: $(yaml-quote ${KUBE_APISERVER_REQUEST_TIMEOUT})
EOF
  fi
  if [ -n "${TERMINATED_POD_GC_THRESHOLD:-}" ]; then
    cat >>$file <<EOF
TERMINATED_POD_GC_THRESHOLD: $(yaml-quote ${TERMINATED_POD_GC_THRESHOLD})
EOF
  fi
  if [[ "${OS_DISTRIBUTION}" == "trusty" ]]; then
    cat >>$file <<EOF
KUBE_MANIFESTS_TAR_URL: $(yaml-quote ${KUBE_MANIFESTS_TAR_URL})
KUBE_MANIFESTS_TAR_HASH: $(yaml-quote ${KUBE_MANIFESTS_TAR_HASH})
EOF
  fi
  if [ -n "${TEST_CLUSTER:-}" ]; then
    cat >>$file <<EOF
TEST_CLUSTER: $(yaml-quote ${TEST_CLUSTER})
EOF
  fi
  if [[ "${master}" == "true" ]]; then
    # Master-only env vars.
    cat >>$file <<EOF
KUBERNETES_MASTER: $(yaml-quote "true")
KUBE_USER: $(yaml-quote ${KUBE_USER})
KUBE_PASSWORD: $(yaml-quote ${KUBE_PASSWORD})
KUBE_BEARER_TOKEN: $(yaml-quote ${KUBE_BEARER_TOKEN})
MASTER_CERT: $(yaml-quote ${MASTER_CERT_BASE64:-})
MASTER_KEY: $(yaml-quote ${MASTER_KEY_BASE64:-})
KUBECFG_CERT: $(yaml-quote ${KUBECFG_CERT_BASE64:-})
KUBECFG_KEY: $(yaml-quote ${KUBECFG_KEY_BASE64:-})
KUBELET_APISERVER: $(yaml-quote ${KUBELET_APISERVER:-})
ENABLE_MANIFEST_URL: $(yaml-quote ${ENABLE_MANIFEST_URL:-false})
MANIFEST_URL: $(yaml-quote ${MANIFEST_URL:-})
MANIFEST_URL_HEADER: $(yaml-quote ${MANIFEST_URL_HEADER:-})
NUM_NODES: $(yaml-quote ${NUM_NODES})
EOF
    if [ -n "${APISERVER_TEST_ARGS:-}" ]; then
      cat >>$file <<EOF
APISERVER_TEST_ARGS: $(yaml-quote ${APISERVER_TEST_ARGS})
EOF
    fi
    if [ -n "${KUBELET_TEST_ARGS:-}" ]; then
      cat >>$file <<EOF
KUBELET_TEST_ARGS: $(yaml-quote ${KUBELET_TEST_ARGS})
EOF
    fi
    if [ -n "${CONTROLLER_MANAGER_TEST_ARGS:-}" ]; then
      cat >>$file <<EOF
CONTROLLER_MANAGER_TEST_ARGS: $(yaml-quote ${CONTROLLER_MANAGER_TEST_ARGS})
EOF
    fi
    if [ -n "${SCHEDULER_TEST_ARGS:-}" ]; then
      cat >>$file <<EOF
SCHEDULER_TEST_ARGS: $(yaml-quote ${SCHEDULER_TEST_ARGS})
EOF
    fi
  else
    # Node-only env vars.
    cat >>$file <<EOF
KUBERNETES_MASTER: $(yaml-quote "false")
ZONE: $(yaml-quote ${ZONE})
EXTRA_DOCKER_OPTS: $(yaml-quote ${EXTRA_DOCKER_OPTS:-})
EOF
    if [ -n "${KUBELET_TEST_ARGS:-}" ]; then
      cat >>$file <<EOF
KUBELET_TEST_ARGS: $(yaml-quote ${KUBELET_TEST_ARGS})
EOF
    fi
    if [ -n "${KUBEPROXY_TEST_ARGS:-}" ]; then
      cat >>$file <<EOF
KUBEPROXY_TEST_ARGS: $(yaml-quote ${KUBEPROXY_TEST_ARGS})
EOF
    fi
  fi
  if [[ "${OS_DISTRIBUTION}" == "coreos" ]]; then
    # CoreOS-only env vars. TODO(yifan): Make them available on other distros.
    cat >>$file <<EOF
KUBERNETES_CONTAINER_RUNTIME: $(yaml-quote ${CONTAINER_RUNTIME:-docker})
RKT_VERSION: $(yaml-quote ${RKT_VERSION:-})
RKT_PATH: $(yaml-quote ${RKT_PATH:-})
KUBERNETES_CONFIGURE_CBR0: $(yaml-quote ${KUBERNETES_CONFIGURE_CBR0:-true})
EOF
  fi
}
