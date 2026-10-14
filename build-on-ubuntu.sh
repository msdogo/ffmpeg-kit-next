#!/usr/bin/env bash
# =============================================================================
#  build-on-ubuntu.sh
#
#  在本机 Ubuntu 上编译「改名版」FFmpegKitNext for Android
#  （arm64-v8a / 全量外部库 / 所有 .so 改名以避开 DJI SDK 的 FFmpeg 冲突）
#
#  最终产物：<源码目录>/out/ 下的
#      ffmpeg-kit-release.aar          可直接放进 App 的 libs/ 用
#      bundle-android-aar-24-maven/    本地 Maven 仓库（含 .aar + .pom）
#      libs/arm64-v8a/*.so             9 个 libfkit_*.so（已改名、已校验）
#
#  用法（最简，全部默认）：
#      bash build-on-ubuntu.sh
#
#  常用组合：
#      bash build-on-ubuntu.sh --jobs 8
#      bash build-on-ubuntu.sh --stage build      # 工具链/源码已就绪，直接从编译开始
#      bash build-on-ubuntu.sh --from-local /path/to/work-fork
#      bash build-on-ubuntu.sh --dry-run          # 只打印将执行的命令，不做任何改动
#
#  阶段（--stage 指定起点，该阶段及其后所有阶段都会执行）：
#      checks -> deps -> sdk -> src -> build -> pack
#
#  为什么做成可分段重入：
#      55 个外部库 + ffmpeg 自身，本机通常要 15~30 分钟。中途任何一步失败，
#      用 `--stage build` 就能从编译接着跑，不用重新装 apt 依赖和 NDK。
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
WORKDIR="${HOME}/ffmpeg-kit-build"
STAGE="checks"
JOBS=""
FROM_LOCAL=""
PKG_NAME=""         # 空=从 tools/rebrand/rebrand.config.env 自动取
BRANCH="main"
CLONE_URL="https://github.com/msdogo/ffmpeg-kit-next.git"
DRY_RUN=0
API_LEVEL="24"
NDK_VERSION="27.3.13750724"
PLATFORM_VERSION="34"
BUILD_TOOLS_VERSION="35.0.0"
CMAKE_VERSION="3.22.1"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

STAGES=(checks deps sdk src build pack)
SRC_DIR=""          # 由 --workdir 推导
LOGS=""             # 由 --workdir 推导
MIN_DISK_GB=35      # 55 个库的中间产物非常占地方

# ---------------------------------------------------------------------------
# 输出helper
# ---------------------------------------------------------------------------
c_info()  { printf '\033[36m[info ]\033[0m %s\n' "$*"; }
c_ok()    { printf '\033[32m[ ok  ]\033[0m %s\n' "$*"; }
c_warn()  { printf '\033[33m[warn ]\033[0m %s\n' "$*" >&2; }
c_die()   { printf '\033[31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }
stage_hdr(){ printf '\n\033[1m============================================================\n 阶段：%s\n============================================================\033[0m\n' "$*"; }

usage() {
  # 打印文件顶部的注释块（跳过 shebang，遇到第一个非注释行即停）
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
  cat <<'EOF'

可选参数：
  --stage NAME       从哪个阶段开始（checks|deps|sdk|src|build|pack），默认 checks
  --workdir PATH     构建根目录，默认 $HOME/ffmpeg-kit-build（源码/日志/SDK 都放这里）
  --jobs N           并行编译数，默认按 CPU 与内存自动推算并上限 8
  --from-local PATH  用本地已存在的源码目录（如 Windows 上的 work-fork），
                     而不是去 GitHub clone
  --branch REF       clone 的分支/标签，默认 main
  --clone-url URL    fork 地址，默认 msdogo/ffmpeg-kit-next
  --api-level N      Android API level，默认 24
  --package-name P   原生侧上报的包名（对应 android.sh --package-name），
                     默认从 tools/rebrand/rebrand.config.env 的
                     REBRAND_JAVA_PACKAGE 自动读取
  --dry-run          只打印将执行的命令
  -h | --help        显示本帮助
EOF
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --stage)      STAGE="${2:?--stage 需要值}"; shift 2 ;;
    --workdir)    WORKDIR="${2:?--workdir 需要值}"; shift 2 ;;
    --jobs)       JOBS="${2:?--jobs 需要值}"; shift 2 ;;
    --from-local) FROM_LOCAL="${2:?--from-local 需要值}"; shift 2 ;;
    --branch)     BRANCH="${2:?--branch 需要值}"; shift 2 ;;
    --clone-url)  CLONE_URL="${2:?--clone-url 需要值}"; shift 2 ;;
    --api-level)  API_LEVEL="${2:?--api-level 需要值}"; shift 2 ;;
    --package-name)    PKG_NAME="${2:?--package-name 需要值}"; shift 2 ;;
    --package-name=*)  PKG_NAME="${1#--package-name=}"; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            c_die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

