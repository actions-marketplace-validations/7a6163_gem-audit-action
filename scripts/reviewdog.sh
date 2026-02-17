#!/usr/bin/env bash

# Called by the "Report findings with reviewdog" step in action.yml.
# Expects the following environment variables:
#   GEM_AUDIT_BIN        — path to the gem-audit binary
#   WORKING_DIR          — project directory (e.g. ".")
#   GEMFILE_LOCK         — lockfile filename (e.g. "Gemfile.lock")
#   INPUT_SEVERITY       — minimum severity (optional)
#   INPUT_STRICT         — "true" to enable strict mode
#   INPUT_MAX_DB_AGE     — max advisory DB age in days (optional)
#   INPUT_IGNORE         — space-separated advisory IDs to ignore (optional)
#   REVIEWDOG_REPORTER   — reviewdog reporter name
#   REVIEWDOG_FILTER_MODE — reviewdog filter mode
#   RUNNER_TEMP          — GitHub Actions temp directory

# Normalize lockfile path (strip leading ./ so reviewdog matches PR diff)
lockfile="${WORKING_DIR}/${GEMFILE_LOCK}"
lockfile="${lockfile#./}"

# Build gem-audit arguments
args=("check")
args+=("${WORKING_DIR}")
args+=("--gemfile-lock" "${GEMFILE_LOCK}")
args+=("--format" "json")

if [ -n "${INPUT_SEVERITY}" ]; then
  args+=("--severity" "${INPUT_SEVERITY}")
fi

if [ "${INPUT_STRICT}" = "true" ]; then
  args+=("--strict")
fi

if [ -n "${INPUT_MAX_DB_AGE}" ]; then
  args+=("--max-db-age" "${INPUT_MAX_DB_AGE}")
fi

if [ -n "${INPUT_IGNORE}" ]; then
  # Intentionally unquoted to allow word-splitting for multiple IDs
  # shellcheck disable=SC2086
  args+=("--ignore" ${INPUT_IGNORE})
fi

# Run gem-audit in JSON mode
set +e
json_output=$("${GEM_AUDIT_BIN}" "${args[@]}" 2>"${RUNNER_TEMP}/gem-audit-stderr.log")
audit_exit=$?
set -e

if [ -s "${RUNNER_TEMP}/gem-audit-stderr.log" ]; then
  echo "::group::gem-audit stderr"
  cat "${RUNNER_TEMP}/gem-audit-stderr.log"
  echo "::endgroup::"
fi

if [ -z "$json_output" ]; then
  echo "No findings to report."
  exit 0
fi

rdjsonl_file="${RUNNER_TEMP}/gem-audit-rdjsonl.jsonl"
: > "$rdjsonl_file"

# Unpatched gems
while IFS= read -r result; do
  gem_name=$(echo "$result" | jq -r '.gem.name')
  gem_version=$(echo "$result" | jq -r '.gem.version')
  id=$(echo "$result" | jq -r '.advisory.id // empty')
  title=$(echo "$result" | jq -r '.advisory.title // "Unknown vulnerability"')
  url=$(echo "$result" | jq -r '.advisory.url // empty')
  criticality=$(echo "$result" | jq -r '.advisory.criticality // "unknown"' | tr '[:upper:]' '[:lower:]')

  case "$criticality" in
    critical|high) severity="ERROR" ;;
    medium)        severity="WARNING" ;;
    *)             severity="INFO" ;;
  esac

  message="${id}: ${title}"
  line=$(grep -Fn "    ${gem_name} (${gem_version})" "$lockfile" 2>/dev/null | head -1 | cut -d: -f1 || true)

  if [ -n "$line" ]; then
    location=$(jq -n -c --arg path "$lockfile" --argjson line "$line" \
      '{path: $path, range: {start: {line: $line, column: 1}}}')
  else
    location=$(jq -n -c --arg path "$lockfile" '{path: $path}')
  fi

  if [ -n "$id" ] && [ -n "$url" ]; then
    code_obj=$(jq -n -c --arg value "$id" --arg url "$url" '{value: $value, url: $url}')
  elif [ -n "$id" ]; then
    code_obj=$(jq -n -c --arg value "$id" '{value: $value}')
  else
    code_obj="{}"
  fi

  jq -n -c \
    --arg message "$message" \
    --arg severity "$severity" \
    --argjson location "$location" \
    --argjson code "$code_obj" \
    '{message: $message, location: $location, severity: $severity, code: $code}' \
    >> "$rdjsonl_file"
done < <(echo "$json_output" | jq -c '.results // [] | .[] | select(.type == "unpatched_gem")')

# Insecure sources
while IFS= read -r result; do
  source_url=$(echo "$result" | jq -r '.advisory.url // .gem.name // empty')

  if [ -z "$source_url" ]; then
    continue
  fi

  line=$(grep -Fn "$source_url" "$lockfile" 2>/dev/null | head -1 | cut -d: -f1 || true)

  message="Insecure source: ${source_url}"

  if [ -n "$line" ]; then
    location=$(jq -n -c --arg path "$lockfile" --argjson line "$line" \
      '{path: $path, range: {start: {line: $line, column: 1}}}')
  else
    location=$(jq -n -c --arg path "$lockfile" '{path: $path}')
  fi

  jq -n -c \
    --arg message "$message" \
    --argjson location "$location" \
    '{message: $message, location: $location, severity: "WARNING"}' \
    >> "$rdjsonl_file"
done < <(echo "$json_output" | jq -c '.results // [] | .[] | select(.type == "insecure_source")')

# Pipe collected findings to reviewdog
if [ -s "$rdjsonl_file" ]; then
  cat "$rdjsonl_file" | reviewdog \
    -f=rdjsonl \
    -name=gem-audit \
    -reporter="${REVIEWDOG_REPORTER}" \
    -filter-mode="${REVIEWDOG_FILTER_MODE}" \
    -fail-level=none \
    -level=warning
else
  echo "No findings to report to reviewdog."
fi
