# FFmpegKitNext → 改名版 Android arm64-v8a 构建（GitHub Actions）

给 `https://github.com/arthenica/ffmpeg-kit-next` 加一套 CI，用它编译出：

- **只含 arm64-v8a** 的 release AAR
- **开启了全部外部库**（x264 / x265 / libvpx / libaom / dav1d / opus / openssl / srt / tesseract / fontconfig …共 60+ 个）
- **整包改名**：Java 包名、Maven 坐标、以及**所有 `.so` 文件名**（包括 ffmpeg 自身的 `libavcodec.so` 等）

改名的直接动因：**DJI SDK 自带一套 ffmpeg 动态库**（`libavcodec.so` / `libavformat.so` / `libavutil.so` / `libswscale.so` …），
和 ffmpeg-kit 的同名 `.so` 在同一个 APK 里会撞车——打包报重复、运行时又可能加载到另一个版本导致崩溃。
把 ffmpeg-kit 这边全部改名即可彻底隔离。

---

## 1. 怎么用

### 方式 A：网页操作（最快）

1. 打开 https://github.com/arthenica/ffmpeg-kit-next → 点右上角 **Fork**
2. 在 fork 后的仓库页 → **Add file → Upload files** → 把本目录的 `.github/`、`tools/`、`.gitattributes`
   一起拖进去（拖文件夹可以保留目录结构）→ Commit
3. 回到 fork 仓库 → **Actions** 标签
   - 如果提示 *"Workflows aren't being run on this forked repository"*，点绿色按钮 **I understand my workflows, go ahead and enable them**
   - 左侧选 **Android arm64-v8a (rebranded)** → 右侧 **Run workflow** → 再点 **Run workflow**
4. 等 job 跑完（首次约 **1.5 ~ 3 小时**），在 job 页面底部 **Artifacts** 里下载
   `ffmpeg-kit-arm64-v8a-<run_number>`

### 方式 B：命令行

```bash
# 1) 在网页上 Fork 之后
git clone https://github.com/<你的用户名>/ffmpeg-kit-next.git
cd ffmpeg-kit-next

# 2) 把本目录的 .github/ tools/ .gitattributes 复制进来
cp -r /path/to/ffmpeg-fkit-arm64/.github      .
cp -r /path/to/ffmpeg-fkit-arm64/tools        .
cp    /path/to/ffmpeg-fkit-arm64/.gitattributes .

# 3) 确认换行符正确（.gitattributes 已声明 *.sh 为 LF，这里只是自查）
git add -A && git status --short

git commit -m "ci: build rebranded FFmpegKit for arm64-v8a"
git push origin main
```

### 方式 C：本机 Linux 一键构建（比 CI 快，失败能立刻看日志）

仓库根目录的 `build-on-ubuntu.sh` 把整条链路封成 6 个可重入阶段：

```bash
bash build-on-ubuntu.sh                                   # 从 fork clone 源码
bash build-on-ubuntu.sh --from-local ~/ffmpeg-kit-next    # 用本地已有源码（必须是 git 仓库）
```

- 阶段顺序 `checks → deps → sdk → src → build → pack`；`--stage build` 可从中断处接着跑
- **编译本身也能续跑**：`scripts/main-android.sh` 用 `library_is_installed` 检查安装目录，
  已编好的库会打印 `xxx: already built` 直接跳过。所以上次挂在第 N 个库，重跑就从第 N 个继续，
  不会重编前面的
- 并行数按 CPU / 内存自动推算（`--jobs` 可覆盖）；日志逐阶段 tee 到 `<workdir>/logs/`
- `--from-local` 会预检 `tools/rebrand/`、`android.sh` 与 **`.git`**（`android.sh:39` 依赖
  `git describe` 生成版本号，缺 `.git` 会在编译一开始就 `exit 1`）
- **Ubuntu 26.04 注意**：系统 cmake 是 **4.x**，会拒绝 `cmake_minimum_required(<3.5)` 的老工程
  （`libvidstab` 等）。脚本会自动让 SDK 自带的 **cmake 3.22.1** 优先并写入 `env.sh`，无需手工处理

