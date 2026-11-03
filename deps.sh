#!/bin/zsh
set -euo pipefail
GHOSTTY=8af6897c0afc63037a8a3efee4162a380e3a4572
ZMX=1d86b1c9fba47fa707a6f0e976b20510b07c1c26d0ed010b9414b2a2c5e6beef
ZIG=/opt/homebrew/opt/zig@0.16/bin/zig
C=~/Library/Caches/claudetty-deps; mkdir -p $C
fetch() {
  [[ -d $3/.git ]] || git clone -q https://github.com/$1 $3
  [[ $(git -C $3 rev-parse HEAD 2>/dev/null) == $2 ]] || { git -C $3 fetch -q --depth 1 origin $2 && git -C $3 checkout -q $2; }; }
fetch ghostty-org/ghostty $GHOSTTY $C/ghostty
P=${0:A:h}/ghostty.patch; B=$GHOSTTY-$(shasum $P | cut -c1-12)
[[ -f $C/ghostty/macos/GhosttyKit.xcframework/.built-$B ]] || {
  git -C $C/ghostty checkout -q -- . && git -C $C/ghostty apply $P
  (cd $C/ghostty && $ZIG build -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Doptimize=ReleaseFast)
  touch $C/ghostty/macos/GhosttyKit.xcframework/.built-$B; }
[[ -f $C/zmx/.ok-$ZMX ]] || {
  mkdir -p $C/zmx
  curl -fsSL https://github.com/neurosnap/zmx/releases/download/v0.8.1/zmx-0.8.1-macos-aarch64.tar.gz -o $C/zmx/zmx.tgz
  print "$ZMX  $C/zmx/zmx.tgz" | shasum -a 256 -c
  tar xzf $C/zmx/zmx.tgz -C $C/zmx
  touch $C/zmx/.ok-$ZMX; }
ln -sfn $C/ghostty/macos/GhosttyKit.xcframework ${0:A:h}/GhosttyKit.xcframework
