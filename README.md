# Newloc

iOS 虚拟定位工具。在地图上点一个点，整台手机的位置就切过去。

不需要电脑、不需要数据线、不需要描述文件 —— 代理与证书都在应用内完成，
改写结果由端到端探测回执，生效就是生效。

- 纯 SwiftUI，适配 **iOS 15 ~ iOS 26**
- 内置 MITM 代理，改写 Apple 网络定位服务（`gs-loc.apple.com`）返回的经纬度
- 同时提供 6 种代理客户端的模块外壳，给不想开内置代理的人用

---

## 功能

| | |
|---|---|
| **地图选点** | 搜索地名或直接输入经纬度，点击地图落针 |
| **双坐标显示** | 同时给出 GCJ-02（地图展示）与 WGS-84（实际下发），港澳台与境外坐标恒等 |
| **收藏夹** | 常用位置一键收藏、命名、快速切换 |
| **半径漂移** | 可在目标点周围半径内做小范围漂移，避免坐标钉死在一点 |
| **效果校验** | 不用回读定位（系统会缓存），而是问改写层要证据：内置代理的 Go 日志与第三方脚本的诊断回执汇总成账本，据此判定生效 / 未生效 / 无法判定 |
| **诊断页** | 把代理状态、证书状态、链路探针结果、改写账本一次性摊开 |

## 工作原理

```
              ┌──────────── App（SwiftUI）────────────┐
              │  地图选点 → WGS-84 目标坐标           │
              └───────────────┬──────────────────────┘
                              │ 写坐标
              ┌───────────────▼──────────────────────┐
              │  Core（Go 静态库 · 本机 127.0.0.1）   │
              │  · 本地 HTTPS 代理 + 自签 CA          │
              │  · 命中 gs-loc 时改写 protobuf 响应   │
              │  · 逐次记账（谁被改写、何时）         │
              └───────────────┬──────────────────────┘
                              │ 系统定位请求
              ┌───────────────▼──────────────────────┐
              │  iOS 定位服务                         │
              └──────────────────────────────────────┘
```

代理与证书由 App 在设备内拉起，CA 需手动在
`设置 → 通用 → VPN与设备管理` 里信任一次。

> ⚠️ 内置代理是**常驻**的：Wi-Fi 里配了 `127.0.0.1:8888` 之后，
> 代理一停这台机器就断网。所以它只有「开启」和「带警告的关闭」，没有静默停止。

## 两个版本

同一份源码、两个 target：

| | 普通版 `Newloc` | 全能版 `NewlocUltimate` |
|---|---|---|
| 内置代理 | ✅ | ✅ |
| 第三方客户端模块引导 | — | ✅（`THIRD_PARTY_MODE`） |
| Bundle ID | `com.xxx.loc` | `com.xxx.loc.ultimate` |

两个包可以装在同一台手机上共存。

## 第三方客户端模块

全能版内置引导，也可以在客户端里直接订阅下面任一地址：

| 客户端 | 模块地址 |
|---|---|
| Shadowrocket | `https://cdn.jsdelivr.net/gh/Lululu-0715/Newloc@main/ThirdParty/ProxyScripts/modules/wloc.module` |
| Surge / Egern | `https://cdn.jsdelivr.net/gh/Lululu-0715/Newloc@main/ThirdParty/ProxyScripts/modules/wloc.sgmodule` |
| Quantumult X | `https://cdn.jsdelivr.net/gh/Lululu-0715/Newloc@main/ThirdParty/ProxyScripts/modules/wloc.conf` |
| Loon | `https://cdn.jsdelivr.net/gh/Lululu-0715/Newloc@main/ThirdParty/ProxyScripts/modules/wloc.lpx` |
| Stash | `https://cdn.jsdelivr.net/gh/Lululu-0715/Newloc@main/ThirdParty/ProxyScripts/modules/wloc.stoverride` |

导入后需要开启模块并启用 MITM。**不要**给模块声明的主机名加 `DIRECT` 规则 ——
那会让流量绕过代理，规则看起来装好了却永远不会触发。

> 定位响应是 protobuf 二进制，客户端必须开 `binary-body-mode`。
> 不开的话客户端会先按 UTF-8 解码再交给脚本，高位字节被替换成 `U+FFFD`，
> 表现是「模块在跑、坐标也写进去了，定位纹丝不动」。

## 构建

**环境**：macOS + Xcode（26.x）+ Go 1.23+ + [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
# 1. 编译 Go 静态库 → Core/build/{iphoneos,iphonesimulator}/liblocationcore.a
Scripts/build-core.sh

# 2. 由 project.yml 生成 Xcode 工程
xcodegen generate

# 3. 打开并构建（未签名）
open Newloc.xcodeproj
```

仓库里已经带了生成好的 `Newloc.xcodeproj`；只有改过 `project.yml` 之后才需要重新
`xcodegen generate`。

构建产物是**未签名**的 `.app`，签名交给 Impactor / 爱思助手等工具自行完成。

版本号只从 `project.yml` 的 `MARKETING_VERSION` 读，改它用：

```bash
python3 Scripts/bump-version.py --bump        # 末位 +1
python3 Scripts/bump-version.py --set 1.2.3   # 指定
```

## 目录结构

```
App/          SwiftUI 界面（地图主页、设置、收藏、诊断、欢迎页）
Shared/       业务层（代理控制、证书、坐标转换、校验器、设计系统）
Core/         Go 源码：代理、CA、protobuf 编解码、改写账本
ThirdParty/   第三方客户端的 JS 脚本与 6 种模块外壳
Resources/    本地化字符串、图标、Info.plist
Tests/        单元测试
Scripts/      build-core.sh（Go 静态库）、bump-version.py
```

## 已知限制

- **模拟器**：iOS 18+ 的模拟器在 x86_64 上 `MKMapView` 会把陆地渲染成纯红色
  （Apple 侧问题，真机不受影响）；模拟器地图 POI 数据也比真机薄很多。
- **deployment target 15.0**：`GlassContainer` 在 iOS 15 ~ 25 走 Material 自绘，
  iOS 26 起才切原生 `glassEffect()`，两套实现对齐同一份设计稿。
- Bundle ID 用的是占位 `com.xxx.loc`，自行改 `project.yml` 后再构建。

## 声明

仅供学习与研究使用。使用者需自行遵守所在地法律法规，不得用于考试、考勤等
欺骗性用途。使用本工具产生的一切后果由使用者自行承担。

## 许可

MIT