> ### ⚠️ 两个会让人卡住的点
>
> **1. 首次 push 不会自动触发这个 workflow。**
> GitHub 有个安全机制：**包含 workflow 文件的那个 commit 被 push 时，该 workflow 自身的 `push` 触发器不会执行**
> （防止有人靠 PR 注入 workflow 拿到 secrets）。所以第一次必须**手动 `Run workflow`**。
> 之后你再改 `tools/rebrand/**` 或这个 yml，`push` 才会自动触发。
>
> **2. fork 的仓库默认不会自动同步上游的新 tag。**
> `android.sh` 用 `git describe --tags --always` 生成版本号，workflow 里已经设了 `fetch-depth: 0` 拉全历史，
> 但 fork 只复制了 fork 那一刻的 tag。所以产物版本号可能停留在 fork 时的状态 —— 想要最新版本号，
> 在 fork 仓库页面点 **Sync fork → Update branch**，或改用 `git fetch upstream --tags`。
>
> 小提示：workflow 里用 `bash tools/rebrand/xxx.sh` 而不是 `./xxx.sh`，是为了绕开
> 「在 Windows 上复制文件会丢掉可执行位」这个问题；`.gitattributes` 则保证 `*.sh` 进出仓库都是 LF。
> 想恢复可执行位也可以执行 `git update-index --chmod=+x tools/rebrand/*.sh`。


---

## 2. 改名配置（★ 只有这一处需要改 ★）

全部集中在 workflow 顶部的 `env:` 块（也可以用 `tools/rebrand/rebrand.config.env` 的默认值）：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `REBRAND_NATIVE_PREFIX` | `fkit` | 动态库前缀，见下表。只允许小写字母/数字/下划线 |
| `REBRAND_JAVA_PACKAGE` | `com.fkit.ffmpegkit` | 新 Java/Kotlin 包名，换成你自己的反向域名 |
| `REBRAND_GROUP_ID` | `com.fkit` | Maven groupId |
| `REBRAND_ARTIFACT_ID` | `ffmpeg-kit` | Maven artifactId |
| `REBRAND_ARCHIVE_NAME` | `ffmpeg-kit` | AAR 文件名（`<值>-release.aar`） |
| `REBRAND_STRIP_LIBCXX_SHARED` | `0` | 设 `1` 则从 AAR 中删掉 `libc++_shared.so` |
| `REBRAND_API_LEVEL` | `24` | 需与 `BUILD_OPTS` 里的 `--api-level` 一致 |

改完这两个地方的名字，其它全部自动跟着变（源码、JNI 符号、Android.mk、gradle、产物名、POM）。

### 动态库改名对照（以默认前缀 `fkit` 为例）

| 原文件名 | 新文件名 | 冲突来源 |
| --- | --- | --- |
| `libavcodec.so` | `libfkit_avcodec.so` | ⚠️ DJI 也有 |
| `libavformat.so` | `libfkit_avformat.so` | ⚠️ DJI 也有 |
| `libavutil.so` | `libfkit_avutil.so` | ⚠️ DJI 也有 |
| `libswscale.so` | `libfkit_swscale.so` | ⚠️ DJI 也有 |
| `libavfilter.so` | `libfkit_avfilter.so` | ⚠️ DJI 也有 |
| `libavdevice.so` | `libfkit_avdevice.so` | ⚠️ DJI 也有 |
| `libswresample.so` | `libfkit_swresample.so` | ⚠️ DJI 也有 |
| `libffmpegkit.so` | `libfkit.so` | ffmpeg-kit 本体 |
| `libffmpegkit_abidetect.so` | `libfkit_abidetect.so` | ffmpeg-kit ABI 探测 |

> 只构建 arm64-v8a，所以 `libffmpegkit_armv7a_neon.so` 那一支（armeabi-v7a-neon 专用）**保持原名不动**，相关代码路径不会被编译。

---

## 3. 构建流程做了什么

```
1) rebrand-sources.sh   改源码（在 android.sh 之前）
     ├ Kotlin 包目录迁移 + package 声明 + loadLibrary() 库名
     ├ JNI C 源码：Java_com_arthenica_ffmpegkit_* → Java_com_fkit_ffmpegkit_*，
     │             FindClass 用的 "com/arthenica/ffmpegkit/..." 同步替换
     ├ consumer-rules.pro（它会作为 proguard.txt 打进 AAR）
     ├ gradle：namespace + base.archivesName
     ├ android/jni/ffmpeg/Android.mk：7 个 prebuilt 库的 module/src 名
     ├ android/jni/Android.mk：包装库模块名 + LOCAL_SHARED_LIBRARIES
     ├ 给 scripts/android/ffmpeg.sh 注入 SLIBPREF + LD_LIB 覆盖
     │  （configure 之后改 ffbuild/config.mak，让 ffmpeg 直接产出新名字，
     │    SONAME 和 DT_NEEDED 天然正确，不需要二次改 ELF）
     │  ★ 必须成对改：SLIBPREF 决定输出文件名，LD_LIB 决定库间依赖的
     │    -l 参数（`-l<裸名>`）。只改前者会以
     │    `ld.lld: error: unable to find library -lavutil` 失败
     ├ 修上游 meson cross file 键名 bug：scripts/function-android.sh 里
     │  `pkg-config = ...` → `pkgconfig = ...`（否则 rubberband 构建必失败）
     └ 给 GPL 块补 `--enable-version3`
        （否则 ffmpeg configure 报
         `ERROR: OpenSSL >=3.0.0 requires --enable-version3`）

2) ./android.sh --arch=arm64-v8a --enable-lib-all --enable-gpl
      --disable-lib-gnutls --api-level=24
      --no-archive --package-name=com.fkit.ffmpegkit
     （--no-archive：不在构建脚本里打 AAR，等改名完成后再打；
       --disable-lib-gnutls：ffmpeg 的 TLS 后端只能二选一，见第 7 节）

3) rebrand-native.sh     校验 + 兜底
     ├ 如果上一步 SLIBPREF / LD_LIB 注入没生效，用 patchelf 重命名并修正
     │  SONAME / 所有 DT_NEEDED，保证库之间还能互相找到
     └ 强校验：任何残留的旧库名都会让构建失败（不会给你一个坏包）

4) package-aar.sh        gradle assembleRelease + 生成本地 Maven 仓库 + 汇总产物
```

