#!/usr/bin/env bash
# Copyright 2024 The Karmada Authors.
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

set -o errexit
set -o nounset
set -o pipefail

# This script sets up a development environment for installing Karmada locally.
# It creates multiple Kind clusters, including a host cluster pre-loaded with
# Karmada component images built from the latest code. The remaining clusters
# will serve as member clusters and will be registered to the Karmada control
# plane using the installation tool.
# Note: This script works for both Linux and MacOS.

REPO_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
source "${REPO_ROOT}"/hack/util.sh

# variable define
KUBECONFIG_PATH=${KUBECONFIG_PATH:-"${HOME}/.kube"}
MAIN_KUBECONFIG=${MAIN_KUBECONFIG:-"${KUBECONFIG_PATH}/karmada.config"}
HOST_CLUSTER_NAME=${HOST_CLUSTER_NAME:-"karmada-host"}
MEMBER_CLUSTER_KUBECONFIG=${MEMBER_CLUSTER_KUBECONFIG:-"${KUBECONFIG_PATH}/members.config"}
MEMBER_CLUSTER_1_NAME=${MEMBER_CLUSTER_1_NAME:-"member1"}
MEMBER_CLUSTER_2_NAME=${MEMBER_CLUSTER_2_NAME:-"member2"}
PULL_MODE_CLUSTER_NAME=${PULL_MODE_CLUSTER_NAME:-"member3"}
MEMBER_TMP_CONFIG_PREFIX="member-tmp"
MEMBER_CLUSTER_1_TMP_CONFIG="${KUBECONFIG_PATH}/${MEMBER_TMP_CONFIG_PREFIX}-${MEMBER_CLUSTER_1_NAME}.config"
MEMBER_CLUSTER_2_TMP_CONFIG="${KUBECONFIG_PATH}/${MEMBER_TMP_CONFIG_PREFIX}-${MEMBER_CLUSTER_2_NAME}.config"
PULL_MODE_CLUSTER_TMP_CONFIG="${KUBECONFIG_PATH}/${MEMBER_TMP_CONFIG_PREFIX}-${PULL_MODE_CLUSTER_NAME}.config"
HOST_IPADDRESS=${HOST_IPADDRESS:-}
BUILD_FROM_SOURCE=${BUILD_FROM_SOURCE:-"true"}
EXTRA_IMAGES_LOAD_TO_HOST_CLUSTER=${EXTRA_IMAGES_LOAD_TO_HOST_CLUSTER:-""}

CLUSTER_VERSION=${CLUSTER_VERSION:-"${DEFAULT_CLUSTER_VERSION}"}
KIND_LOG_FILE=${KIND_LOG_FILE:-"/tmp/karmada"}

#step0: prepare
# proxy setting in China mainland
if [[ -n ${CHINA_MAINLAND:-} ]]; then
  util::set_mirror_registry_for_china_mainland ${REPO_ROOT}
fi

# make sure go exists and the go version is a viable version.
util::cmd_must_exist "go"
util::verify_go_version

# make sure docker exists and daemon is running
util::cmd_must_exist "docker"

# Verify Docker daemon is actually reachable
DOCKER_INFO_ERROR_OUTPUT=""
if ! DOCKER_INFO_ERROR_OUTPUT=$(docker info 2>&1 >/dev/null); then
  echo "ERROR: Cannot connect to Docker (docker info failed)."
  echo "Details: ${DOCKER_INFO_ERROR_OUTPUT}"
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "On macOS, please start Docker Desktop."
  else
    echo "On Linux, this may be a permissions issue (e.g., your user is not in the 'docker' group) or a misconfigured Docker context."
    echo "Please ensure the Docker daemon is running and that you have permission to access it."
  fi
  exit 1
fi


# install kind and kubectl
echo -n "Preparing: 'kind' existence check - "
if util::cmd_exist kind; then
  echo "passed"