case " ${STAGES[*]} " in
  *" ${STAGE} "*) : ;;
  *) c_die "--stage 只能是：${STAGES[*]}" ;;
esac
case "${API_LEVEL}" in
  ''|*[!0-9]*) c_die "--api-level 必须是数字" ;;
esac

SRC_DIR="${WORKDIR}/ffmpeg-kit-next"
LOGS="${WORKDIR}/logs"
SDK_DIR="${WORKDIR}/android-sdk"
ENV_FILE="${WORKDIR}/env.sh"

# should_run <阶段名> —— 该阶段是否在本次的待执行区间内
should_run() {
  local want="$1" i started=0
  for i in "${STAGES[@]}"; do
    [ "$i" = "${STAGE}" ] && started=1
    if [ "${started}" = "1" ] && [ "$i" = "${want}" ]; then return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
mem_total_mb() {
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo
  else
    echo 4096
  fi
}

# 可用磁盘（GB，整数）。目录不存在时向上找到最近的已存在祖先。
disk_free_gb() {
  local d="$1"
  while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
  df -Pk "$d" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}'
}

# 按 CPU 与内存推算并行数：每个编译任务高峰约 3GB，上限 8
auto_jobs() {
  local ncpu memmb bymem j
  ncpu="$(nproc 2>/dev/null || echo 4)"
  memmb="$(mem_total_mb)"
  bymem=$(( memmb / 3072 ))
  [ "${bymem}" -lt 1 ] && bymem=1
  j="${ncpu}"
  [ "${bymem}" -lt "${j}" ] && j="${bymem}"
  [ "${j}" -lt 1 ] && j=1
  [ "${j}" -gt 8 ] && j=8
  printf '%s' "${j}"
}

# 读取某个 JDK 安装目录的主版本（如 /usr/lib/jvm/java-17-openjdk-amd64）。
# 优先 $dir/release —— JVM 规范文件，不受 JAVA_TOOL_OPTIONS / locale 影响；
# 注意 Debian/Ubuntu 的 openjdk-17-jdk-headless 自己的文件清单里**没有** release
# （由依赖包 openjdk-17-jre-headless 提供），布局一旦不同就会误判成「不是 JDK」。
# 所以读不到 release 时回落解析 bin/java -version，并用引号锚定 version token，
# 以天然跳过 JVM 先打印的 "Picked up JAVA_TOOL_OPTIONS:" 行。
java_major_of() {
  local d="${1%/}" maj=""
  if [ -n "${d}" ] && [ -r "${d}/release" ]; then
    maj="$(sed -n 's/^JAVA_VERSION="\([0-9][0-9]*\).*/\1/p' "${d}/release" | head -n 1)"
  fi
  if [ -z "${maj}" ] && [ -n "${d}" ] && [ -x "${d}/bin/java" ]; then
    maj="$("${d}/bin/java" -version 2>&1 | tr -d '\r' \
          | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1 || true)"
  fi
  [ -n "${maj}" ] || return 1
  printf '%s' "${maj}"
}

# 在 /usr/lib/jvm 下挑一个 Gradle 8.14.5 能用的 JDK（17~24），优先高版本。
# 绝不能选 25：Ubuntu 26.04 LTS 默认就是 JDK 25，而 Gradle 8.14.5 支持上限是 24。
pick_system_jdk() {
  local d maj best="" bestmaj=0
  for d in /usr/lib/jvm/*/; do
    [ -r "${d}release" ] || [ -x "${d}bin/java" ] || continue
    maj="$(java_major_of "${d%/}" || true)"
    [ -n "${maj}" ] || continue
    [ "${maj}" -ge 17 ] && [ "${maj}" -le 24 ] || continue
    if [ "${maj}" -gt "${bestmaj}" ]; then best="${d%/}"; bestmaj="${maj}"; fi
  done
  [ -n "${best}" ] && printf '%s' "${best}"
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# 把 Windows 侧遗留的 CRLF 统一成 LF。这个不是"洁癖"，是硬需求：
#   - .patch 带 CRLF → Linux 的 git apply 直接拒绝，报 "does not apply cleanly"
#     （SDL 的 configure.android-opensles.patch 上实测踩到，整轮构建挂在 sdl: failed）
#   - shell 脚本带 CRLF → "bad interpreter: ...bash\r"
# tools/ 下全是文本（补丁 + 改名脚本），整目录清一遍最省事；
# 根目录文件 + 构建关键扩展名再覆盖一次；src/ 是上游 clone 的库源码（本来就 LF），跳过。
crlf_to_lf() {
  local root="$1"
  [ -n "${root}" ] && [ -d "${root}" ] || return 0
  find "${root}/tools" -type f -print0 2>/dev/null \
    | xargs -0 -r sed -i 's/\r$//' 2>/dev/null || true
  find "${root}" -type f -not -path '*/.git/*' -not -path "${root}/src/*" \
    \( -name '*.sh' -o -name '*.py' -o -name '*.mk' -o -name 'Makefile*' \
       -o -name '*.config' -o -name '*.patch' -o -name '*.in' -o -name '*.am' \
       -o -name '*.ac' -o -name 'configure' \) -print0 2>/dev/null \
    | xargs -0 -r sed -i 's/\r$//' 2>/dev/null || true
  return 0
}

# 取目标 Java 包名，用于 android.sh 的 --package-name。
# 配置里写的是参数展开形式 ${REBRAND_JAVA_PACKAGE:-com.fkit.ffmpegkit}，
# 直接 sed 取 `:-` 后面的默认值即可，避免 source 整个文件引入副作用。
detect_pkg_name() {
  local f="$1/tools/rebrand/rebrand.config.env" v=""
  if [ -r "${f}" ]; then
    v="$(sed -n 's/.*REBRAND_JAVA_PACKAGE:-\([^}"]*\)}.*/\1/p' "${f}" | head -n 1)"
  fi
  [ -n "${v}" ] || v="com.fkit.ffmpegkit"
  printf '%s' "${v}"
}