---

## 4. 产物

`out/` 目录（同时也会保留 `prebuilt/bundle-android-aar-24-maven/` 的原始结构）：

| 文件 | 用途 |
| --- | --- |
| `ffmpeg-kit-<版本>-arm64_v8a.aar` | 直接作为本地 AAR 依赖 |
| `ffmpeg-kit-<版本>-maven-repo.zip` | 解压后当成本地 Maven 仓库引用 |
| `ffmpeg-kit-<版本>-libs.zip` | 只有 `.so`，想自己塞进 `jniLibs` 时用 |
| `SHA256SUMS` | 校验和 |

另外 `build.log` 也会一起上传（构建失败时先看它）。

CI 上还会单独上传一个 **`native-libs-arm64-v8a-<run_number>`** 产物（内容是 `android/libs/`，
即 ndk-build 出来的 9 个 `.so`，也是 AAR 里 `jniLibs` 的来源）。它在「改名 + 校验」之后、
**无条件上传**，所以哪怕后面的 gradle 打包环节出问题，编译成果也保得住，不必再烧一整轮。

---

## 5. 在 Android 工程里接入

```groovy
repositories {
    // 解压 maven-repo.zip 后的目录
    maven { url "$rootDir/maven-repo" }
    // 解析 POM 里的 com.arthenica:smart-exception-java 传递依赖
    mavenCentral()
}

android {
    defaultConfig {
        ndk { abiFilters 'arm64-v8a' }
    }
    packaging {
        jniLibs {
            // 保险：同时存在多份 libc++_shared.so 时先到先得
            pickFirsts += ['**/libc++_shared.so']
        }
    }
}

dependencies {
    implementation 'com.fkit:ffmpeg-kit:9.0.0'   // 与 workflow env 里的坐标一致
}
```

代码里的 import 也要跟着换：

```java
// 旧
import com.arthenica.ffmpegkit.FFmpegKit;
// 新
import com.fkit.ffmpegkit.FFmpegKit;
```

---

## 6. ⚠️ 两个必须知道的坑

### 6.1 GPL 许可

`--enable-gpl` 会启用 `x264` / `x265` / `xvidcore` / `rubberband` / `libvidstab`，
**构建产物整体变成 GPL v3**（`rubberband` v4 本身就是 GPL-3.0-or-later，
所以即使用 GPLv2 声明也躲不开 v3；构建脚本另外还会补 `--enable-version3`，
把声明明确成 `GPL version 3 or later`）。
商业闭源 APP 里 bundling GPL 代码是有法律风险的。

只需要 LGPL 的话，把 workflow 里 `BUILD_OPTS` 的 `--enable-gpl` 去掉即可
（去掉后 `--enable-lib-all` 会自动跳过所有 GPL 库，其余外部库照常；
`--disable-lib-gnutls` 可以留着，不影响 LGPL 构建）。

### 6.2 `libc++_shared.so`

启用外部库后 `APP_STL` 变成 `c++_shared`，AAR 里会带一个 `libc++_shared.so`，
而 **DJI SDK 也可能自带一份**（由另一个版本的 NDK 编译）。两份混用是崩溃高发点。

处理建议（任选其一，别同时做）：
- 保留 ffmpeg-kit 这份（NDK r27d 编译），在 App 的 `packaging` 里排除掉 DJI 那份；
- 或者设 `REBRAND_STRIP_LIBCXX_SHARED=1`，AAR 不带，用 App 里已有的那份（务必确认 ABI/版本兼容）。

---

## 7. 常见失败与处理

