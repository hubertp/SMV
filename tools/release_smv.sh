#/bin/bash
# Release the current version of SMV.  This will use the tresamigos:smv
# docker container to maintain release consistency.

set -e
PROG_NAME=$(basename "$0")
SMV_TOOLS="$(cd "`dirname "$0"`"; pwd)"
SMV_DIR="$(dirname "$SMV_TOOLS")"
SMV_DIR_BASE="$(basename $SMV_DIR)"
DOCKER_SMV_DIR="/projects/${SMV_DIR_BASE}" # SMV dir inside the docker image.
PROJ_DIR="$(dirname "$SMV_DIR")" # assume parent of SMV directory is the projects dir.

function info()
{
  echo "---- $@"
  echo "---- $@" >> ${LOGFILE}
}

function error()
{
  echo "ERROR: $@"
  echo "ERROR: $@" >> ${LOGFILE}
  echo "(See ${LOGDIR} for error logs/assets)"
  exit 1
}

function usage()
{
  echo "USAGE: ${PROG_NAME} -g github_user:github_token -d docker_user docker_password smv_version_to_release(a.b.c.d)"
  echo "See (https://help.github.com/articles/creating-a-personal-access-token-for-the-command-line/) for auth tokens"
  exit $1
}

function create_logdir()
{
  LOGDIR="/tmp/smv_release_$(date +%Y%m%d_%s)"
  LOGFILE="${LOGDIR}/${PROG_NAME}.log"
  mkdir -p "${LOGDIR}"
  info "logs/assets can be found in: ${LOGDIR}"
}

function clean_logdir()
{
  info "cleaning log directory"
  rm -rf "${LOGDIR}"
}