# ===========================================================================
#  阶段 1：checks
# ===========================================================================
do_checks() {
  stage_hdr "checks（环境自检）"

  if [ "${DRY_RUN}" = "1" ]; then
    c_warn "dry-run：跳过平台检查（实际执行时要求 Linux）"
  else
    [ "$(uname -s)" = "Linux" ] || c_die "本脚本只能在 Linux 上运行（当前：$(uname -s)）"
  fi
  c_ok "系统：$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}"; uname -m 2>/dev/null || echo '?' )"

  local ncpu memmb
  ncpu="$(nproc 2>/dev/null || echo '?')"
  memmb="$(mem_total_mb)"
  c_info "CPU 核心：${ncpu}    内存：$(( memmb / 1024 )) GB"

  [ -z "${JOBS}" ] && JOBS="$(auto_jobs)"
  case "${JOBS}" in ''|*[!0-9]*) c_die "--jobs 必须是数字" ;; esac
  [ "${JOBS}" -ge 1 ] || c_die "--jobs 至少为 1"

  # 交叉编译 55 个库，内存太小时链接阶段容易 OOM
  if [ "${memmb}" -lt 6144 ]; then
    c_warn "内存只有 $(( memmb / 1024 )) GB，LTO 链接可能 OOM。"
    c_warn "建议：--jobs 2，并在 BUILD_OPTS 里追加 --no-link-time-optimization"
  fi

  local free
  free="$(disk_free_gb "${WORKDIR}")"
  c_info "构建目录：${WORKDIR}    该分区可用：${free} GB"
  if [ "${free}" -lt "${MIN_DISK_GB}" ]; then
    c_die "可用空间不足 ${MIN_DISK_GB} GB（当前 ${free} GB）。55 个外部库的中间产物很大。
      可以：1) 清理磁盘；2) 用 --workdir 指向更大的分区，例如 --workdir /data/ffmpeg-build"
  fi

  # 网络：clone 源码 + 下载 NDK 都需要
  if need_cmd curl; then
    if curl -sSfI --max-time 20 https://github.com >/dev/null 2>&1; then
      c_ok "网络：github.com 可达"
    else
      c_warn "github.com 不可达；若用 --from-local 提供源码则不受影响，但 NDK/SDK 仍需联网下载"
    fi
  else
    c_warn "未找到 curl（deps 阶段会装）"
  fi

  # CMake 版本预警：Ubuntu 26.04 自带 cmake 4.x，而 CMake 4.0 起对
  # cmake_minimum_required(<3.5) 是硬错误。libvidstab / soxr 这类老工程会直接挂。
  # 脚本会用 SDK 自带的 3.22.1（与上游 CI 一致），这里只做提示。
  if need_cmd cmake; then
    local SYSCMAKE VER MAJ
    VER="$(cmake --version 2>/dev/null | head -n 1)"
    SYSCMAKE="$(command -v cmake)"
    MAJ="$(printf '%s' "${VER}" | sed -n 's/.*version[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    if [ -n "${MAJ}" ] && [ "${MAJ}" -ge 4 ]; then
      c_warn "系统 cmake 是 ${VER}（${SYSCMAKE}）——4.x 会拒绝 cmake_minimum_required(<3.5) 的老工程。"
      c_warn "本脚本会让 SDK 自带的 CMake ${CMAKE_VERSION} 优先，无需你手工处理。"
    else
      c_info "系统 cmake：${VER}"
    fi
  else
    c_info "未找到系统 cmake（deps 阶段会装；真正构建用的是 SDK 自带的 ${CMAKE_VERSION}）"
  fi

  if [ -n "${FROM_LOCAL}" ]; then
    [ -d "${FROM_LOCAL}/tools/rebrand" ] || c_die "--from-local 指向的目录里没有 tools/rebrand/：${FROM_LOCAL}
      ⇒ 这不是「已含改名脚本的 fork」，很可能是上游 arthenica 原版（它不改名，编出来
        仍是 libav*.so，会与 DJI SDK 冲突）。请换成本 fork 的目录，或去掉 --from-local
        让脚本从 fork clone。"
    [ -f "${FROM_LOCAL}/android.sh" ] || c_die "--from-local 指向的目录里没有 android.sh：${FROM_LOCAL}"
    [ -f "${FROM_LOCAL}/tools/rebrand/rebrand-sources.sh" ] \
      || c_die "--from-local 里缺少 tools/rebrand/rebrand-sources.sh：${FROM_LOCAL}（fork 不完整）"
    # .git 是硬依赖：android.sh:39 跑 `git describe --tags --always` 取 BUILD_VERSION，
    # 第 118 行发现为空会直接 "Can not run git commands in this folder" + exit 1。
    # 所以 --from-local 必须是**可用的 git 仓库**（zip 解压 / 裸拷文件都不行）。
    [ -d "${FROM_LOCAL}/.git" ] || c_die "--from-local 指向的目录不是 git 仓库（缺 .git）：${FROM_LOCAL}
      android.sh 依赖 git 生成版本号，缺 .git 会在编译一开始就 exit 1。
      二选一：
        (a) 用它 clone 一份：git clone https://github.com/msdogo/ffmpeg-kit-next.git
        (b) 就地把它变成 git 仓库：
            cd \"${FROM_LOCAL}\" && git init -q && git add -A \\
              && git -c user.email=a@b -c user.name=a commit -qm init"
    if need_cmd git; then
      local _desc
      if _desc="$(git -C "${FROM_LOCAL}" describe --tags --always 2>&1)"; then
        c_ok "本地源码：${FROM_LOCAL}（git describe: ${_desc}）"
      else
        c_die "--from-local 的 .git 存在但无法执行 git describe（对象库可能损坏或没有任何提交）：
        ${_desc}
      请改用 clone 模式，或按上面的 (b) 重建一个可用仓库。"
      fi
    else
      c_warn "--from-local 已给出，但当前没有 git 可用于预检（deps 阶段会装）"
      c_ok "本地源码：${FROM_LOCAL}"
    fi
  fi
  c_ok "并行编译数：${JOBS}"
}

