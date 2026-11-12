#!/bin/zsh
set -euo pipefail
GHOSTTY=53e55147bbbb0157672dac0228aa7744e881f1fa
ZMX=a35f00a2118b15a5e9d522a43035c8d7487df9b7
ZIG=/opt/homebrew/opt/zig@0.17/bin/zig
ZMX08=1d86b1c9fba47fa707a6f0e976b20510b07c1c26d0ed010b9414b2a2c5e6beef
C=~/Library/Caches/claudetty-deps; G=$C/ghostty-1.4; Z=$C/zmx-1.0; mkdir -p $C
fetch() {
  [[ -d $3/.git ]] || git clone -q https://github.com/$1 $3
  [[ $(git -C $3 rev-parse HEAD 2>/dev/null) == $2 ]] || { git -C $3 fetch -q --depth 1 origin $2 && git -C $3 checkout -qf $2; }; }
fetch ghostty-org/ghostty $GHOSTTY $G
P=${0:A:h}/ghostty.patch; B=$GHOSTTY-$(shasum $P | cut -c1-12)
[[ -f $G/macos/GhosttyKit.xcframework/.built-$B ]] || {
  rm -f "${G:?}"/macos/GhosttyKit.xcframework/.built-*(N)
  git -C $G checkout -q -- . && git -C $G apply $P
  (cd $G && $ZIG build -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Doptimize=ReleaseFast)
  touch $G/macos/GhosttyKit.xcframework/.built-$B; }
fetch neurosnap/zmx $ZMX $Z
Q=${0:A:h}/zmx.patch; B=$ZMX-$B-$(shasum $Q | cut -c1-12)
[[ -f $Z/.built-$B ]] || {
  rm -f "${Z:?}"/.built-*(N)
  git -C $Z checkout -q -- . && git -C $Z apply $Q
  (cd $Z && $ZIG build -Doptimize=ReleaseSafe --fork=../${G:t})
  touch $Z/.built-$B; }
[[ -f $C/zmx/.ok-$ZMX08 ]] || {
  mkdir -p $C/zmx
  curl -fsSL https://github.com/neurosnap/zmx/releases/download/v0.8.1/zmx-0.8.1-macos-aarch64.tar.gz -o $C/zmx/zmx.tgz
  print "$ZMX08  $C/zmx/zmx.tgz" | shasum -a 256 -c
  tar xzf $C/zmx/zmx.tgz -C $C/zmx
  touch $C/zmx/.ok-$ZMX08; }
ln -sfn $G/macos/GhosttyKit.xcframework ${0:A:h}/GhosttyKit.xcframework