| 现象 | 处理 |
| --- | --- |
| `E: Unable to locate package xxx`（exit 100，几秒就死） | apt 源里没有这个包名。workflow 已改成**逐个 `apt-cache show` 探测**再安装，不存在的会 `::warning::` 跳过而不再整步失败 |
| `WARNING: 'asn1Parser' is missing on your system` + `make[2]: *** [..._asn1_tab.c] Error 127` | **gnutls 的隐式主机依赖**。gnutls 是 git 克隆 + submodule 构建，源码树里没有预生成的 `gnutls_asn1_tab.c` / `pkix_asn1_tab.c`，必须由 `asn1Parser` 现场生成。Ubuntu 上该工具在 **`libtasn1-bin`** 包里（默认 apt 列表已含）。注意 `gnutls.sh` 自身**完全不做工具检查**，漏装只会在编译到第 44 个库时才暴露 |
| `Found Pkg-config: NO` + `meson.build:317:4: ERROR: C++ header 'samplerate.h' not found`，`rubberband: failed` | **上游 meson cross file 键名 bug**（`scripts/function-android.sh` 的 `create_mason_cross_file` 写了 `pkg-config = ...`，而 meson 认的键是 `pkgconfig`，且交叉编译时 `allow_default_for_cross=False` 不回退 PATH）。`rebrand-sources.sh` 第 9 步已就地修正为 `pkgconfig = 'pkg-config'`。详见下方说明 |
| ffmpeg configure 阶段 `GnuTLS and OpenSSL must not be enabled at the same time.` | **`--enable-lib-all` 会同时打开 gnutls 和 openssl**，而 ffmpeg 的 TLS 后端只能二选一（configure:4851 直接 die）。必须加 **`--disable-lib-gnutls`**（保留 openssl）。**不能反过来关 openssl**：`scripts/android/srt.sh` 硬编码 `-DUSE_ENCLIB=openssl -DUSE_OPENSSL_PC=1`，没有 openssl 的 `.pc` 时 srt 构建会失败。gnutls 是叶子库（没有别的库依赖它），关掉无副作用。注意这个 die 发生在**所有 55 个外部库都编译完之后**，前面全绿也可能在这里挂 |
| ffmpeg configure 阶段 `ERROR: OpenSSL >=3.0.0 requires --enable-version3`（或 `xxx is version3 and --enable-version3 is not specified`） | ffmpeg 要求 **GPL + OpenSSL ≥ 3.0.0 时必须带 `--enable-version3`**，而上游 `scripts/android/ffmpeg.sh` 只加了 `--enable-gpl`，从未加过 `--enable-version3`；本仓库编的是 `openssl-3.5.7`，必然踩中。`rebrand-sources.sh` 第 10 步已在 GPL 块里补上。详见下方说明 |
| ffmpeg **编译链接**阶段 `ld.lld: error: unable to find library -lavutil`，紧接着 `make: *** [ffbuild/library.mak:153: libswscale/libfkit_swscale.so.10] Error 1` | **`SLIBPREF` 和 `LD_LIB` 必须成对改**。`SLIBPREF` 只决定**输出文件名**（`libfkit_avutil.so`），而库之间的依赖链接走 `ffbuild/common.mak:211` 的 `FFEXTRALIBS := $(LDLIBS:%=$(LD_LIB))`，用的是 `-l<裸名>`。`rebrand-sources.sh` 第 8 步现已同时注入这两项。详见下方说明 |
| 打 AAR 阶段 `Failed to apply plugin 'com.android.internal.library'` + `Android Gradle plugin requires Java 17 to run. You are currently using Java 11.` | **runner 默认 JDK 是 11，而 `android/build.gradle` 用的 AGP 8.13.2 硬性要求 17+**。早先 workflow 靠手写 `${JAVA_HOME_17_X86_64}` 探测，但这个变量名在 runner 镜像里不保证存在；一旦取空，`if` 分支静默跳过、步骤仍显示 success，直到**最后一步**才以「Java 11」暴露，代价是白跑整轮编译。现已改为 `actions/setup-java@v6`（temurin / 17）+ `Verify JDK >= 17` 硬校验，`package-aar.sh` 里也自带一道断言。注意这步失败时**前面 9 步全绿**（55 个外部库 + ffmpeg 都已编译完成），所以此时直接重跑很亏 |
| 打 AAR 阶段 `[package-aar] ERROR: gradle 需要 JDK 17 或更高（AGP 8.13.2），当前为：Picked up JAVA_TOOL_OPTIONS: ...` | **版本探测被脚本自己设的环境变量污染**。`package-aar.sh` 为了强制 gradle 输出英文会 `export JAVA_TOOL_OPTIONS="... -Duser.language=en -Duser.country=US"`，而 JVM 每次启动都会先往 **stderr** 吐一行 `Picked up JAVA_TOOL_OPTIONS: ...`。原来用 `java -version 2>&1 \| head -n 1` 取首行当版本串，取到的正是这行垃圾 → 解析不出主版本 → 误判「JDK 不足 17」直接 die。**诡异之处：同一次 run 里 `Verify JDK >= 17` 步骤是绿的**（该步骤没设 `JAVA_TOOL_OPTIONS`，首行是真版本行），于是表现为「校验通过、打包却挂」。现已改为**优先读 `$JAVA_HOME/release`**（JVM 规范文件，不受环境变量与 locale 影响），仅在读不到时才回落解析 `java -version`，且用 `version "…"` 引号锚定以天然跳过 `Picked up` 行。`package-aar.sh` 与 workflow 两处写法已统一 |
| 打 AAR 阶段 dokka 相关失败（`org.jetbrains.dokka` 插件加载异常 / Kotlin 版本不兼容） | 上游模块 `build.gradle` 无条件 `apply plugin: 'org.jetbrains.dokka'` 并注册 `dokkaJavadocJar`，把 **Kotlin ↔ Dokka 版本矩阵**耦了进来（上游组合是 Kotlin 2.0.21 + Dokka 1.9.20）。我们只要 AAR、不需要 javadoc jar，`rebrand-sources.sh` **第 5b 步**会移除该插件行与整个任务块（awk 按花括号配平删除，幂等；找不到 dokka 痕迹就整段跳过） |
| 编译外部库阶段 `libvidstab: failed`，`build.log` 里是 `CMake Error at CMakeLists.txt:1 (cmake_minimum_required): Compatibility with CMake < 3.5 has been removed from CMake.` | **本机 cmake 太新**。CMake **4.0** 把 `cmake_minimum_required(<3.5)` 从「弃用警告」升级成了**硬错误**，而 ffmpeg-kit 钉的 `arthenica/vid.stab v1.1.1` 写的正是 `cmake_minimum_required (VERSION 2.8.5)` ⇒ 必挂。**Ubuntu 26.04 自带的 cmake 是 4.2.3**，CI 用的 ubuntu-24.04 是 3.x，所以 CI 上不会踩。两种处理：①（推荐）让 SDK 自带的 **cmake 3.22.1** 优先，与上游 CI 装的是同一个版本 —— `build-on-ubuntu.sh` 的 `sdk` 阶段已自动 `export PATH="$SDK/cmake/3.22.1/bin:$PATH"` 并写进 `env.sh`，手工跑时补一句 `export PATH="$ANDROID_SDK_ROOT/cmake/3.22.1/bin:$PATH"` 亦可；② 图快就用 CMake 4.0 官方为此新增的环境变量 `export CMAKE_POLICY_VERSION_MINIMUM=3.5`（旧版 cmake 会忽略它，无副作用）。**注意**：`soxr` / `chromaprint` 等同样是老工程，不处理会一个个接着挂 |
| 链接阶段 OOM / `No space left on device` | 把 `BUILD_OPTS` 改成 `--jobs=2` 并加上 `--no-link-time-optimization`；同时确认 `Free disk space` 步骤没被删 |
| 超过 6 小时被 kill | 同上（关掉 LTO 能省很多时间），或去掉几个用不到的大库（如 `--disable-lib-tesseract --disable-lib-svtav1`） |
| `找不到 sdkmanager` | 把 workflow 里 `Set up Android SDK / NDK` 步骤替换成 `uses: android-actions/setup-android@v3` |
| 校验步骤报「仍然存在旧 ffmpeg 库名」 | 说明 SLIBPREF 注入和 patchelf 兜底都没成功，看 `build.log` 里 `INFO: rebrand:` 那几行 |
| 运行时 `UnsatisfiedLinkError` | 确认 APK 里 `lib/arm64-v8a/` 下是 `libfkit_*` 而不是 `libav*`；确认 App 代码里没有 `System.loadLibrary("ffmpegkit")` 之类硬编码 |
| 想改前端名字 | 改 `env` 里的 `REBRAND_NATIVE_PREFIX` / `REBRAND_JAVA_PACKAGE` 重跑即可（脚本幂等） |

