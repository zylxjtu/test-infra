#!/usr/bin/env bash
# Copyright 2018 The Kubernetes Authors.
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

# generic runner script, handles DIND, etc.

# runs custom docker data root cleanup binary and debugs remaining resources
cleanup_dind() {
    if [[ "${DOCKER_IN_DOCKER_ENABLED:-false}" == "true" ]]; then
        echo "Waiting 30 seconds for pods stopped with terminationGracePeriod:30"
        sleep 30
        echo "Cleaning up after docker"
        docker ps -aq | xargs -r docker rm -f || true
        echo "Waiting for docker to stop for 30 seconds"
        timeout 30 service docker stop || true
        # force kill docker related processes
        (cat /var/run/docker*.pid | xargs kill -9) || true
    fi
}

early_exit_handler() {
    if [ -n "${WRAPPED_COMMAND_PID:-}" ]; then
        kill -TERM "$WRAPPED_COMMAND_PID" || true
    fi
    cleanup_dind
}

# Check if the job has opted-in to docker-in-docker availability.
export DOCKER_IN_DOCKER_ENABLED=${DOCKER_IN_DOCKER_ENABLED:-false}
if [[ "${DOCKER_IN_DOCKER_ENABLED}" == "true" ]]; then
    echo "Docker in Docker enabled, initializing..."
    printf '=%.0s' {1..80}; echo

    # optionally enable CDI in Docker/containerd (see https://github.com/cncf-tags/container-device-interface?tab=readme-ov-file#docker-configuration)
    export CDI_IN_DOCKER_ENABLED=${CDI_IN_DOCKER_ENABLED:-false}
    if [[ "${CDI_IN_DOCKER_ENABLED}" == "true" ]]; then
        echo "Enabling CDI for Docker."
        mkdir -p /etc/docker/
        cat >/etc/docker/daemon.json <<EOF
{
  "features": {
    "cdi": true
  }
}
EOF
    fi

    # docker v27+ has ipv6 by default, but not all e2e hosts have everything
    # we need enabled by default
    # enable ipv6
    sysctl net.ipv6.conf.all.disable_ipv6=0
    sysctl net.ipv6.conf.all.forwarding=1
    # enable ipv6 iptables
    modprobe -v ip6table_nat

    # Fix ulimit issue
    sed -i 's|ulimit -Hn|ulimit -n|' /etc/init.d/docker || true

    # start the docker daemon
    service docker start
    # the service can be started but the docker socket not ready, wait for ready
    WAIT_N=0
    MAX_WAIT=5
    while true; do
        # docker ps -q should only work if the daemon is ready
        docker ps -q > /dev/null 2>&1 && break
        if [[ ${WAIT_N} -lt ${MAX_WAIT} ]]; then
            WAIT_N=$((WAIT_N+1))
            echo "Waiting for docker to be ready, sleeping for ${WAIT_N} seconds."
            sleep ${WAIT_N}
        else
            echo "Reached maximum attempts, not waiting any longer..."
            break
        fi
    done
    printf '=%.0s' {1..80}; echo
    echo "Done setting up docker in docker."

    # Workaround for https://github.com/kubernetes/test-infra/issues/23741
    # Instead of removing, disabled by default in case we need to address again
    if [[ "${BOOTSTRAP_MTU_WORKAROUND:-"false"}" == "true" ]]; then
        echo "configure iptables to set MTU"
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    fi
fi

trap early_exit_handler INT TERM

# disable error exit so we can run post-command cleanup
set +o errexit

# add $GOPATH/bin to $PATH
export PATH="${GOPATH}/bin:${PATH}"
mkdir -p "${GOPATH}/bin"
# Authenticate gcloud, allow failures
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" || true
fi

# Use a reproducible build date based on the most recent git commit timestamp.
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct || true)
export SOURCE_DATE_EPOCH

# actually start bootstrap and the job
set -o xtrace
"$@" &
WRAPPED_COMMAND_PID=$!
wait $WRAPPED_COMMAND_PID
EXIT_VALUE=$?
set +o xtrace

# cleanup after job
if [[ "${DOCKER_IN_DOCKER_ENABLED}" == "true" ]]; then
    echo "Cleaning up after docker in docker."
    printf '=%.0s' {1..80}; echo
    cleanup_dind
    printf '=%.0s' {1..80}; echo
    echo "Done cleaning up after docker in docker."
fi

# preserve exit value from job / bootstrap
exit ${EXIT_VALUE}
