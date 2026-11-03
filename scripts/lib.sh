#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Helpers shared by scripts/*.sh (sourced, not executed).
##############################################################################

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

need() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null || die "missing tool: $t"
  done
}

# project_field <project> <yq-path>
project_field() {
  yq -r "$2" "$REPO_ROOT/projects/$1/project.yaml"
}

# render_env_dir <project> <env> <outdir>
# Writes the env's JCasC files to <outdir>/casc, the merged plain env vars
# to <outdir>/env (later ConfigMaps win, as with envFrom) and fails if two
# ConfigMaps ship the same JCasC file name.
render_env_dir() {
  local project="$1" env="$2" out="$3" built dupes
  local edir="$REPO_ROOT/projects/$project/envs/$env"
  [[ -d "$edir" ]] || die "no such env: $edir"
  mkdir -p "$out/casc"
  built="$(kustomize build "$edir")"

  dupes="$(yq -N 'select(.metadata.labels["jenkins-jenkins-config"] == "true") | .data | keys | .[]' \
    <<<"$built" | sort | uniq -d)"
  [[ -z "$dupes" ]] || die "JCasC file shipped by two ConfigMaps: $dupes"

  local f
  for f in $(yq -N 'select(.metadata.labels["jenkins-jenkins-config"] == "true") | .data | keys | .[]' <<<"$built"); do
    yq -N "select(.metadata.labels[\"jenkins-jenkins-config\"] == \"true\") | .data[\"$f\"] | select(. != null)" \
      <<<"$built" > "$out/casc/$f"
  done

  : > "$out/env"
  local cm
  for cm in jenkins-env-project jenkins-env; do
    yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$cm\") | .data | to_entries | .[] | .key + \"=\" + .value" \
      <<<"$built" >> "$out/env"
  done
}

# real_severe < jenkins-log: print SEVERE/ConfiguratorException lines that
# are not explained by the test's deliberate lack of internet access
# (update-site and cloud-API lookups). The exception text is on the SEVERE
# line or the one after it. Exit status is grep's: 0 if anything printed.
real_severe() {
  awk -v off='UnknownHostException|Temporary failure in name resolution|Network is unreachable|connect timed out|Connect timed out|Connection refused' '
    prev != "" { if ($0 !~ off) print prev; prev = "" }
    /SEVERE|ConfiguratorException/ { if ($0 !~ off) prev = $0 }
    END { if (prev != "") print prev }' | grep .
}

# secret_keys <project>: keys the env's secret store must provide
secret_keys() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$REPO_ROOT/projects/$1/secret-keys.txt" | grep -v '^$'
}

# expected_objects <cascdir> <envfile>: "kind=name" lines declared in JCasC
expected_objects() {
  local casc="$1" envfile="$2" line var val
  for f in "$casc"/*.yaml; do
    yq -N '
      (.jenkins.clouds // [] | .[] | to_entries | .[0].value.name | "cloud=" + .),
      (.credentials.system.domainCredentials // [] | .[].credentials[] | to_entries | .[0].value.id | "cred=" + .),
      (.unclassified.globalConfigFiles.configs // [] | .[] | to_entries | .[0].value.id | "file=" + .),
      (.unclassified["gerrit-trigger"].servers // [] | .[].name | "gerrit=" + .)
    ' "$f"
  done | while IFS= read -r line; do
    # Resolve ${VAR} / ${VAR:-default} from the env file, like JCasC does.
    while [[ "$line" =~ \$\{([A-Z_][A-Z0-9_]*)(:-([^}]*))?\} ]]; do
      var="${BASH_REMATCH[1]}"
      val="$(grep -m1 "^$var=" "$envfile" | cut -d= -f2- || true)"
      [[ -n "$val" ]] || val="${BASH_REMATCH[3]}"
      line="${line/"${BASH_REMATCH[0]}"/$val}"
    done
    echo "$line"
  done | sort -u
}

# HTTP client for live checks. casc-smoke-test.sh points this at curl
# inside the (network-less) container: JCURL=(docker exec -i <name> curl).
JCURL=(curl)

# live_objects <base-url> <user> <password>: the same lines, from Jenkins
live_objects() {
  local url="$1" user="$2" pw="$3" crumb
  # Crumbs are tied to the web session, so both calls share a cookie jar.
  crumb="$("${JCURL[@]}" -fsS -c /tmp/jg-cookies -u "$user:$pw" "$url/crumbIssuer/api/json" \
    | yq -p json -r '.crumbRequestField + ":" + .crumb')"
  "${JCURL[@]}" -fsS -b /tmp/jg-cookies -u "$user:$pw" -H "$crumb" "$url/scriptText" \
    --data-urlencode script@- < "$REPO_ROOT/scripts/live-objects.groovy" | sort -u
}

# verify_live <base-url> <user> <password> <cascdir> <envfile>
verify_live() {
  local missing
  missing="$(comm -23 <(expected_objects "$4" "$5") <(live_objects "$1" "$2" "$3"))"
  if [[ -n "$missing" ]]; then
    echo "Declared in JCasC but missing from Jenkins:" >&2
    echo "$missing" >&2
    return 1
  fi
  log "Live Jenkins has all $(expected_objects "$4" "$5" | wc -l) declared clouds/credentials/files/gerrit servers"
}
