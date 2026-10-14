#!/usr/bin/env bash
# =============================================================================
#  rebrand-sources.sh
#
#  在 ffmpeg-kit-next 仓库根目录下运行（必须在 ./android.sh 之前执行）。
#
#  做的事：
#    1. Kotlin/Java 包名改名（目录 + package 声明 + consumer-rules.pro）
#    2. Kotlin NativeLoader 里的动态库名改名
#    3. JNI C 源码里的 JNI 导出符号 + FindClass 类路径改名
#    4. gradle namespace / AAR 文件名改名
#    5. android/jni/*.mk 里 prebuilt ffmpeg 库与包装库模块改名
#    6. 给 scripts/android/ffmpeg.sh 注入 SLIBPREF 覆盖，让 ffmpeg 直接产出
#       lib<前缀>_avcodec.so 等（这一步失败时由 rebrand-native.sh 兜底修正）
#    7. 修上游 meson cross file 的 pkg-config 键名 bug（rubberband 构建失败根因）
#    8. 给 GPL 构建补 --enable-version3（OpenSSL >= 3.0.0 的硬性要求）
#
#  脚本可重复执行（幂等）。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=rebrand.config.env
source "${SCRIPT_DIR}/rebrand.config.env"

ROOT="${REBRAND_REPO_ROOT:-${AUTO_ROOT}}"

PREFIX="${REBRAND_NATIVE_PREFIX}"
OLD_PKG="${REBRAND_OLD_JAVA_PACKAGE}"
NEW_PKG="${REBRAND_JAVA_PACKAGE}"
OLD_PATH="$(printf '%s' "${OLD_PKG}" | tr '.' '/')"
NEW_PATH="$(printf '%s' "${NEW_PKG}" | tr '.' '/')"
OLD_SYM="$(printf '%s' "${OLD_PKG}" | tr '.' '_')"
NEW_SYM="$(printf '%s' "${NEW_PKG}" | tr '.' '_')"

LIB_MODULE="${ROOT}/android/ffmpeg-kit-next-android-lib"
CPP_DIR="${LIB_MODULE}/src/main/cpp"
JNI_MK="${ROOT}/android/jni/Android.mk"
FFMPEG_MK="${ROOT}/android/jni/ffmpeg/Android.mk"
FFMPEG_SH="${ROOT}/scripts/android/ffmpeg.sh"