# ===========================================================================
#  阶段 2：deps（apt 依赖 + JDK）
# ===========================================================================
do_deps() {
  stage_hdr "deps（主机构建依赖 + JDK）"

  if [ "${DRY_RUN}" = "1" ]; then
    c_info "[dry-run] 跳过 apt 安装与 JDK 探测"
    return 0
  fi

  need_cmd apt-get || c_die "本脚本按 Debian/Ubuntu 的 apt 设计，当前系统没有 apt-get"

  # 与上游 flake.nix 的 commonToolPackages + androidPackages 对齐。
  # 逐个 apt-cache show 探测再安装：不同镜像/发行版里个别包名可能不存在
  # （例如某些版本没有独立的 which 包，which 由 debianutils 提供），
  # 整串直接 install 会因一个包定位失败而 exit 100。
  local PKGS="
    build-essential gcc g++ make cmake ninja-build meson
    autoconf automake libtool libtool-bin autopoint m4
    pkg-config bison flex gperf ragel autogen
    nasm yasm
    gettext texinfo groff gawk
    doxygen gtk-doc-tools
    python3 python3-pip perl ruby
    rsync zip unzip wget curl gnupg ca-certificates file patch
    debianutils
    libtasn1-bin libtasn1-6-dev zlib1g-dev patchelf
    git sudo
  "
  c_info "更新 apt 索引 ..."
  sudo apt-get update -qq

  local INSTALL="" SKIPPED="" p
  for p in ${PKGS}; do
    if apt-cache show "${p}" >/dev/null 2>&1; then
      INSTALL="${INSTALL} ${p}"
    else
      SKIPPED="${SKIPPED} ${p}"
    fi
  done
  [ -n "${SKIPPED}" ] && c_warn "当前 apt 源里没有这些包，已跳过：${SKIPPED}"

  c_info "安装：${INSTALL}"
  # shellcheck disable=SC2086
  sudo apt-get install -y --no-install-recommends ${INSTALL}

  # 关键工具自检：缺任何一个都提前失败，而不是等到编译到第 44 个库
  # （gnutls）才以 make Error 127 暴露 —— asn1Parser 来自 libtasn1-bin，
  # gnutls.sh 自身没有任何工具检查，是最典型的坑。
  local MISSING="" t
  for t in make cmake ninja meson patchelf nasm yasm autoconf automake \
           libtoolize autoreconf autogen bison flex gperf ragel \
           asn1Parser python3 perl pkg-config gawk patch zip unzip file which git; do
    need_cmd "${t}" || MISSING="${MISSING} ${t}"
  done
  if [ -n "${MISSING}" ]; then
    c_die "关键构建工具仍然缺失：${MISSING}
      多数情况是包名在该发行版里不同，请手动安装后再用 --stage sdk 继续"
  fi
  c_ok "工具链就绪（asn1Parser: $(command -v asn1Parser)）"

  # ---- JDK：Gradle 8.14.5 支持 JDK 17~24，AGP 8.13.2 要求 >= 17 ----
  local JH
  JH="$(pick_system_jdk || true)"
  if [ -z "${JH}" ]; then
    # 优先 17（与 AGP 8.13.2 兼容性最好），再退到 21/24/23。
    # 注意不要装 25+：Gradle 8.14.5 官方支持上限是 24（Ubuntu 26.04 的默认
    # JDK 就是 25，所以这里必须显式挑低版本，不能直接用系统默认 java）。
    c_info "没找到可用的 JDK 17~24，尝试从 apt 安装 ..."
    local JDK_PKG=""
    for cand in openjdk-17-jdk-headless openjdk-21-jdk-headless \
                openjdk-24-jdk-headless openjdk-23-jdk-headless; do
      if apt-cache show "${cand}" >/dev/null 2>&1; then JDK_PKG="${cand}"; break; fi
    done
    if [ -z "${JDK_PKG}" ]; then
      c_die "apt 源里找不到 JDK 17/21/24/23。请手动装一个 17~24 的 JDK 后重试，例如：
        sudo apt-get install -y openjdk-17-jdk-headless
      或（源里确实没有时）用 SDKMAN：
        curl -s https://get.sdkman.io | bash && source ~/.sdkman/bin/sdkman-init.sh && sdk install java 17.0.13-tem
      装好后确认 /usr/lib/jvm/ 下存在 17~24 的 JDK（有 release 或 bin/java 均可识别）"
    fi
    sudo apt-get install -y --no-install-recommends "${JDK_PKG}"
    JH="$(pick_system_jdk || true)"
  fi
  [ -n "${JH}" ] || c_die "仍未找到可用的 JDK 17~24"

  local jmaj; jmaj="$(java_major_of "${JH}" || echo '?')"
  c_ok "JDK：${JH}（主版本 ${jmaj}）"
  if [ "${jmaj}" = "?" ]; then
    c_warn "读不出 JDK 主版本（${JH}/release 缺失或格式异常），继续，但 gradle 若报版本问题请手动确认"
  elif [ "${jmaj}" -gt 24 ]; then
    c_warn "JDK ${jmaj} 高于 Gradle 8.14.5 支持的上限（24），若 gradle 启动失败请改装 JDK 17 或 21"
  fi
}

