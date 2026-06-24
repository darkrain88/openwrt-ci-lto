#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGES_REPO="${PACKAGES_REPO:-https://github.com/laipeng668/packages}"
LUCI_REPO="${LUCI_REPO:-https://github.com/laipeng668/luci}"
GECOOSAC_REPO="${GECOOSAC_REPO:-https://github.com/laipeng668/luci-app-gecoosac}"
AURORA_REPO="${AURORA_REPO:-https://github.com/eamonxg/luci-theme-aurora}"
OPENLIST2_REPO="${OPENLIST2_REPO:-https://github.com/sbwml/luci-app-openlist2}"
OPENWRT_TARGET="${OPENWRT_TARGET:-x86}"
OPENWRT_SUBTARGET="${OPENWRT_SUBTARGET:-64}"
OPENWRT_TARGET_PROFILE="${OPENWRT_TARGET_PROFILE:-}"
OPENWRT_DOWNLOADS_BASE_URL="${OPENWRT_DOWNLOADS_BASE_URL:-https://downloads.openwrt.org}"
OPENWRT_SDK_VERSION="${OPENWRT_SDK_VERSION:-${SDK_VERSION:-main}}"
OPENWRT_SDK_BASE_URL="${OPENWRT_SDK_BASE_URL:-}"
SDK_URL="${SDK_URL:-}"
PACKAGE_CONFIG_FILES="${PACKAGE_CONFIG_FILES:-${CONFIG_FILES:-configs/x86-64.config configs/Packages.config}}"
unset CONFIG_FILES
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
SDK_ROOT="${SDK_ROOT:-$RUNNER_TEMP/openwrt-sdk}"
OUTPUT_DIR="${OUTPUT_DIR:-${GITHUB_WORKSPACE:-$PWD}/artifacts/packages}"
PACKAGE_ARCH_NAME="${PACKAGE_ARCH_NAME:-$OPENWRT_TARGET-$OPENWRT_SUBTARGET}"
PACKAGE_SELECTION="${PACKAGE_SELECTION:-${PACKAGE_NAME:-all}}"
SDK_ARCHIVE="$RUNNER_TEMP/openwrt-sdk.tarball"
SPARSE_ROOT="$RUNNER_TEMP/openwrt-sparse-clone"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

COMPILE_TARGETS=()
CONFIG_FILE_LIST=()
ARTIFACT_PACKAGE_NAMES=()

log() {
  printf '\n==> %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

normalize_package_selection() {
  local selection="${1:-all}"

  selection="${selection,,}"
  case "$selection" in
    "" | all | "全部")
      printf 'all\n'
      ;;
    aria2 | ariang | frp | nginx | gecoosac | openlist2 | luci-app-aria2 | luci-app-frpc | luci-app-frps | luci-app-gecoosac | luci-app-openlist2 | luci-theme-aurora)
      printf '%s\n' "$selection"
      ;;
    frpc | frps | frp-binary-toml | frp-toml)
      printf 'frp\n'
      ;;
    nginx-full | nginx-ssl)
      printf 'nginx\n'
      ;;
    openlist)
      printf 'openlist2\n'
      ;;
    luci-app-openlist)
      printf 'luci-app-openlist2\n'
      ;;
    *)
      die "Unsupported PACKAGE_SELECTION: ${1:-} (supported: all, aria2, ariang, frp, nginx, gecoosac, openlist2, luci-app-aria2, luci-app-frpc, luci-app-frps, luci-app-gecoosac, luci-app-openlist2, luci-theme-aurora)"
      ;;
  esac
}

normalize_sdk_version() {
  local version="${1:-main}"

  version="${version,,}"
  case "$version" in
    "" | main | snapshot | snapshots | master)
      printf 'main\n'
      ;;
    23.05 | 24.10 | 25.12)
      printf '%s\n' "$version"
      ;;
    *)
      die "Unsupported OPENWRT_SDK_VERSION: ${1:-} (supported: main, 23.05, 24.10, 25.12)"
      ;;
  esac
}

