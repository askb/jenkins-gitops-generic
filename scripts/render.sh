#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Render what ArgoCD would apply for every (or one) project/env, i.e. the
# jenkins chart with layered values plus the env's kustomize dir, and
# validate it with kubeconform. Output goes to rendered/<project>/<env>/.
#
# Usage: scripts/render.sh [<project> [<env>]]
##############################################################################

set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need helm kustomize yq kubeconform

CHART_REPO="${CHART_REPO:-https://charts.jenkins.io}"
cache="$REPO_ROOT/rendered/.charts"

render_one() {
  local project="$1" env="$2" edir out version tgz
  edir="$REPO_ROOT/projects/$project/envs/$env"
  out="$REPO_ROOT/rendered/$project/$env"
  version="$(yq -r .chartVersion "$edir/env.yaml")"
  tgz="$cache/jenkins-$version.tgz"
  [[ -f "$tgz" ]] || helm pull jenkins --repo "$CHART_REPO" --version "$version" -d "$cache" >/dev/null

  # The env.yaml fields must match its path; the ApplicationSet uses them.
  [[ "$(yq -r .project "$edir/env.yaml")" == "$project" ]] || die "$edir/env.yaml: project mismatch"
  [[ "$(yq -r .env "$edir/env.yaml")" == "$env" ]] || die "$edir/env.yaml: env mismatch"

  mkdir -p "$out"
  helm template jenkins "$tgz" --namespace "$project-jenkins-$env" \
    -f "$REPO_ROOT/common/values.yaml" \
    -f "$REPO_ROOT/projects/$project/values.yaml" \
    -f "$edir/values.yaml" > "$out/chart.yaml"
  kustomize build "$edir" > "$out/kustomize.yaml"

  # All JCasC comes from kustomize; any chart-made JCasC ConfigMap would
  # be applied alongside it and clash at boot.
  local chart_cms
  chart_cms="$(yq -N 'select(.metadata.labels["jenkins-jenkins-config"] == "true") | .metadata.name' "$out/chart.yaml")"
  [[ -z "$chart_cms" ]] || die "$project/$env: chart renders JCasC ConfigMaps: $chart_cms"

  # CRDs (ExternalSecret, SecretStore) have no bundled schema.
  kubeconform -strict -summary -ignore-missing-schemas \
    -kubernetes-version "${KUBE_VERSION:-1.33.0}" "$out/chart.yaml" "$out/kustomize.yaml"
  log "rendered $project/$env -> ${out#"$REPO_ROOT"/}"
}

mkdir -p "$cache"
if [[ $# -ge 2 ]]; then
  render_one "$1" "$2"
  exit 0
fi
if [[ $# -eq 1 ]]; then
  envyamls=("$REPO_ROOT/projects/$1"/envs/*/env.yaml)
else
  envyamls=("$REPO_ROOT"/projects/*/envs/*/env.yaml)
fi
[[ -f "${envyamls[0]}" ]] || die "no envs found"
for envyaml in "${envyamls[@]}"; do
  env="$(basename "$(dirname "$envyaml")")"
  project="$(basename "$(dirname "$(dirname "$(dirname "$envyaml")")")")"
  render_one "$project" "$env"
done
