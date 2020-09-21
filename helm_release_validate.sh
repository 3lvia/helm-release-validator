#!/bin/bash

set -o errexit

function debug {
  if [ $DEBUG ]; then
    echo $1
  fi
}

function usage() {
    echo "Usage: "
    echo "  helm_release_validate.sh --helm-release <file> --kube-version <version>"
    echo ""
    echo "Flags:"
    echo "  -r, --helm-release string         Path to a yaml file with a HelmRelease definition"
    echo "      --kube-version string         Version of Kubernetes  to validate against, i.e. 1.17.0, 1.18.0, 1.19.0. Defaults to master. "
    echo "      --debug                       Enable debugging output"
    echo ""
    echo "Example:"
    echo "  helm_release_validate.sh --helm-release myapp.yaml --kube-version 1.17"
}

function check_deps() {
  if ! [ -x "$(command -v helm)" ]; then
    echo "Error: helm not found" >&2
    exit 1
  fi
  if ! [ -x "$(command -v kubeval)" ]; then
    echo "Error: kubeval not found" >&2
    exit 1
  fi
  ! getopt --test > /dev/null 
  if [[ ${PIPESTATUS[0]} -ne 4 ]]; then
      echo 'I’m sorry, `getopt --test` failed in this environment.'
      exit 1
  fi
}

function init() {
  # Store location of the script to $script_path
  script_path="`dirname \"$0\"`"              # relative
  script_path="`( cd \"$script_path\" && pwd )`"  # absolutized and normalized
  if [ -z "$script_path" ] ; then
    # error; for some reason, the path is not accessible
    # to the script (e.g. permissions re-evaled after suid)
    echo "Unable to find location of this script"
    exit 1  # fail
  fi
}

function get_command_line_args() {
  OPTIONS=r:h
  LONGOPTS=debug,help,helm-release:,kube-version:
  # -use ! and PIPESTATUS to get exit code with errexit set
  # -temporarily store output to be able to check for errors
  # -activate quoting/enhanced mode (e.g. by writing out “--options”)
  # -pass arguments only via   -- "$@"   to separate them correctly
  ! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@")
  if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      # e.g. return value is 1
      #  then getopt has complained about wrong arguments to stdout
      exit 1
  fi
  # read getopt’s output this way to handle the quoting right:
  eval set -- "$PARSED"

  HELM_RELEASE=""
  KUBE_VER="master"

  # now enjoy the options in order and nicely split until we see --
  while true; do
      case "$1" in
          --debug)
              DEBUG=true
              shift
              ;;
          -h|--help)
              usage
              exit 0
              ;;
          -r|--helm-release)
              HELM_RELEASE="$2"
              shift 2
              ;;
          --kube-version)
              KUBE_VER="$2"
              shift 2
              ;;
          --)
              shift
              break
              ;;
          *)
              echo "Found unknown parameter"
              usage
              exit 1
              ;;
      esac
  done

  if [ "$HELM_RELEASE" = "" ]; then
    echo "Error: helm-release missing"
    echo ""
    usage
    exit 1
  fi
}

function isHelmRelease {
  KIND=$(yq r ${1} kind)
  if [[ ${KIND} == "HelmRelease" ]]; then
      echo true
  else
    echo false
  fi
}

function download {
  CHART_REPO=$(yq r ${1} spec.chart.repository)
  CHART_NAME=$(yq r ${1} spec.chart.name)
  CHART_VERSION=$(yq r ${1} spec.chart.version)
  CHART_DIR=${2}/${CHART_NAME}

  CHART_REPO_MD5=`/bin/echo $CHART_REPO | /usr/bin/md5sum | cut -f1 -d" "`

  helm repo add ${CHART_REPO_MD5} ${CHART_REPO}
  helm repo update
  helm fetch --version ${CHART_VERSION} --untar ${CHART_REPO_MD5}/${CHART_NAME} --untardir ${2}

  echo ${CHART_DIR}
}


function fetch {
  cd ${1}
  git init -q
  git remote add origin ${3}
  git fetch -q origin
  git checkout -q ${4}
  cd ${5}
  echo ${2}
}


function clone {
  ORIGIN=$(git rev-parse --show-toplevel)
  CHART_GIT_REPO=$(yq r ${1} spec.chart.git)

  CHART_BASE_URL=$(echo "${CHART_GIT_REPO}" | sed -e 's/ssh:\/\///' -e 's/http:\/\///' -e 's/https:\/\///' -e 's/git@//' -e 's/:/\//')

  if [[ -n "${GITHUB_TOKEN}" ]]; then
    CHART_GIT_REPO="https://${GITHUB_TOKEN}:x-oauth-basic@${CHART_BASE_URL}"
  fi

  GIT_REF=$(yq r ${1} spec.chart.ref)
  CHART_PATH=$(yq r ${1} spec.chart.path)

  fetch ${2} ${2}/${CHART_PATH} ${CHART_GIT_REPO} ${GIT_REF} ${ORIGIN}
}

function validate {
  if [[ $(isHelmRelease ${HELM_RELEASE}) == "false" ]]; then
    echo "\"${HELM_RELEASE}\" is not of kind HelmRelease!"
    exit 1
  fi

  TMPDIR=$(mktemp -d)
  CHART_PATH=$(yq r ${HELM_RELEASE} spec.chart.path)

  if [[ -z "${CHART_PATH}" ]]; then
    debug "Downloading to ${TMPDIR}"
    CHART_DIR=$(download ${HELM_RELEASE} ${TMPDIR}| tail -n1)
  else
    debug "Cloning to ${TMPDIR}"
    CHART_DIR=$(clone ${HELM_RELEASE} ${TMPDIR} | tail -n1)
  fi

  HELM_RELEASE_NAME=$(yq r ${HELM_RELEASE} metadata.name)
  HELM_RELEASE_NAMESPACE=$(yq r ${HELM_RELEASE} metadata.namespace)

  debug "Extracting values to ${TMPDIR}/${HELM_RELEASE_NAME}.values.yaml"
  yq r ${HELM_RELEASE} spec.values > ${TMPDIR}/${HELM_RELEASE_NAME}.values.yaml

  debug "Writing Helm release to ${TMPDIR}/${HELM_RELEASE_NAME}.release.yaml"
  if [[ "${CHART_PATH}" ]]; then
    helm dependency build ${CHART_DIR}
  fi
  helm template ${HELM_RELEASE_NAME} ${CHART_DIR} \
    --namespace ${HELM_RELEASE_NAMESPACE} \
    --skip-crds=true \
    -f ${TMPDIR}/${HELM_RELEASE_NAME}.values.yaml > ${TMPDIR}/${HELM_RELEASE_NAME}.release.yaml 


  debug "Validating Helm release ${HELM_RELEASE_NAME}.${HELM_RELEASE_NAMESPACE} against Kubernetes ${KUBE_VER}"
  kubeval --strict --kubernetes-version ${KUBE_VER} ${TMPDIR}/${HELM_RELEASE_NAME}.release.yaml
}

check_deps
init
get_command_line_args "$@"

debug "Debug enabled"

debug "Processing ${HELM_RELEASE}"

validate
