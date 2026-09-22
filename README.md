# WechatOpenSDK Wrapper

将微信官方 **含支付** 的 OpenSDK 封装为 Swift Package。

- **Current WechatOpenSDK version:** 2.0.8
- **变体(variant):** 含支付（不是 `NoPay`）
- **官方下载:** https://developers.weixin.qq.com/doc/oplatform/Downloads/iOS_Resource.html

每次从官网下载新的 `WechatOpenSDK.xcframework` 后，在本仓库根目录运行：

```bash
./patch.sh <下载的 WechatOpenSDK.xcframework 路径> [最低iOS版本(默认17.0)]
```

然后按官方版本号打 tag（例如 `2.0.8`）再推送。

## 接入

Xcode → Project → Package Dependencies → 添加本仓库，选中 library `WechatOpenSDK`。

2.0.5 起头文件变成 module 路径，Bridging Header 需要写成：

```objc
#import <WechatOpenSDK/WXApi.h>
#import <WechatOpenSDK/WXApiObject.h>
#import <WechatOpenSDK/WechatAuthSDK.h>
```

不要再用 `#import <WXApi.h>`。

## 为什么需要 patch.sh

官方 2.0.8 的 inner `WechatOpenSDK.framework/Info.plist` 不完整：

- 没有 `CFBundlePackageType = FMWK`
- `CFBundleShortVersionString` / `CFBundleVersion` 写成了 `1.0`，不是 SDK 版本

SwiftPM 的 `binaryTarget` 仍可能把 `.framework` 拷进 `.app/Frameworks/`。App Store 校验这份 plist 时，缺 `FMWK` 或版本号不合法会拒包（例如 ITMS-90060 / Invalid Bundle）。

`patch.sh` 只做这些事：

1. 用官网包覆盖 `Sources/WechatOpenSDK.xcframework`
2. 确认这是含支付包（头文件里有 `PayReq`）
3. 给每个 slice 写入合法的 framework `Info.plist`
4. 删掉 `.DS_Store` 和失效的 `_CodeSignature`

**不会改 Mach-O 二进制。** 这点和 AlipaySDK 包装不同：

- 微信这个包的 “framework 可执行文件” 实际是静态 `.a`（多个 `.o` 的 archive）
- 每个 `.o` 带有 `LC_VERSION_MIN_IPHONEOS 5.1.1`
- `vtool` 无法改写（`not enough space to hold load commands`）
- 用 `ld -r` 能改出版本 load command，但会重写 object，不是纯替换

静态 `.a` 会链进宿主 App，最终主二进制的最低系统版本跟 App 的 deployment target，不跟这些 `.o` 的 `5.1.1`。因此这里不改二进制。

## 升级检查清单

1. 官网下载 **含支付** 的 iOS 包，不要下 `NoPay`
2. 更新 `patch.sh` 里读到的版本（一般会从包内 `README.txt` 的 `SDK2.x.x` 自动解析）
3. `./patch.sh ~/Downloads/WechatOpenSDK.xcframework`
4. 确认 `Sources/WechatOpenSDK.xcframework` 仍有 `ios-arm64` 和 `ios-arm64_x86_64-simulator`
5. commit + tag 官方版本号（必须和官网一致，例如 `2.0.8`）
