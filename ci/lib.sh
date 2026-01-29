#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ci/lib.sh - GitLab CI helper library
#
# Conventions:
# - Functions write their "return value" to stdout.
# - Functions return 0 on success, non-zero on error.
# - Errors are printed to stderr via die().
#
# Required env vars (in CI jobs):
# - CI_API_V4_URL
# - CI_PROJECT_ID
# - CI_PIPELINE_ID
# - CI_JOB_TOKEN
#
# External deps:
# - curl
# - jq (for JSON parsing)
# =============================================================================

# Default retry configuration
MAX_RETRIES="${MAX_RETRIES:-5}"  # Maximum number of retries (default: 5)
RETRY_DELAY="${RETRY_DELAY:-2}"  # Delay between retries in seconds (default: 2)

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

# require_bin <name>
#
# Args:
#   name: Binary name to verify exists on PATH.
#
# Returns (stdout):
#   (none)
#
# Exit:
#   0 if present, non-zero if missing.
require_bin() {
  local name="${1:?binary name required}"
  command -v "$name" >/dev/null 2>&1 || die "Missing required binary: $name"
}

# api_get <url>
#
# Args:
#   url: Fully qualified GitLab API v4 URL.
#
# Returns (stdout):
#   Response body.
#
# Exit:
#   Non-zero if HTTP request fails after retries.
api_get() {
    local url="${1:?url required}"
    local attempt=0

    while (( attempt < MAX_RETRIES )); do
        if curl --fail --silent --show-error \
            --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
            "$url"; then
            return 0  # Success
        fi

        attempt=$(( attempt + 1 ))
        warn "Failed to fetch URL: $url (attempt $attempt/$MAX_RETRIES)"

        if (( attempt < MAX_RETRIES )); then
            echo "Retrying in $RETRY_DELAY seconds..." >&2
            sleep "$RETRY_DELAY"
        fi
    done

    die "ERROR: Failed to fetch URL: $url after $MAX_RETRIES attempts"
}

# get_bridge_downstream <trigger_job_name>
#
# Resolve the downstream pipeline for a trigger bridge by name using:
#   GET /projects/:id/pipelines/:pipeline_id/bridges
#
# Args:
#   trigger_job_name: Name of the trigger job in THIS pipeline (e.g., "trigger_builder").
#
# Returns (stdout):
#   "<downstream_project_id> <downstream_pipeline_id>"
#
# Exit:
#   Non-zero if the bridge is not found or has no downstream pipeline.
get_bridge_downstream() {
  local trigger_job_name="${1:?trigger_job_name required}"

  local bridges_json
  bridges_json="$(api_get "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${CI_PIPELINE_ID}/bridges?per_page=100")"

  local ds_project_id ds_pipeline_id
  ds_project_id="$(echo "$bridges_json" | jq -r --arg n "$trigger_job_name" \
    '.[] | select(.name==$n) | .downstream_pipeline.project_id' | head -n 1)"
  ds_pipeline_id="$(echo "$bridges_json" | jq -r --arg n "$trigger_job_name" \
    '.[] | select(.name==$n) | .downstream_pipeline.id' | head -n 1)"

  [[ -n "$ds_project_id" && "$ds_project_id" != "null" ]] || die "Downstream project_id not found for bridge '$trigger_job_name'"
  [[ -n "$ds_pipeline_id" && "$ds_pipeline_id" != "null" ]] || die "Downstream pipeline_id not found for bridge '$trigger_job_name'"

  echo "${ds_project_id} ${ds_pipeline_id}"
}

