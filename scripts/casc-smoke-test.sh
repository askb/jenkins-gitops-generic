#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Boot the project image with an env's rendered JCasC and dummy secrets, and
# fail on any configuration error. Fast feedback (~1-2 min) before the full
# k3d run.
#
# The container runs with --network none: rendering a production-shaped env
# must never reach a real Gerrit, OpenStack or SSO. Gerrit connections and
# OpenStack provisioning are also switched off explicitly.
#
# Usage: scripts/casc-smoke-test.sh <project> [env=ci] [image=jenkins-<project>:ci]
##############################################################################
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need docker kustomize yq curl

project="${1:?usage: $0 <project> [env] [image]}"
env="${2:-ci}"
image="${3:-jenkins-$project:ci}"
timeout="${SMOKE_TIMEOUT:-300}"
name="casc-smoke-$project-$env-$$"
work="$(mktemp -d)"

cleanup() {
  [[ -n "${KEEP:-}" ]] || docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

render_env_dir "$project" "$env" "$work"
mkdir -p "$work/secrets"
admin_pw="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
for k in $(secret_keys "$project"); do printf 'dummy-%s' "$k" > "$work/secrets/$k"; done
printf '%s' "$admin_pw" > "$work/secrets/ci-admin-password"
chmod -R a+rX "$work"
log "JCasC files: $(cd "$work/casc" && printf '%s ' *)"

# Appended last, so they win over the env's own values.
printf '%s\n' GERRIT_NO_CONNECTION_ON_STARTUP=true OPENSTACK_INSTANCE_CAP=0 >> "$work/env"

docker run -d --name "$name" --network none \
  --env-file "$work/env" \
  -e CASC_JENKINS_CONFIG=/casc -e SECRETS=/secrets \
  -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
  -v "$work/casc:/casc:ro" -v "$work/secrets:/secrets:ro" \
  "$image" >/dev/null

log "Waiting up to ${timeout}s for $image ($project/$env)"
deadline=$((SECONDS + timeout))
until docker logs "$name" 2>&1 | grep -q 'Jenkins is fully up and running'; do
  if docker logs "$name" 2>&1 | grep -qE 'BootFailure|ConfiguratorException|io\.jenkins\.plugins\.casc\.[A-Za-z]*Exception'; then
    docker logs "$name" 2>&1 | grep -E 'SEVERE|Exception:' | head -20
    die "JCasC failed to apply"
  fi
  [[ "$(docker inspect -f '{{.State.Running}}' "$name")" == true ]] || { docker logs "$name" 2>&1 | grep -E 'SEVERE|Exception:' | head -20; die "container exited"; }
  ((SECONDS < deadline)) || { docker logs "$name" 2>&1 | tail -60; die "timed out"; }
  sleep 5
done

if docker logs "$name" 2>&1 | real_severe; then
  die "SEVERE messages during startup"
fi

if [[ ! -f "$work/casc/45-ci-pods.yaml" ]]; then
  log "PASS: $project/$env JCasC applied cleanly"
  exit 0
fi
JCURL=(docker exec -i "$name" curl)
who="$("${JCURL[@]}" -fsS -u "admin:$admin_pw" "http://127.0.0.1:8080/whoAmI/api/json")"
yq -p json -e '.authenticated == true and .name == "admin"' <<<"$who" >/dev/null \
  || die "local admin login failed: $who"
verify_live "http://127.0.0.1:8080" admin "$admin_pw" "$work/casc" "$work/env"
log "PASS: $project/$env JCasC applied cleanly; admin login works"
