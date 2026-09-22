#!/bin/bash
# 把官网 WechatOpenSDK.xcframework 拷进本仓库,并做 App Store 需要的修正:
#   1. 每个 .o 的 LC_VERSION_MIN_IPHONEOS / LC_BUILD_VERSION minos 改成宿主
#      最低 iOS(默认 17.0)。微信静态 .a 的 load command 没有多余空间,vtool
#      会报 not enough space;因此只原地改 version/minos 这 4 个字节,不重链。
#   2. inner WechatOpenSDK.framework 补齐合法 Info.plist(FMWK + 官方版本号)。
#      官方 plist 缺 CFBundlePackageType、版本写成 1.0;SPM 嵌入时商店会验。
#   3. 删除失效签名(若有);framework 会在宿主 App 归档时随 App 重新签名。
#
# 用法:
#   ./patch.sh <源 WechatOpenSDK.xcframework 路径> [最低iOS版本(默认17.0)]
#
set -euo pipefail

SRC_XCFRAMEWORK="${1:?用法: ./patch.sh <源 WechatOpenSDK.xcframework 路径> [最低iOS版本]}"
MIN_IOS="${2:-17.0}"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_XCFRAMEWORK="$REPO_DIR/Sources/WechatOpenSDK.xcframework"
BUNDLE_ID="com.tencent.WechatOpenSDK"

if [[ ! -d "$SRC_XCFRAMEWORK" ]]; then
    echo "找不到源 xcframework: $SRC_XCFRAMEWORK" >&2
    exit 1
fi
if [[ ! -f "$SRC_XCFRAMEWORK/Info.plist" ]]; then
    echo "源路径不是 xcframework(缺 Info.plist): $SRC_XCFRAMEWORK" >&2
    exit 1
fi

echo "源:   $SRC_XCFRAMEWORK"
echo "目标: $DEST_XCFRAMEWORK"
echo "最低 iOS: $MIN_IOS"
echo ""

rm -rf "$DEST_XCFRAMEWORK"
mkdir -p "$(dirname "$DEST_XCFRAMEWORK")"
rsync -a --exclude '.DS_Store' "$SRC_XCFRAMEWORK/" "$DEST_XCFRAMEWORK/"
find "$DEST_XCFRAMEWORK" -name '.DS_Store' -delete

README_TXT="$DEST_XCFRAMEWORK/README.txt"
if [[ ! -f "$README_TXT" ]]; then
    echo "源包缺少 README.txt,无法确认官方版本号。" >&2
    exit 1
fi
SDK_VERSION="$(grep -E '^SDK[0-9]' "$README_TXT" | head -1 | sed -E 's/^SDK//')"
if [[ -z "$SDK_VERSION" ]]; then
    echo "无法从 README.txt 解析 SDK 版本号。" >&2
    exit 1
fi
# CFBundleShortVersionString 最多三段(x.y.z),否则触发 ITMS-90060。
SHORT_VERSION="$(echo "$SDK_VERSION" | awk -F. '{print $1"."$2"."$3}')"
echo "解析到官方版本: $SDK_VERSION (plist short version: $SHORT_VERSION)"
echo ""

PAY_HEADER="$(find "$DEST_XCFRAMEWORK" -name WXApiObject.h | head -1)"
if [[ -z "$PAY_HEADER" ]] || ! grep -q '@interface PayReq' "$PAY_HEADER"; then
    echo "这不是含支付的 OpenSDK(头文件里没有 PayReq)。请下载官网含支付包,不要用 NoPay。" >&2
    exit 1
fi

# 原地改 Mach-O 里的 minos / LC_VERSION_MIN version,不重链。
patch_object() {
    local object="$1"
    python3 - "$object" "$MIN_IOS" <<'PY'
import struct, sys

path, minos_s = sys.argv[1], sys.argv[2]
parts = [int(x) for x in minos_s.split(".")] + [0, 0]
minos = (parts[0] << 16) | (parts[1] << 8) | parts[2]

LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32
MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE

data = bytearray(open(path, "rb").read())
magic = struct.unpack_from("<I", data, 0)[0]
if magic == MH_MAGIC_64:
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
elif magic == MH_MAGIC:
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 28
else:
    raise SystemExit(f"{path}: not mach-o ({magic:#x})")

changed = 0
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", data, off)
    if cmd == LC_VERSION_MIN_IPHONEOS and cmdsize >= 16:
        struct.pack_into("<I", data, off + 8, minos)
        changed += 1
    elif cmd == LC_BUILD_VERSION and cmdsize >= 24:
        struct.pack_into("<I", data, off + 12, minos)
        changed += 1
    off += cmdsize

if changed == 0:
    raise SystemExit(f"{path}: 没有 LC_VERSION_MIN_IPHONEOS / LC_BUILD_VERSION")
open(path, "wb").write(data)
PY
}