# ===========================================================================
#  阶段 3：sdk（Android SDK / NDK / CMake）
# ===========================================================================
do_sdk() {
  stage_hdr "sdk（Android SDK / NDK / CMake）"

  if [ "${DRY_RUN}" = "1" ]; then
    c_info "[dry-run] 跳过 SDK 下载与安装"
    return 0
  fi

  mkdir -p "${SDK_DIR}"
  local SDKMGR="${SDK_DIR}/cmdline-tools/latest/bin/sdkmanager"

  # 已经装过就复用（可重入的关键）
  if [ ! -x "${SDKMGR}" ]; then
    c_info "下载 Android commandline-tools ..."
    local zip="${WORKDIR}/cmdline-tools.zip"
    curl -fL --retry 3 --retry-delay 5 -o "${zip}" "${CMDLINE_TOOLS_URL}"
    rm -rf "${SDK_DIR}/cmdline-tools/latest" "${SDK_DIR}/cmdline-tools-tmp"
    mkdir -p "${SDK_DIR}/cmdline-tools-tmp"
    unzip -q "${zip}" -d "${SDK_DIR}/cmdline-tools-tmp"
    mkdir -p "${SDK_DIR}/cmdline-tools"
    mv "${SDK_DIR}/cmdline-tools-tmp/cmdline-tools" "${SDK_DIR}/cmdline-tools/latest"
    rmdir "${SDK_DIR}/cmdline-tools-tmp" 2>/dev/null || true
    rm -f "${zip}"
    [ -x "${SDKMGR}" ] || c_die "sdkmanager 解压失败，请检查 ${CMDLINE_TOOLS_URL} 是否仍可访问"
    c_ok "cmdline-tools 就绪"
  else
    c_ok "复用已安装的 cmdline-tools"
  fi

  export ANDROID_SDK_ROOT="${SDK_DIR}"
  export ANDROID_HOME="${SDK_DIR}"
  # 注意：只在真拿到 JDK 时才覆盖 JAVA_HOME —— 赋成空串会让 sdkmanager 找不到 java
  local JH; JH="$(pick_system_jdk || true)"
  [ -n "${JH}" ] && export JAVA_HOME="${JH}"

  c_info "接受 SDK 许可 ..."
  yes | "${SDKMGR}" --sdk_root="${SDK_DIR}" --licenses >/dev/null 2>&1 || true

  # 已装的组件不重复下载（sdkmanager 自身幂等，但显式跳过能省时间）
  local want=""
  [ -d "${SDK_DIR}/platform-tools" ]                        || want="${want} platform-tools"
  [ -d "${SDK_DIR}/platforms/android-${PLATFORM_VERSION}" ] || want="${want} platforms;android-${PLATFORM_VERSION}"
  [ -d "${SDK_DIR}/build-tools/${BUILD_TOOLS_VERSION}" ]    || want="${want} build-tools;${BUILD_TOOLS_VERSION}"
  [ -d "${SDK_DIR}/ndk/${NDK_VERSION}" ]                    || want="${want} ndk;${NDK_VERSION}"
  [ -d "${SDK_DIR}/cmake/${CMAKE_VERSION}" ]                || want="${want} cmake;${CMAKE_VERSION}"

  if [ -n "${want}" ]; then
    c_info "安装 SDK 组件（NDK 约 1.5GB，请耐心）：${want}"
    # shellcheck disable=SC2086
    "${SDKMGR}" --sdk_root="${SDK_DIR}" --install ${want}
  else
    c_ok "SDK 组件已齐全"
  fi

  [ -d "${SDK_DIR}/ndk/${NDK_VERSION}" ] || c_die "NDK ${NDK_VERSION} 安装失败"
  c_ok "NDK：$(sed -n 's/^Pkg.Revision[[:space:]]*=[[:space:]]*//p' "${SDK_DIR}/ndk/${NDK_VERSION}/source.properties")"

  # ---- CMake：必须优先用 SDK 自带的那份（默认 3.22.1）----
  # Ubuntu 26.04 的系统 cmake 是 4.x；CMake 4.0 起对 cmake_minimum_required(<3.5)
  # 由「弃用警告」变为**硬错误**，arthenica/vid.stab v1.1.1（VERSION 2.8.5）会直接挂。
  local SDK_CMAKE="${SDK_DIR}/cmake/${CMAKE_VERSION}/bin"
  if [ -x "${SDK_CMAKE}/cmake" ]; then
    export PATH="${SDK_CMAKE}:${PATH}"
    c_ok "CMake：${SDK_CMAKE}/cmake（$("${SDK_CMAKE}/cmake" --version | head -n 1)）"
  else
    c_warn "没找到 SDK 自带的 CMake ${CMAKE_VERSION}（${SDK_CMAKE}）"
    c_warn "将回落到系统 cmake：$(command -v cmake >/dev/null 2>&1 && cmake --version | head -n 1 || echo '未安装')"
    c_warn "若系统 cmake 是 4.x，libvidstab 等老工程会报「Compatibility with CMake < 3.5 has been removed」"
  fi
  # 双保险：官方为 CMake 4.x 提供的兼容开关（旧版 cmake 会忽略）
  export CMAKE_POLICY_VERSION_MINIMUM=3.5
  c_info "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}（兼容老 CMake 工程）"
}

