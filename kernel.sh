#!/bin/bash
# shellcheck disable=SC2154

# Script For Building Android arm64 Kernel
# Copyright (c) 2018-2021 Panchajanya1999
# Licensed under the Apache License, Version 2.0

# Kernel building script
WORKDIR="$(pwd)"
KERNEL="$WORKDIR/kernel"
VERSION_FILE="$WORKDIR/.kernel_build_version"

# Stop on errors, including pipeline failures
set -e
set -o pipefail

# Automatic release version
if [ ! -f "$VERSION_FILE" ]; then
    printf '0\n' > "$VERSION_FILE"
fi

BUILD_NUMBER=$(cat "$VERSION_FILE")

case "$BUILD_NUMBER" in
    ''|*[!0-9]*)
        echo "Invalid build counter: $VERSION_FILE" >&2
        exit 1
        ;;
esac

if [ "$BUILD_NUMBER" -eq 0 ]; then
    RELEASE="R1.7+"
else
    RELEASE="R1.7.$BUILD_NUMBER+"
fi

# Clone kernel source
git clone --single-branch --depth=1 \
    https://github.com/Kentanglu/kernel_xiaomi_sm6250 \
    -b 16-ksu "$KERNEL"

cd "$KERNEL"

# Random emoji from official Unicode list
EMOJI_FILE="$WORKDIR/emoji-test.txt"

if [ ! -s "$EMOJI_FILE" ]; then
    curl -fsSL \
        https://unicode.org/Public/emoji/latest/emoji-test.txt \
        -o "$EMOJI_FILE.tmp"
    mv "$EMOJI_FILE.tmp" "$EMOJI_FILE"
fi

RANDOM_EMOTE=$(python3 - "$EMOJI_FILE" <<'PYEMOJI'
import random
import sys

emojis = []

with open(sys.argv[1], encoding="utf-8") as file:
    for line in file:
        if "; fully-qualified" not in line:
            continue

        codepoints = line.split(";", 1)[0].strip()
        emoji = "".join(
            chr(int(code, 16))
            for code in codepoints.split()
        )
        emojis.append(emoji)

if not emojis:
    raise SystemExit("No fully-qualified Unicode emojis found")

print(random.choice(emojis))
PYEMOJI
)

export LOCALVERSION="/${RELEASE,,}${RANDOM_EMOTE}"

# Function to show messages
msger()
{
    while getopts ":n:e:" opt
    do
        case "${opt}" in
            n) printf "[*] $2 \n" ;;
            e) printf "[×] $2 \n"; return 1 ;;
        esac
    done
}

cdir()
{
    cd "$1" 2>/dev/null ||
        msger -e "The directory $1 doesn't exist!"
}

# Basic information
KERNEL_DIR="$(pwd)"
BASEDIR="$(basename "$KERNEL_DIR")"

# Detect KernelSU source
KSU=0
KERNELSU_VERSION="Not detected"
KSU_DIR=""

for dir in \
    "$KERNEL_DIR/KernelSU/kernel" \
    "$KERNEL_DIR/KernelSU-Next/kernel" \
    "$KERNEL_DIR/KernelSU" \
    "$KERNEL_DIR/KernelSU-Next" \
    "$KERNEL_DIR/drivers/kernelsu" \
    "$KERNEL_DIR/drivers/ksu"
do
    if [ -d "$dir" ] &&
       { [ -f "$dir/Makefile" ] ||
         [ -f "$dir/Kbuild" ] ||
         [ -f "$dir/Kconfig" ]; }; then
        KSU=1
        KSU_DIR="$dir"
        break
    fi
done