else
  echo "not pass"
  # Install kind using the version defined in util.sh
  util::install_tools "sigs.k8s.io/kind" "${KIND_VERSION}"
fi

# get arch name and os name in bootstrap
BS_ARCH=$(go env GOARCH)
BS_OS=$(go env GOOS)
# check arch and os name before installing
util::install_environment_check "${BS_ARCH}" "${BS_OS}"
echo -n "Preparing: 'kubectl' existence check - "
if util::cmd_exist kubectl; then
  echo "passed"
else
  echo "not pass"
  util::install_kubectl "" "${BS_ARCH}" "${BS_OS}"
fi

#step1. create host cluster and member clusters in parallel
# host IP address: script parameter ahead of WSL2 or macOS IP
if [[ -z "${HOST_IPADDRESS}" ]]; then
  if util::is_wsl2; then
    util::get_wsl2_ipaddress # adapt for WSL2
    HOST_IPADDRESS=${WSL2_HOST_IP_ADDRESS:-}
  else
    util::get_macos_ipaddress # Adapt for macOS
    HOST_IPADDRESS=${MAC_NIC_IPADDRESS:-}
  fi
fi
#prepare for kindClusterConfig
TEMP_PATH=$(mktemp -d)
trap '{ rm -rf ${TEMP_PATH}; }' EXIT
echo -e "Preparing kindClusterConfig in path: ${TEMP_PATH}"
cp -rf "${REPO_ROOT}"/artifacts/kindClusterConfig/member1.yaml "${TEMP_PATH}"/member1.yaml
cp -rf "${REPO_ROOT}"/artifacts/kindClusterConfig/member2.yaml "${TEMP_PATH}"/member2.yaml
cp -rf "${REPO_ROOT}"/artifacts/kindClusterConfig/member3.yaml "${TEMP_PATH}"/member3.yaml

util::delete_necessary_resources "${MAIN_KUBECONFIG},${MEMBER_CLUSTER_KUBECONFIG}" "${HOST_CLUSTER_NAME},${MEMBER_CLUSTER_1_NAME},${MEMBER_CLUSTER_2_NAME},${PULL_MODE_CLUSTER_NAME}" "${KIND_LOG_FILE}"

#step2. make images and get karmadactl BEFORE creating clusters.
# Building images is CPU/IO-intensive (~16 min) and contends with kind's
# container boot + kubeadm init if both run concurrently inside the VM.
# Building first means clusters start on an idle VM and succeed reliably.
export VERSION="latest"
export REGISTRY="docker.io/karmada"
if [[ "${BUILD_FROM_SOURCE}" == "true" ]]; then
  export KARMADA_IMAGE_LABEL_VALUE="May_be_pruned_in_local_up_environment"
  export DOCKER_BUILD_ARGS="${DOCKER_BUILD_ARGS:-} --label=image.karmada.io=${KARMADA_IMAGE_LABEL_VALUE}"
  make images GOOS="linux" --directory="${REPO_ROOT}"
  #clean up dangling images
  docker image prune --force --filter "label=image.karmada.io=${KARMADA_IMAGE_LABEL_VALUE}"
fi
GO111MODULE=on go install "github.com/karmada-io/karmada/cmd/karmadactl"