> **主机工具清单的权威来源**：上游 `flake.nix` 的 `commonToolPackages` + `androidPackages` 就是 Nix 构建成功时的完整 host 依赖集。本 workflow 的 apt 列表已与它逐项对齐（含容易漏的 `libtasn1`）。如果又遇到 `Error 127` 类问题，先回去对比这份清单。
>
> 失败时 workflow 会额外上传 `build-log-<run_number>` 产物，里面有完整 `build.log`；`Show build log tail on failure` 步骤也会打印末尾 800 行 + 所有 `ERROR` 行 + 各外部库 `ok/failed` 汇总。

### 关于 rubberband / meson `Found Pkg-config: NO`（已修，留个记录）

这是上游在**非 Nix 路径**上的真实缺陷，不是我们的改名引入的：

```bash
# scripts/function-android.sh
create_mason_cross_file() {
  cat >"$1" <<EOF
[binaries]
c = '$CC'
...
pkg-config = 'pkg-config'   # ← 键名错了，meson 认的是 pkgconfig
```

meson 定位 pkg-config 时走的是：

```python
# mesonbuild/dependencies/pkgconfig.py
find_external_program(env, for_machine, 'pkgconfig', 'Pkg-config',
                      environment.default_pkgconfig,
                      allow_default_for_cross=False)   # ← 交叉编译不回退 PATH
```