# find_artifacts_job_id <project_id> <pipeline_id> <job_name_regex>
#
# In a given downstream pipeline, find the "best" job that produced artifacts.
# Selection strategy:
# - filters to jobs with artifacts_file != null
# - filters to job names matching regex
# - returns the maximum job id (typically the latest among those listed)
#
# Args:
#   project_id: Numeric GitLab project id that owns the pipeline.
#   pipeline_id: Numeric GitLab pipeline id.
#   job_name_regex: jq-compatible regex string (e.g. "run|publish_success|publish_failed|publish").
#
# Returns (stdout):
#   "<job_id>"
#
# Exit:
#   Non-zero if no matching job is found.
find_artifacts_job_id() {
  local project_id="${1:?project_id required}"
  local pipeline_id="${2:?pipeline_id required}"
  local job_name_regex="${3:?job_name_regex required}"

  local jobs_json
  jobs_json="$(api_get "${CI_API_V4_URL}/projects/${project_id}/pipelines/${pipeline_id}/jobs?per_page=100")"

  local job_id
  job_id="$(
    echo "$jobs_json" \
      | jq -r --arg re "$job_name_regex" '
          [ .[]
            | select(.artifacts_file != null)
            | select(.name | test($re))
            | .id ] | max // empty
        '
  )"

  [[ -n "$job_id" ]] || die "No artifacts job matched regex '$job_name_regex' in project=${project_id} pipeline=${pipeline_id}"
  echo "$job_id"
}

# download_job_artifacts_zip <project_id> <job_id> <out_zip_path>
#
# Args:
#   project_id: Numeric GitLab project id.
#   job_id: Numeric job id.
#   out_zip_path: Where to write the downloaded artifacts zip.
#
# Returns (stdout):
#   (none)
#
# Exit:
#   Non-zero if download fails after retries.
download_job_artifacts_zip() {
    local project_id="${1:?project_id required}"
    local job_id="${2:?job_id required}"
    local out_zip="${3:?out_zip_path required}"
    local attempt=0

    while (( attempt < MAX_RETRIES )); do
        if curl --fail --silent --show-error \
            --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
            "${CI_API_V4_URL}/projects/${project_id}/jobs/${job_id}/artifacts" \
            -o "$out_zip"; then
            return 0  # Success
        fi

        attempt=$(( attempt + 1 ))
        warn "Failed to download artifacts for project_id=$project_id, job_id=$job_id (attempt $attempt/$MAX_RETRIES)"

        if (( attempt < MAX_RETRIES )); then
            echo "Retrying in $RETRY_DELAY seconds..." >&2
            sleep "$RETRY_DELAY"
        fi
    done

    die "ERROR: Failed to download artifacts for project_id=$project_id, job_id=$job_id after $MAX_RETRIES attempts"
}

# upload_generic_package_file <project_id> <package_name> <version> <file_path> <dest_name>
#
# Upload a file to GitLab's Generic Package Registry.
#
# Args:
#   project_id: Numeric GitLab project id of the bus project.
#   package_name: Generic package name.
#   version: Package version (we use RUN_ID).
#   file_path: Local path to file.
#   dest_name: Destination filename in the package.
#
# Returns (stdout):
#   (none)
#
# Exit:
#   Non-zero if upload fails after retries.
upload_generic_package_file() {
    local project_id="${1:?project_id required}"
    local package_name="${2:?package_name required}"
    local version="${3:?version required}"
    local file_path="${4:?file_path required}"
    local dest_name="${5:?dest_name required}"
    local attempt=0

    while (( attempt < MAX_RETRIES )); do
        if curl --fail --silent --show-error \
            --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
            --upload-file "$file_path" \
            "${CI_API_V4_URL}/projects/${project_id}/packages/generic/${package_name}/${version}/${dest_name}"; then
            return 0  # Success
        fi

        attempt=$(( attempt + 1 ))
        warn "Failed to upload file=$file_path to project_id=$project_id, package=$package_name, version=$version (attempt $attempt/$MAX_RETRIES)"

        if (( attempt < MAX_RETRIES )); then
            echo "Retrying in $RETRY_DELAY seconds..." >&2
            sleep "$RETRY_DELAY"
        fi
    done

    die "ERROR: Failed to upload file=$file_path to project_id=$project_id, package=$package_name, version=$version after $MAX_RETRIES attempts"
}
