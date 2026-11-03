#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Full-stack test on a throwaway k3d cluster: ArgoCD + External Secrets +
# this repo's ApplicationSet deploying a project's "ci" env, then a real
# build on a Kubernetes pod agent and a GitOps reload check.
#
# Usage: scripts/e2e.sh up|test|down|all <project>
#   up    cluster, ArgoCD, ESO, in-cluster git server, fake secrets, apps
#   test  wait for sync, verify JCasC live, JJB job + build, git reload
#   down  delete the cluster
#   all   up + test (+ down unless KEEP_CLUSTER=1)
#
# Kubelet disk eviction is relaxed: a throwaway cluster on a busy
# laptop or runner disk should not evict ArgoCD.
# Needs: docker, k3d, kubectl, helm, kustomize, yq, curl, git, python3.
# The image jenkins-<project>:ci must already exist locally.
##############################################################################
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.7}"
ESO_CHART_VERSION="${ESO_CHART_VERSION:-2.14.0}"
CLUSTER="${E2E_CLUSTER:-jenkins-gitops}"
JENKINS_PORT="${E2E_JENKINS_PORT:-18080}"
WAIT_APP="${E2E_WAIT_APP:-900}"

cmd="${1:?usage: $0 up|test|down|all <project>}"
project="${2:-}"
ns="$project-jenkins-ci"
app="$project-jenkins-ci"
state="$REPO_ROOT/.e2e"
pf_pids=()