`BinaryTable` 存键是原样保存、`lookup_entry('pkgconfig')` 是精确匹配，
所以 `pkg-config` 这个键等于没写；再加上交叉编译禁用了默认 PATH 回退，
meson 直接判定「本机没有 pkg-config」，打印红色 `Found Pkg-config: NO`。

本仓库用 meson 的只有 `dav1d` / `harfbuzz` / `liblc3` / `rubberband`，
前三个没有外部依赖所以看不出来，只有 rubberband 需要 `libsamplerate` 时炸：

```
Run-time dependency samplerate found: NO (tried pkgconfig and cmake)
meson.build:317:4: ERROR: C++ header 'samplerate.h' not found
```

修好后 pkg-config 会被正常调用，并继承 `scripts/run-android.sh` 导出的
`PKG_CONFIG_LIBDIR`（= `prebuilt/android-arm64-24/pkgconfig`，
`libsamplerate.sh` 结尾已经把 `samplerate.pc` 拷进这个目录），探测即通过。

> 另外注意：**rubberband 是 GPL 库**，`--enable-lib-all` 想把它编进去就绕不开
> `--enable-gpl`。反过来，一旦去掉 `--enable-gpl`，`enable_all_libraries()`
> 会按 `is_gpl_licensed` 把 `x264/x265/xvidcore/libvidstab/rubberband` 全部跳过，
> 这个 meson 问题也就不会出现了。

### ffmpeg configure 的两道坎：TLS 互斥 + `--enable-version3`

`--enable-lib-all` 是「把所有外部库都开上」的粗暴选项，它不管库之间的互斥关系，
所以在 **ffmpeg 自己的 configure 阶段**（注意：此时 55 个外部库已经全部编译成功了）
会连着撞两堵墙。两处都不是我们改名引入的，是上游 `--enable-lib-all` 路径的缺陷。

**第一堵：gnutls / openssl 互斥**

```sh
# FFmpeg/configure:4851
enabled_all gnutls openssl &&
    die "GnuTLS and OpenSSL must not be enabled at the same time."
```

`--enable-lib-all` 同时打开了这两个 TLS 后端（日志里能看到
`Enabling library gnutls` 和 `Enabling library openssl` 两条），configure 直接 fail。
解决办法是加 `--disable-lib-gnutls`：

- 上游 `scripts/android/ffmpeg.sh` 里，**openssl 未启用时会显式 `--disable-openssl`**
  （configure:343 附近那个分支），说明「默认不用 openssl」是上游的意图；
- 但**不能真的去关 openssl** —— `scripts/android/srt.sh` 里写死了
  `-DUSE_ENCLIB=openssl -DUSE_OPENSSL_PC=1`，openssl 的 `.pc` 不在
  `PKG_CONFIG_LIBDIR` 里时 srt 的 cmake 直接失败；
- 反过来 gnutls 是**叶子库**：依赖图里只有别人指向它
  （`gmp→gnutls`、`nettle→gnutls`、`libiconv→gnutls`、`zlib→gnutls`），
  没有任何库依赖 gnutls，所以关掉它是零代价的。

`--disable-lib-*` 在 ffmpeg-kit-next 里是原生支持的（`scripts/function.sh:1229`），
而且 `android.sh:131` 明确让 `--enable-lib-all` **先**执行、`--disable-lib-*` **后**覆盖，
顺序上安全。

**第二堵：OpenSSL ≥ 3.0.0 要求 `--enable-version3`**

```sh
# FFmpeg/configure:7551
enabled openssl && { { check_pkg_config openssl "openssl >= 3.0.0" openssl/ssl.h DTLS_get_data_mtu &&
    { enabled gplv3 || ! enabled gpl || enabled nonfree ||
      die "ERROR: OpenSSL >=3.0.0 requires --enable-version3"; }; } || ... }
```

