#!/usr/bin/env bash
# =============================================================================
#  rebrand-native.sh
#
#  在 ./android.sh 之后、打包 AAR 之前运行。
#
#  正常情况下（rebrand-sources.sh 里的 SLIBPREF 注入生效），ndk-build 产出的
#  android/libs/<abi>/ 里已经是 lib<前缀>_avcodec.so 等，本脚本只做「校验」。
#
#  如果构建期改名没生效，本脚本会用 patchelf 兜底：重命名 + 修正 SONAME +
#  修正所有 DT_NEEDED 引用，保证改名后的动态库仍能互相找到。
#
#  最后会强校验：任何还在引用旧 ffmpeg 库名的地方都会让脚本以非 0 退出。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=rebrand.config.env
source "${SCRIPT_DIR}/rebrand.config.env"

ROOT="${REBRAND_REPO_ROOT:-${AUTO_ROOT}}"
PREFIX="${REBRAND_NATIVE_PREFIX}"
LIBS_ROOT="${ROOT}/android/libs"
STRIP_LIBCXX="${REBRAND_STRIP_LIBCXX_SHARED}"

log() { printf '[rebrand-native] %s\n' "$*"; }
warn() { printf '[rebrand-native] WARN: %s\n' "$*" >&2; }
die() { printf '[rebrand-native] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 旧名 / 新名映射（不带 lib 前缀与 .so 后缀）
# ---------------------------------------------------------------------------
OLD_NAMES=()
NEW_NAMES=()
for lib in ${REBRAND_FFMPEG_LIBS}; do
  OLD_NAMES+=("${lib}")
  NEW_NAMES+=("${PREFIX}_${lib}")
done
OLD_NAMES+=("ffmpegkit_abidetect")
NEW_NAMES+=("${PREFIX}_abidetect")
OLD_NAMES+=("ffmpegkit")
NEW_NAMES+=("${PREFIX}")

# 系统库（Android linker 用名字直连，不需要在 jniLibs 里存在）
SYSTEM_LIBS_RE='^lib(c|m|dl|z|log|android|stdc\+\+|c\+\+_shared|jnigraphics|EGL|GLESv1_CM|GLESv2|OpenSLES|OpenMAXAL|aaudio|mediandk|nativewindow|vulkan|sync|cutils|utils|binder_ndk|hardware|base|ui|OpenCL)\.so.*$'

# ---------------------------------------------------------------------------
# 工具发现
# ---------------------------------------------------------------------------
find_readelf() {
  local c
  for c in \
    "${ANDROID_NDK_ROOT:-}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" \
    "${ANDROID_NDK_ROOT:-}/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf" \
    "$(command -v llvm-readelf 2>/dev/null || true)" \
    "$(command -v readelf 2>/dev/null || true)"; do
    if [ -n "${c}" ] && [ -x "${c}" ]; then printf '%s' "${c}"; return 0; fi
  done
  return 1
}

READELF="$(find_readelf || true)"
[ -n "${READELF}" ] || die "找不到 readelf / llvm-readelf，无法校验动态库"
log "使用 readelf: ${READELF}"

PATCHELF="$(command -v patchelf 2>/dev/null || true)"
if [ -z "${PATCHELF}" ]; then
  warn "未安装 patchelf；如果构建期改名已生效则不需要它"
fi

elf_needed() {
  LC_ALL=C "${READELF}" -d "$1" 2>/dev/null |
    awk '/\(NEEDED\)/ { if (match($0, /\[[^]]+\]/)) print substr($0, RSTART + 1, RLENGTH - 2) }'
}

elf_soname() {
  LC_ALL=C "${READELF}" -d "$1" 2>/dev/null |
    awk '/\(SONAME\)/ { if (match($0, /\[[^]]+\]/)) print substr($0, RSTART + 1, RLENGTH - 2) }'
}

# 旧 NEEDED 名 -> 新 NEEDED 名；不匹配输出空
map_needed() {
  local need="$1" i
  for i in "${!OLD_NAMES[@]}"; do
    if [[ "${need}" =~ ^lib${OLD_NAMES[$i]}(\.so(\..*)?)?$ ]]; then
      printf '%s' "lib${NEW_NAMES[$i]}.so"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------------------
[ -d "${LIBS_ROOT}" ] || die "找不到 ${LIBS_ROOT}，请先执行 ./android.sh"

ABI_DIRS=()
while IFS= read -r -d '' d; do ABI_DIRS+=("$d"); done < <(find "${LIBS_ROOT}" -mindepth 1 -maxdepth 1 -type d -print0)
[ "${#ABI_DIRS[@]}" -gt 0 ] || die "${LIBS_ROOT} 下没有 ABI 目录，构建可能失败了"

log "发现 ABI 目录: ${ABI_DIRS[*]}"

RENAMED_ANY=0

for ABI_DIR in "${ABI_DIRS[@]}"; do
  ABI="$(basename "${ABI_DIR}")"
  printf '\n[rebrand-native] ===== ABI: %s =====\n' "${ABI}"

  # -------------------------------------------------------------------------
  # 1. 兜底重命名（构建期改名没生效时才会命中）
  # -------------------------------------------------------------------------
  for i in "${!OLD_NAMES[@]}"; do
    old_file="${ABI_DIR}/lib${OLD_NAMES[$i]}.so"
    new_file="${ABI_DIR}/lib${NEW_NAMES[$i]}.so"

    if [ -f "${old_file}" ]; then
      [ -n "${PATCHELF}" ] || die "需要重命名 ${old_file##*/} 但系统里没有 patchelf，请先 apt-get install -y patchelf"

      if [ -e "${new_file}" ]; then
        die "${new_file} 已存在，同时发现了 ${old_file}，请先清理 android/libs 后重试"
      fi

      mv "${old_file}" "${new_file}"
      "${PATCHELF}" --set-soname "lib${NEW_NAMES[$i]}.so" "${new_file}" 2>/dev/null ||
        warn "设置 SONAME 失败（不影响 Android 按文件名加载）：${new_file##*/}"

      log "重命名 ${old_file##*/} -> ${new_file##*/}"
      RENAMED_ANY=1
    fi

    # 带版本号后缀的残留，仅提示
    while IFS= read -r -d '' v; do
      warn "发现带版本号的旧库 ${v##*/}，ffmpeg 的 android target 不应产生这种文件，请检查构建配置"
    done < <(find "${ABI_DIR}" -maxdepth 1 -name "lib${OLD_NAMES[$i]}.so.*" -print0)
  done

  # -------------------------------------------------------------------------
  # 2. 修正 SONAME 与 DT_NEEDED（幂等，任何时候都可以跑）
  # -------------------------------------------------------------------------
  mapfile -d '' SOS < <(find "${ABI_DIR}" -maxdepth 1 -name '*.so' -print0)

  for so in "${SOS[@]}"; do
    base="$(basename "${so}")"

    # 2.1 我们自己产出的库：SONAME 必须等于文件名
    for i in "${!NEW_NAMES[@]}"; do
      if [ "${base}" = "lib${NEW_NAMES[$i]}.so" ]; then
        cur="$(elf_soname "${so}" || true)"
        if [ "${cur}" != "${base}" ]; then
          if [ -n "${PATCHELF}" ]; then
            "${PATCHELF}" --set-soname "${base}" "${so}" 2>/dev/null ||
              warn "设置 SONAME 失败：${base}"
            log "SONAME 修正 ${base}: '${cur}' -> '${base}'"
          else
            warn "${base} 的 SONAME 是 '${cur}'（Android 按文件名加载，通常无影响）"
          fi
        fi
      fi
    done

    # 2.2 依赖里所有旧 ffmpeg 库名改成新名
    while IFS= read -r need; do
      [ -n "${need}" ] || continue
      if new_need="$(map_needed "${need}")"; then
        if [ -n "${PATCHELF}" ]; then
          "${PATCHELF}" --replace-needed "${need}" "${new_need}" "${so}"
          log "DT_NEEDED 修正 ${base}: ${need} -> ${new_need}"
        else
          die "${base} 仍依赖 ${need}，但没有 patchelf 可用"
        fi
      fi
    done < <(elf_needed "${so}" || true)
  done

  # -------------------------------------------------------------------------
  # 3. 可选：剔除 libc++_shared.so
  # -------------------------------------------------------------------------
  if [ "${STRIP_LIBCXX}" = "1" ] && [ -f "${ABI_DIR}/libc++_shared.so" ]; then
    rm -f "${ABI_DIR}/libc++_shared.so"
    log "已按配置删除 libc++_shared.so（请确保你的工程里另有一份）"
  fi

  # -------------------------------------------------------------------------
  # 4. 强校验
  # -------------------------------------------------------------------------
  fail=0
  mapfile -d '' SOS < <(find "${ABI_DIR}" -maxdepth 1 -name '*.so' -print0)

  for so in "${SOS[@]}"; do
    base="$(basename "${so}")"
    while IFS= read -r need; do
      [ -n "${need}" ] || continue

      # 4.1 还有旧名 -> 失败
      for i in "${!OLD_NAMES[@]}"; do
        if [[ "${need}" =~ ^lib${OLD_NAMES[$i]}(\.so(\..*)?)?$ ]]; then
          printf '[rebrand-native] ERROR: %s 仍然依赖旧库名 %s\n' "${base}" "${need}" >&2
          fail=1
        fi
      done

      # 4.2 依赖能在同目录找到吗 -> 找不到只警告（可能是系统库）
      if [ ! -e "${ABI_DIR}/${need}" ]; then
        if ! printf '%s' "${need}" | grep -Eq "${SYSTEM_LIBS_RE}"; then
          warn "${base} 依赖 ${need}，但 ${ABI} 目录下没有这个文件（如果不是系统库，运行时可能加载失败）"
        fi
      fi
    done < <(elf_needed "${so}" || true)
  done

  [ "${fail}" -eq 0 ] || die "${ABI} 目录里仍然存在旧 ffmpeg 库名，改名未完成"

  # -------------------------------------------------------------------------
  # 5. 报告
  # -------------------------------------------------------------------------
  printf '\n[rebrand-native] %s 最终产物：\n' "${ABI}"
  for so in "${SOS[@]}"; do
    printf '  %-34s %8s B   SONAME=%s\n' \
      "$(basename "${so}")" "$(stat -c '%s' "${so}" 2>/dev/null || echo '?')" "$(elf_soname "${so}" || true)"
  done
done

printf '\n'
if [ "${RENAMED_ANY}" -eq 1 ]; then
  log "构建期改名未完全生效，已用 patchelf 兜底完成改名"
else
  log "构建期改名已生效，无需 patchelf 兜底 ✅"
fi
log "校验通过：所有动态库都已使用 lib${PREFIX}* 命名，且互相依赖一致"
