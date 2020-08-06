#!/bin/bash
set -o errexit
#set -o nounset
set -o pipefail
THIS_SCRIPT=$(realpath $(cd "$(dirname "${BASH_SOURCE:-$0}")"; pwd)/$(basename ${BASH_SOURCE:-$0}))
#automatic detection TOPDIR
SCRIPT_DIR=$(dirname $(realpath ${THIS_SCRIPT}))
SRC_TOP="$(realpath ${SCRIPT_DIR}/..)"

USAGE="
  usage:
  simple docker build script:
  I. build docker:
  $(basename $(realpath $0)) [/path/to/your-dockerfile] docker-build
  II. build docker then push:
  export DOCKER_REPO=
  export DOCKER_NS=
  export DOCKER_USER=
  export DOCKER_PASS=
  $(basename $(realpath $0)) [/path/to/your-dockerfile] docker-push
  III. genarate docker-compose
  $(basename $(realpath $0)) [/path/to/your-dockerfile] compose-gen
  $(basename $(realpath $0)) [/path/to/your-dockerfile] compose-test
  IV. develment phase 
  $(basename $(realpath $0)) [/path/to/your-dockerfile] dev
  $(basename $(realpath $0)) [/path/to/your-dockerfile] pre
"

if [[ $# -lt 1 ]];then
    if [[ -f ${PWD}/Dockerfile ]];then
      DOCKERFILE=${PWD}/Dockerfile
    else
      echo "${USAGE}"
      exit 1
    fi
else
    GIVE_DOCKERFILE=$1
    if [[ -f ${GIVE_DOCKERFILE} ]];then
      DOCKERFILE=$(realpath ${GIVE_DOCKERFILE} )
    else
      echo "error, Dockerfile not found"
      echo "${USAGE}"
      exit 1
    fi
fi

if [[ $# -gt 0 ]];then
    ACTION=$2
else
    ACTION="docker-build"
fi

readonly REPO_NAME=$(basename ${SRC_TOP})
readonly DOCKERFILE_DIR=$(dirname "$(realpath "${DOCKERFILE}")" | tr '[A-Z]' '[a-z]')
readonly DOCKERFILE_NAME=$(basename ${DOCKERFILE} | tr '[A-Z]' '[a-z]')
readonly IMG_TMP=$(echo "${REPO_NAME}-${DOCKERFILE_NAME}" | tr '[A-Z]' '[a-z]')
readonly ARTIFACT_DIR="${SRC_TOP}/dist/${DOCKERFILE_NAME}"

readonly SRC_VERSION=$(head -n 1 ${SRC_TOP}/VERSION)
readonly SRC_SHA=-$(git describe --abbrev=1 --always | perl -n -e 'my @arr=split(/-/,$_); print $arr[-2]')
readonly OS_DIST=$(echo ${DOCKERFILE_NAME} |cut -d. -f2)

mkdir -p ${ARTIFACT_DIR}


function do_docker_build() {

  docker build . --file ${DOCKERFILE} --tag ${IMG_TMP}
}

function do_docker_push() {
  readonly DOCKER_REPO=${DOCKER_REPO:-registry-1.docker.io}
  readonly DOCKER_NS=${DOCKER_NS:-bettercode}
  readonly DOCKER_USER=${DOCKER_USER:-bettercode}
  readonly DOCKER_PASS=${DOCKER_PASS}
  if [[ ${STABLE_PUSH} -gt 0 ]];then
    readonly IMAGE_URL=$(echo ${DOCKER_REPO}/${DOCKER_NS}/${REPO_NAME}| tr '[A-Z]' '[a-z]')
    readonly DOCKER_TAG=$(echo ${SRC_VERSION}-${OS_DIST}-${SRC_SHA} |perl -ni -e 's@--@-@;s@(.+)-$@\1@;print' )
  else
    readonly IMAGE_URL=$(echo ${DOCKER_REPO}/${DOCKER_NS}/testimg| tr '[A-Z]' '[a-z]')
    readonly DOCKER_TAG=$(echo ${REPO_NAME}-${SRC_VERSION}-${OS_DIST}-${SRC_SHA} |perl -ni -e 's@--@-@;s@(.+)-$@\1@;print' )
  fi
  if [[ -n ${DOCKER_PASS} ]];then
    echo IMAGE_URL=$IMAGE_URL
    echo DOCKER_TAG=$DOCKER_TAG
    if [[ ${STABLE_PUSH} -gt 0 ]];then
      DOCKER_TAG_LATEST=latest
    else
      DOCKER_TAG_LATEST=latest-$(echo ${REPO_NAME}| tr '[A-Z]' '[a-z]')
    fi
    docker tag ${IMG_TMP} $IMAGE_URL:${DOCKER_TAG_LATEST}
    # maybe already login,try push
    set +e
    docker push $IMAGE_URL:${DOCKER_TAG_LATEST}
    rv=$?
    set -e
    # failed ,maybe not login, try login
    if [[ ${rv} -ne 0 ]];then
      docker login -u "${DOCKER_USER}" -p  "${DOCKER_PASS}" ${DOCKER_REPO}/${DOCKER_NS}
      docker push $IMAGE_URL:${DOCKER_TAG_LATEST}
    fi
    echo $IMAGE_URL:${DOCKER_TAG} > ${ARTIFACT_DIR}/img.txt
    docker rmi $IMAGE_URL:${DOCKER_TAG_LATEST}

    docker tag ${IMG_TMP} $IMAGE_URL:${DOCKER_TAG}
    docker push $IMAGE_URL:${DOCKER_TAG}
    echo $IMAGE_URL:${DOCKER_TAG} > ${ARTIFACT_DIR}/img.txt
    set +e
    docker rmi ${IMG_TMP}
    docker rmi $IMAGE_URL:${DOCKER_TAG}
    set -e

  else
    set +e
    docker rmi ${IMG_TMP}
    set -e
  fi
}

do_compose_gen() {
  mkdir -p ${ARTIFACT_DIR}

  IMG=${IMG_TMP}
  echo "Using Docker Image: ${IMG}"
  set +e
  /bin/ls --color ${ARTIFACT_DIR}/*
  set -e
  /bin/cp -f ${SRC_TOP}/deployments/syncbot ${ARTIFACT_DIR}/


  set -e
  perl -ni -e "s@^([# ]+image:).+@\1 ${IMG}@g;print" ${ARTIFACT_DIR}/syncbot/docker-compose*.yaml
  cd ${ARTIFACT_DIR}/syncbot/
  docker-compose config
  # zip
  cd ${ARTIFACT_DIR}/
  rm -rf "./syncbot/.tpl" "./syncbot/tpl" "./syncbot/*.sh"
  /bin/cp ${ARTIFACT_DIR}/syncbot/docker-compose-allinone.yaml ${ARTIFACT_DIR}/syncbot/docker-compose.yaml
  zip -r ${ARTIFACT_DIR}/compose-syncbot-${DOCKER_TAG}.zip ./syncbot
  unzip -tvl ${ARTIFACT_DIR}/compose-syncbot-${DOCKER_TAG}.zip
}

do_compose_test() {
  /bin/cp ${ARTIFACT_DIR}/syncbot/docker-compose-allinone.yaml ${ARTIFACT_DIR}/syncbot/docker-compose.yaml
  cd ${ARTIFACT_DIR}/syncbot
  docker-compose config
  docker-compose up --force-recreate -d
  sleep 20
  docker-compose ps
  docker-compose exec -T syncbot ps aux
  docker-compose down
  docker-compose rm -f
}

do_release() {
  local GITHUB_USER=${GITHUB_USER:-chimeh}
  local GITHUB_REPO=${GITHUB_REPO:-${REPO_NAME}}

  set +e
  git rev-parse --show-toplevel >/dev/null 2>&1
  if [[ $? -ne 0 ]];then
    echo "not a git repo, no perform release."
    return
  fi
  CUR_BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
  LATEST_TAG_NAME=$(git describe --abbrev=0 --tags)
  if [[ "${CUR_BRANCH_NAME}" =~ "release" ||  "${CUR_BRANCH_NAME}" =~ "master" ]];then
    # branch name  contain `release` or master.
    echo "CUR_BRANCH_NAME ${CUR_BRANCH_NAME}"
    echo "SRC_VERSION ${SRC_VERSION}"
    echo "LATEST_TAG_NAME ${LATEST_TAG_NAME}"
    BRANCH_MARJOR_MINOR=$(echo ${CUR_BRANCH_NAME} |  perl -ne '$_ =~ /((0|[1-9][0-9]*).(0|[1-9][0-9]*))/;print $1' -)
    SRC_MARJOR_MINOR=$(echo ${SRC_VERSION} |  perl -ne '$_ =~ /((0|[1-9][0-9]*).(0|[1-9][0-9]*))/;print $1' -)
    TAG_MARJOR_MINOR=$(echo ${LATEST_TAG_NAME}| perl -ne '$_ =~ /((0|[1-9][0-9]*).(0|[1-9][0-9]*))/;print $1' -)

    echo "BRANCH_MARJOR_MINOR ${BRANCH_MARJOR_MINOR}"
    echo "SRC_MARJOR_MINOR ${SRC_MARJOR_MINOR}"
    echo "TAG_MARJOR_MINOR ${TAG_MARJOR_MINOR}"
    if [[ "${CUR_BRANCH_NAME}" =~ "master" ]];then
        if [[ ! "${TAG_MARJOR_MINOR}" =~ "${SRC_MARJOR_MINOR}" ]];then
          echo " error. Marjor.Minor should be equal, ${TAG_MARJOR_MINOR} on tag name ${LATEST_TAG_NAME} via ${SRC_MARJOR_MINOR} on src."
          #exit 1
        fi
        PRERELEASE_TYPE="${DOCKER_TAG}-alpha"
    elif [[ "${CUR_BRANCH_NAME}" =~ "release" ]];then
      if [[ ! "${BRANCH_MARJOR_MINOR}" =~ "${SRC_MARJOR_MINOR}" ]];then
        echo " error. Marjor.Minor should be equal, ${BRANCH_MARJOR_MINOR} on branch name ${CUR_BRANCH_NAME} via ${SRC_MARJOR_MINOR} on src."
        #exit 1
      elif [[ ! "${TAG_MARJOR_MINOR}" =~ "${SRC_MARJOR_MINOR}" ]];then
        echo " error. Marjor.Minor should be equal, ${TAG_MARJOR_MINOR} on tag name ${LATEST_TAG_NAME} via ${SRC_MARJOR_MINOR} on src."
        #exit 1
      fi
      # word 'alpha' 'beta' appear on branch name or commit message, assume that release
      if [[ "${LATEST_TAG_NAME}" =~ "beta" ]];then
        PRERELEASE_TYPE="${DOCKER_TAG}-beta"
      elif [[ $(echo "${LATEST_TAG_NAME}" | egrep '[0-9]+\.[0-9]+\.[0-9]+$' -) ]];then
        PRERELEASE_TYPE=''
      else
        PRERELEASE_TYPE="${DOCKER_TAG}-beta"
      fi
    else
      echo "branch name don't master or release,can't do release "
      #exit 1
    fi

    if [[ -z ${GITHUB_TOKEN} ]];then
        echo "GITHUB_TOKEN not set ,exit!"
        exit 1
    fi
    if ! command -v github-release; then
        echo "github-release cli not found!"
        rm -rf bld/github-release
        git clone https://github.com/github-release/github-release.git bld/github-release
        mkdir -p bld/gopath/bin
        cd bld/github-release
        git checkout -f v0.8.1
        env GOPATH="$(realpath ../gopath)" GO111MODULE='off' make
        export PATH=${PATH}:$(realpath ./)
    fi
    
    touch ${ARTIFACT_DIR}/buildnote.md
    RELEASE_TITLE="${PRERELEASE_TYPE} release"
    cat ${ARTIFACT_DIR}/buildnote.md | github-release edit \
      --user ${GITHUB_USER} \
      --repo ${GITHUB_REPO} \
      --tag ${LATEST_TAG_NAME} \
      --name "${RELEASE_TITLE}" \
      --description -
    rv=$?
    if [[ ${rv} -ne 0 ]];then
      cat ${ARTIFACT_DIR}/buildnote.md | github-release release \
        --user ${GITHUB_USER} \
        --repo ${GITHUB_REPO} \
        --tag ${LATEST_TAG_NAME} \
        --name "${RELEASE_TITLE}" \
        --description - \
        --pre-release
    fi
    FILE=$(/bin/ls ${ARTIFACT_DIR}/compose-syncbot-${DOCKER_TAG}.zip)
    github-release  upload \
        --user ${GITHUB_USER} \
        --repo ${GITHUB_REPO} \
        --tag ${LATEST_TAG_NAME} \
        --name "$(basename ${FILE})" \
        --file ${FILE} \
        --replace
  fi

}

case ${ACTION} in
    dev)
        do_docker_build
        do_compose_gen
        do_compose_test
        ;;
    pre)
        do_docker_build
        do_docker_push
        do_compose_gen
        do_compose_test
        do_docker_push
        do_release
        ;;
    *)
        echo "unkown action"
        ;;
esac