# ===========================================================================
#  阶段 4：src（准备源码）
# ===========================================================================
do_src() {
  stage_hdr "src（准备源码）"

  local need_src=1
  if [ -n "${FROM_LOCAL}" ]; then
    need_src=0
    if [ "${DRY_RUN}" = "1" ]; then
      c_info "[dry-run] 将把 ${FROM_LOCAL} 复制到 ${SRC_DIR}"
    else
      c_info "从本地复制源码：${FROM_LOCAL} -> ${SRC_DIR}"
      mkdir -p "${SRC_DIR}"
      # 保留 .git：android.sh 里 `git describe --tags --always` 会用。
      # 必须排除构建产物目录：否则重跑 --from-local 会把已下载的第三方源码
      # （src/）、已编译好的库（prebuilt/）与日志当成「多余文件」删掉，全部重来。
      rsync -a --delete \
        --exclude='src/' \
        --exclude='prebuilt/' \
        --exclude='.tmp/' \
        --exclude='build.log' \
        "${FROM_LOCAL}/" "${SRC_DIR}/"
      crlf_to_lf "${SRC_DIR}"
      c_ok "源码就绪（已统一为 LF）"
    fi
  fi

  if [ "${need_src}" = "1" ]; then
    if [ -d "${SRC_DIR}/.git" ]; then
      c_info "复用已有源码：${SRC_DIR}"
      if [ "${DRY_RUN}" != "1" ]; then
        git -C "${SRC_DIR}" fetch --depth=1 origin "${BRANCH}" 2>/dev/null || true
        git -C "${SRC_DIR}" reset --hard "origin/${BRANCH}" 2>/dev/null || c_warn "git reset 失败，继续用当前工作区"
      fi
    elif [ "${DRY_RUN}" = "1" ]; then
      c_info "[dry-run] git clone ${CLONE_URL} -> ${SRC_DIR}"
    else
      c_info "克隆 ${CLONE_URL}（分支 ${BRANCH}）..."
      mkdir -p "$(dirname "${SRC_DIR}")"
      local i
      for i in 1 2 3; do
        if git clone --branch "${BRANCH}" "${CLONE_URL}" "${SRC_DIR}"; then break; fi
        c_warn "clone 第 ${i} 次失败，重试 ..."
        rm -rf "${SRC_DIR}"
        [ "${i}" = "3" ] && c_die "clone 连续失败，请检查网络；也可用 --from-local 提供本地源码"
        sleep 5
      done
      c_ok "clone 完成"
    fi
  fi

  [ "${DRY_RUN}" = "1" ] && return 0
  [ -f "${SRC_DIR}/android.sh" ] || c_die "源码目录里没有 android.sh，路径可能不对：${SRC_DIR}"
  [ -f "${SRC_DIR}/tools/rebrand/rebrand-sources.sh" ] || c_die "源码里缺少 tools/rebrand/，请确认用的是已含改名脚本的 fork"
  c_ok "源码校验通过"
}

