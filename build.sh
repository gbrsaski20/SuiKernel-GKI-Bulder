#!/usr/bin/env bash
# SuiKernel build for Redmi Note 14 4G (tanzanite, MT6789)
# Replaces the upstream builder script. Invoked by .github/workflows/build.yml
# (workflow_dispatch). Env from the workflow: KERNEL_BRANCH_ENV, ROOT_METHOD,
# RUNNER_TYPE, STATUS, BUILD_BOOTIMG, PERMISSIVE_MODE.
set -uo pipefail
workdir=$(pwd)

KERNEL_REPO="${KERNEL_REPO:-https://github.com/gbrsaski20/SuiKernel-android12-5.10}"
KERNEL_BRANCH="${KERNEL_BRANCH_ENV:-suikernel-stable}"
VARIANT="${ROOT_METHOD:-Vanilla}"
BRANCH_TAG="Stable"
LOCALVERSION_SUFFIX="-SuiKernel-${BRANCH_TAG}-${VARIANT}"
ANYKERNEL_REPO="https://github.com/LoggingNewMemory/SuiKernel-anykernel"
ANYKERNEL_BRANCH="gki"
RELEASE_REPO="gbrsaski20/SuiKernel-android12-5.10"

log() { echo "[$(date +%H:%M:%S)] $*"; }
trap 'log "FAILED at line $LINENO: $BASH_COMMAND"' ERR

log "=== SuiKernel CI build ==="
log "repo=$KERNEL_REPO branch=$KERNEL_BRANCH variant=$VARIANT"
log "cpus=$(nproc) ram=$(free -g | awk '/^Mem:/{print $2}')G"

########################################
# source
########################################
log "--- cloning kernel source (shallow) ---"
rm -rf ksrc
git clone -q --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" ksrc || {
  log "FATAL: source clone failed"; exit 1; }
cd ksrc
log "kernel version: $(make -s kernelversion 2>/dev/null || echo unknown)"

########################################
# toolchain (official SuiKernel clang)
########################################
if [ ! -x "$workdir/clang/bin/clang" ]; then
  log "--- cloning clang r416183b (lineage-20.0) ---"
  git clone -q --depth=1 -b lineage-20.0 \
    https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b \
    "$workdir/clang" || { log "FATAL: clang clone failed"; exit 1; }
fi
export PATH="$workdir/clang/bin:$PATH"
export CROSS_COMPILE=aarch64-linux-gnu-
clang --version | head -1

########################################
# configure + build
########################################
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-gbrsaski20}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-tanzanite-ci}"
export KBUILD_BUILD_TIMESTAMP="$(date)"
export KBUILD_MODPOST_WARN=1
touch .scmversion   # stops the git sha being appended to the version

FLAGS="-j$(nproc) ARCH=arm64 LLVM=1 LLVM_IAS=1 O=out CROSS_COMPILE=aarch64-linux-gnu-"

log "--- gki_defconfig ---"
make $FLAGS gki_defconfig > "$workdir/config.log" 2>&1 || {
  log "FATAL: defconfig failed"; tail -30 "$workdir/config.log"; exit 1; }

# vendor drivers (YamadaKSUCore) trip -Wunused-variable; gki_defconfig turns
# that into a hard error, which is not what we want for a custom build
sed -i 's/^CONFIG_WERROR=y/# CONFIG_WERROR is not set/' out/.config

# deterministic vermagic so the release is reproducible
sed -i '/^CONFIG_LOCALVERSION=/d' out/.config
echo "CONFIG_LOCALVERSION=\"${LOCALVERSION_SUFFIX}\"" >> out/.config
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' out/.config
log "localversion: $(grep -E '^CONFIG_LOCALVERSION' out/.config | tr '\n' ' ')"
log "lto: $(grep -E '^CONFIG_LTO_CLANG_(THIN|FULL)=y|^CONFIG_LTO_NONE=y' out/.config | tr '\n' ' ')"

log "--- compiling Image + modules (this takes a while) ---"
set -o pipefail
make $FLAGS Image modules 2>&1 | tee "$workdir/build.log"
rc=$?
if [ $rc -ne 0 ]; then
  log "FATAL: build failed (rc=$rc)"
  grep -nE "error:|Error [0-9]|undefined reference" "$workdir/build.log" | tail -20
  exit $rc
fi

KREL=$(make -s kernelrelease O=out)
log "kernelrelease: $KREL"
ls -lh out/arch/arm64/boot/Image

########################################
# package (SuiKernel anykernel, branch gki)
########################################
log "--- packaging anykernel ---"
cd "$workdir"
rm -rf ak3
git clone -q --depth=1 -b "$ANYKERNEL_BRANCH" "$ANYKERNEL_REPO" ak3 || {
  log "FATAL: anykernel clone failed"; exit 1; }
rm -rf ak3/.git
cp ksrc/out/arch/arm64/boot/Image ak3/Image
if [ -f ak3/anykernel.sh ]; then
  sed -i "s/^kernel.string=.*/kernel.string=${KREL}/" ak3/anykernel.sh
fi
ZIP="SuiKernel-${KREL}.zip"
( cd ak3 && zip -r9 "../$ZIP" ./* >/dev/null )
ls -lh "$ZIP"
cp ksrc/out/arch/arm64/boot/Image ./Image

########################################
# publish (workflow has no upload-artifact step)
########################################
TAG="ci-$(date +%Y%m%d-%H%M%S)"
log "--- publishing release $TAG ---"
if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
  gh release create "$TAG" "$ZIP" ./Image "$workdir/build.log" \
     -R "$RELEASE_REPO" -t "CI $KREL" -n "Automated build of $KREL ($VARIANT)" \
     && log "release created: https://github.com/$RELEASE_REPO/releases/tag/$TAG" \
     || log "WARN: release upload failed"
else
  log "WARN: gh or GH_TOKEN unavailable, zip stays on the runner"
fi

log "=== done ==="