# Detect KernelSU version
if [ "$KSU" = 1 ]; then
    for version_file in \
        "$KSU_DIR/Makefile" \
        "$KSU_DIR/Kbuild" \
        "$KSU_DIR/include/linux/ksu_version.h" \
        "$KSU_DIR/ksu_version.h"
    do
        [ -f "$version_file" ] || continue

        detected=$(grep -E \
            'KSU_VERSION_TAG|KERNELSU_VERSION_TAG' \
            "$version_file" | head -n 1 || true)

        if [ -n "$detected" ]; then
            KERNELSU_VERSION=$(printf '%s\n' "$detected" |
                sed -E 's/.*[=:][[:space:]]*["'\'']?([^"'\'']+).*/\1/' |
                tr -d '[:space:]')

            if [ -n "$KERNELSU_VERSION" ]; then
                break
            fi
        fi
    done

    if [ "$KERNELSU_VERSION" = "Not detected" ]; then
        KERNELSU_VERSION=$(git -C "$KERNEL_DIR" describe \
            --tags --always 2>/dev/null ||
            echo "Source present, version unknown")
    fi

    VER="${RELEASE}-KSUN"
else
    VER="$RELEASE"
fi

# Kernel ZIP name
ZIPNAME="Sea"

# Build author and host
AUTHOR="Asyanx"
HOSTR="${RELEASE,,}"

# Architecture
ARCH=arm64

# Device information
MODEL="Redmi Note 9 Pro"
DEVICE="Miatoll"

# Defconfig
DEFCONFIG=vendor/xiaomi/miatoll_defconfig

# Compiler: clang or gcc
COMPILER=clang

# Build modules: 0 = NO, 1 = YES
MODULES=0

# Linker
LINKER=ld.lld

# Clean source: 0 = YES, 1 = NO
INCREMENTAL=0

# Upload ZIP to Telegram: 1 = YES, 0 = NO
PTTG=1

if [ "$PTTG" = 1 ]; then
    CHATID="-1001910249307"
    TOKEN="REPLACE_WITH_YOUR_NEW_TELEGRAM_BOT_TOKEN"
fi

# Generate full defconfig
DEF_REG=0

# Kernel image
FILES=Image.gz

# Build DTBO
BUILD_DTBO=0

# Sign ZIP
SIGN=0

if [ "$SIGN" = 1 ]; then
    if ! command -v java >/dev/null 2>&1; then
        SIGN=0
        msger -n "Install Java to enable ZIP signing"
    fi
fi

# Silence compilation
SILENCE=0

# Verbose build
VERBOSE=0

# Upload debug logs
LOG_DEBUG=0

# Environment
export DISTRO=$(source /etc/os-release && echo "${NAME}")
export KBUILD_BUILD_HOST=$(uname -a | awk '{print $2}')
TERM=xterm

# Kernel version and commit
KERVER=$(make kernelversion)
COMMIT_HEAD=$(git log --oneline -1)

# Build date
DATE=$(TZ=Asia/Jakarta date +"%Y%m%d-%T")
WAKTU=$(date +"%F-%S")

# Clone toolchains and AnyKernel
clone()
{
    echo " "

    if [ "$COMPILER" = "gcc" ]; then
        msger -n "|| Cloning GCC 9.3.0 baremetal ||"

        git clone --depth=1 \
            https://github.com/mvaisakh/gcc-arm64.git gcc64

        git clone --depth=1 \
            https://github.com/arter97/arm32-gcc.git gcc32

        GCC64_DIR="$KERNEL_DIR/gcc64"
        GCC32_DIR="$KERNEL_DIR/gcc32"
    fi

    if [ "$COMPILER" = "clang" ]; then
        TC_DIR="$KERNEL_DIR/clang-llvm"

        git clone --depth=1 \
            https://gitlab.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-r547379.git \
            "$TC_DIR"

        export LD_LIBRARY_PATH="$TC_DIR/bin/:$LD_LIBRARY_PATH"
        export LLVM=1
        export LLVM_IAS=1
    fi

    msger -n "|| Cloning AnyKernel ||"

    git clone --depth=1 \
        https://github.com/Kentanglu/AnyKernel33 \
        -b miatoll AnyKernel3

    if [ "$BUILD_DTBO" = 1 ]; then
        msger -n "|| Cloning libufdt ||"

        git clone \
            https://android.googlesource.com/platform/system/libufdt \
            "$KERNEL_DIR/scripts/ufdt/libufdt"
    fi
}

# Export build variables
exports()
{
    KBUILD_BUILD_USER="$AUTHOR"
    KBUILD_BUILD_HOST="$HOSTR"
    SUBARCH="$ARCH"

    if [ "$COMPILER" = "clang" ]; then
        KBUILD_COMPILER_STRING=$(
            "$TC_DIR/bin/clang" --version |
            head -n 1 |
            perl -pe 's/\(http.*?\)//gs' |
            sed -e 's/  */ /g' -e 's/[[:space:]]*$//'
        )

        PATH="$TC_DIR/bin/:$PATH"

    elif [ "$COMPILER" = "gcc" ]; then
        KBUILD_COMPILER_STRING=$(
            "$GCC64_DIR/bin/aarch64-elf-gcc" --version |
            head -n 1
        )

        PATH="$GCC64_DIR/bin/:$GCC32_DIR/bin/:/usr/bin:$PATH"
    fi

    BOT_MSG_URL="https://api.telegram.org/bot$TOKEN/sendMessage"
    BOT_BUILD_URL="https://api.telegram.org/bot$TOKEN/sendDocument"

    PROCS=$(nproc --all)

    export KBUILD_BUILD_USER ARCH SUBARCH PATH \
        KBUILD_COMPILER_STRING BOT_MSG_URL \
        BOT_BUILD_URL PROCS
}

# Telegram text message
tg_post_msg()
{
    curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$CHATID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$1"
}

# Upload file and checksum
tg_post_build()
{
    MD5CHECK=$(md5sum "$1" | cut -d' ' -f1)

    curl --progress-bar \
        -F "document=@$1" "$BOT_BUILD_URL" \
        -F "chat_id=$CHATID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=Markdown" \
        -F "caption=$2 | MD5 Checksum: \`$MD5CHECK\`"
}

# Build kernel
build_kernel()
{
    if [ "$INCREMENTAL" = 0 ]; then
        msger -n "|| Cleaning Sources ||"
        make mrproper
        rm -rf out
    fi

    # Emoji beside the build title
    if [ "$KSU" = 1 ]; then
        tg_post_msg \
            "<b>Sea CI Build Triggered $RANDOM_EMOTE</b>%0A<b>Docker OS:</b> <code>$DISTRO</code>%0A<b>Kernel Version:</b> <code>$KERVER</code>%0A<b>Date:</b> <code>$(TZ=Asia/Jakarta date)</code>%0A<b>Device:</b> <code>$MODEL [$DEVICE]</code>%0A<b>Host Core Count:</b> <code>$PROCS</code>%0A<b>Compiler Used:</b> <code>$KBUILD_COMPILER_STRING</code>%0A<b>KernelSU:</b> <code>$KERNELSU_VERSION</code>%0A<b>Top Commit:</b> <code>$COMMIT_HEAD</code>"
    else
        tg_post_msg \
            "<b>Sea CI Build Triggered $RANDOM_EMOTE</b>%0A<b>Docker OS:</b> <code>$DISTRO</code>%0A<b>Kernel Version:</b> <code>$KERVER</code>%0A<b>Date:</b> <code>$(TZ=Asia/Jakarta date)</code>%0A<b>Device:</b> <code>$MODEL [$DEVICE]</code>%0A<b>Host Core Count:</b> <code>$PROCS</code>%0A<b>Compiler Used:</b> <code>$KBUILD_COMPILER_STRING</code>%0A<b>KernelSU:</b> <code>Not detected</code>%0A<b>Top Commit:</b> <code>$COMMIT_HEAD</code>"
    fi

    make O=out "$DEFCONFIG"

    if [ "$DEF_REG" = 1 ]; then
        cp .config "arch/arm64/configs/$DEFCONFIG"
        git add "arch/arm64/configs/$DEFCONFIG"

        git commit -m "$DEFCONFIG: Regenerate

This is an auto-generated commit"
    fi

    BUILD_START=$(date +"%s")

    if [ "$COMPILER" = "clang" ]; then
        MAKE+=(
            CC=clang
            LD=ld.lld
            AS=llvm-as
            AR=llvm-ar
            NM=llvm-nm
            OBJCOPY=llvm-objcopy
            OBJDUMP=llvm-objdump
            STRIP=llvm-strip
            CROSS_COMPILE=aarch64-linux-gnu-
            CROSS_COMPILE_ARM32=arm-linux-gnueabi-
        )

    elif [ "$COMPILER" = "gcc" ]; then
        MAKE+=(
            CROSS_COMPILE_ARM32=arm-eabi-
            CROSS_COMPILE=aarch64-elf-
            AR=aarch64-elf-ar
            OBJDUMP=aarch64-elf-objdump
            STRIP=aarch64-elf-strip
            NM=aarch64-elf-nm
            OBJCOPY=aarch64-elf-objcopy
            LD=aarch64-elf-$LINKER
        )
    fi

    if [ "$SILENCE" = 1 ]; then
        MAKE+=( -s )
    fi

    msger -n "|| Started Compilation ||"

    make -kj"$PROCS" O=out \
        V="$VERBOSE" \
        "${MAKE[@]}" 2>&1 | tee error.log

    if [ "$MODULES" = 1 ]; then
        msger -n "|| Started Compiling Modules ||"

        make -j"$PROCS" O=out \
            "${MAKE[@]}" modules_prepare

        make -j"$PROCS" O=out \
            "${MAKE[@]}" modules \
            INSTALL_MOD_PATH="$KERNEL_DIR/out/modules"

        make -j"$PROCS" O=out \
            "${MAKE[@]}" modules_install \
            INSTALL_MOD_PATH="$KERNEL_DIR/out/modules"

        find "$KERNEL_DIR/out/modules" \
            -type f -iname '*.ko' \
            -exec cp {} AnyKernel3/modules/system/lib/modules/ \;
    fi

    BUILD_END=$(date +"%s")
    DIFF=$((BUILD_END - BUILD_START))

    if [ -f "$KERNEL_DIR/out/arch/arm64/boot/$FILES" ]; then
        msger -n "|| Kernel successfully compiled ||"

        if [ "$BUILD_DTBO" = 1 ]; then
            msger -n "|| Building DTBO ||"

            tg_post_msg "<code>Building DTBO...</code>"

            python2 "$KERNEL_DIR/scripts/ufdt/libufdt/utils/src/mkdtboimg.py" \
                create "$KERNEL_DIR/out/arch/arm64/boot/dtbo.img" \
                --page_size=4096 \
                "$KERNEL_DIR/out/arch/arm64/boot/dts/$DTBO_PATH"
        fi

        gen_zip
    else
        if [ "$PTTG" = 1 ]; then
            tg_post_build "error.log" \
                "Build failed after $((DIFF / 60)) minute(s) and $((DIFF % 60)) seconds"
        fi

        return 1
    fi
}

# Generate flashable ZIP
gen_zip()
{
    msger -n "|| Zipping into a flashable zip ||"

    mv "$KERNEL_DIR/out/arch/arm64/boot/$FILES" \
        "AnyKernel3/$FILES"

    if [ "$BUILD_DTBO" = 1 ]; then
        mv "$KERNEL_DIR/out/arch/arm64/boot/dtbo.img" \
            "AnyKernel3/dtbo.img"
    fi

    cdir AnyKernel3

    ZIP_FINAL="$ZIPNAME-$DEVICE-$VER-$WAKTU"

    zip -r "$ZIP_FINAL.zip" . \
        -x ".git*" \
        -x "README.md" \
        -x "*.zip"

    if [ ! -s "$ZIP_FINAL.zip" ]; then
        msger -e "ZIP file not found or empty: $ZIP_FINAL.zip"
        return 1
    fi

    if ! unzip -t "$ZIP_FINAL.zip" >/dev/null 2>&1; then
        msger -e "ZIP file is corrupted: $ZIP_FINAL.zip"
        return 1
    fi

    # Sign ZIP if enabled
    if [ "$SIGN" = 1 ]; then
        if [ "$PTTG" = 1 ]; then
            msger -n "|| Signing ZIP ||"
            tg_post_msg "<code>Signing ZIP file...</code>"
        fi

        curl -fsSL -o zipsigner-3.0.jar \
            "https://github.com/Magisk-Modules-Repo/zipsigner/raw/master/bin/zipsigner-3.0-dexed.jar"

        java -jar zipsigner-3.0.jar \
            "$ZIP_FINAL.zip" "$ZIP_FINAL-signed.zip"

        ZIP_FINAL="$ZIP_FINAL-signed"

        if [ ! -s "$ZIP_FINAL.zip" ]; then
            msger -e "Signed ZIP was not created"
            return 1
        fi

        if ! unzip -t "$ZIP_FINAL.zip" >/dev/null 2>&1; then
            msger -e "Signed ZIP is corrupted"
            return 1
        fi
    fi

    # Advance version only after ZIP validation
    NEXT_BUILD_NUMBER=$((BUILD_NUMBER + 1))
    printf '%s\n' "$NEXT_BUILD_NUMBER" > "$VERSION_FILE"

    # Upload ZIP to Telegram
    if [ "$PTTG" = 1 ]; then
        tg_post_build "$ZIP_FINAL.zip" \
            "Build took: $((DIFF / 60)) minute(s) and $((DIFF % 60)) second(s)"
    fi

    cd ..
}

clone
exports
build_kernel

if [ "$LOG_DEBUG" = 1 ]; then
    tg_post_build "error.log" "Debug Mode Logs"
fi
