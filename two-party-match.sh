#!/bin/sh
set -eu

# Run SMPC-RL matching and real linkage for the two test sites: SiteA-SiteB.
#
# Optional env vars:
#   SUCCESS_REGEX  regex that marks /jobs/list as finished
#                  default: success|successful|finished|completed|done
#   POLL_SECONDS   seconds between job polls, default: 5
#   MAX_ATTEMPTS   max polls per pair, default: 120

SUCCESS_REGEX=${SUCCESS_REGEX:-'success|successful|finished|completed|done'}
POLL_SECONDS=${POLL_SECONDS:-5}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-120}

REPORT_DIR=${REPORT_DIR:-/test-results}
MATCH_STATUS=''
MATCH_JOBS=''
LINKAGE_JOBS=''
ID_TOTAL=0
ID_UNIQUE=0
ID_PERSISTED=0
ID_MISSING=0
ID_NUMERIC=0

write_report() {
  report_exit_code=$1
  mkdir -p "$REPORT_DIR"

  jq -n \
    --argjson exitCode "$report_exit_code" \
    --arg matchStatus "$MATCH_STATUS" \
    --arg matchJobs "$MATCH_JOBS" \
    --arg linkageJobs "$LINKAGE_JOBS" \
    --argjson totalIds "$ID_TOTAL" \
    --argjson uniqueIds "$ID_UNIQUE" \
    --argjson persistedIds "$ID_PERSISTED" \
    --argjson missingIds "$ID_MISSING" \
    --argjson numericTemporaryIds "$ID_NUMERIC" \
    '{
      exitCode: $exitCode,
      matching: (if $matchStatus == "" then null else ($matchStatus | fromjson) end),
      jobs: {
        matching: (if $matchJobs == "" then null else ($matchJobs | fromjson) end),
        linkage: (if $linkageJobs == "" then null else ($linkageJobs | fromjson) end)
      },
      idVerification: {
        total: $totalIds,
        unique: $uniqueIds,
        persisted: $persistedIds,
        missing: $missingIds,
        numericTemporary: $numericTemporaryIds,
        passed: ($totalIds > 0 and $totalIds == $uniqueIds and $totalIds == $persistedIds and $missingIds == 0 and $numericTemporaryIds == 0)
      }
    }' > "$REPORT_DIR/smpc-rl-report.json"
}

on_exit() {
  report_exit_code=$?
  write_report "$report_exit_code"
}

trap on_exit EXIT

compose_project() {
  docker container inspect "$HOSTNAME" \
    --format '{{ index .Config.Labels "com.docker.compose.project" }}'
}

container_for_service() {
  lookup_service=$1
  lookup_project=$(compose_project)

  container=$(docker container ls \
    --filter "label=com.docker.compose.project=${lookup_project}" \
    --filter "label=com.docker.compose.service=${lookup_service}" \
    --format '{{.ID}}' \
    | head -n 1)

  if [ -n "$container" ]; then
    printf '%s\n' "$container"
    return 0
  fi

  echo "Could not find running container for service '$lookup_service' in Compose project '$lookup_project'" >&2
  return 1
}

curl_container_for_site() {
  container_for_service "${1}-curl"
}

run_in_site() {
  exec_site=$1
  shift
  exec_container=$(curl_container_for_site "$exec_site")
  docker exec "$exec_container" "$@"
}

wait_for_container_log() {
  container=$1
  pattern=$2
  attempt=1

  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if docker logs "$container" 2>&1 | grep -Eq "$pattern"; then
      return 0
    fi
    sleep "$POLL_SECONDS"
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for '$pattern' in logs of $container" >&2
  return 1
}

wait_for_beam() {
  echo "Waiting for both Beam proxies to report startup complete ..."
  for site in SiteA SiteB; do
    container=$(container_for_service "${site}-beam-proxy")
    wait_for_container_log "$container" "Startup complete"
  done
}

