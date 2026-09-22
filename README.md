# WechatOpenSDK Wrapper

将微信官方 WechatOpenSDK 封装为 Swift Package。

- **Current WechatOpenSDK version:** 2.0.8
- **变体(variant):** 含支付（不是 `NoPay`）
- **官方下载:** https://developers.weixin.qq.com/doc/oplatform/Downloads/iOS_Resource.html
- **最低 iOS:** 17.0（与 STTiOS 一致）

> **为什么用含支付包而不是 NoPay:** 中国区 App 要通过 `PayReq` 调起微信支付。NoPay 变体没有支付接口。升级时务必继续从官网 **含支付** 目录取源。

## ⚠️ 升级 SDK 时必须运行 patch.sh

微信官方发布的 xcframework，从 2.0.5 起把静态 `.a` 套进 `.framework`。这个包装过 App Store 时会碰到两类问题：

1. **ITMS-90208（Invalid Bundle — does not support the minimum OS Version）**  
   真机 `.o` 带过时的 `LC_VERSION_MIN_IPHONEOS`（version **5.1.1**）。App Store 上传校验读的是这个 load command（**不是** `Info.plist` 里的 `MinimumOSVersion`）。宿主 App 部署目标是 iOS 17 时会被拒。

2. **残缺的 framework `Info.plist`**  
   官方 inner plist 没有 `CFBundlePackageType = FMWK`，版本还写成 `1.0`。SwiftPM `binaryTarget` 仍可能把 `.framework` 拷进 `.app/Frameworks/`，商店会按 framework 去验这份 plist。

> 注意:只改 `Info.plist` 的 `MinimumOSVersion` **不够** —— ITMS-90208 看二进制 load command。

因此每次从官网下载新版 xcframework 后，都要运行 `patch.sh`：

```bash
./patch.sh <下载的 WechatOpenSDK.xcframework 路径> [最低iOS版本(默认17.0)]
```

`patch.sh` 会：

- 把所有 slice/arch 里每个 `.o` 的最低系统版本改成 17.0（原地改 4 字节，不重链、不改代码）
- 写入合法的 framework `Info.plist`（`FMWK` + 官方三段版本号）
- 确认这是含支付包（头文件里有 `PayReq`）

framework 在宿主 App 归档时随 App 一并签名，无需在此重签。

## 接入

Xcode → Project → Package Dependencies → 添加本仓库，选中 library `WechatOpenSDK`。

2.0.5 起头文件是 module 路径，Bridging Header 写成：

```objc
#import <WechatOpenSDK/WXApi.h>
#import <WechatOpenSDK/WXApiObject.h>
#import <WechatOpenSDK/WechatAuthSDK.h>
```

不要再用 `#import <WXApi.h>`。

## 升级检查清单

1. 官网下载 **含支付** 的 iOS 包，不要下 `NoPay`
2. `./patch.sh ~/Downloads/WechatOpenSDK.xcframework`
3. 确认仍有 `ios-arm64` 和 `ios-arm64_x86_64-simulator`
4. commit + tag 官方版本号（必须和官网一致，例如 `2.0.8`）
