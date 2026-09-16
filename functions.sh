#!/usr/bin/env bash

# Only GKI 5.10 (Android 12 LTS) is supported by this fork — the other
# lines' branch/commit maps were dropped along with everything else.
declare -A ANDROID_RELEASE_FOR_KVER=(
  ["5.10"]="12"
)

declare -A GKI_BRANCH=(
  ["5.10"]="android12-5.10"
)

declare -A GKI_AOSP_BRANCH=(
  ["5.10"]="android12-5.10-lts"
)

declare -A GKI_SUSFS_BRANCH=(
  ["5.10"]="gki-android12-5.10"
)

# No pinned SuSFS commit for 5.10 — tracks branch tip (same as upstream).
declare -A GKI_SUSFS_COMMIT=()

android_release_for_version() {
  echo "${ANDROID_RELEASE_FOR_KVER[$1]:-unknown}"
}

resolve_kernel_source() {
  local ver="$1"
  local branch="${GKI_AOSP_BRANCH[$ver]:-}"
  local kmi="${GKI_BRANCH[$ver]:-}"

  if [ -z "$branch" ]; then
    error "No AOSP GKI branch mapped for KERNEL_VERSION='$ver' (see GKI_AOSP_BRANCH in functions.sh)"
    exit 1
  fi

  echo "https://android.googlesource.com/kernel/common|$branch|$kmi"
}

resolve_susfs_branch() {
  local ver="$1"
  local branch="${GKI_SUSFS_BRANCH[$ver]:-}"

  if [ -z "$branch" ]; then
    error "No susfs4ksu branch mapped for KERNEL_VERSION='$ver'"
    exit 1
  fi

  echo "$branch"
}

apply_ntsync_compat_patch() {
  local branch="$1"
  local url="https://github.com/WildKernels/kernel_patches/raw/main/common/ntsync/ntsync_compat_${branch}.patch"

  if command curl -LSsf -o /dev/null "$url" 2>/dev/null; then
    curl -LSs "$url" | patch -p1 --fuzz=3
    success "NTSync compat patch applied for $branch"
  else
    warning "No NTSync compat patch found for $branch"
  fi
}

install_ksu() {
  local REPO="$1"
  local REF="$2"
  local URL

  if [ -z "$REPO" ] || [ -z "$REF" ]; then
    echo "Usage: install_ksu <user/repo> <ref>"
    exit 1
  fi

  URL="https://raw.githubusercontent.com/$REPO/$REF/kernel/setup.sh"
  log "Installing KernelSU from $REPO | $REF"
  curl -LSs "$URL" | bash -s "$REF"
}

susfs_included() {
  [ "$KSU_SUSFS" == "true" ]
  return $?
}

simplify_gh_url() {
  local URL="$1"
  echo "$URL" | sed "s|https://github.com/||g" | sed "s|.git||g"
}

config() {
  $KSRC/scripts/config --file $DEFCONFIG_FILE $@
}

log() {
  echo -e "[*] $*"
}
info() { log "$@"; }

success() {
  echo -e "[+] $*"
}

warning() {
  echo -e "[!] $*"
}

error() {
  echo -e "[-] $*"
}

retry() {
    local max_attempts=5
    local delay=2
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi

        error "Command failed (attempt $attempt/$max_attempts): $*"
        log "Retrying in ${delay}s..."
        sleep $delay
        delay=$((delay + 1))
        attempt=$((attempt + 1))
    done

    error "Command failed after $max_attempts attempts: $*" >&2
    return 1
}

curl() { retry command curl "$@"; }
wget() { retry command wget "$@"; }

bash() {
    case "$*" in

        *curl*|*wget*|*git*clone*|*git*fetch*|*git*pull*|*git*push*|*git*ls-remote*|*git*submodule*)
            retry command bash "$@"
            ;;
        *)
            command bash "$@"
            ;;
    esac
}

git() {
    local cmd="$1"
    shift

    case "$cmd" in
        clone|fetch|pull|push|ls-remote|submodule)
            retry command git "$cmd" "$@"
            ;;
        *)
            command git "$cmd" "$@"
            ;;
    esac
}

export -f retry curl git wget bash

generate_gh_changelog() {
    local repo="$1"
    local branch="$2"
    local count="${3:-5}"
    local output="$4"

    gh api "repos/${repo}/commits?sha=${branch}&per_page=${count}" \
        --jq '.[] | "- [" + .sha[0:7] + "](" + .html_url + ") " + (.commit.message | split("\n")[0])' \
        > "$output"
}