即：`--enable-gpl` + 本机 OpenSSL ≥ 3.0.0 ⇒ 必须同时给 `--enable-version3`。
上游 `scripts/source.sh` 选的 openssl 是 **`openssl-3.5.7`**，稳稳满足 `>= 3.0.0`；
而 `scripts/android/ffmpeg.sh:361` 的 GPL 分支只加了 `--enable-gpl`，
全仓库搜不到任何 `--enable-version3`，所以 GPL 全量构建在 configure 这一步是必挂的。

同一个开关还顺带解决一处同类隐患（configure:4831）：

```sh
map "die_license_disabled version3" $EXTERNAL_LIBRARY_VERSION3_LIST $EXTERNAL_LIBRARY_GPLV3_LIST
```

这段会对 `EXTERNAL_LIBRARY_VERSION3_LIST` 里的 version3-only 库报
`xxx is version3 and --enable-version3 is not specified.`，而这份列表里
**`gmp`、`libopencore_amrnb`、`libopencore_amrwb`、`libvo_amrwbenc`** 正是
本次 GPL 全量构建开启的（`--enable-gmp` / `--enable-libopencore-amrnb` /
`--enable-libvo-amrwbenc`）。一起加 `--enable-version3` 就把这两处都消掉了。

**许可影响**：`--enable-gpl` + `--enable-version3` ⇒ 许可声明变成
`GPL version 3 or later`。本构建里 **rubberband v4 本身就是 GPL-3.0-or-later**，
产物本来就已经是 GPLv3，所以这里只是把声明对齐，没有引入新的许可约束。

### ffmpeg 内部库改名：`SLIBPREF` 与 `LD_LIB` 必须成对改

改名方案是在 configure 之后往 `ffbuild/config.mak` 写 `SLIBPREF=lib<前缀>_`。
但 **`SLIBPREF` 只管输出文件名，管不到库之间的依赖链接** —— 这是两套机制：

```make
# ffbuild/library.mak:96   —— 产出文件名（SLIBPREF 生效）
$(SUBDIR)$(SLIBNAME_WITH_MAJOR): ...
#   SLIBNAME_WITH_MAJOR = $(SLIBPREF)$(FULLNAME)$(SLIBSUF).$(LIBMAJOR)
#                       = libfkit_avutil.so.61            ✓

# ffbuild/common.mak:211   —— 库间依赖的链接参数（SLIBPREF 完全不参与）
FFEXTRALIBS := $(LDLIBS:%=$(LD_LIB)) $(...) $(EXTRALIBS)
#   LDLIBS = avutil avcodec ...     裸名，没有 lib 前缀、也没有前缀
#   LD_LIB = '-l%'                  configure:4518
#   ⇒ -lavutil -lavcodec ...        找的是 libavutil.so
```

所以只改 `SLIBPREF` 的后果是：`libavutil` 能编成 `libfkit_avutil.so.61`（成功），
但 `libswscale` 链接时要 `-lavutil`，而 `libavutil/` 目录里没有 `libavutil.so`：

```
LDXX  libavutil/libfkit_avutil.so.61      ← 成功（它没有依赖）
LDXX  libswscale/libfkit_swscale.so.10
ld.lld: error: unable to find library -lavutil
make: *** [ffbuild/library.mak:153: libswscale/libfkit_swscale.so.10] Error 1
```

**修法**：同时改 `LD_LIB='-l<前缀>_%'`。`$(LDLIBS:%=$(LD_LIB))` 是 make 的替换引用，
替换串里的 `%` 会被词干替换，所以 `LD_LIB=-lfkit_%` 把 `avutil` 映射成 `-lfkit_avutil`；
而 `common.mak:50` 生成的 `-Llibavutil` 仍然指向正确子目录，
`libavutil/libfkit_avutil.so` 则由 library.mak 的软链规则自动创建。

改动面已逐项核对，很干净：

| 关注点 | 结论 |
| --- | --- |
| `LD_LIB` 的全部消费者 | 只有 `common.mak:211` 和 `library.mak:66`（后者属 `$(TOOLS)`，本构建开了 `--disable-programs`，走不到） |
| `LDLIBS` 的内容 | `$(FFLIBS:%=%$(BUILDSUF))`，就是 ffmpeg 自家裸库名；外部库走 `$(EXTRALIBS)`，不受影响 |
| `DEP_LIBS`（依赖文件路径） | 走 `PATH_LIBNAME` → `$(S)LIBNAME`，已被 `SLIBPREF` 覆盖成 `libavutil/libfkit_avutil.so`，与 `-lfkit_avutil` 一致 |
| `make install` 产物 | `SLIB_INSTALL_NAME` / `SLIB_INSTALL_LINKS` 都基于 `SLIBNAME*`，装出来就是 `libfkit_avcodec.so`（外加 `.so.61` 软链） |
| `libav*.pc` 内容 | `pkgconfig_generate.sh` 不读 `LD_LIB`；而且 Android 链路上**没有任何消费者**（包装库由 ndk-build + `Android.mk` 直接引用 prebuilt `.so`），纯装饰 |
| 改动生效时机 | ffmpeg 是**单次非递归 make**，top Makefile 先 include `config.mak` 再 include `common.mak`，所以在 config.mak 末尾追加赋值必然盖住前面的 `LD_LIB=-l%` |

