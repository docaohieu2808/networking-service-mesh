#!/usr/bin/env bash
# Install pinned CLI tools into /usr/local/bin, verifying a SHA-256 for each download.
# Usage: install-tools.sh kind helm istioctl kubeconform
# Versions and checksums are pinned here on purpose; bump both together.
set -euo pipefail

KIND_VERSION=v0.33.0
KIND_SHA256=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
HELM_VERSION=v4.3.1
HELM_SHA256=0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b
ISTIO_VERSION=1.30.7
ISTIO_SHA256=485d08aef8906023a014f725fbd6e12674661977c17007802137f40ab1fba85d
KUBECONFORM_VERSION=v0.8.0
KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

fetch() { # url sha256 outfile
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - >/dev/null
}

for tool in "$@"; do
  case "$tool" in
    kind)
      fetch "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" "$KIND_SHA256" "$tmp/kind"
      sudo install -m 0755 "$tmp/kind" /usr/local/bin/kind ;;
    helm)
      fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" "$HELM_SHA256" "$tmp/helm.tgz"
      tar -xzf "$tmp/helm.tgz" -C "$tmp" linux-amd64/helm
      sudo install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm ;;
    istioctl)
      fetch "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-linux-amd64.tar.gz" "$ISTIO_SHA256" "$tmp/istioctl.tgz"
      tar -xzf "$tmp/istioctl.tgz" -C "$tmp" istioctl
      sudo install -m 0755 "$tmp/istioctl" /usr/local/bin/istioctl ;;
    kubeconform)
      fetch "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" "$KUBECONFORM_SHA256" "$tmp/kc.tgz"
      tar -xzf "$tmp/kc.tgz" -C "$tmp" kubeconform
      sudo install -m 0755 "$tmp/kubeconform" /usr/local/bin/kubeconform ;;
    *) echo "unknown tool $tool" >&2; exit 2 ;;
  esac
  echo "installed $tool"
done