#step1. create clusters: karmada-host first (alone), then member clusters in parallel.
# karmada-host has extra port mappings and its kubeadm init takes ~7 min. Running it
# alone (waiting for completion via $!) before launching the 3 member clusters achieves
# two things:
#   1. karmada-host gets full VM resources during its kubeadm init — no 300s timeout
#      race from util::check_clusters_ready being called while kind is still running.
#   2. Member clusters run in parallel with less contention (only 3 concurrent kubeadm
#      inits instead of 4), fixing the "Starting control-plane ✗" failures.
if [[ -n "${HOST_IPADDRESS}" ]]; then # If bind the port of clusters(karmada-host, member1 and member2) to the host IP
  util::verify_ip_address "${HOST_IPADDRESS}"
  cp -rf "${REPO_ROOT}"/artifacts/kindClusterConfig/karmada-host.yaml "${TEMP_PATH}"/karmada-host.yaml
  sed -i'' -e "s/{{host_ipaddress}}/${HOST_IPADDRESS}/g" "${TEMP_PATH}"/karmada-host.yaml
  sed -i'' -e 's/networking:/&\'$'\n''  apiServerAddress: "'${HOST_IPADDRESS}'"/' "${TEMP_PATH}"/member1.yaml
  sed -i'' -e 's/networking:/&\'$'\n''  apiServerAddress: "'${HOST_IPADDRESS}'"/' "${TEMP_PATH}"/member2.yaml
  sed -i'' -e 's/networking:/&\'$'\n''  apiServerAddress: "'${HOST_IPADDRESS}'"/' "${TEMP_PATH}"/member3.yaml
  # On macOS/Darwin with a colima VM, HOST_IPADDRESS is the VM's vmnet IP
  # (e.g. 192.168.64.2) which is NOT a local macOS interface. kind's port probe
  # (net.Listen on HOST_IPADDRESS) runs on the macOS host process and requires
  # the address to be a local interface. The lo0 alias for HOST_IPADDRESS is
  # added at the END of the CI "install colima" step (step 4), BEFORE the curl
  # connectivity loop, so the routing-cache flush it causes is absorbed there
  # rather than here mid-step — which would cancel the runner via lost heartbeat.
  util::create_cluster "${HOST_CLUSTER_NAME}" "${MAIN_KUBECONFIG}" "${CLUSTER_VERSION}" "${KIND_LOG_FILE}" "${TEMP_PATH}"/karmada-host.yaml
else
  util::create_cluster "${HOST_CLUSTER_NAME}" "${MAIN_KUBECONFIG}" "${CLUSTER_VERSION}" "${KIND_LOG_FILE}"
fi
KARMADA_HOST_KIND_PID=$!  # PID of the nohup kind process launched by util::create_cluster

# Block until karmada-host's kind process exits (success or failure).
# util::check_clusters_ready has a 300s timeout on the kubeconfig file; waiting
# here means the kubeconfig already exists when check_clusters_ready runs, so it
# passes immediately without racing the 300s clock.
echo "Waiting for karmada-host cluster creation to complete..."
wait "${KARMADA_HOST_KIND_PID}" || true
if [[ ! -f "${MAIN_KUBECONFIG}" ]]; then
  echo "[ERROR] karmada-host cluster creation failed (kubeconfig not written). See ${KIND_LOG_FILE}/${HOST_CLUSTER_NAME}.log"
  exit 1
fi
echo "karmada-host created. Starting member clusters in parallel..."

# Now create member clusters in parallel (VM resources freed from karmada-host)
util::create_cluster "${MEMBER_CLUSTER_1_NAME}" "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${CLUSTER_VERSION}" "${KIND_LOG_FILE}" "${TEMP_PATH}"/member1.yaml
util::create_cluster "${MEMBER_CLUSTER_2_NAME}" "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${CLUSTER_VERSION}" "${KIND_LOG_FILE}" "${TEMP_PATH}"/member2.yaml
util::create_cluster "${PULL_MODE_CLUSTER_NAME}" "${PULL_MODE_CLUSTER_TMP_CONFIG}" "${CLUSTER_VERSION}" "${KIND_LOG_FILE}" "${TEMP_PATH}"/member3.yaml

