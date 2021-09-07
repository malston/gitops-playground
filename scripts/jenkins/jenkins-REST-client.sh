#!/usr/bin/env bash
set -o errexit -o pipefail

function curlJenkins() {
  curl -s -H "Jenkins-Crumb:$(crumb)" --cookie /tmp/cookies \
    -u "${JENKINS_USERNAME}:${JENKINS_PASSWORD}" \
    "$@"
}
function createJob() {
  JOB_NAME=${1}

  # shellcheck disable=SC2016
  # we don't want to expand these variables in single quotes
  JOB_CONFIG=$(SCMM_NAMESPACE_JOB_SERVER_URL="${2}" \
               SCMM_NAMESPACE_JOB_NAMESPACE="${3}" \
               SCMM_NAMESPACE_JOB_CREDENTIALS_ID="${4}" \
               envsubst '${SCMM_NAMESPACE_JOB_SERVER_URL},
                         ${SCMM_NAMESPACE_JOB_NAMESPACE},
                         ${SCMM_NAMESPACE_JOB_CREDENTIALS_ID}' \
               < scripts/jenkins/namespaceJobTemplate.xml)

  printf 'Creating job %s ... ' "${JOB_NAME}"

  # Don't add --fail here, because if the job already exists we get a return code of 400
  STATUS=$(curlJenkins -L -o /dev/null --write-out '%{http_code}' \
           -X POST "${JENKINS_URL}/createItem?name=${JOB_NAME}" \
           -H "Content-Type:text/xml" \
           --data "${JOB_CONFIG}" ) && EXIT_STATUS=$? || EXIT_STATUS=$?
  if [ $EXIT_STATUS != 0 ]
    then
      echo "Creating Job failed with exit code: curl: ${EXIT_STATUS}, HTTP Status: ${STATUS}"
      exit $EXIT_STATUS
  fi

  printStatus "${STATUS}"
}

function createCredentials() {
  printf 'Creating credentials for %s ... ' "${1}"

  # shellcheck disable=SC2016
  # we don't want to expand these variables in single quotes
  CRED_CONFIG=$(CREDENTIALS_ID="${1}" \
               USERNAME="${2}" \
               PASSWORD="${3}" \
               DESCRIPTION="${4}" \
               envsubst '${CREDENTIALS_ID},
                         ${USERNAME},
                         ${PASSWORD},
                         ${DESCRIPTION}' \
               < scripts/jenkins/credentialsTemplate.json)

  STATUS=$(curlJenkins --fail -L -o /dev/null --write-out '%{http_code}' \
        -X POST "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
        --data-urlencode "json=${CRED_CONFIG}") && EXIT_STATUS=$? || EXIT_STATUS=$?
  if [ $EXIT_STATUS != 0 ]
    then
      echo "Creating Credentials failed with exit code: curl: ${EXIT_STATUS}, HTTP Status: ${STATUS}"
      exit $EXIT_STATUS
  fi

  printStatus "${STATUS}"
}

function crumb() {
  curl -s --cookie-jar /tmp/cookies \
    -u "${JENKINS_USERNAME}:${JENKINS_PASSWORD}" \
    "${JENKINS_URL}/crumbIssuer/api/json" | jq -r '.crumb'
}

function installPlugin() {
  PLUGIN_NAME=${1}
  PLUGIN_VERSION=${2}

  printf 'Installing plugin %s v%s ...' "${PLUGIN_NAME}" "${PLUGIN_VERSION}"

  STATUS=$(postPlugin "${PLUGIN_NAME}" "${PLUGIN_VERSION}")
  waitForPluginInstallation "${PLUGIN_NAME}" && PLUGIN_INSTALLED=$? || PLUGIN_INSTALLED=$?

  until [[ $PLUGIN_INSTALLED = 0 ]]; do
    STATUS=$(postPlugin "${PLUGIN_NAME}" "${PLUGIN_VERSION}")
    waitForPluginInstallation "${PLUGIN_NAME}" && PLUGIN_INSTALLED=$? || PLUGIN_INSTALLED=$?
  done

  printStatus "${STATUS}"
}

function postPlugin() {
  PLUGIN_NAME=${1}
  PLUGIN_VERSION=${2}

  STATUS=$(curlJenkins --fail -L -o /dev/null --write-out '%{http_code}' \
          -X POST "${JENKINS_URL}/pluginManager/installNecessaryPlugins" \
          -d '<jenkins><install plugin="'"${PLUGIN_NAME}"'@'"${PLUGIN_VERSION}"'"/></jenkins>' \
          -H 'Content-Type: text/xml') && EXIT_STATUS=$? || EXIT_STATUS=$?
  if [ $EXIT_STATUS != 0 ]
    then
      echo "Installing Plugin failed with exit code: curl: ${EXIT_STATUS}, ${STATUS}"
      exit $EXIT_STATUS
  fi

  echo "${STATUS}"
}

function waitForPluginInstallation() {
  PLUGIN_NAME=${1}
  ITERATIONS=0
  while [[ $(curlJenkins --fail -L \
            "${JENKINS_URL}/pluginManager/api/json?depth=1" \
            | jq '.plugins[]|{shortName}' -c \
            | grep "${PLUGIN_NAME}" >/dev/null; echo $?) \
            -ne "0" ]]; do

    if [[ "$ITERATIONS" -gt "4" ]]; then
      return 1
    fi

    echo -n .
    sleep 2
    ((ITERATIONS++))
  done

  return 0
}

function safeRestart() {
  # Don't use -L here, otherwise follows to root page which is 503 on restart. Then fails.
  curlJenkins --fail -o /dev/null --write-out '%{http_code}' \
    -X POST "${JENKINS_URL}/safeRestart" && EXIT_STATUS=$? || EXIT_STATUS=$?
  if [ $EXIT_STATUS != 0 ]
    then
      echo "Restarting Jenkins failed with exit code: curl: ${EXIT_STATUS}, HTTP Status: ${STATUS}"
      exit $EXIT_STATUS
  fi
}

function setGlobalProperty() {
  printf 'Setting Global Property %s:%s ...' "${1}" "${2}"

  # shellcheck disable=SC2016
  # we don't want to expand these variables in single quotes
  GROOVY_SCRIPT=$(KEY="${1}" \
               VALUE="${2}" \
               envsubst '${KEY},
                         ${VALUE}' \
               < scripts/jenkins/setGlobalPropertyTemplate.groovy)

  STATUS=$(curlJenkins --fail -L -o /dev/null --write-out '%{http_code}' \
       -d "script=${GROOVY_SCRIPT}" --user "${JENKINS_USERNAME}:${JENKINS_PASSWORD}" \
       "${JENKINS_URL}/scriptText" ) && EXIT_STATUS=$? || EXIT_STATUS=$?
  if [ $EXIT_STATUS != 0 ]
    then
      echo "Setting Global Property ${1}:${2} failed with exit code: curl: ${EXIT_STATUS}, HTTP Status: ${STATUS}"
      exit $EXIT_STATUS
  fi

  printStatus "${STATUS}"
}

function printStatus() {
  STATUS_CODE=${1}
  if [ "${STATUS_CODE}" -eq 200 ] || [ "${STATUS_CODE}" -eq 302 ]
  then
    echo -e ' \u2705'
  else
    echo -e ' \u274c ' "(status code: $STATUS_CODE)"
  fi
}
