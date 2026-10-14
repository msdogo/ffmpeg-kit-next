#!/usr/bin/env bash
# =============================================================================
#  package-aar.sh
#
#  在 rebrand-native.sh 之后运行。
#
#  1. 用 gradle 把 android/libs 里的动态库 + Kotlin API 打成 release AAR
#  2. 生成一个本地 Maven 仓库（含 .aar 与 .pom），目录结构与上游 android.sh 一致：
#       prebuilt/bundle-android-aar-<API>-maven/<groupId 路径>/<artifactId>/<版本>/
#  3. 把所有产物汇总到仓库根的 out/ 目录，方便 CI 上传
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=rebrand.config.env
source "${SCRIPT_DIR}/rebrand.config.env"

ROOT="${REBRAND_REPO_ROOT:-${AUTO_ROOT}}"
API="${REBRAND_API_LEVEL}"
LIB_MODULE_DIR="${ROOT}/android/ffmpeg-kit-next-android-lib"
OUT_DIR="${ROOT}/out"

log() { printf '[package-aar] %s\n' "$*"; }
die() { printf '[package-aar] ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "${ROOT}/android" ] || die "找不到 ${ROOT}/android"
[ -d "${ROOT}/android/libs" ] || die "找不到 ${ROOT}/android/libs，请先构建"

# ---------------------------------------------------------------------------
# 1. 取版本号
# ---------------------------------------------------------------------------
VERSION="$(sed -n 's/.*#define FFMPEG_KIT_VERSION "\([^"]*\)".*/\1/p' "${LIB_MODULE_DIR}/src/main/cpp/ffmpegkit.h" | head -1)"
[ -n "${VERSION}" ] || die "无法从 ffmpegkit.h 解析 FFMPEG_KIT_VERSION"
log "FFmpegKit 版本: ${VERSION}"

# 以 android.sh 写出的 build.mk 为准（它的 API := N 就是真正构建用的 API level）
BUILD_MK_API="$(sed -n 's/^API[[:space:]]*:=[[:space:]]*//p' "${ROOT}/android/jni/build.mk" 2>/dev/null | head -1)"
if [ -n "${BUILD_MK_API}" ]; then
  API="${BUILD_MK_API}"
  log "API level（取自 android/jni/build.mk）: ${API}"
else
  log "API level（取自配置）: ${API}"
fi

# ---------------------------------------------------------------------------
# 2. gradle 打包
# ---------------------------------------------------------------------------
cd "${ROOT}/android"

export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Duser.language=en -Duser.country=US"

log "执行 gradlew assembleRelease ..."
bash ./gradlew --no-daemon ffmpeg-kit-next-android-lib:clean ffmpeg-kit-next-android-lib:assembleRelease

AAR_FILE="$(find "${LIB_MODULE_DIR}/build/outputs/aar" -maxdepth 1 -name '*.aar' | head -1)"
[ -n "${AAR_FILE}" ] || die "gradle 没有产出 .aar"
log "AAR: ${AAR_FILE}"

# ---------------------------------------------------------------------------
# 3. 本地 Maven 仓库
# ---------------------------------------------------------------------------
GROUP_PATH="$(printf '%s' "${REBRAND_GROUP_ID}" | tr '.' '/')"
MAVEN_REPO="${ROOT}/prebuilt/bundle-android-aar-${API}-maven"
MAVEN_ARTIFACT_DIR="${MAVEN_REPO}/${GROUP_PATH}/${REBRAND_ARTIFACT_ID}/${VERSION}"

rm -rf "${MAVEN_ARTIFACT_DIR}"
mkdir -p "${MAVEN_ARTIFACT_DIR}"

cp "${AAR_FILE}" "${MAVEN_ARTIFACT_DIR}/${REBRAND_ARTIFACT_ID}-${VERSION}.aar"

cat > "${MAVEN_ARTIFACT_DIR}/${REBRAND_ARTIFACT_ID}-${VERSION}.pom" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">

  <modelVersion>4.0.0</modelVersion>

  <groupId>${REBRAND_GROUP_ID}</groupId>
  <artifactId>${REBRAND_ARTIFACT_ID}</artifactId>
  <version>${VERSION}</version>
  <packaging>aar</packaging>

  <dependencies>
    <dependency>
      <groupId>com.arthenica</groupId>
      <artifactId>smart-exception-java</artifactId>
      <version>0.2.1</version>
      <scope>runtime</scope>
    </dependency>
  </dependencies>
</project>
EOF

log "本地 Maven 仓库: ${MAVEN_REPO}"

# ---------------------------------------------------------------------------
# 4. 汇总产物到 out/
# ---------------------------------------------------------------------------
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}/maven" "${OUT_DIR}/libs"

ABIS="$(find "${ROOT}/android/libs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tr '\n' ' ')"
ABI_TAG="$(printf '%s' "${ABIS}" | tr ' ' '_' | sed 's/_$//')"
[ -n "${ABI_TAG}" ] || ABI_TAG="unknown"

cp "${AAR_FILE}" "${OUT_DIR}/${REBRAND_ARTIFACT_ID}-${VERSION}-${ABI_TAG}.aar"

# 需要放进 Maven 仓库的内容（保持目录结构）
mkdir -p "${OUT_DIR}/maven/${GROUP_PATH}/${REBRAND_ARTIFACT_ID}/${VERSION}"
cp "${MAVEN_ARTIFACT_DIR}/${REBRAND_ARTIFACT_ID}-${VERSION}.aar" "${OUT_DIR}/maven/${GROUP_PATH}/${REBRAND_ARTIFACT_ID}/${VERSION}/"
cp "${MAVEN_ARTIFACT_DIR}/${REBRAND_ARTIFACT_ID}-${VERSION}.pom" "${OUT_DIR}/maven/${GROUP_PATH}/${REBRAND_ARTIFACT_ID}/${VERSION}/"

# 动态库单独一份（想直接丢进自己 jniLibs 的场景）
for abi_dir in "${ROOT}/android/libs"/*/; do
  abi="$(basename "${abi_dir}")"
  mkdir -p "${OUT_DIR}/libs/${abi}"
  cp "${abi_dir}"*.so "${OUT_DIR}/libs/${abi}/"
done

( cd "${OUT_DIR}" && zip -qr "${OUT_DIR}/${REBRAND_ARTIFACT_ID}-${VERSION}-maven-repo.zip" maven )
( cd "${OUT_DIR}" && zip -qr "${OUT_DIR}/${REBRAND_ARTIFACT_ID}-${VERSION}-libs.zip" libs )
rm -rf "${OUT_DIR}/maven" "${OUT_DIR}/libs"

# ---------------------------------------------------------------------------
# 5. 校验 + 报告
# ---------------------------------------------------------------------------
AAR_LIST="$(unzip -l "${OUT_DIR}/${REBRAND_ARTIFACT_ID}-${VERSION}-${ABI_TAG}.aar")"

printf '\n[package-aar] AAR 内的动态库：\n'
printf '%s\n' "${AAR_LIST}" | awk '/\.so$/ { printf "  %s\n", $NF }'

if printf '%s' "${AAR_LIST}" | grep -Eq '/lib(avcodec|avformat|avutil|avfilter|avdevice|swscale|swresample)\.so$'; then
  die "AAR 里仍然存在未改名的 libav*/libsw*.so，改名流程有问题"
fi

printf '\n[package-aar] 产物清单：\n'
ls -lh "${OUT_DIR}" | tail -n +2

( cd "${OUT_DIR}" && sha256sum ./*.aar ./*.zip > SHA256SUMS ) 2>/dev/null || true

printf '\n'
log "完成 ✅"
log "  AAR        : out/${REBRAND_ARTIFACT_ID}-${VERSION}-${ABI_TAG}.aar"
log "  Maven 仓库 : out/${REBRAND_ARTIFACT_ID}-${VERSION}-maven-repo.zip"
log "  动态库     : out/${REBRAND_ARTIFACT_ID}-${VERSION}-libs.zip"
log "  依赖声明   : ${REBRAND_GROUP_ID}:${REBRAND_ARTIFACT_ID}:${VERSION}"