# ===========================================================================
#  环境文件 —— 后续阶段 source 它拿到 JAVA_HOME / ANDROID_* 与 PATH
# ===========================================================================
write_env_file() {
  local JH; JH="$(pick_system_jdk || true)"
  [ -n "${JH}" ] || c_warn "写 env.sh 时没找到 JDK；若后续 gradle 报错请检查 /usr/lib/jvm"

  if [ "${DRY_RUN}" = "1" ]; then
    c_info "[dry-run] 将写入 ${ENV_FILE}"
    return 0
  fi

  mkdir -p "${WORKDIR}"
  cat > "${ENV_FILE}" <<EOF
# 由 build-on-ubuntu.sh 生成，可 source 后手工重跑任何一步
export WORKDIR="${WORKDIR}"
export JAVA_HOME="${JH}"
export ANDROID_SDK_ROOT="${SDK_DIR}"
export ANDROID_HOME="${SDK_DIR}"
export ANDROID_NDK_ROOT="${SDK_DIR}/ndk/${NDK_VERSION}"
# CMake 必须让 SDK 自带的 ${CMAKE_VERSION} 优先：Ubuntu 26.04 的系统 cmake 是 4.x，
# 而 CMake 4.0 起移除了对 cmake_minimum_required(<3.5) 的兼容，会**直接报错**。
# ffmpeg-kit 钉的 arthenica/vid.stab v1.1.1 里写的就是 VERSION 2.8.5，必挂。
# CI 侧装的也正是 3.22.1，这里保持一致。
export PATH="\${ANDROID_SDK_ROOT}/cmake/${CMAKE_VERSION}/bin:\${JAVA_HOME}/bin:\${ANDROID_SDK_ROOT}/platform-tools:\${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:\${PATH}"
# 双保险：万一某些阶段仍落到系统 cmake 4.x，这个官方开关能让老工程继续配置。
# CMake 4.0 新增的环境变量（用于初始化 CMAKE_POLICY_VERSION_MINIMUM），旧版 cmake 会忽略它。
export CMAKE_POLICY_VERSION_MINIMUM=3.5
export ANDROID_NDK_HOME="\${ANDROID_NDK_ROOT}"
EOF
  c_ok "环境文件：${ENV_FILE}"
}

# ===========================================================================
#  阶段 5：build（编译 55 个外部库 + ffmpeg）
# ===========================================================================
do_build() {
  stage_hdr "build（编译 FFmpegKit，这一步最慢，通常 15~30 分钟）"

  [ "${DRY_RUN}" = "1" ] || { [ -f "${ENV_FILE}" ] || write_env_file; }
  # shellcheck disable=SC1090
  [ "${DRY_RUN}" = "1" ] || source "${ENV_FILE}"

  # 幂等兜底：--stage build 会跳过 do_src，这里必须再清一次 CRLF。
  # .patch 一旦带 CRLF，Linux 的 git apply 会直接拒绝（SDL 上实测踩到）。
  [ "${DRY_RUN}" = "1" ] || crlf_to_lf "${SRC_DIR}"

  [ "${DRY_RUN}" = "1" ] || mkdir -p "${LOGS}"

  local BUILD_OPTS PKG
  # 与 CI workflow 的 android.sh 调用保持一致：同样传 --package-name。
  # 它只影响原生侧上报的包名字符串（FFmpegKitConfig 初始化日志前缀、
  # Packages.getPackageName() 的返回值），不影响 JNI 符号匹配——符号匹配由
  # rebrand-sources.sh 改名保证。但两处不一致会让产物行为不同，故一并传上。
  PKG="${PKG_NAME}"
  [ -n "${PKG}" ] || PKG="$(detect_pkg_name "${SRC_DIR}")"
  BUILD_OPTS="--arch=arm64-v8a --enable-lib-all --enable-gpl --disable-lib-gnutls --api-level=${API_LEVEL} --no-archive --jobs=${JOBS} --package-name=${PKG}"

  c_info "构建参数：${BUILD_OPTS}"
  c_info "日志目录：${LOGS}"

  # ---- 5.1 源码改名（幂等，可重复跑）----
  if [ "${DRY_RUN}" = "1" ]; then
    c_info "[dry-run] (cd ${SRC_DIR} && bash tools/rebrand/rebrand-sources.sh)"
  else
    ( cd "${SRC_DIR}" && bash tools/rebrand/rebrand-sources.sh 2>&1 | tee "${LOGS}/01-rebrand-sources.log" )
    c_ok "源码改名完成"
  fi

  # ---- 5.2 正式编译 ----
  if [ "${DRY_RUN}" = "1" ]; then
    c_info "[dry-run] (cd ${SRC_DIR} && bash ./android.sh ${BUILD_OPTS})"
  else
    ( cd "${SRC_DIR}" && bash ./android.sh ${BUILD_OPTS} 2>&1 | tee "${LOGS}/02-build.log" )
    c_ok "编译完成（完整日志：${LOGS}/02-build.log）"
  fi
}