apply_patch_file() {
    local patch="$1"
    local patch_data=""

    if [[ -n "$patch" && -f "$patch" ]]; then
        patch_data=$(cat "$patch")
        info "Applying: $(basename "$patch")"
    elif [[ -n "$patch" ]]; then
        patch_data="$patch"
        info "Applying patch from data"
    else
        patch_data=$(cat)
        info "Applying patch from stdin"
    fi

    [[ -z "$patch_data" ]] && { error "No patch data"; return 1; }

    if echo "$patch_data" | git apply --check - 2>/dev/null; then
        if echo "$patch_data" | git apply - 2>/dev/null; then
            success "Applied patch successfully"
            return 0
        fi
    fi

    warning "git apply failed, trying patch with fuzz"

    if ! echo "$patch_data" | patch -p1 --fuzz=3 --dry-run 2>/dev/null; then
        warning "Skipping: patch does not apply"
        return 1
    fi

    if echo "$patch_data" | patch -p1 --fuzz=3 2>/dev/null; then
        success "Applied patch with fuzz"
        return 0
    else
        error "Failed to apply patch"
        return 1
    fi
}

apply_kernel_patches() {
    local patch_dir="${1:-$KERNEL_PATCHES/common}"
    local failed=0

    [[ ! -d "$patch_dir" ]] && { error "$patch_dir not found"; return 1; }

    local patches=()
    while IFS= read -r -d '' patch; do
        patches+=("$patch")
    done < <(find "$patch_dir" -type f \( -name "*.patch" -o -name "*.diff" \) -print0 | sort -z -V)

    [[ ${#patches[@]} -eq 0 ]] && { warning "No patches found in $patch_dir"; return 0; }

    info "Found ${#patches[@]} patches in $patch_dir"

    for patch in "${patches[@]}"; do
        if ! apply_patch_file "$patch"; then
            ((failed++))
        fi
    done

    [[ $failed -eq 0 ]] && success "All patches applied successfully" || warning "Applied $((${#patches[@]} - failed))/${#patches[@]} patches, $failed failed"
    return $failed
}

apply_force_load_module_patch() {
    local file=""

    if [[ -f "kernel/module/version.c" ]]; then
        file="kernel/module/version.c"
    elif [[ -f "kernel/module.c" ]]; then
        file="kernel/module.c"
    else
        warning "Module file not found - skipping force load patch"
        return 0
    fi

    if grep -q "disagrees about version of symbol.*but ignore" "$file"; then
        success "Force load module patch already applied"
        return 0
    fi

    python3 - "$file" <<'PYEOF'
import re
import sys

path = sys.argv[1]

with open(path, "r") as f:
    content = f.read()

# Match the specific pr_warn(...) + return 0; pair from check_version()'s
# bad_version label. This string is unique to that function on both 5.10
# (kernel/module.c) and 6.1+ (kernel/module/version.c).
pattern = re.compile(
    r'(pr_warn\("%s: disagrees about version of symbol %s\\n",\s*'
    r'\n?\s*info->name, symname\);\s*\n\s*)return 0;'
)

def repl(m):
    prefix = m.group(1).replace(
        'disagrees about version of symbol %s\\n"',
        'disagrees about version of symbol %s, but ignore...\\n"',
    )
    return prefix + "return 1;"

new_content, n = pattern.subn(repl, content, count=1)

if n == 0:
    print("PATCH_PATTERN_NOT_FOUND", file=sys.stderr)
    sys.exit(1)

with open(path, "w") as f:
    f.write(new_content)
PYEOF

    if [[ $? -eq 0 ]]; then
        success "Force load module patch applied to $file"
    else
        warning "Force load module patch pattern not found in $file (source may differ from expected) - skipping"
        return 1
    fi
}

apply_extract_cert_key_pass_patch() {
    local file="certs/extract-cert.c"

    if [[ ! -f "$file" ]]; then
        warning "extract-cert.c not found - skipping key_pass patch"
        return 0
    fi

    if grep -q "ifdef USE_PKCS11_ENGINE" "$file" && grep -qB2 "static const char \*key_pass;" "$file" | grep -q "ifdef USE_PKCS11_ENGINE"; then
        success "extract-cert key_pass patch already applied"
        return 0
    fi

    sed -i '/^static const char \*key_pass;/i #ifdef USE_PKCS11_ENGINE' "$file"
    sed -i '/^static const char \*key_pass;/a #endif' "$file"

    sed -i 's/^\([[:space:]]*\)if (key_pass)$/\1#ifdef USE_PKCS11_ENGINE\n\1if (key_pass)/' "$file"
    sed -i '/ERR(!ENGINE_ctrl_cmd_string(e, "PIN", key_pass, 0), "Set PKCS#11 PIN");/a #endif' "$file"

    success "extract-cert key_pass patch applied via sed"
}

cleanup_abi_gki_protected_exports() {
    local files_found=0

    for path in "android" "."; do
        if [[ -d "$path" ]] && compgen -G "$path/*protected_exports*" > /dev/null; then
            rm -rf "$path"/*protected_exports*
            files_found=1
        fi
    done

    if [[ $files_found -eq 0 ]]; then
        success "No ABI GKI protected exports files found to remove"
    else
        success "Removed ABI GKI protected exports file(s)"
    fi
}

build_and_install_pahole() {
    local pahole_dir="$HOME/.local/src/pahole"
    local install_prefix="$HOME/.local"
    local bin_dir="$install_prefix/bin"
    local lib_dir="$install_prefix/lib"
    local start_dir
    start_dir="$(pwd)"

    export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
    export PATH="$bin_dir:$PATH"
    export LD_LIBRARY_PATH="$lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    mkdir -p "$bin_dir" "$CCACHE_DIR"

    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get remove -y --purge dwarves pahole 2>/dev/null || true
        sudo apt-get autoremove -y 2>/dev/null || true
        hash -r
    fi

    local missing=()
    for pkg in cmake libdw-dev libelf-dev zlib1g-dev; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} )); then
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing[@]}" || {
            error "failed to install build deps: ${missing[*]}"
            return 1
        }
    fi

    if [[ ! -d "$pahole_dir/.git" ]]; then
        rm -rf "$pahole_dir"
        git clone --depth=1 https://git.kernel.org/pub/scm/devel/pahole/pahole.git "$pahole_dir" || {
            error "failed to clone pahole"
            return 1
        }
    else
        git -C "$pahole_dir" fetch --depth=1 origin master
        git -C "$pahole_dir" reset --hard origin/master
    fi

    local build_dir="$pahole_dir/build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir" || return 1

    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_prefix" \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_INSTALL_RPATH="$lib_dir" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -D__LIB=lib \
        .. || {
        error "cmake failed"
        cd "$start_dir"
        return 1
    }

    make -j"$(nproc)" || {
        error "pahole build failed"
        cd "$start_dir"
        return 1
    }

    make install || {
        error "pahole install failed"
        cd "$start_dir"
        return 1
    }

    cd "$start_dir"

    hash -r
    if ! command -v pahole >/dev/null 2>&1; then
        error "pahole not found in PATH after install"
        return 1
    fi
    if ! pahole --version >/dev/null 2>&1; then
        error "pahole found but fails to run (check LD_LIBRARY_PATH/rpath)"
        return 1
    fi

    success "pahole $(pahole --version | head -1) installed to $bin_dir"
    return 0
}

apply_susfs_patches() {
    log "Applying SUSFS patches"

    cp -R $SUSFS_PATCHES/fs/* ./fs
    cp -R $SUSFS_PATCHES/include/linux/* ./include/linux/

    # Only the gki-android12-5.10 line is built here — the 6.1 mount fix
    # and the 6.12 task_mmu corruption fix from upstream don't apply.
    patch -p1 --fuzz=3 < "$SUSFS_PATCHES/50_add_susfs_in_${SUSFS_PATCH}.patch"

    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
    echo "SUSFS_VERSION=$SUSFS_VERSION" >> $GITHUB_ENV
}

clone_susfs() {
    DEPTH=${1:-1}
    local pin="${GKI_SUSFS_COMMIT[$KERNEL_VERSION]:-}"

    if [ ! -d "$SUSFS_DIR" ]; then
        if [ -n "$pin" ]; then
            log "Cloning $SUSFS_URL (branch $SUSFS_BRANCH) to pin commit $pin"
            git clone -q --single-branch -b "$SUSFS_BRANCH" "$SUSFS_URL" "$SUSFS_DIR"
        else
            log "Cloning $SUSFS_URL (branch $SUSFS_BRANCH, depth $DEPTH, no pin)"
            git clone --depth=$DEPTH -q "$SUSFS_URL" -b "$SUSFS_BRANCH" "$SUSFS_DIR"
        fi
    else
        log "$SUSFS_DIR already exists, reusing existing clone"
    fi

    if [ -n "$pin" ]; then
        git -C "$SUSFS_DIR" fetch -q origin "$pin" 2>/dev/null || true
        if ! git -C "$SUSFS_DIR" checkout -q "$pin"; then
            error "Failed to checkout pinned commit $pin for KERNEL_VERSION=$KERNEL_VERSION on branch $SUSFS_BRANCH"
            exit 1
        fi
        success "Commit pin $pin applied for KERNEL_VERSION=$KERNEL_VERSION (branch $SUSFS_BRANCH)"
    else
        log "No commit pin configured for KERNEL_VERSION=$KERNEL_VERSION, using branch $SUSFS_BRANCH tip"
    fi

    log "susfs4ksu HEAD is now $(git -C "$SUSFS_DIR" rev-parse HEAD)"
}
