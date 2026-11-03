#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Install the pinned, checksum-verified CLI tools the scripts use
# (linux/amd64) into $TOOLS_DIR, default ~/.local/bin. kubectl, docker,
# git and python3 are expected from the runner image.
#
# Usage: scripts/install-tools.sh
##############################################################################

set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-$HOME/.local/bin}"
KUSTOMIZE_VERSION=v5.8.3
KUSTOMIZE_SHA256=cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61
YQ_VERSION=v4.54.1
YQ_SHA256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
K3D_VERSION=v5.9.0
K3D_SHA256=06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0
KUBECONFORM_VERSION=v0.8.0
KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
HELM_VERSION=v3.22.1
HELM_SHA256=896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$TOOLS_DIR"

# fetch <url> <sha256> <file>
fetch() {
  curl -fsSL --retry 3 -o "$work/$3" "$1"
  echo "$2  $work/$3" | sha256sum -c --quiet -
}

fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
  "$KUSTOMIZE_SHA256" kustomize.tgz
tar -xzf "$work/kustomize.tgz" -C "$TOOLS_DIR" kustomize

fetch "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_amd64" "$YQ_SHA256" yq
install -m 0755 "$work/yq" "$TOOLS_DIR/yq"

fetch "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/k3d-linux-amd64" "$K3D_SHA256" k3d
install -m 0755 "$work/k3d" "$TOOLS_DIR/k3d"

fetch "https://github.com/yannh/kubeconform/releases/download/$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz" \
  "$KUBECONFORM_SHA256" kubeconform.tgz
tar -xzf "$work/kubeconform.tgz" -C "$TOOLS_DIR" kubeconform

fetch "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" "$HELM_SHA256" helm.tgz
tar -xzf "$work/helm.tgz" -C "$work" linux-amd64/helm
install -m 0755 "$work/linux-amd64/helm" "$TOOLS_DIR/helm"

echo "==> Installed kustomize $KUSTOMIZE_VERSION, yq $YQ_VERSION, k3d $K3D_VERSION," \
  "kubeconform $KUBECONFORM_VERSION, helm $HELM_VERSION into $TOOLS_DIR"