# 静态 .a(可能是 fat):拆 arch → 抽 .o → 改 minos → 重新归档 → 再合并。
patch_archive() {
    local binary="$1"
    local archs
    archs="$(lipo -archs "$binary")"
    local tmp
    tmp="$(mktemp -d)"
    local thin_files=()

    for arch in $archs; do
        local thin="$tmp/$arch.a"
        local objs="$tmp/$arch.objs"
        mkdir -p "$objs"
        lipo "$binary" -thin "$arch" -output "$thin"
        (cd "$objs" && ar -x "$thin")
        local obj_list=()
        for obj in "$objs"/*.o; do
            [[ -f "$obj" ]] || continue
            patch_object "$obj"
            obj_list+=("$obj")
        done
        if [[ ${#obj_list[@]} -eq 0 ]]; then
            echo "❌ $binary ($arch) 里没有 .o" >&2
            rm -rf "$tmp"
            exit 1
        fi
        libtool -static -o "$tmp/$arch.patched.a" "${obj_list[@]}"
        thin_files+=("$tmp/$arch.patched.a")
    done

    if [[ ${#thin_files[@]} -gt 1 ]]; then
        lipo -create "${thin_files[@]}" -output "$binary"
    else
        cp "${thin_files[0]}" "$binary"
    fi
    rm -rf "$tmp"
}

write_framework_plist() {
    local fw_dir="$1"
    cat > "$fw_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>WechatOpenSDK</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>WechatOpenSDK</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$SDK_VERSION</string>
	<key>MinimumOSVersion</key>
	<string>$MIN_IOS</string>
</dict>
</plist>
PLIST
}

slice_count=0
for slice_dir in "$DEST_XCFRAMEWORK"/*/; do
    slice_name="$(basename "$slice_dir")"
    fw_dir="$slice_dir/WechatOpenSDK.framework"
    binary="$fw_dir/WechatOpenSDK"
    [[ -d "$fw_dir" && -f "$binary" ]] || continue
    slice_count=$((slice_count + 1))

    echo "改写 $slice_name ..."
    patch_archive "$binary"
    write_framework_plist "$fw_dir"
    rm -rf "$fw_dir/_CodeSignature"
done

if [[ "$slice_count" -eq 0 ]]; then
    echo "没有找到任何 WechatOpenSDK.framework slice。" >&2
    exit 1
fi

echo ""
echo "=== 校验 ==="
fail=0
has_device=0
has_simulator=0
for slice_dir in "$DEST_XCFRAMEWORK"/*/; do
    slice_name="$(basename "$slice_dir")"
    fw_dir="$slice_dir/WechatOpenSDK.framework"
    binary="$fw_dir/WechatOpenSDK"
    [[ -f "$binary" ]] || continue

    if [[ "$slice_name" == *simulator* ]]; then
        has_simulator=1
    else
        has_device=1
    fi

    if otool -l "$binary" | grep -E -q 'version 5\.|minos 5\.|minos 14\.'; then
        echo "❌ $slice_name 仍残留过低的 minos / LC_VERSION_MIN"; fail=1
    elif [[ ! -f "$fw_dir/Info.plist" ]]; then
        echo "❌ $slice_name 缺少 Info.plist"; fail=1
    else
        pkg="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$fw_dir/Info.plist" 2>/dev/null || true)"
        ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$fw_dir/Info.plist" 2>/dev/null || true)"
        if [[ "$pkg" != "FMWK" ]]; then
            echo "❌ $slice_name CFBundlePackageType=$pkg (期望 FMWK)"; fail=1
        elif [[ "$ver" != "$SHORT_VERSION" ]]; then
            echo "❌ $slice_name CFBundleShortVersionString=$ver (期望 $SHORT_VERSION)"; fail=1
        else
            archs="$(lipo -archs "$binary")"
            echo "✅ $slice_name -> minos $MIN_IOS, FMWK $ver, archs: $archs"
        fi
    fi
done

if [[ "$has_device" -eq 0 ]]; then
    echo "❌ 缺少真机 slice"; fail=1
fi
if [[ "$has_simulator" -eq 0 ]]; then
    echo "❌ 缺少模拟器 slice"; fail=1
fi

[[ $fail -eq 0 ]] && echo "" && echo "全部 slice 已修正。" || { echo "存在未修正的 slice。"; exit 1; }