wait_for_linkage_service() {
  echo "Waiting for Linkage Service with configured parties ..."
  run_in_site SiteA sh -c 'until curl -fsS http://linkage-service:5000/health >/dev/null; do sleep 2; done'

  for configured_site in SiteA SiteB; do
    run_in_site SiteA curl -fsS "http://linkage-service:5000/parties/${configured_site}"
    echo
  done
}

wait_for_pair_config() {
  pair_site=$1
  pair_remote_site=$2
  pair_site_sel=$(container_for_service "${pair_site}-secureepilinker")
  pair_remote_sel=$(container_for_service "${pair_remote_site}-secureepilinker")

  echo "Waiting for SecureEpiLinker config for ${pair_site}<->${pair_remote_site} ..."
  wait_for_container_log "$pair_site_sel" "Creating local configuration"
  wait_for_container_log "$pair_remote_sel" "Creating local configuration"
  wait_for_container_log "$pair_site_sel" "Creating remote Config for: \"${pair_remote_site}\""
  wait_for_container_log "$pair_remote_sel" "Creating remote Config for: \"${pair_site}\""
}

request_init_ids() {
  init_site=$1
  init_remote_site=$2

  run_in_site "$init_site" sh -c \
    "curl -fsS -X POST 'http://mainzelliste:8080/Communicator/initIDs/${init_remote_site}' 2>/dev/null || curl -fsS 'http://mainzelliste:8080/Communicator/initIDs/${init_remote_site}'"
}

get_jobs() {
  site=$1
  run_in_site "$site" curl -s http://secureepilinker:8161/jobs/list || true
}

wait_for_successful_new_job() {
  site=$1
  remote_site=$2
  before_jobs=$3
  attempt=1

  echo "Waiting for successful new SecureEpiLinker job on ${site} for ${remote_site} ..."
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    jobs=$(get_jobs "$site")
    echo "[${site}->${remote_site}] jobs/list attempt ${attempt}/${MAX_ATTEMPTS}:"
    echo "$jobs"

    if [ "$jobs" != "$before_jobs" ] \
      && echo "$jobs" | grep -Eiq "$SUCCESS_REGEX" \
      && ! echo "$jobs" | grep -Eiq 'running|fault|error'; then
      echo "[${site}->${remote_site}] new job successful"
      LAST_SUCCESSFUL_JOBS=$(jq -n \
        --argjson before "$before_jobs" \
        --argjson after "$jobs" \
        '$after | with_entries(select($before[.key] == null))')
      return 0
    fi

    sleep "$POLL_SECONDS"
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for successful new job on ${site} for ${remote_site}" >&2
  return 1
}

match_pair() {
  site=$1
  remote_site=$2
  label=${3:-"${site}-${remote_site}"}

  echo
  echo "============================================================"
  echo "Matching ${label} (${site} -> ${remote_site})"
  echo "============================================================"

  echo "1/4 Waiting for pair config and calling SecureEpiLinker test endpoint"
  wait_for_pair_config "$site" "$remote_site"
  run_in_site "$site" curl -v -k "http://secureepilinker:8161/test/${remote_site}"

  echo
  echo "2/4 Triggering Mainzelliste matchMN"
  before_jobs=$(get_jobs "$site")
  run_in_site "$site" curl -s "http://mainzelliste:8080/Communicator/matchMN/trigger/${remote_site}"

  echo
  echo "3/4 Polling jobs/list"
  wait_for_successful_new_job "$site" "$remote_site" "$before_jobs"
  MATCH_JOBS=$LAST_SUCCESSFUL_JOBS

  echo
  echo "4/4 Fetching match status/results"
  MATCH_STATUS=$(run_in_site "$site" curl -fsS "http://mainzelliste:8080/Communicator/matchMN/status/${remote_site}")
  echo "$MATCH_STATUS"
  if ! echo "$MATCH_STATUS" | grep -q '"matchingStatus":"finished"'; then
    echo "Match status did not reach finished" >&2
    return 1
  fi
}