# Remove lo0 alias now that all kind cluster port probes are complete.
# The alias was added at the end of the CI "install colima" step (step 4).
# kind's port probe (net.Listen) runs before container creation. Once each
# kind node container is running, its probe is definitively done.
# Keeping the alias routes kubectl traffic to loopback instead of the VM,
# causing util::check_clusters_ready's healthz checks to fail with
# connection-refused from loopback rather than reaching the API server in the VM.
if [[ "$(uname)" == "Darwin" ]] && [[ -n "${HOST_IPADDRESS}" ]]; then
  for _cluster in "${HOST_CLUSTER_NAME}" "${MEMBER_CLUSTER_1_NAME}" "${MEMBER_CLUSTER_2_NAME}" "${PULL_MODE_CLUSTER_NAME}"; do
    for _i in $(seq 1 30); do
      docker ps --filter "name=${_cluster}-control-plane" --filter "status=running" --quiet 2>/dev/null | grep -q . && break
      sleep 2
    done
  done
  sudo ifconfig lo0 -alias "${HOST_IPADDRESS}" 2>/dev/null || true
  echo "Removed lo0 alias ${HOST_IPADDRESS} (kind containers running, port probes done)"
fi

# darwin_check_clusters_ready: Darwin-specific variant of util::check_clusters_ready.
# On macOS with colima (vmnet-shared NAT), port-mapped addresses (e.g. 192.168.64.2:PORT)
# are bound inside the VM — macOS host processes cannot TCP-connect inbound to them.
# This function performs the same kubeconfig setup as util::check_clusters_ready but runs
# the healthz probe inside the VM via 'colima ssh', where the container's Docker bridge IP
# is directly routable without any port mapping.
darwin_check_clusters_ready() {
  local kubeconfig="${1}"
  local ctx="${2}"
  echo "Waiting for kubeconfig file ${kubeconfig} and cluster ${ctx} to be ready..."
  util::wait_file_exist "${kubeconfig}" 300
  util::wait_for_condition 'running' \
    "docker inspect --format='{{.State.Status}}' ${ctx}-control-plane &> /dev/null" 300
  kubectl config rename-context "kind-${ctx}" "${ctx}" \
    --kubeconfig="${kubeconfig}" 2>/dev/null || true
  local container_ip_port
  container_ip_port=$(util::get_docker_host_ip_port "${ctx}-control-plane")
  kubectl config set-cluster "kind-${ctx}" \
    --server="https://${container_ip_port}" \
    --kubeconfig="${kubeconfig}"
  # Get the container's Docker bridge IP — directly routable from inside the VM.
  # We query this from the macOS host (via DOCKER_HOST unix socket) which talks to
  # the VM's Docker daemon and returns the container's internal IP.
  local bridge_ip
  bridge_ip=$(docker inspect \
    --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "${ctx}-control-plane" 2>/dev/null | head -1)
  echo "Checking healthz for ${ctx} via colima ssh (container bridge IP: ${bridge_ip})..."
  # Run healthz from inside the VM via colima ssh. 150 retries × 2 s = 300 s max.
  local count=0
  while true; do
    if colima ssh -- bash -c \
      "curl -sk 'https://${bridge_ip}:6443/healthz' 2>/dev/null | grep -q ok" 2>/dev/null; then
      echo "${ctx} healthz: ok"
      break
    fi
    if [[ ${count} -ge 150 ]]; then
      echo "[ERROR] Timeout waiting for condition ok (${ctx})"
      return 1
    fi
    count=$((count + 1))
    sleep 2
  done
}

#step3. wait until clusters ready
echo "Waiting for the clusters to be ready..."
if [[ "$(uname)" == "Darwin" ]] && [[ -n "${HOST_IPADDRESS}" ]]; then
  darwin_check_clusters_ready "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}"
  darwin_check_clusters_ready "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${MEMBER_CLUSTER_1_NAME}"
  darwin_check_clusters_ready "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${MEMBER_CLUSTER_2_NAME}"
  darwin_check_clusters_ready "${PULL_MODE_CLUSTER_TMP_CONFIG}" "${PULL_MODE_CLUSTER_NAME}"
else
  util::check_clusters_ready "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}"
  util::check_clusters_ready "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${MEMBER_CLUSTER_1_NAME}"
  util::check_clusters_ready "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${MEMBER_CLUSTER_2_NAME}"
  util::check_clusters_ready "${PULL_MODE_CLUSTER_TMP_CONFIG}" "${PULL_MODE_CLUSTER_NAME}"