function parse_args()
{
  info "parsing command line args"
  [ "$1" = "-h" ] && usage 0
  [ $# -ne 6 ] && echo "ERROR: invalid number of arguments" && usage 1
  [ "$1" != "-g" ] && echo "ERROR: must supply github user name/token" && usage 1
  [ "$3" != "-d" ] && echo "ERROR: must supply dockerhub user name/password" && usage 1

  GITHUB_USER_TOKEN="$2"
  DOCKERHUB_USER_NAME="$4"
  DOCKERHUB_USER_PASSWORD="$5"
  SMV_VERSION="$6"
  validate_version "$SMV_VERSION"

  # version specific vars
  TGZ_IMAGE="${LOGDIR}/smv_${SMV_VERSION}.tgz"
}

function check_for_existing_tag()
{
  info "checking for existing tag"
  if [ $(git tag -l "v${SMV_VERSION}" | wc -l) -eq 1 ]; then
    error version ${SMV_VERSION} already exists.
  fi
}

function get_prev_smv_version()
{
  PREV_SMV_VERSION=$(cat "${SMV_DIR}/.smv_version")
  info "previous SMV version: $PREV_SMV_VERSION"
  validate_version "$PREV_SMV_VERSION"
}

# make sure version is of the format a.b.c.d where a,b,c,d are all numbers.
function validate_version()
{
  local ver="$1"
  local res=$(echo "$ver" | sed -E -e 's/^([0-9]+\.){3}[0-9]+$//')
  if [ -n "$res" ]; then
    echo "ERROR: invalid version format: $ver"
    usage 1
  fi
}

function build_smv()
{
  info "Building SMV"
  # explicitly add -ivy flag as SMV docker image is not picking up sbtopts file. (SMV issue #556)
  docker run --rm -it -v ${PROJ_DIR}:/projects tresamigos/smv:latest \
    -u $(id -u)\
    sh -c "cd $DOCKER_SMV_DIR; sbt -ivy /projects/.ivy2 clean assembly" \
    >> ${LOGFILE} 2>&1 || error "SMV build failed"

  info "Testing SMV"
  sbt alltest >> ${LOGFILE} 2>&1 || error "SMV Test failed"
}

# find the gnu tar on this system.
function find_gnu_tar()
{
  info "find gnu tar"
  local tars="gtar gnutar tar"
  TAR=""
  for t in $tars; do
    if [ -n "$(type -p $t)" ]; then
      TAR=$t
      break
    fi
  done

  # make sure it is gnu tar:
  if [ $($TAR --version | head -1 | grep "GNU tar" | wc -l) -ne 1 ]; then
    echo "ERROR: did not find a gnu tar.  Need gnu tar to build SMV release"
    exit 1
  fi
}

# find the release message in /releases dir.
function find_release_msg_file()
{
  info "finding release message file"
  RELEASE_MSG_FILE="releases/v${SMV_VERSION}.md"
  cd "${SMV_DIR}"
  if [ ! -r "${RELEASE_MSG_FILE}" ]; then
    error "Unable to find release message file: ${RELEASE_MSG_FILE}"
  fi
}

function check_git_repo()
{
  echo "--- checking repo for modified files"
  cd "${SMV_DIR}"
  if ! git diff-index --quiet HEAD --; then
    error "SMV git repo has locally modified files"
  fi
}

function update_version()
{
  info "updating version to $SMV_VERSION"
  cd "${SMV_DIR}"
  git pull # update to latest before making any changes.

  # update version in user docs.
  find docs/user -name '*.md' \
    -exec perl -pi -e "s/${PREV_SMV_VERSION}/${SMV_VERSION}/g" \{\} +

  # update version in README file
  perl -pi -e "s/${PREV_SMV_VERSION}/${SMV_VERSION}/g" README.md

  # update version in Dockerfile
  perl -pi -e "s/${PREV_SMV_VERSION}/${SMV_VERSION}/g" docker/smv/Dockerfile

  # add the smv version to the SMV directory.
  echo ${SMV_VERSION} > "${SMV_DIR}/.smv_version"

  git commit -a -m "updated version to $SMV_VERSION"
  git push origin
}

function tag_release()
{
  local tag=v"$SMV_VERSION"
  info "tagging release as $tag"
  cd "${SMV_DIR}"
  git tag -a $tag -m "SMV Release $SMV_VERSION on `date +%m/%d/%Y`"
  git push origin $tag
}

function create_tar()
{
  info "create tar image"

  # cleanup some unneeded binary files.
  rm -rf "${SMV_DIR}/project/target" "${SMV_DIR}/project/project"
  rm -rf "${SMV_DIR}/target/resolution-cache" "${SMV_DIR}/target/streams"
  find "${SMV_DIR}/target" -name '*with-dependencies.jar' -prune -o -type f -exec rm -f \{\} +

  # create the tar image
  ${TAR} zcvf "${TGZ_IMAGE}" -C "${PROJ_DIR}" --exclude=.git \
    --transform "s/^${SMV_DIR_BASE}/SMV_${SMV_VERSION}/" \
    ${SMV_DIR_BASE} >> ${LOGFILE} 2>&1 || error "tar creation failed"
}

# This only creates the release and does NOT attach the zip asset to it.
function create_github_release()
{
  info "Create github release"
  local body_file="${LOGDIR}/req1.body.json"
  local res_file="${LOGDIR}/res1.json"
  local rel_doc_url="https://github.com/TresAmigosSD/SMV/blob/master/releases/v${SMV_VERSION}.md"

  # create POST request body for creating the repo.
  # See https://developer.github.com/v3/repos/releases/ for details.
  echo "{" > $body_file
  echo "  \"tag_name\": \"v${SMV_VERSION}\"," >> $body_file
  echo "  \"name\": \"SMV v${SMV_VERSION} release $(date +%m/%d/%Y)\"," >> $body_file
  echo "  \"body\": \"See ${rel_doc_url} for release doc\"" >> $body_file
  echo "}" >> $body_file

  curl -i -u "${GITHUB_USER_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d @${body_file} \
    https://api.github.com/repos/tresamigossd/SMV/releases \
    > ${res_file} 2>&1

  grep -q "^HTTP/1.1 201 Created" ${res_file} || error "Unable to create github release: see ${res_file}"

  # extract the upload_url from the server response.  Need url to upload assets.
  UPLOAD_URL="$(sed -n -e 's/^[ ]*"upload_url":[ ]*"\(https:.*assets\).*/\1/gp' ${res_file})"
  echo "Using UPLOAD_URL: ${UPLOAD_URL}" >> ${LOGFILE}
}

function attach_tar_to_github_release()
{
  info "attach tar image to github release"
  local res_file="${LOGDIR}/res2.json"
  local tgz_basename="$(basename ${TGZ_IMAGE})"

  curl -i -u "${GITHUB_USER_TOKEN}" \
    -H "Content-Type: application/gzip" \
    -X POST \
    --data-binary "@${TGZ_IMAGE}" \
    "${UPLOAD_URL}?name=${tgz_basename}" \
    > ${res_file} 2>&1

  grep -q "^HTTP/1.1 201 Created" ${res_file} || error "Unable to upload tgz image to github: see ${res_file}"

}

function create_docker_image()
{
  local tag=v"$SMV_VERSION"

  cd "${SMV_DIR}/docker/smv"

  info "logging in to docker hub"
  docker login -u ${DOCKERHUB_USER_NAME} -p ${DOCKERHUB_USER_PASSWORD}

  info "building docker image"
  docker build -t docker_build .

  info "pushing new tagged docker image (${tag})"
  docker tag docker_build tresamigos/smv:${tag}
  docker push tresamigos/smv:${tag}

  # TODO: make this an option.
  info "pushing docker image as latest"
  docker tag docker_build tresamigos/smv:latest
  docker push tresamigos/smv:latest
}


# ---- MAIN ----
create_logdir
parse_args "$@"
check_for_existing_tag
get_prev_smv_version
find_gnu_tar
find_release_msg_file
check_git_repo
build_smv
update_version
tag_release
create_tar
create_github_release
attach_tar_to_github_release
create_docker_image
clean_logdir
