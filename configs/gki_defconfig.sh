#!/usr/bin/env bash

# Define target defconfig location
DEFCONFIG="arch/arm64/configs/gki_defconfig"

function apply_config(){
  cat "$1" >> "$2"
}

# Base KSU Config & Dependencies (always on — this fork is KernelSU-only)
echo "⚙️ Added KSU configuration"
cat >> $DEFCONFIG <<EOF
CONFIG_KSU=y
CONFIG_KPM=y
EOF

# SuSFS always on
echo "🔧 Mode: SuSFS Hook Enabled"
apply_config "$WORKDIR/configs/susfs.config" "$DEFCONFIG"

echo "⚙️ Adding Compatibility GKI Networking and Filesystem configs"
apply_config "$WORKDIR/configs/compat.config" "$DEFCONFIG"

echo "⚙️ Adding Universal Performance Tuning"
apply_config "$WORKDIR/configs/custom.config" "$DEFCONFIG"

case "$LTO" in
  thinLTO)
    echo "🔥 ThinLTO optimizations enabled"
    cat >> "$DEFCONFIG" <<EOF
CONFIG_LTO_NONE=n
CONFIG_LTO_CLANG_THIN=y
EOF
    ;;
  fullLTO)
    echo "🔥 Full LTO optimizations enabled"
    cat >> "$DEFCONFIG" <<EOF
CONFIG_LTO_NONE=n
CONFIG_LTO_CLANG_FULL=y
EOF
    ;;
  *)
    echo "ℹ️ LTO disabled or not specified"
    ;;
esac

# DroidSpaces + NetHunter always on
echo "🐳 DroidSpaces support enabled"
apply_config "$WORKDIR/configs/droidspaces.config" "$DEFCONFIG"

echo "🐉 NetHunter support enabled"
apply_config "$WORKDIR/configs/nethunter.config" "$DEFCONFIG"

echo "🔧 Disable useless debugging configs for performance and resources"
cat >> $DEFCONFIG <<EOF
# Disable useless debugging configs for performance and resources
CONFIG_RCU_TRACE=n
EOF