load_inline_target_profile() {
  local profile="${1:-}"

  [ -n "$profile" ] || return 0

  case "$profile" in
    rax3000m | cmcc-rax3000m | cmcc_rax3000m)
      [ "$OPENWRT_TARGET" = mediatek ] && [ "$OPENWRT_SUBTARGET" = filogic ] ||
        die "OPENWRT_TARGET_PROFILE=$profile requires OPENWRT_TARGET=mediatek and OPENWRT_SUBTARGET=filogic"
      cat >> "$SDK_ROOT/.config" <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m=y
EOF
      ;;
    *)
      die "Unsupported OPENWRT_TARGET_PROFILE: $profile (supported: rax3000m)"
      ;;
  esac
}

selection_is_all() {
  [ "$PACKAGE_SELECTION" = all ]
}

selection_is() {
  [ "$PACKAGE_SELECTION" = "$1" ]
}

selection_in() {
  local package_name

  selection_is_all && return 0

  for package_name in "$@"; do
    selection_is "$package_name" && return 0
  done

  return 1
}

resolve_sdk_url() {
  local sdk_base_url
  local sdk_href

  if [ -n "$SDK_URL" ]; then
    printf '%s\n' "$SDK_URL"
    return
  fi

  sdk_base_url="$(resolve_sdk_base_url)"
  log "Resolve OpenWrt $OPENWRT_SDK_VERSION SDK for $OPENWRT_TARGET/$OPENWRT_SUBTARGET"
  sdk_href="$(
    curl -fsSL "${sdk_base_url%/}/" |
      grep -oE 'href="[^"]*openwrt-sdk-[^"]+\.tar\.(xz|zst|gz)"' |
      sed -E 's/^href="([^"]+)"/\1/' |
      head -n 1 || true
  )"

  [ -n "$sdk_href" ] || die "OpenWrt SDK archive was not found at $sdk_base_url"

  case "$sdk_href" in
    http://* | https://*)
      printf '%s\n' "$sdk_href"
      ;;
    /*)
      printf '%s%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$sdk_href"
      ;;
    *)
      printf '%s/%s\n' "${sdk_base_url%/}" "$sdk_href"
      ;;
  esac
}

resolve_sdk_base_url() {
  local release_version
  local sdk_version

  if [ -n "$OPENWRT_SDK_BASE_URL" ]; then
    printf '%s\n' "$OPENWRT_SDK_BASE_URL"
    return
  fi

  sdk_version="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"
  if [ "$sdk_version" = main ]; then
    printf '%s/snapshots/targets/%s/%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$OPENWRT_TARGET" "$OPENWRT_SUBTARGET"
    return
  fi

  release_version="$(resolve_latest_release_version "$sdk_version")"
  printf '%s/releases/%s/targets/%s/%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$release_version" "$OPENWRT_TARGET" "$OPENWRT_SUBTARGET"
}

resolve_latest_release_version() {
  local release_version
  local series="$1"

  release_version="$(
    curl -fsSL "${OPENWRT_DOWNLOADS_BASE_URL%/}/releases/" |
      grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' |
      sed -E 's/^href="([^"]+)\/"/\1/' |
      grep -E "^${series//./\\.}(\\.[0-9]+)?$" |
      sort -V |
      tail -n 1 || true
  )"

  [ -n "$release_version" ] || die "OpenWrt release series was not found: $series"
  printf '%s\n' "$release_version"
}

download_sdk() {
  local resolved_url="$1"

  case "$resolved_url" in
    file://*)
      cp "${resolved_url#file://}" "$SDK_ARCHIVE"
      ;;
    /*)
      cp "$resolved_url" "$SDK_ARCHIVE"
      ;;
    *)
      curl -fsSL --retry 3 "$resolved_url" -o "$SDK_ARCHIVE"
      ;;
  esac
}

extract_sdk() {
  local resolved_url="$1"
  local archive_name
  archive_name="${resolved_url%%\?*}"

  mkdir -p "$SDK_ROOT"
  case "$archive_name" in
    *.tar.zst | *.tzst)
      tar --zstd -xf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *.tar.xz | *.txz)
      tar -xJf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *.tar.gz | *.tgz)
      tar -xzf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *)
      tar -xf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
  esac
}

git_sparse_clone() {
  local branch="$1"
  local repourl="$2"
  local target_root="$3"
  local repodir
  local sparse_path
  shift 3

  repodir="$SPARSE_ROOT/$(basename "${repourl%.git}")-${branch//\//-}"
  rm -rf "$repodir"
  git clone \
    --depth=1 \
    --no-tags \
    -b "$branch" \
    --single-branch \
    --filter=blob:none \
    --sparse \
    "$repourl" \
    "$repodir"

  (
    cd "$repodir"
    git sparse-checkout set "$@"
  )

  for sparse_path in "$@"; do
    local source_path="$repodir/$sparse_path"
    local target_path

    target_path="$SDK_ROOT/$target_root/$sparse_path"

    [ -d "$source_path" ] || die "Sparse package directory not found: $source_path"
    if [ ! -f "$source_path/Makefile" ] &&
      [ -z "$(find "$source_path" -mindepth 2 -maxdepth 2 -type f -name Makefile -print -quit)" ]; then
      die "Package Makefile not found under: $source_path"
    fi

    rm -rf "$target_path"
    mkdir -p "$(dirname "$target_path")"
    cp -a "$source_path" "$target_path"
  done

  rm -rf "$repodir"
}

git_clone_package_repo() {
  local repourl="$1"
  local target_path="$2"
  local makefile_path
  shift 2

  rm -rf "$target_path"
  git clone \
    --depth=1 \
    --no-tags \
    "$repourl" \
    "$target_path"

  for makefile_path in "$@"; do
    [ -f "$target_path/$makefile_path" ] || die "Package Makefile not found: $target_path/$makefile_path"
  done
}

remove_builtin_packages() {
  rm -rf \
    "$SDK_ROOT/feeds/packages/net/aria2" \
    "$SDK_ROOT/feeds/packages/net/ariang" \
    "$SDK_ROOT/feeds/packages/net/frp" \
    "$SDK_ROOT/feeds/packages/lang/golang" \
    "$SDK_ROOT/feeds/packages/net/nginx" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-frpc" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-frps"
}

load_custom_packages() {
  mkdir -p "$SPARSE_ROOT"

  git_sparse_clone aria2 "$PACKAGES_REPO" feeds/packages net/aria2
  git_sparse_clone ariang "$PACKAGES_REPO" feeds/packages net/ariang
  git_sparse_clone master "$PACKAGES_REPO" feeds/packages lang/golang
  git_sparse_clone frp-binary-toml "$PACKAGES_REPO" feeds/packages net/frp
  git_sparse_clone nginx "$PACKAGES_REPO" feeds/packages net/nginx
  git_sparse_clone frp-toml "$LUCI_REPO" feeds/luci \
    applications/luci-app-frpc \
    applications/luci-app-frps
  git_clone_package_repo "$GECOOSAC_REPO" "$SDK_ROOT/package/luci-app-gecoosac" \
    gecoosac/Makefile \
    luci-app-gecoosac/Makefile
  git_clone_package_repo "$AURORA_REPO" "$SDK_ROOT/package/luci-theme-aurora" Makefile
  git_clone_package_repo "$OPENLIST2_REPO" "$SDK_ROOT/package/openlist2" \
    openlist2/Makefile \
    luci-app-openlist2/Makefile
}

prune_luci_translations() {
  local lang_dir
  local lang_name
  local po_dir
  local removed_count=0
  local root_dir

  for root_dir in \
    "$SDK_ROOT/package/luci-app-gecoosac" \
    "$SDK_ROOT/package/luci-theme-aurora" \
    "$SDK_ROOT/package/roc" \
    "$SDK_ROOT/package/feeds/luci" \
    "$SDK_ROOT/feeds/luci/applications"; do
    [ -d "$root_dir" ] || continue

    while IFS= read -r -d '' po_dir; do
      while IFS= read -r -d '' lang_dir; do
        lang_name="$(basename "$lang_dir")"
        case "$lang_name" in
          templates | zh_Hans | zh_Hant)
            ;;
          *)
            rm -rf "$lang_dir"
            removed_count=$((removed_count + 1))
            ;;
        esac
      done < <(find "$po_dir" -mindepth 1 -maxdepth 1 -type d -print0)
    done < <(find "$root_dir" -type d -name po -print0)
  done

  log "Pruned LuCI translations: kept zh_Hans and zh_Hant, removed $removed_count other language directories"
}

normalize_config_files() {
  printf '%s\n' "$PACKAGE_CONFIG_FILES" |
    sed -e 's/\r$//' -e 's/#.*$//' |
    tr ',[:space:]' '\n' |
    sed -e '/^$/d'
}

load_config_files() {
  local config_file
  local source_file

  : > "$SDK_ROOT/.config"
  load_inline_target_profile "$OPENWRT_TARGET_PROFILE"
  mapfile -t CONFIG_FILE_LIST < <(normalize_config_files)

  [ "${#CONFIG_FILE_LIST[@]}" -gt 0 ] || die "PACKAGE_CONFIG_FILES did not contain any config file"

  for config_file in "${CONFIG_FILE_LIST[@]}"; do
    if [ -f "$config_file" ]; then
      source_file="$config_file"
    else
      source_file="$WORKSPACE/$config_file"
    fi

    [ -f "$source_file" ] || die "Config file not found: $config_file"
    cat "$source_file" >> "$SDK_ROOT/.config"
    printf '\n' >> "$SDK_ROOT/.config"
  done
}

config_package_enabled() {
  local package_name="$1"

  grep -Eq "^CONFIG_PACKAGE_${package_name}=(y|m)$" "$SDK_ROOT/.config"
}

add_compile_target() {
  local compile_target="$1"
  local existing_target

  for existing_target in "${COMPILE_TARGETS[@]}"; do
    [ "$existing_target" != "$compile_target" ] || return
  done

  COMPILE_TARGETS+=("$compile_target")
}

add_artifact_package() {
  local package_name="$1"
  local existing_package

  for existing_package in "${ARTIFACT_PACKAGE_NAMES[@]}"; do
    [ "$existing_package" != "$package_name" ] || return
  done

  ARTIFACT_PACKAGE_NAMES+=("$package_name")
}

add_luci_i18n_packages() {
  local app_name="$1"

  add_artifact_package "luci-i18n-${app_name}-zh-cn"
  add_artifact_package "luci-i18n-${app_name}-zh-tw"
}

generate_artifact_filters() {
  ARTIFACT_PACKAGE_NAMES=()

  if { selection_in aria2 && config_package_enabled aria2; } ||
    { selection_in luci-app-aria2 && {
      config_package_enabled aria2 ||
        config_package_enabled luci-app-aria2
    }; }; then
    add_artifact_package aria2
  fi

  if selection_in ariang && config_package_enabled ariang; then
    add_artifact_package ariang
  fi

  if selection_in luci-app-aria2 && config_package_enabled luci-app-aria2; then
    add_artifact_package luci-app-aria2
    add_luci_i18n_packages aria2
  fi

  if { selection_in frp && config_package_enabled frpc; } ||
    { selection_in luci-app-frpc && {
      config_package_enabled frpc ||
        config_package_enabled luci-app-frpc
    }; }; then
    add_artifact_package frpc
  fi

  if { selection_in frp && config_package_enabled frps; } ||
    { selection_in luci-app-frps && {
      config_package_enabled frps ||
        config_package_enabled luci-app-frps
    }; }; then
    add_artifact_package frps
  fi

  if selection_in luci-app-frpc && config_package_enabled luci-app-frpc; then
    add_artifact_package luci-app-frpc
    add_luci_i18n_packages frpc
  fi

  if selection_in luci-app-frps && config_package_enabled luci-app-frps; then
    add_artifact_package luci-app-frps
    add_luci_i18n_packages frps
  fi

  selection_in nginx && config_package_enabled nginx && add_artifact_package nginx
  selection_in nginx && config_package_enabled nginx-full && add_artifact_package nginx-full
  selection_in nginx && config_package_enabled nginx-ssl && add_artifact_package nginx-ssl

  if { selection_in openlist2 && config_package_enabled openlist2; } ||
    { selection_in luci-app-openlist2 && {
      config_package_enabled openlist2 ||
        config_package_enabled luci-app-openlist2
    }; }; then
    add_artifact_package openlist2
  fi

  if selection_in gecoosac luci-app-gecoosac && {
    config_package_enabled gecoosac ||
      config_package_enabled luci-app-gecoosac
  }; then
    add_artifact_package gecoosac
  fi

  if selection_in luci-app-gecoosac && config_package_enabled luci-app-gecoosac; then
    add_artifact_package luci-app-gecoosac
    add_luci_i18n_packages gecoosac
  fi

  if selection_in luci-app-openlist2 && config_package_enabled luci-app-openlist2; then
    add_artifact_package luci-app-openlist2
    add_luci_i18n_packages openlist2
  fi

  selection_in luci-theme-aurora && config_package_enabled luci-theme-aurora && add_artifact_package luci-theme-aurora

  [ "${#ARTIFACT_PACKAGE_NAMES[@]}" -gt 0 ] || die "No package artifact filters were generated for PACKAGE_SELECTION=$PACKAGE_SELECTION"
}

artifact_package_allowed() {
  local package_file_name="$1"
  local package_name

  for package_name in "${ARTIFACT_PACKAGE_NAMES[@]}"; do
    case "$package_file_name" in
      "${package_name}_"* | "${package_name}-"[0-9]* | "${package_name}-git"* | "${package_name}-v"[0-9]*)
        return 0
        ;;
    esac
  done

  return 1
}

release_package_name() {
  local package_file="$1"
  local package_arch
  local package_release_name
  local package_file_name
  local safe_package_name
  local sdk_prefix

  package_file_name="$(basename "$package_file")"
  safe_package_name="${package_file_name//\~/-}"
  sdk_prefix="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")-"

  case "$safe_package_name" in
    *.ipk)
      package_release_name="$safe_package_name"
      ;;
    *.apk)
      package_arch="$(basename "$(dirname "$(dirname "$package_file")")")"
      case "$safe_package_name" in
        ariang*.apk | luci*.apk)
          package_arch=all
          ;;
      esac
      package_release_name="${safe_package_name%.apk}-$package_arch.apk"
      ;;
    *)
      package_release_name="$safe_package_name"
      ;;
  esac

  case "$package_release_name" in
    main-* | 23.05-* | 24.10-* | 25.12-*)
      printf '%s\n' "$package_release_name"
      ;;
    *)
      printf '%s%s\n' "$sdk_prefix" "$package_release_name"
      ;;
  esac
}

generate_compile_targets() {
  COMPILE_TARGETS=()

  if { selection_in aria2 ariang && {
    config_package_enabled aria2 ||
      config_package_enabled ariang
  }; } || { selection_in luci-app-aria2 && {
    config_package_enabled aria2 ||
      config_package_enabled luci-app-aria2
  }; }; then
    add_compile_target package/feeds/packages/aria2/compile
  fi

  if selection_in ariang && {
    config_package_enabled ariang ||
      config_package_enabled ariang-nginx
  }; then
    add_compile_target package/feeds/packages/ariang/compile
  fi

  if { selection_in frp && {
    config_package_enabled frpc ||
      config_package_enabled frps
  }; } || { selection_in luci-app-frpc && {
    config_package_enabled frpc ||
      config_package_enabled luci-app-frpc
  }; } || { selection_in luci-app-frps && {
    config_package_enabled frps ||
      config_package_enabled luci-app-frps
  }; }; then
    add_compile_target package/feeds/packages/frp/compile
  fi

  if selection_in nginx && {
    config_package_enabled nginx ||
    config_package_enabled nginx-full ||
    config_package_enabled nginx-ssl
  }; then
    add_compile_target package/feeds/packages/nginx/compile
  fi

  if { selection_in openlist2 && config_package_enabled openlist2; } ||
    { selection_in luci-app-openlist2 && {
      config_package_enabled openlist2 ||
        config_package_enabled luci-app-openlist2
    }; }; then
    add_compile_target package/openlist2/openlist2/compile
  fi

  if selection_in luci-app-frpc && config_package_enabled luci-app-frpc; then
    add_compile_target package/feeds/luci/luci-app-frpc/compile
  fi

  if selection_in luci-app-frps && config_package_enabled luci-app-frps; then
    add_compile_target package/feeds/luci/luci-app-frps/compile
  fi

  if selection_in luci-app-aria2 && config_package_enabled luci-app-aria2 && [ -d "$SDK_ROOT/package/feeds/luci/luci-app-aria2" ]; then
    add_compile_target package/feeds/luci/luci-app-aria2/compile
  fi

  if selection_in gecoosac luci-app-gecoosac && {
    config_package_enabled gecoosac ||
      config_package_enabled luci-app-gecoosac
  }; then
    add_compile_target package/luci-app-gecoosac/gecoosac/compile
  fi

  if selection_in luci-app-gecoosac && config_package_enabled luci-app-gecoosac; then
    add_compile_target package/luci-app-gecoosac/luci-app-gecoosac/compile
  fi

  if selection_in luci-app-openlist2 && config_package_enabled luci-app-openlist2; then
    add_compile_target package/openlist2/luci-app-openlist2/compile
  fi

  if selection_in luci-theme-aurora && config_package_enabled luci-theme-aurora; then
    add_compile_target package/luci-theme-aurora/compile
  fi

  [ "${#COMPILE_TARGETS[@]}" -gt 0 ] || die "No matching package compile targets were enabled by $PACKAGE_CONFIG_FILES for PACKAGE_SELECTION=$PACKAGE_SELECTION"
}

copy_artifacts() {
  local package_bin_dir="$SDK_ROOT/bin/packages"
  local copied_count=0
  local package_file
  local package_name
  local skipped_count=0
  local target_file

  if [ ! -d "$package_bin_dir" ]; then
    die "SDK package output directory was not created: $package_bin_dir"
  fi

  if [ -z "$(find "$package_bin_dir" -type f \( -name '*.ipk' -o -name '*.apk' \) -print -quit)" ]; then
    die "No compiled .ipk or .apk files were found under $package_bin_dir"
  fi

  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"
  while IFS= read -r -d '' package_file; do
    package_name="$(basename "$package_file")"
    if ! artifact_package_allowed "$package_name"; then
      skipped_count=$((skipped_count + 1))
      continue
    fi

    target_file="$OUTPUT_DIR/$(release_package_name "$package_file")"
    [ ! -e "$target_file" ] || die "Duplicate package artifact name: $target_file"
    cp -a "$package_file" "$target_file"
    copied_count=$((copied_count + 1))
  done < <(find "$package_bin_dir" -type f \( -name '*.ipk' -o -name '*.apk' \) -print0)

  [ "$copied_count" -gt 0 ] || die "No selected package files were copied from $package_bin_dir"
  log "Copied $copied_count selected package files to $OUTPUT_DIR with package architecture suffixes; LuCI and AriaNg APK files use all; skipped $skipped_count dependency files"

  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "PACKAGE_OUTPUT_DIR=$OUTPUT_DIR" >> "$GITHUB_ENV"
    echo "RESOLVED_SDK_URL=$RESOLVED_SDK_URL" >> "$GITHUB_ENV"
  fi
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

PACKAGE_SELECTION="$(normalize_package_selection "$PACKAGE_SELECTION")"
OPENWRT_SDK_VERSION="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"

log "Download OpenWrt SDK"
log "Selected package group: $PACKAGE_SELECTION"
log "Selected OpenWrt SDK version: $OPENWRT_SDK_VERSION"
RESOLVED_SDK_URL="$(resolve_sdk_url)"
rm -rf "$SDK_ROOT"
mkdir -p "$RUNNER_TEMP"
download_sdk "$RESOLVED_SDK_URL"
extract_sdk "$RESOLVED_SDK_URL"
[ -x "$SDK_ROOT/scripts/feeds" ] || die "Invalid SDK archive: scripts/feeds was not found"
[ -f "$SDK_ROOT/Makefile" ] || die "Invalid SDK archive: Makefile was not found"

log "Update SDK feeds"
cd "$SDK_ROOT"
./scripts/feeds update -a

log "Load custom packages"
remove_builtin_packages
load_custom_packages

log "Install SDK feeds"
./scripts/feeds install -a
prune_luci_translations

log "Load package config"
load_config_files
make defconfig
generate_compile_targets
generate_artifact_filters

log "Compile packages"
for compile_target in "${COMPILE_TARGETS[@]}"; do
  make -j"$(nproc)" "$compile_target" || make -j1 "$compile_target" V=s
done

log "Collect package artifacts"
copy_artifacts
