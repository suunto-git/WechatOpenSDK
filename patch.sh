#!/bin/bash
# 把官网 WechatOpenSDK.xcframework 拷进本仓库,并补齐 SPM / App Store 需要的
# framework Info.plist。
#
# 不改 Mach-O。微信 2.0.8 的 inner binary 是静态 .a,每个 .o 带
# LC_VERSION_MIN_IPHONEOS 5.1.1;vtool 因 load command 空间不够无法改写。
# 静态库会链进宿主 App,最终最低系统版本跟 App deployment target。
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

    echo "修正 $slice_name ..."
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
    [[ -d "$fw_dir" ]] || continue

    if [[ "$slice_name" == *simulator* ]]; then
        has_simulator=1
    else
        has_device=1
    fi

    if [[ ! -f "$fw_dir/Info.plist" ]]; then
        echo "❌ $slice_name 缺少 Info.plist"; fail=1; continue
    fi
    pkg="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$fw_dir/Info.plist" 2>/dev/null || true)"
    ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$fw_dir/Info.plist" 2>/dev/null || true)"
    if [[ "$pkg" != "FMWK" ]]; then
        echo "❌ $slice_name CFBundlePackageType=$pkg (期望 FMWK)"; fail=1
    elif [[ "$ver" != "$SHORT_VERSION" ]]; then
        echo "❌ $slice_name CFBundleShortVersionString=$ver (期望 $SHORT_VERSION)"; fail=1
    else
        archs="$(lipo -archs "$fw_dir/WechatOpenSDK" 2>/dev/null || echo "?")"
        echo "✅ $slice_name -> FMWK $ver, archs: $archs"
    fi
done

if [[ "$has_device" -eq 0 ]]; then
    echo "❌ 缺少真机 slice"; fail=1
fi
if [[ "$has_simulator" -eq 0 ]]; then
    echo "❌ 缺少模拟器 slice"; fail=1
fi

[[ $fail -eq 0 ]] && echo "" && echo "全部 slice 已修正。" || { echo "存在未修正的 slice。"; exit 1; }