fi

#step4. load components images to kind cluster
if [[ "${BUILD_FROM_SOURCE}" == "true" ]]; then
  # host cluster
  kind load docker-image "${REGISTRY}/karmada-controller-manager:${VERSION}" --name="${HOST_CLUSTER_NAME}"
  kind load docker-image "${REGISTRY}/karmada-scheduler:${VERSION}" --name="${HOST_CLUSTER_NAME}"
  kind load docker-image "${REGISTRY}/karmada-descheduler:${VERSION}" --name="${HOST_CLUSTER_NAME}"
  kind load docker-image "${REGISTRY}/karmada-webhook:${VERSION}" --name="${HOST_CLUSTER_NAME}"
  kind load docker-image "${REGISTRY}/karmada-scheduler-estimator:${VERSION}" --name="${HOST_CLUSTER_NAME}"
  kind load docker-image "${REGISTRY}/karmada-aggregated-apiserver:${VERSION}" --name="${HOST_CLUSTER_NAME}"
  kind load docker-image "${REGISTRY}/karmada-search:${VERSION}" --name="${HOST_CLUSTER_NAME}"
  kind load docker-image "${REGISTRY}/karmada-metrics-adapter:${VERSION}" --name="${HOST_CLUSTER_NAME}"
  for img in ${EXTRA_IMAGES_LOAD_TO_HOST_CLUSTER//,/ }; do
    kind load docker-image "$img" --name="${HOST_CLUSTER_NAME}"
  done
  # pull mode member cluster
  kind load docker-image "${REGISTRY}/karmada-agent:${VERSION}" --name="${PULL_MODE_CLUSTER_NAME}"
fi

# Load any extra images into all member clusters (set EXTRA_IMAGES_LOAD_TO_MEMBER_CLUSTERS
# to a comma-separated list).  Useful for pre-seeding images that would otherwise be pulled
# from the internet by containerd inside the kind nodes (e.g. metrics-server).
for img in ${EXTRA_IMAGES_LOAD_TO_MEMBER_CLUSTERS//,/ }; do
  kind load docker-image "$img" --name="${MEMBER_CLUSTER_1_NAME}"
  kind load docker-image "$img" --name="${MEMBER_CLUSTER_2_NAME}"
  kind load docker-image "$img" --name="${PULL_MODE_CLUSTER_NAME}"
done

#step5. connecting networks between karmada-host, member1 and member2 clusters
echo "connecting cluster networks..."
util::add_routes "${MEMBER_CLUSTER_1_NAME}" "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${MEMBER_CLUSTER_2_NAME}"
util::add_routes "${MEMBER_CLUSTER_2_NAME}" "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${MEMBER_CLUSTER_1_NAME}"

util::add_routes "${HOST_CLUSTER_NAME}" "${MEMBER_CLUSTER_1_TMP_CONFIG}" "${MEMBER_CLUSTER_1_NAME}"
util::add_routes "${MEMBER_CLUSTER_1_NAME}" "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}"

util::add_routes "${HOST_CLUSTER_NAME}" "${MEMBER_CLUSTER_2_TMP_CONFIG}" "${MEMBER_CLUSTER_2_NAME}"
util::add_routes "${MEMBER_CLUSTER_2_NAME}" "${MAIN_KUBECONFIG}" "${HOST_CLUSTER_NAME}"
echo "cluster networks connected"

#step6. merge temporary kubeconfig of member clusters by kubectl
export KUBECONFIG=$(find ${KUBECONFIG_PATH} -maxdepth 1 -type f | grep ${MEMBER_TMP_CONFIG_PREFIX} | tr '\n' ':')
kubectl config view --flatten > ${MEMBER_CLUSTER_KUBECONFIG}
rm $(find ${KUBECONFIG_PATH} -maxdepth 1 -type f | grep ${MEMBER_TMP_CONFIG_PREFIX})