cleanup() {
  local pid
  for pid in "${pf_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

port_forward() { # ns target local:remote
  kubectl -n "$1" port-forward "$2" "$3" >/dev/null 2>&1 &
  pf_pids+=("$!")
  local port="${3%%:*}"
  for _ in $(seq 1 30); do
    (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0
    sleep 1
  done
  die "port-forward $1/$2 did not come up"
}

diagnostics() {
  set +e
  echo "::group::diagnostics"
  kubectl get applications -A -o wide
  kubectl -n argocd get application "$app" -o yaml | yq '.status | del(.resources)'
  kubectl get pods -A -o wide
  kubectl -n "$ns" get externalsecret,secretstore,configmap,secret
  kubectl -n "$ns" describe externalsecret jenkins-jcasc-secrets | tail -20
  kubectl -n "$ns" get events --sort-by=.lastTimestamp | tail -40
  kubectl -n "$ns" logs sts/jenkins -c jenkins --tail=200
  kubectl -n "$ns" logs sts/jenkins -c config-reload --tail=50
  kubectl -n "$ns" logs sts/jenkins -c init --tail=50
  echo "::endgroup::"
}

# Publish the working tree (committed or not) to the in-cluster git server.
# Streams a tarball through kubectl exec and commits inside the pod: no
# port-forward to race against git-daemon start-up.
publish_tree() {
  local msg="$1" tmp
  tmp="$(mktemp -d)"
  (cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard \
    | xargs -0 -I{} cp --parents {} "$tmp/")
  [[ -z "${PUBLISH_HOOK:-}" ]] || (cd "$tmp" && eval "$PUBLISH_HOOK") || { rm -rf "$tmp"; return 1; }
  # shellcheck disable=SC2016 # $1 is expanded by the pod's sh
  tar -C "$tmp" -cf - . | kubectl -n git exec -i deploy/git-server -c git-daemon -- sh -euc '
    rm -rf /tmp/w && mkdir /tmp/w && tar -xof - -C /tmp/w && cd /tmp/w
    git init -q -b main
    git add -A
    git -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m "$1"
    git push -q --force /repos/jenkins-gitops.git main' sh "$msg" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

fake_secret_store() {
  local admin_pw json k
  admin_pw="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
  mkdir -p "$state"
  printf '%s' "$admin_pw" > "$state/$project-admin-password"
  json="$(
    {
      for k in $(secret_keys "$project"); do printf '%s\t%s\n' "$k" "dummy-$k"; done
      printf '%s\t%s\n' ci-admin-password "$admin_pw"
    } | python3 -c 'import json,sys; print(json.dumps(dict(l.rstrip("\n").split("\t",1) for l in sys.stdin)))'
  )"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  # ESO "fake" provider: same ExternalSecret path as 1Password, no backend.
  JSON="$json" yq -n '
    .apiVersion = "external-secrets.io/v1" |
    .kind = "SecretStore" |
    .metadata.name = "jcasc-store" |
    .spec.provider.fake.data = [{"key": "jenkins-jcasc", "value": strenv(JSON)}]
  ' | kubectl -n "$ns" apply -f -
}

up() {
  need docker k3d kubectl helm kustomize yq git python3
  [[ -n "$project" ]] || die "project required"
  docker image inspect "jenkins-$project:ci" >/dev/null 2>&1 \
    || die "build the image first: docker build -f image/Dockerfile --build-arg PROJECT=$project -t jenkins-$project:ci ."

  log "Creating k3d cluster $CLUSTER"
  k3d cluster list "$CLUSTER" >/dev/null 2>&1 \
    || k3d cluster create "$CLUSTER" --agents 0 --wait \
         --k3s-arg "--disable=traefik@server:0" --k3s-arg "--disable=metrics-server@server:0" \
         --k3s-arg "--kubelet-arg=eviction-hard=imagefs.available<1%,nodefs.available<1%@server:0" \
         --k3s-arg "--kubelet-arg=eviction-minimum-reclaim=imagefs.available=1%,nodefs.available=1%@server:0"
  k3d image import -c "$CLUSTER" "jenkins-$project:ci"

  log "Installing ArgoCD $ARGOCD_VERSION"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" >/dev/null

  log "Installing External Secrets $ESO_CHART_VERSION"
  helm upgrade --install external-secrets external-secrets \
    --repo https://charts.external-secrets.io --version "$ESO_CHART_VERSION" \
    -n external-secrets --create-namespace --wait --timeout 5m >/dev/null

  log "Starting in-cluster git server"
  kubectl apply -f "$REPO_ROOT/scripts/git-server.yaml" >/dev/null
  kubectl -n git rollout status deploy/git-server --timeout=180s
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
  kubectl -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s
  kubectl -n argocd rollout status sts/argocd-application-controller --timeout=300s

  publish_tree "e2e: working tree" || die "could not publish to the git server"

  log "Creating fake SecretStore for $ns"
  fake_secret_store

  log "Applying argocd/clusters/ci (limited to project $project)"
  kustomize build "$REPO_ROOT/argocd/clusters/ci" \
    | P="$project" yq '(select(.kind == "ApplicationSet") | .spec.generators[0].selector.matchLabels.project) = strenv(P)' \
    | kubectl apply -f -
}

wait_app() {
  local deadline=$((SECONDS + WAIT_APP)) sync health
  log "Waiting up to ${WAIT_APP}s for Application $app to be Synced/Healthy"
  while :; do
    sync="$(kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl -n argocd get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    [[ "$sync" == Synced && "$health" == Healthy ]] && break
    ((SECONDS < deadline)) || die "Application $app is sync=$sync health=$health"
    sleep 10
  done
  kubectl -n "$ns" rollout status sts/jenkins --timeout=600s
  log "Application $app: Synced/Healthy"
}

jenkins_api() { # path [curl args...]
  local path="$1"; shift
  curl -fsS -u "admin:$(cat "$state/$project-admin-password")" "http://127.0.0.1:$JENKINS_PORT$path" "$@"
}

run_smoke_build() {
  local venv="$state/venv" jjbini="$state/jjb.ini" deadline result console
  # Always the pinned JJB in a private venv, never whatever is on PATH.
  # JJB 6.4.3 imports pkg_resources, which new venvs no longer include.
  [[ -x "$venv/bin/jenkins-jobs" ]] || { python3 -m venv "$venv" && "$venv/bin/pip" install -q 'jenkins-job-builder==6.4.3' 'setuptools<81'; }
  cat > "$jjbini" <<EOF
[jenkins]
url=http://127.0.0.1:$JENKINS_PORT/
user=admin
password=$(cat "$state/$project-admin-password")
query_plugins_info=False
EOF
  log "Pushing tests/jjb with jenkins-jobs"
  "$venv/bin/jenkins-jobs" --conf "$jjbini" --flush-cache update "$REPO_ROOT/tests/jjb" 2>&1 | tail -3

  log "Building gitops-smoke on a Kubernetes pod agent"
  local jar crumb
  jar="$(mktemp)"
  crumb="$(jenkins_api /crumbIssuer/api/json -c "$jar" | yq -p json -r '.crumbRequestField + ":" + .crumb')"
  jenkins_api /job/gitops-smoke/build -X POST -b "$jar" -H "$crumb" -o /dev/null
  rm -f "$jar"
  deadline=$((SECONDS + 600))
  until result="$(jenkins_api '/job/gitops-smoke/1/api/json?tree=result' 2>/dev/null | yq -p json -r '.result // ""')" && [[ -n "$result" && "$result" != null ]]; do
    ((SECONDS < deadline)) || { kubectl -n "$ns" get pods; die "build did not finish"; }
    sleep 10
  done
  console="$(jenkins_api /job/gitops-smoke/1/consoleText)"
  echo "$console" | tail -15
  [[ "$result" == SUCCESS ]] || die "build result: $result"
  grep -q 'GITOPS_SMOKE_OK' <<<"$console" || die "smoke marker missing from console"
  grep -q '^SILO=ci$' <<<"$console" || die "global node env (SILO) not propagated"
  log "Build #1: SUCCESS on a pod agent"
}

# Change JCasC in git only, then check Jenkins picks it up with no manual
# step: git -> ArgoCD -> ConfigMap -> config-reload sidecar -> JCasC reload.
gitops_reload() {
  local marker="gitops-reload-$RANDOM$RANDOM" deadline desc
  log "GitOps reload: committing systemMessage '$marker'"
  PUBLISH_HOOK="yq -i '.jenkins.systemMessage = \"$marker\"' common/jcasc/00-jenkins.yaml" \
    publish_tree "e2e: change systemMessage" || die "publish failed"
  kubectl -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  deadline=$((SECONDS + 420))
  until desc="$(jenkins_api '/api/json?tree=description' | yq -p json -r '.description')" && [[ "$desc" == "$marker" ]]; do
    ((SECONDS < deadline)) || die "Jenkins systemMessage is '$desc', expected '$marker'"
    sleep 10
  done
  log "Jenkins reloaded the new JCasC from git without a restart"
  publish_tree "e2e: restore working tree" || die "publish failed"
}

test_stack() {
  need kubectl kustomize yq curl git python3
  [[ -n "$project" ]] || die "project required"
  trap 'diagnostics; cleanup' ERR
  wait_app
  port_forward "$ns" svc/jenkins "$JENKINS_PORT:8080"

  local rendered="$state/rendered-$project"
  rm -rf "$rendered"; render_env_dir "$project" ci "$rendered"
  if kubectl -n "$ns" logs sts/jenkins -c jenkins | real_severe; then
    die "controller logged SEVERE/ConfiguratorException"
  fi
  log "Checking the controller cannot reach the internet (no-internet-egress)"
  if kubectl -n "$ns" exec sts/jenkins -c jenkins -- curl -sS -m 10 -o /dev/null https://example.com 2>/dev/null; then
    die "controller reached the internet; NetworkPolicy not enforced"
  fi
  log "Egress blocked as expected"
  verify_live "http://127.0.0.1:$JENKINS_PORT" admin "$(cat "$state/$project-admin-password")" \
    "$rendered/casc" "$rendered/env"
  run_smoke_build
  gitops_reload
  log "PASS: $project end-to-end"
}

case "$cmd" in
  up) up ;;
  test) test_stack ;;
  down) k3d cluster delete "$CLUSTER" ;;
  all)
    up
    test_stack
    [[ -n "${KEEP_CLUSTER:-}" ]] || k3d cluster delete "$CLUSTER"
    ;;
  *) die "unknown command: $cmd" ;;
esac
