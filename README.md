<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# jenkins-gitops-generic

> **Prototype only.** It is a proof of concept for running LF project
> Jenkins instances (OpenDaylight, ONAP, ...) from **one** GitOps repository
> with per-project config. It does not deploy anywhere real. All tests run
> on GitHub Actions against a throwaway [k3d](https://k3d.io) cluster.
> It does not touch any existing ODL/ONAP/LF infrastructure: Gerrit,
> Jenkins, OpenStack, 1Password, Nexus or `lfit/*` repos.

It follows [opensearch-project/jenkins-gitops][opensearch] and
[onap/jenkins-gitops][onap]. One difference: everything project-specific
sits under `projects/<name>/`, so adding a project means adding a
directory, not forking the repo.

[opensearch]: https://github.com/opensearch-project/jenkins-gitops
[onap]: https://github.com/onap/jenkins-gitops

## How it works

```text
git (this repo)
  └─ ArgoCD ApplicationSet: one Application per projects/*/envs/*/env.yaml
       whose `cluster:` matches the cluster's overlay (argocd/clusters/<c>)
        ├─ source 1: upstream jenkins Helm chart (env's chartVersion)
        │            values: common → project → env
        ├─ source 2: this repo ($repo ref for the value files)
        └─ source 3: kustomize projects/<p>/envs/<env>
             ├─ JCasC ConfigMaps (label jenkins-jenkins-config=true)
             │    → chart's config-reload sidecar → live JCasC reload
             ├─ jenkins-env-project / jenkins-env ConfigMaps (plain env)
             └─ ExternalSecret → SecretStore (1Password; fake in CI)
                  → Secret mounted at /run/secrets/jcasc → JCasC ${key}
```

Plugins are not installed at runtime. Each project's controller image is
built from `image/Dockerfile` with the plugin versions locked in
`projects/<p>/plugins.lock.txt`.

## Layout and layering

| Path | What |
| --- | --- |
| `common/values.yaml` | Chart values for all projects |
| `common/jcasc/` | Base JCasC: security, tools, globals |
| `common/features/<f>/` | Opt-in kustomize Components |
| `projects/<p>/project.yaml` | Name, Jenkins version, image |
| `projects/<p>/plugins*.txt` | Plugins and the pinned lock file |
| `projects/<p>/base/` | Clouds, credentials, files, authz |
| `projects/<p>/secret-keys.txt` | Keys the secret store must provide |
| `projects/<p>/envs/<env>/` | One Jenkins: env.yaml, values, features |
| `argocd/` | AppProjects, ApplicationSet, overlays |

Features in this prototype:

- `gerrit-trigger`: Gerrit server, from env vars.
- `lf-sso`: LF SAML realm. Used by real envs.
- `ci-local`: Used by the CI test only. It adds:
  - a local admin;
  - a Kubernetes pod agent cloud (`ci-pod`);
  - a NetworkPolicy that blocks internet egress.

JCasC values use two kinds of references:

- `${UPPER_CASE}`: plain settings from the `jenkins-env*` ConfigMaps.
- `${lower-case}`: secrets, one file per key from the ExternalSecret.

`scripts/check-secret-keys.sh` keeps `secret-keys.txt` in sync with the
JCasC that uses it.

## Add a project or an environment

1. Create `projects/<p>/`. Copy an existing project:
   - `project.yaml`, `plugins.txt`, `values.yaml`, `secret-keys.txt`;
   - `base/`, with its clouds, credentials and managed files.
2. Run `scripts/pin-plugins.sh <p>` to write `plugins.lock.txt`.
3. Add `argocd/base/projects/<p>.yaml` (AppProject) and list it in
   `argocd/base/kustomization.yaml`.
4. For each env, create `projects/<p>/envs/<env>/` with these files:
   - `env.yaml` (`project`, `env`, `cluster`, `chartVersion`);
   - `values.yaml`;
   - `kustomization.yaml` (components and `jenkins-env` literals);
   - `secret-store.yaml`, for real envs.
5. Add `<p>` to the matrix in `.github/workflows/e2e.yaml` and
   `build-image.yaml`.

ArgoCD picks up a new env from git. You do not edit the ApplicationSet.

## Run it

Needs Docker and `kubectl`. `scripts/install-tools.sh` installs pinned,
checksum-verified kustomize, yq, k3d, kubeconform and helm.

```bash
scripts/install-tools.sh                    # into ~/.local/bin
scripts/check-secret-keys.sh                # secret keys vs JCasC
scripts/render.sh                           # helm + kustomize + kubeconform
docker build -f image/Dockerfile --build-arg PROJECT=odl -t jenkins-odl:ci .
scripts/casc-smoke-test.sh odl sandbox      # boot one env, no network (~1 min)
scripts/e2e.sh all odl                      # full stack on k3d (~10 min)
```

`scripts/e2e.sh up|test|down|all <project>` runs these steps:

1. Creates a k3d cluster and installs ArgoCD and External Secrets.
2. Starts an in-cluster git server and pushes the working tree to it.
3. Fakes the 1Password store with dummy secrets.
4. Waits for ArgoCD to sync `<project>-jenkins-ci`.
5. Checks the live Jenkins:
   - no SEVERE errors in the logs;
   - every declared cloud, credential, managed file and Gerrit server
     exists;
   - internet egress is blocked.
6. Pushes `tests/jjb/` with Jenkins Job Builder and runs it on a
   Kubernetes pod agent.
7. Commits a JCasC change to the in-cluster git and checks that Jenkins
   reloads it without a restart.

## CI on GitHub Actions

- `lint.yaml` runs pre-commit and Zizmor. It also checks the secret keys,
  renders every env through kubeconform, and renders the ArgoCD overlays
  and JJB jobs.
- `e2e.yaml` runs three steps for each project:
  1. Builds the image.
  2. Smoke-tests every env with no network.
  3. Runs `e2e.sh all` on k3d.
- `build-image.yaml` pushes `ghcr.io/<owner>/jenkins-<p>` on `main`.

## Safety guards

The prototype carries production-shaped config: real Gerrit hosts,
OpenStack clouds and SSO. That config must never connect to anything
real, so three guards are in place:

- `casc-smoke-test.sh` runs containers with `--network none`. It also
  forces two settings:
  - `GERRIT_NO_CONNECTION_ON_STARTUP=true`;
  - `OPENSTACK_INSTANCE_CAP=0`.
- The k3d test deploys only `ci` envs. These use local auth and dummy
  secrets, and a NetworkPolicy denies internet egress. `e2e.sh` checks the
  NetworkPolicy.
- Real envs (`cluster: vexxhost`) appear only in
  `argocd/clusters/vexxhost`. No cluster applies that overlay.

## Known gaps (prototype)

- The ODL and ONAP data is a hand-written sample from
  `releng/builder` `jenkins-config` and `onap/jenkins-gitops`:
  - a few cloud templates;
  - credentials as shells only;
  - representative managed files.
- These names are placeholders:
  - the Gerrit users for real envs;
  - the 1Password vault names (`<p>-jenkins-<env>`);
  - the hostnames.
- There is no Vexxhost cluster. `argocd/clusters/vexxhost` and
  `argocd/bootstrap/root-app.yaml` are untested.
- No jobs are migrated. Jobs still come from JJB in `ci-management` /
  `releng/builder`.
- Adding a project needs a hand-written AppProject.
- The final home of the repo (for example `lfit/jenkins-gitops`) is not
  yet agreed.

## License

Apache-2.0. See [LICENSE](LICENSE).