# ===========================================================================
#  阶段 6：pack（.so 改名校验 + 打 AAR）
# ===========================================================================
do_pack() {
  stage_hdr "pack（校验 .so 改名并打包 AAR）"

  [ "${DRY_RUN}" = "1" ] || { [ -f "${ENV_FILE}" ] || write_env_file; }
  # shellcheck disable=SC1090
  [ "${DRY_RUN}" = "1" ] || source "${ENV_FILE}"
  [ "${DRY_RUN}" = "1" ] || mkdir -p "${LOGS}"

  # ---- 6.1 .so 改名校验（构建期 改名生效的话这里只做校验）----
  if [ "${DRY_RUN}" = "1" ]; then
    c_info "[dry-run] (cd ${SRC_DIR} && bash tools/rebrand/rebrand-native.sh)"
  else
    ( cd "${SRC_DIR}" && bash tools/rebrand/rebrand-native.sh 2>&1 | tee "${LOGS}/03-rebrand-native.log" )
    c_ok "动态库命名校验通过"
  fi

  # ---- 6.2 打 AAR + 本地 Maven 仓库 ----
  if [ "${DRY_RUN}" = "1" ]; then
    c_info "[dry-run] (cd ${SRC_DIR} && bash tools/rebrand/package-aar.sh)"
    return 0
  fi
  ( cd "${SRC_DIR}" && bash tools/rebrand/package-aar.sh 2>&1 | tee "${LOGS}/04-package-aar.log" )

  # ---- 6.3 汇总产物 ----
  stage_hdr "完成 ✅"
  local OUT="${SRC_DIR}/out"
  if [ -d "${OUT}" ]; then
    c_ok "产物目录：${OUT}"
    find "${OUT}" -maxdepth 3 -type f \( -name '*.aar' -o -name '*.so' -o -name '*.pom' -o -name '*.jar' \) -printf '  %-70p %10s B\n' 2>/dev/null | head -40
    local aar
    aar="$(find "${OUT}" -name '*.aar' | head -1)"
    [ -n "${aar}" ] && c_ok "AAR：${aar}"
  else
    c_warn "没有看到 ${OUT}，请检查 ${LOGS}/04-package-aar.log"
  fi

  cat <<EOF

下一步：把 AAR 加进 App 工程
  1) 复制 $(find "${OUT}" -name '*.aar' 2>/dev/null | head -1 || echo "${OUT}/*.aar") 到 app/libs/
  2) app/build.gradle(.kts) 里加：
       implementation(files("libs/ffmpeg-kit-release.aar"))
  3) 代码里改用新包名与 JNI 前缀：
       import com.fkit.ffmpegkit.FFmpegKit        // 原 com.arthenica.ffmpegkit
       System.loadLibrary("fkit_ffmpegkit")       // 由 SDK 内部加载，一般无需手写
  4) 打出来的 APK 里 lib/arm64-v8a/ 下应当是 libfkit_*.so，
     若仍出现 libavcodec.so 说明改名没生效，回头检查 ${LOGS}/01-rebrand-sources.log

重新编译某一阶段（不必从头来）：
  bash $0 --stage build     # 工具链与源码都在了，直接重编
  bash $0 --stage pack      # 只重新改名+打包
EOF
}

# ===========================================================================
#  主流程
# ===========================================================================
main() {
  printf '\033[1mFFmpegKitNext「改名版」本机构建\033[0m\n'
  c_info "阶段区间：${STAGE} -> ${STAGES[-1]}"
  c_info "构建根目录：${WORKDIR}"
  [ "${DRY_RUN}" = "1" ] && c_warn "dry-run 模式：只打印命令，不做任何改动"

  # checks 永远先跑：它负责算出 JOBS 并做磁盘/内存判定
  do_checks
  should_run deps  && do_deps
  should_run sdk   && do_sdk
  should_run src   && do_src
  should_run build && do_build
  should_run pack  && do_pack
}

main "$@"
