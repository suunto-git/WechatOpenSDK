// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WechatOpenSDK",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "WechatOpenSDK", targets: ["WechatOpenSDK"]),
    ],
    targets: [
        .binaryTarget(
            name: "WechatOpenSDK",
            path: "./Sources/WechatOpenSDK.xcframework"
        )
    ]
)