脚本里的实现是**成对且原子**的：只有 `^SLIBPREF=` 与 `^LD_LIB=` 在 config.mak 里
都能找到才动手，任一缺失就整体跳过并在 `build.log` 打 `WARNING`，
交给构建后的 `rebrand-native.sh` 用 patchelf 兜底 —— 不会产出半改状态。

### 无 CI，本地 / 其他机器上编译

```bash
export ANDROID_SDK_ROOT=/path/to/android-sdk
export ANDROID_NDK_ROOT=$ANDROID_SDK_ROOT/ndk/27.3.13750724

bash tools/rebrand/rebrand-sources.sh
bash ./android.sh --arch=arm64-v8a --enable-lib-all --enable-gpl \
                  --disable-lib-gnutls --api-level=24 \
                  --no-archive --jobs=4 --package-name=com.fkit.ffmpegkit
bash tools/rebrand/rebrand-native.sh
bash tools/rebrand/package-aar.sh
```

> 上游推荐用 Nix（`./nix-android.sh -p android-r27d ...`）作为构建环境；
> 本方案的 workflow 走的是非 Nix 路线（自装 apt 依赖 + SDK/NDK），
> 因为它可控性更好、CI 上更容易排查。想换 Nix 的话，
> 把构建命令换成 `./nix-android.sh -p android-r27d <同样的参数>` 即可，
> 但后两步的 gradle 打包需要在同一个 Nix shell 里执行。

---

## 8. 验证到什么程度（重要，别当成 100% 已通过）

- ✅ `rebrand-sources.sh` 已在上游源码上**实际跑过**并逐项核对：
  Kotlin 包目录/声明、`Java_com_fkit_ffmpegkit_*` 共 99 个 JNI 符号、
  `FindClass` 类路径、`consumer-rules.pro`、gradle、两个 `Android.mk`、
  `ffmpeg.sh` 注入后的语法（`bash -n` 通过）、重复执行幂等；
  且已确认**只改了头文件引用以外的必要位置**（`#include "libavutil/log.h"` 这类 ffmpeg 头目录名不动）。
- ✅ **编译段已在 CI 实证通过**：连续两轮 run 里
  `Build FFmpegKit (arm64-v8a, all external libraries)` 与
  `Rebrand native libraries (.so) and verify` 都是绿的 —— 55 个外部库全部编成、ffmpeg 自身链接成功、
  `android/libs/arm64-v8a/` 下 9 个 `libfkit_*.so` 命名与互相依赖一致
  （`build.log` 里可见 `INFO: rebrand: ffmpeg SLIBPREF -> libfkit_, LD_LIB -> -lfkit_%`）。
- ✅ **JDK 探测逻辑已实测**：把这段代码抽出来配假 JDK 目录跑了 8 个场景
  （有/无 `release` 文件、`Picked up JAVA_TOOL_OPTIONS` 污染、低版本拒绝、
  `JAVA_HOME` 缺失而回退 PATH、无 minor 的 `"17"`），结果全部符合预期；
  `package-aar.sh` 与 workflow 两处写法已统一。
- ⚠️ **`Package AAR + local Maven repository` 这一步尚未成功跑通**。上一轮它被上面那条
  JDK 误判挡在 gradle 启动之前，也就是说 **JDK 17 下 gradle 打包本身还没被真正验证过**。
  已提前排除的风险：模块 `build.gradle` 用 `jniLibs.srcDirs = ["../libs"]` 直接吃预编译 `.so`
  （**没有 externalNativeBuild**，不会重跑 NDK/CMake）、依赖只有 `smart-exception-java`
  （Maven Central 可得）、dokka 已摘除。若此处仍失败，先看 `--stacktrace` 打出的完整堆栈。
- ⚠️ **完整 AAR 需要在 CI 里编译**（Linux + Android NDK 才能交叉编译 Android 目标，Windows 本机无法完成）。
  `rebrand-native.sh` 里的 patchelf 兜底路径与 `package-aar.sh` 只能在真实构建环境里跑到，
  所以第一次跑完务必看一眼 job 里 `Rebrand native libraries (.so) and verify` 这一步的输出。
- 校验是「硬失败」设计：只要还有旧库名残留、或 AAR 里还能看到 `libavcodec.so`，构建就直接失败，
  不会给你一个能编译但运行时崩的包。