log() { printf '[rebrand-sources] %s\n' "$*"; }
die() { printf '[rebrand-sources] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. 前置校验
# ---------------------------------------------------------------------------
[ -d "${LIB_MODULE}" ] || die "找不到 ${LIB_MODULE}，请确认在 ffmpeg-kit-next 仓库里运行"
[ -f "${JNI_MK}" ] || die "找不到 ${JNI_MK}"
[ -f "${FFMPEG_MK}" ] || die "找不到 ${FFMPEG_MK}"
[ -f "${FFMPEG_SH}" ] || die "找不到 ${FFMPEG_SH}"
[ -n "${PREFIX}" ] || die "REBRAND_NATIVE_PREFIX 不能为空"

if ! printf '%s' "${PREFIX}" | grep -Eq '^[a-z][a-z0-9_]*$'; then
  die "REBRAND_NATIVE_PREFIX 只允许小写字母/数字/下划线且以字母开头，当前为 '${PREFIX}'"
fi
if ! printf '%s' "${NEW_PKG}" | grep -Eq '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$'; then
  die "REBRAND_JAVA_PACKAGE 不是合法 Java 包名，当前为 '${NEW_PKG}'"
fi
[ "${NEW_PKG}" != "${OLD_PKG}" ] || die "新旧包名相同，不需要改名"

log "仓库根目录 : ${ROOT}"
log "原生库前缀 : ${PREFIX}  (lib${PREFIX}_avcodec.so … lib${PREFIX}.so)"
log "Java 包名  : ${OLD_PKG} -> ${NEW_PKG}"

# ---------------------------------------------------------------------------
# 1. Kotlin 包目录迁移
# ---------------------------------------------------------------------------
for src_set in main test; do
  old_dir="${LIB_MODULE}/src/${src_set}/kotlin/${OLD_PATH}"
  new_dir="${LIB_MODULE}/src/${src_set}/kotlin/${NEW_PATH}"

  if [ -d "${old_dir}" ]; then
    mkdir -p "$(dirname "${new_dir}")"
    rm -rf "${new_dir}"
    mv "${old_dir}" "${new_dir}"
    find "${LIB_MODULE}/src/${src_set}/kotlin" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    log "移动 ${src_set} 源码目录：${OLD_PATH} -> ${NEW_PATH}"
  elif [ -d "${new_dir}" ]; then
    log "${src_set} 源码目录已经是 ${NEW_PATH}（跳过）"
  fi
done

# ---------------------------------------------------------------------------
# 2. Kotlin 源码：包名 + loadLibrary 库名
# ---------------------------------------------------------------------------
while IFS= read -r -d '' f; do
  sed -i "s|${OLD_PKG}|${NEW_PKG}|g" "$f"
done < <(find "${LIB_MODULE}/src" -name '*.kt' -print0)

# 只改 NativeLoader 里的字符串字面量；顺序：长的先换，避免前缀误伤
while IFS= read -r -d '' f; do
  sed -i \
    -e "s|\"ffmpegkit_abidetect\"|\"${PREFIX}_abidetect\"|g" \
    -e "s|\"ffmpegkit\"|\"${PREFIX}\"|g" \
    "$f"
done < <(find "${LIB_MODULE}/src/main/kotlin" -name '*.kt' -print0)
log "Kotlin 包名与 loadLibrary() 库名已替换"

# ---------------------------------------------------------------------------
# 3. JNI C 源码：导出符号 + FindClass 类路径
# ---------------------------------------------------------------------------
while IFS= read -r -d '' f; do
  sed -i -e "s|${OLD_SYM}|${NEW_SYM}|g" -e "s|${OLD_PATH}|${NEW_PATH}|g" "$f"
done < <(find "${CPP_DIR}" \( -name '*.c' -o -name '*.h' -o -name '*.cpp' \) -print0)

leftover="$(grep -rl "${OLD_SYM}\|${OLD_PATH}" "${CPP_DIR}" 2>/dev/null || true)"
[ -z "${leftover}" ] || die "JNI 源码里仍有旧包名残留：${leftover}"
log "JNI 符号与类路径已替换（Java_${NEW_SYM}_* / ${NEW_PATH}/*）"

# ---------------------------------------------------------------------------
# 4. consumer-rules.pro（会被打进 AAR 作为 proguard.txt）
# ---------------------------------------------------------------------------
if [ -f "${LIB_MODULE}/consumer-rules.pro" ]; then
  sed -i "s|${OLD_PKG}|${NEW_PKG}|g" "${LIB_MODULE}/consumer-rules.pro"
  log "consumer-rules.pro 已替换"
fi

# ---------------------------------------------------------------------------
# 5. gradle：namespace 与 AAR 文件名
# ---------------------------------------------------------------------------
GRADLE_FILE="${LIB_MODULE}/build.gradle"
[ -f "${GRADLE_FILE}" ] || die "找不到 ${GRADLE_FILE}"

sed -i -E "s|^([[:space:]]*namespace[[:space:]]*=[[:space:]]*).*$|\1'${NEW_PKG}'|" "${GRADLE_FILE}"
sed -i -E "s|^([[:space:]]*archivesName[[:space:]]*=[[:space:]]*).*$|\1\"${REBRAND_ARCHIVE_NAME}\"|" "${GRADLE_FILE}"
log "gradle namespace=${NEW_PKG}, archivesName=${REBRAND_ARCHIVE_NAME}"

# ---------------------------------------------------------------------------
# 6. android/jni/ffmpeg/Android.mk —— prebuilt ffmpeg 库改名
#    LOCAL_MODULE := libavcodec        -> fkit_avcodec
#    LOCAL_SRC_FILES := libavcodec.so  -> libfkit_avcodec.so
#    两种命名规则（lib<module>.so / src 文件名）结果一致
# ---------------------------------------------------------------------------
for lib in ${REBRAND_FFMPEG_LIBS}; do
  sed -i \
    -e "s|lib${lib}\.so|lib${PREFIX}_${lib}.so|g" \
    -e "s|lib${lib}\b|${PREFIX}_${lib}|g" \
    "${FFMPEG_MK}"
done
log "${FFMPEG_MK##*/} 中 7 个 ffmpeg 库的 module/src 名已替换"

# ---------------------------------------------------------------------------
# 7. android/jni/Android.mk
#    a) 包装库模块名（只匹配整行，避免误伤 armv7a-neon 分支）
#    b) arm64 用的 LOCAL_SHARED_LIBRARIES 精确整行替换
# ---------------------------------------------------------------------------
sed -i -E \
  -e "s|^([[:space:]]*LOCAL_MODULE[[:space:]]*:=[[:space:]]*)ffmpegkit_abidetect[[:space:]]*$|\1${PREFIX}_abidetect|" \
  -e "s|^([[:space:]]*LOCAL_MODULE[[:space:]]*:=[[:space:]]*)ffmpegkit[[:space:]]*$|\1${PREFIX}|" \
  "${JNI_MK}"

sed -i -E \
  -e "s|^([[:space:]]*LOCAL_SHARED_LIBRARIES[[:space:]]*:=[[:space:]]*)libavfilter libavformat libavcodec libavutil libswresample libavdevice libswscale[[:space:]]*$|\1${PREFIX}_avfilter ${PREFIX}_avformat ${PREFIX}_avcodec ${PREFIX}_avutil ${PREFIX}_swresample ${PREFIX}_avdevice ${PREFIX}_swscale|" \
  "${JNI_MK}"

grep -q "LOCAL_MODULE := ${PREFIX}$" "${JNI_MK}" || die "Android.mk 里包装库模块名替换失败"
grep -q "LOCAL_SHARED_LIBRARIES := ${PREFIX}_avfilter" "${JNI_MK}" || die "Android.mk 里 LOCAL_SHARED_LIBRARIES 替换失败"
log "android/jni/Android.mk 包装库模块名与依赖列表已替换"

# ---------------------------------------------------------------------------
# 8. 给 scripts/android/ffmpeg.sh 注入 SLIBPREF 覆盖
#    configure 之后、make 之前改 ffbuild/config.mak，让 ffmpeg 直接产出
#    lib<前缀>_avcodec.so，并且 SONAME / DT_NEEDED 天然正确。
# ---------------------------------------------------------------------------
MARK_BEGIN="# >>> ffmpeg-kit-next rebrand: SLIBPREF >>>"
MARK_END="# <<< ffmpeg-kit-next rebrand: SLIBPREF <<<"

if ! grep -qF "${MARK_BEGIN}" "${FFMPEG_SH}"; then
  # 用 -F 定长匹配：既避开 ERE 里 "$" 被当作行尾锚点的坑，也顺带兼容 CRLF 行尾
  ANCHOR_LINE=""
  for anchor in \
    'if [[ -z ${NO_OUTPUT_REDIRECTION} ]]; then' \
    '${CONFIGURE_POSTFIX} 1>>"${BASEDIR}"/build.log 2>&1'; do
    ANCHOR_LINE="$(grep -nF -- "${anchor}" "${FFMPEG_SH}" | head -1 | cut -d: -f1)"
    if [ -n "${ANCHOR_LINE}" ]; then
      log "SLIBPREF 注入锚点：'${anchor}'（第 ${ANCHOR_LINE} 行）"
      break
    fi
  done

  if [ -z "${ANCHOR_LINE}" ]; then
    log "警告：在 ${FFMPEG_SH##*/} 里找不到注入锚点，跳过 SLIBPREF 注入；"
    log "      构建后 rebrand-native.sh 会用 patchelf 兜底改名"
  else
    # 注意：这里刻意不用 mktemp。在某些受限环境（例如 Windows Git Bash）mktemp 会返回
    # 带盘符的系统临时目录路径（C:\Users\...\Temp/xxx），后续删除可能被安全策略拒绝，
    # 导致整个改名流程中断。改为在目标脚本同目录下建临时文件，任何环境都可靠。
    BLOCK_FILE="${FFMPEG_SH}.rebrand-block.$$"
    trap 'rm -f "${BLOCK_FILE:-}"' EXIT INT TERM
    # 用引号 heredoc 原样写出，再把占位符替换成真正的前缀
    cat > "${BLOCK_FILE}" <<'EOF'

# >>> ffmpeg-kit-next rebrand: SLIBPREF >>>
_REBRAND_SLIBPREF="lib@@PREFIX@@_"
if grep -q '^SLIBPREF=' "${BASEDIR}"/src/ffmpeg/ffbuild/config.mak 2>/dev/null; then
  ${SED_INLINE} "s|^SLIBPREF=.*|SLIBPREF=${_REBRAND_SLIBPREF}|" "${BASEDIR}"/src/ffmpeg/ffbuild/config.mak
  echo -e "INFO: rebrand: ffmpeg SLIBPREF -> ${_REBRAND_SLIBPREF}\n" 1>>"${BASEDIR}"/build.log 2>&1
else
  echo -e "INFO: rebrand: WARNING SLIBPREF not found in ffbuild/config.mak; post-build rename will fix it\n" 1>>"${BASEDIR}"/build.log 2>&1
fi
# <<< ffmpeg-kit-next rebrand: SLIBPREF <<<
EOF
    sed -i "s|@@PREFIX@@|${PREFIX}|g" "${BLOCK_FILE}"
    sed -i "${ANCHOR_LINE}r ${BLOCK_FILE}" "${FFMPEG_SH}"
    rm -f "${BLOCK_FILE}"
    trap - EXIT INT TERM
    log "已在 ${FFMPEG_SH##*/} 第 ${ANCHOR_LINE} 行后注入 SLIBPREF=lib${PREFIX}_"
  fi
else
  log "${FFMPEG_SH##*/} 里已存在 SLIBPREF 注入（跳过）"
fi

# ---------------------------------------------------------------------------
# 9. 修上游 meson cross file 的 pkg-config 键名 bug（rubberband 构建失败根因）
#
#    scripts/function-android.sh 的 create_mason_cross_file() 生成的是：
#        [binaries]
#        ...
#        pkg-config = 'pkg-config'     <-- 键名错了
#
#    而 meson 在 [binaries] 里认的键名是 **pkgconfig**（不带连字符）。关键在于
#    meson 定位 pkg-config 时用的是：
#        find_external_program(env, for_machine, 'pkgconfig', 'Pkg-config',
#                              environment.default_pkgconfig,
#                              allow_default_for_cross=False)
#    allow_default_for_cross=False 意味着【交叉编译时不会回退到 PATH 去找
#    pkg-config】，只认 cross file 里的 'pkgconfig' 键。键名写错 -> meson 认为
#    系统没有 pkg-config -> 打印红色 'Found Pkg-config: NO'
#    (mesonbuild/dependencies/pkgconfig.py) -> 所有 dependency() 探测失败。
#
#    影响面：本仓库用 meson 构建的库只有 dav1d / harfbuzz / liblc3 / rubberband，
#    其中只有 rubberband 需要外部依赖（libsamplerate），所以只有它会炸：
#        meson.build:317:4: ERROR: C++ header 'samplerate.h' not found
#    这是上游在非 Nix 路径上的真实缺陷，这里就地修正。修正后 pkg-config 会被正常
#    调用，并继承 run-android.sh 导出的 PKG_CONFIG_LIBDIR（= INSTALL_PKG_CONFIG_DIR，
#    其中已有 libsamplerate.sh 拷进去的 samplerate.pc），探测即可通过。
# ---------------------------------------------------------------------------
FUNC_ANDROID_SH="${ROOT}/scripts/function-android.sh"
[ -f "${FUNC_ANDROID_SH}" ] || die "找不到 ${FUNC_ANDROID_SH}"

if grep -qF "pkgconfig = 'pkg-config'" "${FUNC_ANDROID_SH}"; then
  log "meson cross file 键名已是 pkgconfig（跳过）"
elif grep -qF "pkg-config = 'pkg-config'" "${FUNC_ANDROID_SH}"; then
  sed -i "s|^pkg-config = 'pkg-config'|pkgconfig = 'pkg-config'|" "${FUNC_ANDROID_SH}"
  grep -qF "pkgconfig = 'pkg-config'" "${FUNC_ANDROID_SH}" || die "meson cross file 键名替换失败"
  log "已修正 meson cross file：pkg-config -> pkgconfig（rubberband 探测 libsamplerate 用）"
else
  die "在 ${FUNC_ANDROID_SH##*/} 里找不到 \"pkg-config = 'pkg-config'\"，上游结构可能已变，请人工确认"
fi

# ---------------------------------------------------------------------------
# 10. 让 GPL 构建同时打开 --enable-version3
#
#     ffmpeg configure 里 OpenSSL 的检查是（configure:7551 附近）：
#         enabled openssl && { { check_pkg_config openssl "openssl >= 3.0.0" ... &&
#             { enabled gplv3 || ! enabled gpl || enabled nonfree ||
#               die "ERROR: OpenSSL >=3.0.0 requires --enable-version3"; }; } || ... }
#     即：一旦 --enable-gpl 且本机 OpenSSL >= 3.0.0，就必须再给 --enable-version3，
#     否则直接 die。ffmpeg-kit 编的是 openssl-3.5.7（scripts/source.sh），满足 >= 3.0.0，
#     而 scripts/android/ffmpeg.sh 只在 GPL_ENABLED=yes 时加了 --enable-gpl，
#     从来没加过 --enable-version3 —— 于是 GPL 全量构建必然卡在这一步。
#
#     另有一个同类隐患（configure:4831）：
#         map "die_license_disabled version3" $EXTERNAL_LIBRARY_VERSION3_LIST ...
#     会对 gmp / libopencore_amrnb / libopencore_amrwb / libvo_amrwbenc 这些
#     version3-only 的库报「xxx is version3 and --enable-version3 is not specified」。
#     这次 GPL 全量构建里 gmp、opencore-amr、vo-amrwbenc 都是开的，同样依赖这个开关。
#     加上 --enable-version3 一并消除。
#
#     许可影响：--enable-gpl + --enable-version3 => GPL version 3 or later。
#     本构建里 rubberband v4 本身就是 GPL-3.0-or-later，产物本来就已经是 GPLv3，
#     所以这里只是把许可声明对齐，不引入新的许可约束。
# ---------------------------------------------------------------------------
VER3_FLAG='CONFIGURE_POSTFIX+=" --enable-version3"'
if grep -qF "${VER3_FLAG}" "${FFMPEG_SH}"; then
  log "ffmpeg.sh 已注入 --enable-version3（跳过）"
else
  grep -qF 'CONFIGURE_POSTFIX+=" --enable-gpl"' "${FFMPEG_SH}" \
    || die "在 ${FFMPEG_SH##*/} 里找不到 CONFIGURE_POSTFIX+=\" --enable-gpl\"，上游结构可能已变"
  sed -i 's|^  CONFIGURE_POSTFIX+=" --enable-gpl"$|  CONFIGURE_POSTFIX+=" --enable-gpl"\n  CONFIGURE_POSTFIX+=" --enable-version3"|' "${FFMPEG_SH}"
  grep -qF "${VER3_FLAG}" "${FFMPEG_SH}" || die "--enable-version3 注入失败"
  grep -qF 'CONFIGURE_POSTFIX+=" --enable-gpl"' "${FFMPEG_SH}" || die "注入后 --enable-gpl 丢失"
  log "已注入 --enable-version3（OpenSSL >= 3.0.0 + GPL 的硬性要求）"
fi

# ---------------------------------------------------------------------------
# 11. 结果自检 + 摘要
# ---------------------------------------------------------------------------
printf '\n'
log "==== 改名配置摘要 ===="
log "动态库"
log "  libavcodec.so    -> lib${PREFIX}_avcodec.so"
log "  libavdevice.so   -> lib${PREFIX}_avdevice.so"
log "  libavfilter.so   -> lib${PREFIX}_avfilter.so"
log "  libavformat.so   -> lib${PREFIX}_avformat.so"
log "  libavutil.so     -> lib${PREFIX}_avutil.so"
log "  libswresample.so -> lib${PREFIX}_swresample.so"
log "  libswscale.so    -> lib${PREFIX}_swscale.so"
log "  libffmpegkit.so  -> lib${PREFIX}.so"
log "  libffmpegkit_abidetect.so -> lib${PREFIX}_abidetect.so"
log "Java 包   : ${NEW_PKG}（请把工程里的 import 同步改掉）"
log "Maven     : ${REBRAND_GROUP_ID}:${REBRAND_ARTIFACT_ID}:<version>"
log "AAR 文件名: ${REBRAND_ARCHIVE_NAME}-release.aar"
printf '\n'
log "如需还原源码改名：git checkout . （本脚本只修改受 git 管理的文件）"
printf '\n'
log "下一步：./android.sh --arch=arm64-v8a --enable-lib-all --enable-gpl --disable-lib-gnutls --no-archive --package-name=${NEW_PKG}"
