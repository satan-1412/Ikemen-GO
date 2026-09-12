#!/bin/bash

# Exit in case of failure; print function-trap friendly errors
set -o errtrace
set -euo pipefail

tolower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

sed_inplace() {
  local expr="$1" file="$2"
  if sed --version >/dev/null 2>&1; then
    sed -i "$expr" "$file"
  else
    sed -i '' "$expr" "$file"
  fi
}

ensure_go_flags_android() {
  if [[ -f "$REPO_ROOT/vendor/modules.txt" ]]; then
    if [[ " ${GOFLAGS:-} " != *" -mod=vendor "* ]]; then
      export GOFLAGS="${GOFLAGS:-} -mod=vendor"
    fi
  else
    if [[ " ${GOFLAGS:-} " != *" -modcacherw "* ]]; then
      export GOFLAGS="${GOFLAGS:-} -modcacherw"
    fi
  fi
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"

DEBUG_BUILD="${DEBUG_BUILD:-0}"
OUTDIR="bin"
BUILDDIR="build"
FFMPEG_SRCDIR="$BUILDDIR/ffmpeg-src"

SCREENPACK_REPO="${SCREENPACK_REPO:-https://github.com/ikemen-engine/Ikemen-GO-Screenpack.git}"
SCREENPACK_REF="${SCREENPACK_REF:-master}"

SCREENPACK_REF="${SCREENPACK_REF:-master}"
SCREENPACK_DIR="$REPO_ROOT/$BUILDDIR/elecbyte-screenpack"

BUILD_ANDROID_APK="${BUILD_ANDROID_APK:-1}"
ANDROID_APK_REPO="${ANDROID_APK_REPO:-https://github.com/satan-1412/ikemen-droid.git}"
ANDROID_APK_REF="${ANDROID_APK_REF:-main}"
ANDROID_APK_DIR="$REPO_ROOT/$BUILDDIR/android-apk/ikemen-droid"
ANDROID_APK_OUT="${ANDROID_APK_OUT:-$REPO_ROOT/bin/ikemen-go.apk}"

FFMPEG_REV="${FFMPEG_REV:-release/7.1}"
APP_VERSION="${APP_VERSION:-nightly}"
APP_BUILDTIME="${APP_BUILDTIME:-$(date '+%Y.%m.%d')}"

function ensure_go_env() {
	local GO_VER="1.25.9"
	echo "==> Enforcing Go $GO_VER to maintain compatibility..."
	
	mkdir -p "$REPO_ROOT/$BUILDDIR/go-env"
	if [[ ! -f "$REPO_ROOT/$BUILDDIR/go-env/go/bin/go" ]]; then
		echo "==> Downloading Go $GO_VER Linux toolchain..."
		curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz" -o "$REPO_ROOT/$BUILDDIR/go-env/go.tar.gz"
		tar -C "$REPO_ROOT/$BUILDDIR/go-env" -xzf "$REPO_ROOT/$BUILDDIR/go-env/go.tar.gz"
	fi
	
	export GOROOT="$REPO_ROOT/$BUILDDIR/go-env/go"
	export PATH="$GOROOT/bin:$PATH"
	go version || exit 1
}

check_deps() {
	local missing=()
	need() { command -v "$1" >/dev/null 2>&1 || missing+=("$1"); }
	case "$OSTYPE" in
		linux*)
			need git; need pkg-config; need gcc; need g++; need make; need nasm
			if ((${#missing[@]})); then
				echo "ERROR: Missing Linux host tools: ${missing[*]}" >&2
				exit 1
			fi
		;;
	esac
}

function build_ffmpeg_arch() {
	local ABI=$1; local FFMPEG_ARCH=$2; local TARGET_PREFIX=$3
	local PREFIX_DIR=$4; local API_LEVEL=$5; local PAGE_ALIGN=$6; local FFMPEG_ASM=$7
	
	# --- 新增: 编译 libvpx 以支持 WebM 透明通道与高色深 ---
	local vpx_src="$BUILDDIR/libvpx-src"
	echo "==> Building libvpx for $ABI (API $API_LEVEL) for WebM Alpha support..."
	if [[ ! -d "$vpx_src" ]]; then
		git clone --depth=1 -b v1.14.0 https://github.com/webmproject/libvpx.git "$vpx_src"
	fi
	mkdir -p "$vpx_src/build-android-$ABI"
	pushd "$vpx_src/build-android-$ABI" >/dev/null
	
	local vpx_target="armv7-android-gcc"
	if [[ "$ABI" == "arm64-v8a" ]]; then vpx_target="arm64-android-gcc"; fi
	
	local cc_compiler="$TOOLCHAIN/bin/${TARGET_PREFIX}${API_LEVEL}-clang"
	local cxx_compiler="$TOOLCHAIN/bin/${TARGET_PREFIX}${API_LEVEL}-clang++"
	
	# 交叉编译 libvpx（启用共享库，禁用静态库以规避安卓链接冲突）
	CC="$cc_compiler" CXX="$cxx_compiler" AS="$cc_compiler" AR="$TOOLCHAIN/bin/llvm-ar" NM="$TOOLCHAIN/bin/llvm-nm" ../configure \
		--target="$vpx_target" --prefix="$PREFIX_DIR" \
		--disable-examples --disable-docs --disable-unit-tests --disable-tools \
		--enable-vp9-highbitdepth --disable-shared --enable-static --enable-pic
	make -j"$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)"
	make install
	popd >/dev/null
	# -----------------------------------------------

	echo "==> Building FFmpeg for $ABI (API $API_LEVEL)..."
	if [[ ! -d "$FFMPEG_SRCDIR" ]]; then
		mkdir -p "$BUILDDIR"
		git clone --depth=1 -b "$FFMPEG_REV" https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_SRCDIR"
	fi
	
	pushd "$FFMPEG_SRCDIR" >/dev/null
	make clean 2>/dev/null || true
	
	local extra_cflags="-fPIC -I$PREFIX_DIR/include"
	local extra_ldflags="-L$PREFIX_DIR/lib"
	
	if [[ "${FAST_BUILD_MODE:-1}" == "0" ]]; then
		extra_cflags="$extra_cflags -O3 -flto -ffast-math -funroll-loops"
		extra_ldflags="$extra_ldflags -flto"
	else
		extra_cflags="$extra_cflags -O0"
	fi

	if [[ "$ABI" == "armeabi-v7a" ]]; then
		extra_cflags="$extra_cflags -march=armv7-a -mfloat-abi=softfp -mfpu=neon"
	fi
	
	local configure_args=(
		"--prefix=$PREFIX_DIR" "--enable-cross-compile" "--target-os=android" "--arch=$FFMPEG_ARCH"
		"--cc=$cc_compiler" "--ar=$TOOLCHAIN/bin/llvm-ar" "--nm=$TOOLCHAIN/bin/llvm-nm" "--strip=$TOOLCHAIN/bin/llvm-strip"
		"--extra-cflags=$extra_cflags" $FFMPEG_ASM
		"--enable-shared" "--disable-static" "--install-name-dir=@rpath"
		"--disable-gpl" "--disable-nonfree" "--disable-debug" "--disable-doc" "--disable-programs" "--disable-everything"
		"--disable-autodetect" "--enable-avformat" "--enable-avcodec" "--enable-avutil" "--enable-swresample" "--enable-swscale"
		"--enable-avfilter" "--enable-filter=buffer,buffersink,format,scale,pad,crop"
		"--enable-protocol=file" "--enable-demuxer=matroska,webm"
		"--enable-libvpx" "--enable-decoder=vp8,vp9,libvpx_vp8,libvpx_vp9,opus,vorbis"
		"--enable-parser=vp8,vp9,opus,vorbis" "--enable-jni" "--enable-mediacodec"
		"--pkg-config=$(which pkg-config)"
	)
	
	if [[ -n "$PAGE_ALIGN" ]]; then
		extra_ldflags="$extra_ldflags $PAGE_ALIGN"
	fi

	if [[ -n "$extra_ldflags" ]]; then
		configure_args+=("--extra-ldflags=$extra_ldflags")
	fi

	./configure "${configure_args[@]}"
	make -j"$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)"
	make install
	popd >/dev/null
}

function build_libxmp_arch() {
	local ABI=$1; local PREFIX_DIR=$2; local PAGE_ALIGN=$3
	local src="$BUILDDIR/libxmp-src"
	
	local cmake_build_type="Debug"
	if [[ "${FAST_BUILD_MODE:-1}" == "0" ]]; then cmake_build_type="Release"; fi

	echo "==> Building LibXMP for $ABI (Mode: $cmake_build_type)..."
	if [[ ! -d "$src" ]]; then
		git clone https://github.com/libxmp/libxmp.git "$src"
	fi
	mkdir -p "$src/build-android-$ABI"
	pushd "$src/build-android-$ABI" >/dev/null
	cmake ../ -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
		-DANDROID_ABI="$ABI" -DANDROID_PLATFORM=android-21 -DCMAKE_INSTALL_PREFIX="$PREFIX_DIR" \
		-DCMAKE_BUILD_TYPE="$cmake_build_type" \
		-DBUILD_STATIC=OFF -DBUILD_SHARED=ON -DCMAKE_SHARED_LINKER_FLAGS="$PAGE_ALIGN"
	make -j"$(nproc 2>/dev/null || echo 4)"
	make install
	popd >/dev/null
}

function build_sdl2_arch() {
	local ABI=$1; local PREFIX_DIR=$2; local PAGE_ALIGN=$3
	local src="$BUILDDIR/sdl2-src"

	local cmake_build_type="Debug"
	if [[ "${FAST_BUILD_MODE:-1}" == "0" ]]; then cmake_build_type="Release"; fi

	echo "==> Building SDL2 for $ABI (Mode: $cmake_build_type)..."
	if [[ ! -d "$src" ]]; then
		git clone https://github.com/libsdl-org/SDL.git "$src"
		pushd "$src" >/dev/null
		git checkout tags/release-2.32.10
		popd >/dev/null
	fi
	mkdir -p "$src/build-android-$ABI"
	pushd "$src/build-android-$ABI" >/dev/null
	cmake ../ -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
		-DANDROID_ABI="$ABI" -DANDROID_PLATFORM=android-21 -DCMAKE_INSTALL_PREFIX="$PREFIX_DIR" \
		-DCMAKE_BUILD_TYPE="$cmake_build_type" \
		-DSDL_ANDROID_PACKAGE_NAME=org.ikemen_engine.ikemen_go -DSDL_STATIC=OFF -DSDL_SHARED=ON \
		-DCMAKE_SHARED_LINKER_FLAGS="$PAGE_ALIGN"
	make -j"$(nproc 2>/dev/null || echo 4)"
	make install
	popd >/dev/null
}

function create_dummy_gles_pc() {
	local PREFIX_DIR=$1; local PC_LIBS=$2
	mkdir -p "$PREFIX_DIR/lib/pkgconfig"
	for lib_name in $PC_LIBS; do
		local pc_file="$PREFIX_DIR/lib/pkgconfig/${lib_name}.pc"
		if [[ ! -f "$pc_file" ]]; then
			cat > "$pc_file" <<EOF
Name: ${lib_name}
Description: Android GLES fake
Version: 3.0
Libs:
Cflags:
EOF
		fi
	done
}

function patch_go_sdl2_android() {
	local f=""
	local vendorf="$REPO_ROOT/vendor/github.com/veandco/go-sdl2/sdl/system_android.go"
	if [[ -f "$vendorf" ]]; then 
		f="$vendorf"
	else
		local modver="$(go list -m -f '{{.Version}}' github.com/veandco/go-sdl2 2>/dev/null || true)"
		if [[ -z "$modver" ]]; then return 0; fi
		local modcache="$(go env GOMODCACHE 2>/dev/null || true)"
		f="$modcache/github.com/veandco/go-sdl2@${modver}/sdl/system_android.go"
	fi
	
	if [[ -f "$f" ]] && grep -q "return bool(C.SDL_AndroidRequestPermission" "$f"; then
		local d="$(dirname "$f")"
		if [[ ! -w "$d" ]]; then chmod u+w "$d" 2>/dev/null || true; fi
		if [[ ! -w "$d" ]]; then
			echo "ERROR: Cannot patch go-sdl2; directory is not writable: $d" >&2
			exit 1
		fi
		chmod u+w "$f" 2>/dev/null || true
		sed_inplace 's/return bool(C.SDL_AndroidRequestPermission(_permission))/return C.SDL_AndroidRequestPermission(_permission) != C.SDL_FALSE/' "$f"
	fi
}

function patch_reisen_android() {
	local modver="$(go list -m -f '{{.Version}}' github.com/ikemen-engine/reisen 2>/dev/null || true)"
	if [[ -z "$modver" ]]; then return 0; fi
	local modcache="$(go env GOMODCACHE 2>/dev/null || true)"
	local reisen_dir="$modcache/github.com/ikemen-engine/reisen@${modver}"
	
	if [[ -d "$reisen_dir" ]]; then
		chmod -R u+w "$reisen_dir" 2>/dev/null || true
		
		local f_audio="$reisen_dir/audio.go"
		if [[ -f "$f_audio" ]]; then
			if ! grep -q "C.size_t(bufferSize" "$f_audio"; then
				sed_inplace 's/bufferSize(maxBufferSize)/C.size_t(bufferSize(maxBufferSize))/g' "$f_audio"
			fi
		fi
		
		local f_stream="$reisen_dir/stream.go"
		if [[ -f "$f_stream" ]]; then
			if ! grep -q "C.int64_t(rewindPosition" "$f_stream"; then
				sed_inplace 's/rewindPosition(dur)/C.int64_t(rewindPosition(dur))/g' "$f_stream"
			fi
		fi
		
		local f_video="$reisen_dir/video.go"
		if [[ -f "$f_video" ]]; then
			if ! grep -q "C.size_t(bufferSize" "$f_video"; then
				sed_inplace 's/bufferSize(video.bufSize)/C.size_t(bufferSize(video.bufSize))/g' "$f_video"
			fi
		fi
	fi
}

function build_engine_arch() {
    local ARCH=$1; local ABI=""; local FFMPEG_ARCH=""; local TARGET_PREFIX=""
    local OUT_BIN_NAME=""; local API_LEVEL=""; local GLES_VERSION=""
    local GLES_LINK=""; local PC_LIBS=""; local PAGE_ALIGN=""; local FFMPEG_ASM=""
    local GO_VIRTUAL_MACHINE_HACK=""
    
    if [[ "$ARCH" == "arm64" ]]; then
        ABI="arm64-v8a"; FFMPEG_ARCH="aarch64"; TARGET_PREFIX="aarch64-linux-android"
        OUT_BIN_NAME="libmain.so"; export GOARCH=arm64; unset GOARM
        API_LEVEL="24"; GLES_VERSION="gles32"; GLES_LINK="-lGLESv3"
        PC_LIBS="gl glesv3"; PAGE_ALIGN="-Wl,-z,max-page-size=16384"
        FFMPEG_ASM="--enable-neon --enable-asm"; GO_VIRTUAL_MACHINE_HACK=""
    else
        ABI="armeabi-v7a"; FFMPEG_ARCH="arm"; TARGET_PREFIX="armv7a-linux-androideabi"
        OUT_BIN_NAME="libmain_${ABI}.so"; export GOARCH=arm; export GOARM=7
        API_LEVEL="21"; GLES_VERSION="gles2"; GLES_LINK="-lGLESv2"
        PC_LIBS="gl glesv2"; PAGE_ALIGN=""
        FFMPEG_ASM="--enable-neon --enable-asm"
        GO_VIRTUAL_MACHINE_HACK="-X 'runtime.godebugDefault=asyncpreemptoff=1,sigaltstack=0,cgocheck=0,invalidptr=0'"
    fi
    
    echo "=========================================================="
    echo "==> BUILDING ENGINE FOR ARCHITECTURE: $ABI"
    echo "==> Target API: $API_LEVEL | Graphics Engine: $GLES_VERSION"
    echo "=========================================================="

    local host_os="linux"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        host_os="darwin"
    fi
    
    export TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/${host_os}-x86_64"
    export CC="$TOOLCHAIN/bin/${TARGET_PREFIX}${API_LEVEL}-clang"
    export CXX="$TOOLCHAIN/bin/${TARGET_PREFIX}${API_LEVEL}-clang++"
    
    local DEPS_PREFIX="$REPO_ROOT/build/android-deps/$ABI"
    export PKG_CONFIG_LIBDIR="$DEPS_PREFIX/lib/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$DEPS_PREFIX"
    
    if [[ -f "$DEPS_PREFIX/lib/libavcodec.so" && -f "$DEPS_PREFIX/lib/libSDL2.so" ]]; then
        echo "✅ 发现 $ABI 架构的缓存依赖包! 成功跳过 FFmpeg 与 SDL2 的编译。"
    else
        build_sdl2_arch "$ABI" "$DEPS_PREFIX" "$PAGE_ALIGN"
        build_libxmp_arch "$ABI" "$DEPS_PREFIX" "$PAGE_ALIGN"
        build_ffmpeg_arch "$ABI" "$FFMPEG_ARCH" "$TARGET_PREFIX" "$DEPS_PREFIX" "$API_LEVEL" "$PAGE_ALIGN" "$FFMPEG_ASM"
    fi

    create_dummy_gles_pc "$DEPS_PREFIX" "$PC_LIBS"
    
    go mod download || true
    
    patch_go_sdl2_android
    patch_reisen_android
    ensure_go_flags_android

    export CGO_CFLAGS="-I$DEPS_PREFIX/include -I$DEPS_PREFIX/include/SDL2"
    local deps_libs="-L$DEPS_PREFIX/lib -lSDL2 -lxmp -lavformat -lavcodec -lavutil -lswscale -lswresample -lavfilter -lvpx"
    export CGO_LDFLAGS="${deps_libs} $GLES_LINK -lOpenSLES -llog $PAGE_ALIGN"

    local go_ldflags="-X 'main.Version=${APP_VERSION}' -X 'main.BuildTime=${APP_BUILDTIME}' $GO_VIRTUAL_MACHINE_HACK"

    if [[ "${FAST_BUILD_MODE:-1}" == "0" ]]; then
        go_ldflags="-s -w $go_ldflags"
        go build -buildmode=c-shared -trimpath -v -tags=android,$GLES_VERSION \
        -ldflags="$go_ldflags" -o "$OUTDIR/$OUT_BIN_NAME" ./src
    else
        go build -buildmode=c-shared -trimpath -v -tags=android,$GLES_VERSION \
        -gcflags="all=-N -l" -ldflags="$go_ldflags" -o "$OUTDIR/$OUT_BIN_NAME" ./src
    fi
    
    local abi_dir="$ANDROID_APK_DIR/app/src/main/jniLibs/$ABI"
    mkdir -p "$abi_dir"
    rm -f "$abi_dir"/*.so* 2>/dev/null || true
    
    cp -av "$OUTDIR/$OUT_BIN_NAME" "$abi_dir/libmain.so"
    cp -av "$DEPS_PREFIX"/lib/*.so* "$abi_dir/" 2>/dev/null || true
}

function sync_android_apk_repo() {
	mkdir -p "$(dirname "$ANDROID_APK_DIR")"
	if [[ ! -d "$ANDROID_APK_DIR/.git" ]]; then
		git clone --depth=1 -b "$ANDROID_APK_REF" "$ANDROID_APK_REPO" "$ANDROID_APK_DIR"
	else
		( cd "$ANDROID_APK_DIR" && git fetch --depth=1 origin "$ANDROID_APK_REF" && git checkout -f FETCH_HEAD )
	fi
}

function ensure_android_runtime_assets() {
	mkdir -p "$(dirname "$SCREENPACK_DIR")"
	if [[ ! -d "$SCREENPACK_DIR/.git" ]]; then
		git clone --depth=1 -b "$SCREENPACK_REF" "$SCREENPACK_REPO" "$SCREENPACK_DIR"
	fi
	local db="$REPO_ROOT/external/gamecontrollerdb.txt"
	if [[ ! -f "$db" ]]; then
		curl -fsSL "https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/master/gamecontrollerdb.txt" -o "$db"
	fi
	
	local sys="$REPO_ROOT/data/system.base.def"
	if [[ ! -f "$sys" ]]; then
		echo "==> Generating data/system.base.def from src/resources/defaultMotif.ini..."
		mkdir -p "$REPO_ROOT/data"
		cp -a "$REPO_ROOT/src/resources/defaultMotif.ini" "$sys"
	fi
}

function stage_android_apk_assets() {
	local assets_dir="$ANDROID_APK_DIR/app/src/main/assets"
	local manifest="$assets_dir/manifest.txt"
	if [[ ! -f "$manifest" ]]; then return 0; fi
	
	find "$assets_dir" -mindepth 1 -maxdepth 1 ! -name "manifest.txt" -exec rm -rf {} + 2>/dev/null || true
	
	while read -r p; do
		if [[ -z "$p" ]]; then continue; fi
		local src="$REPO_ROOT/$p"
		if [[ ! -e "$src" && -e "$SCREENPACK_DIR/$p" ]]; then
			src="$SCREENPACK_DIR/$p"
		fi
		if [[ -e "$src" ]]; then
			mkdir -p "$(dirname "$assets_dir/$p")"
			cp -R "$src" "$assets_dir/$p"
		fi
	done < <(tr -s '[:space:]' '\n' < "$manifest")
}

function build_android_apk() {
	local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
	export ANDROID_SDK_ROOT="$sdk"
	export ANDROID_HOME="$sdk"
	export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk-bundle}"
	
	echo "==> Compiling Go Engine Bridge with Gomobile..."
	
	# 👇 终极隔离结界：在这括号内进行所有 Gomobile 相关的操作，完全避开上方的干扰
	(
		# 1. 彻底清除会干扰编译的变量
		unset CGO_CFLAGS
		unset CGO_LDFLAGS
		unset GOOS
		unset GOARCH
		export CGO_ENABLED=0
		
		# 2. 安装工具
		go install golang.org/x/mobile/cmd/gomobile@latest
		go install golang.org/x/mobile/cmd/gobind@latest
		
		# 👇 核心修复 5：给隔离结界赋予寻找 gobind 工具的能力！
		export PATH="$PATH:$(go env GOPATH)/bin"
		
		local GOMOBILE_BIN="$(go env GOPATH)/bin/gomobile"
		"$GOMOBILE_BIN" init
		
		local libs_dir="$ANDROID_APK_DIR/app/libs"
		mkdir -p "$libs_dir"
		
		if [ -d "$ANDROID_APK_DIR/go_engine" ]; then
			pushd "$ANDROID_APK_DIR/go_engine" >/dev/null
			
			# 3. 整理模块并强制拉取核心依赖包
			go mod tidy
			echo "==> 下载并绑定 Gomobile 核心依赖包..."
			go get golang.org/x/mobile/bind@latest
			
			# 4. 重新开启 CGO (因为打包成 aar 需要它)
			export CGO_ENABLED=1
			
			if [[ "${FAST_BUILD_MODE:-1}" == "0" ]]; then
				echo "🔥 满血模式: 正在以最高优化编译 Go 桌面扩展模块 (已屏蔽模拟器，锁定 32/64 位真机架构)..."
				"$GOMOBILE_BIN" bind -androidapi 21 -ldflags="-s -w" -target=android/arm,android/arm64 -o "$libs_dir/ikemenapi.aar" ./api
			else
				echo "⚡ 测试模式: 正在极速编译 Go 桌面扩展模块 (已屏蔽模拟器，锁定 32/64 位真机架构)..."
				"$GOMOBILE_BIN" bind -androidapi 21 -target=android/arm,android/arm64 -o "$libs_dir/ikemenapi.aar" ./api
			fi
			popd >/dev/null
		else
			echo "⚠️ 提示: 未在安卓仓库找到 go_engine 目录，正常跳过。"
		fi
	)
	# 👆 隔离区结束 ========================================================

	echo "==> Building APK with Gradle..."
	pushd "$ANDROID_APK_DIR" >/dev/null
	printf "sdk.dir=%s\n" "${ANDROID_SDK_ROOT}" > local.properties
	chmod +x ./gradlew || true
	./gradlew --no-daemon clean assembleRelease -Pandroid.lintOptions.abortOnError=false
	
	local apk_found=$(find app/build/outputs/apk/release/ -maxdepth 1 -name "*.apk" | head -n 1)
	if [[ -z "$apk_found" ]]; then
		echo "ERROR: No APK generated." >&2
		exit 1
	fi
	mkdir -p "$(dirname "$ANDROID_APK_OUT")"
	cp -v "$apk_found" "$ANDROID_APK_OUT"
	popd >/dev/null
}

function main() {
	export CGO_ENABLED=1
	export GOOS=android
	export GOEXPERIMENT=arenas
	mkdir -p "$OUTDIR"
	
	ensure_go_env
	check_deps
	
	sync_android_apk_repo
	ensure_android_runtime_assets
	stage_android_apk_assets
	
	build_engine_arch "arm64"
	build_engine_arch "arm"
	
	build_android_apk
}

main "$@"