link_pair() {
  site=$1
  remote_site=$2
  label=${3:-"${site}-${remote_site}"}

  echo
  echo "============================================================"
  echo "Linking ${label} (${site} -> ${remote_site})"
  echo "============================================================"

  echo "1/5 Initializing Linkage Service IDs in remote Mainzelliste"
  request_init_ids "$remote_site" "$site"

  echo
  echo "2/5 Calling SecureEpiLinker peer test endpoint"
  wait_for_pair_config "$site" "$remote_site"
  run_in_site "$site" curl -v -k "http://secureepilinker:8161/test/${remote_site}"

  echo
  echo "3/5 Calling SecureEpiLinker Linkage Service test endpoint on both sites"
  run_in_site "$site" curl -v -k "http://secureepilinker:8161/testLS/${remote_site}"
  echo
  run_in_site "$remote_site" curl -v -k "http://secureepilinker:8161/testLS/${site}"

  echo
  echo "4/5 Triggering Mainzelliste linkMN"
  before_jobs=$(get_jobs "$site")
  run_in_site "$site" curl -s "http://mainzelliste:8080/Communicator/linkMN/trigger/${remote_site}"

  echo
  echo "5/5 Polling jobs/list"
  wait_for_successful_new_job "$site" "$remote_site" "$before_jobs"
  LINKAGE_JOBS=$LAST_SUCCESSFUL_JOBS
}

verify_linkage_ids() {
  verify_site=$1
  verify_remote_site=$2
  api_ids=/tmp/smpc-rl-api-ids.txt
  api_unique_ids=/tmp/smpc-rl-api-unique-ids.txt
  db_ids=/tmp/smpc-rl-db-ids.txt
  : > "$api_ids"

  page=1
  last_page=1
  while [ "$page" -le "$last_page" ]; do
    response=$(run_in_site "$verify_site" curl -fsS \
      -H 'Authorization: apiKey apiKey="testApi"' \
      "http://mainzelliste:8080/Communicator/getAllRecords/${verify_remote_site}?page=${page}&pageSize=5")
    echo "$response" | jq -r '.records[].id' >> "$api_ids"
    last_page=$(echo "$response" | jq -r '.lastPageNumber')
    page=$((page + 1))
  done

  postgres_container=$(container_for_service "${verify_site}-postgres")
  docker exec "$postgres_container" psql \
    -U mainzelliste-sel -d mainzelliste-sel -At \
    -c "select idstring from id where type='link-${verify_site}-${verify_remote_site}';" \
    | sort -u > "$db_ids"
  sort -u "$api_ids" > "$api_unique_ids"

  ID_TOTAL=$(wc -l < "$api_ids" | tr -d ' ')
  ID_UNIQUE=$(wc -l < "$api_unique_ids" | tr -d ' ')
  ID_PERSISTED=$(comm -12 "$api_unique_ids" "$db_ids" | wc -l | tr -d ' ')
  ID_MISSING=$(comm -23 "$api_unique_ids" "$db_ids" | wc -l | tr -d ' ')
  ID_NUMERIC=$(grep -Ec '^[0-9]+$' "$api_ids" || true)

  echo
  echo "Linkage ID verification"
  echo "  total:             $ID_TOTAL"
  echo "  unique:            $ID_UNIQUE"
  echo "  persisted:         $ID_PERSISTED"
  echo "  missing:           $ID_MISSING"
  echo "  numeric temporary: $ID_NUMERIC"

  if [ "$ID_TOTAL" -eq 0 ] \
    || [ "$ID_TOTAL" -ne "$ID_UNIQUE" ] \
    || [ "$ID_TOTAL" -ne "$ID_PERSISTED" ] \
    || [ "$ID_MISSING" -ne 0 ] \
    || [ "$ID_NUMERIC" -ne 0 ]; then
    echo "Linkage ID verification failed" >&2
    return 1
  fi
}

wait_for_beam
wait_for_linkage_service

echo "Initializing SiteB linkage IDs for the SiteA match ..."
request_init_ids SiteB SiteA

match_pair SiteA SiteB "SiteA-SiteB"
link_pair SiteA SiteB "SiteA-SiteB"
verify_linkage_ids SiteB SiteA
