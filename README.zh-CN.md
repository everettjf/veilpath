<p align="center">
  <img src="Vellune/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Vellune 应用图标">
</p>

<h1 align="center">Vellune</h1>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

<p align="center">
  一款适用于 iPhone 和 iPad 的原生只读容器浏览器，<br>
  基于 <a href="https://github.com/forcequitOS/bad_query"><code>bad_query</code></a> 沙盒逃逸技术构建。
</p>

<p align="center">
  <a href="https://xnu.app/vellune/">网站</a> ·
  <a href="#兼容性">兼容性</a> ·
  <a href="#构建">构建</a> ·
  <a href="#致谢">致谢</a>
</p>

> [!IMPORTANT]
> **支持版本：iOS / iPadOS 26 至 27 beta 3。** 完整的 `bad_query` 访问路径
> 已在运行 **iPadOS 27 beta 3（`24A5380l`）** 的 iPad Air 真机上验证。
> 实际功能必须使用真机，模拟器只能验证编译和界面。上游概念验证项目标注支持
> 至 iOS 26.6.1 和 iOS 27 beta 4，但这些额外版本尚未全部经过 Vellune 验证。

![Vellune 在 iPad 上运行](docs/assets/ipad-ui.png)

## Vellune 是什么？

Vellune 将 `bad_query` 概念验证项目转化为一个专注于文件探索的界面，
适用于该技术能够生效的 iOS 和 iPadOS 版本。它可以发现通常无法访问的容器、
解析容器标识符，并在不开放任意写入能力的前提下查看和导出文件。

**Vellune** 是一个由 **veil**（面纱）和 **lune**（法语“月亮”）启发而来的
自造词。它所表达的意象是“透过面纱，看见此前被隐藏的事物”——这与探索
应用正常沙盒边界之外的数据十分契合。

## 主要特性

- 原生 SwiftUI 界面，自适应 iPad 和 iPhone。
- 索引应用、App Group、PluginKit、内部守护进程、系统数据和系统组容器。
- 通过容器元数据将容器 UUID 解析为易读的 Bundle ID。
- 当容器根目录无法直接打开时，使用 `fsgetpath` 进行 inode 回退发现。
- 每次操作单独获取沙盒扩展，并在操作完成后立即释放。
- 支持预览文本、JSON、属性列表和图像。
- 先将文件暂存到 Vellune 缓存，再调用系统共享面板。
- 内置真机诊断套件，可生成结构化 JSON 报告。
- 刻意保持只读，不提供破坏性的容器操作。

## 兼容性

Vellune 只对已经完成适配和测试的系统范围作出支持声明。**不能因为项目可以编译，
就认为更新的 beta 或正式版同样兼容。** 安装后应运行 App 内置的真机自检；
Container Manager 的私有行为可能在不同系统构建版本之间发生变化。

| 平台 | 目标版本 | 验证情况 |
| --- | --- | --- |
| iPadOS | 27 beta 3（`24A5380l`） | 已在 iPad Air（`iPad15,3`）真机完整测试 |
| iOS / iPadOS | 26.x | 部署目标及 App Group 兼容路径 |
| iPhone | 26–27 beta 3 | 自适应界面构建及模拟器验证 |
| 模拟器 | 26–27 | 仅验证界面；`bad_query` 需要真机 |

上游项目目前说明支持至 iOS 26.6.1 和 iOS 27 beta 4。Vellune 在此有意只记录
已经实现并验证的较窄范围：**iOS/iPadOS 26 至 27 beta 3**。超出这个范围的版本，
在完成真机测试之前均视为不受支持。

### 真机诊断

Vellune 内置真机回归套件，用于验证沙盒访问、容器发现、结构化预览、文件分析、
Mach-O 解析、安全导出及本地搜索。结果会写入 Vellune 自身数据容器内的
`Documents/vellune-self-test.json`。容器数量完全取决于每台设备安装的应用和
系统状态，因此文档不再把某一台设备的数量作为项目的通用指标。

## 构建

### 环境要求

- Xcode 27 beta
- iOS 或 iPadOS 26.0 及以上版本
- 用于真机签名的 Apple 开发团队
- 用于测试沙盒访问能力的实体设备

### 步骤

1. 克隆仓库：

   ```sh
   git clone https://github.com/everettjf/vellune.git
   cd vellune
   ```

2. 打开 `Vellune.xcodeproj`。
3. 选择 `Vellune` scheme 和一个 iPhone 或 iPad 目标设备。
4. 在 **Signing & Capabilities** 中选择你的开发团队。
5. 构建并运行。

Vellune 在 iOS 26 的 App Group 访问路径中使用
`group.com.eevv.Vellune`。如果你使用不同的 Bundle ID 或开发团队构建，
请在 `Vellune/Vellune.entitlements` 和
`Vellune/Core/BadQueryClient.swift` 中将其替换为你的账户所拥有的
App Group。

## 项目结构

```text
Vellune.xcodeproj/          Xcode 工程
Vellune/
  BadQuery/                 C 桥接与沙盒扩展原语
  Containers/               容器索引与元数据解析
  Core/                     文件访问、预览与导出
  Diagnostics/              真机回归测试套件
  Model/                    Observable 应用状态
  ContentView.swift         自适应 iPad/iPhone 界面
docs/                       GitHub Pages 网站
```

## 安全与范围

Vellune 是实验性安全研究软件。它依赖私有 API 以及可能随系统版本变化的行为。
请仅在你拥有的设备和数据上使用，或在获得明确授权的环境中进行测试。

用户界面被有意设计为只读。导出操作只会在 Vellune 缓存中创建副本，不会修改
源文件。诊断功能会明确报告失败，而不会假定某条路径可以访问。

## 致谢

Vellune 的诞生离不开原始的
[`forcequitOS/bad_query`](https://github.com/forcequitOS/bad_query)
沙盒逃逸概念验证项目。感谢 **forcequitOS** 及该项目的贡献者研究这一问题，
并为社区公开了清晰的实现。

Vellune 的底层容器查询方式源自该项目。复用或扩展相关实现时，请注明并支持
上游项目。

## 许可状态

上游 `bad_query` 仓库目前没有声明开源许可证。因此，
`Vellune/BadQuery/` 下的衍生文件**不会**自动获得宽松许可证的授权，
本仓库也不会作出相反声明。

在为整个仓库指定统一的开源许可证之前，应先取得上游作者的许可或明确其许可
方式。其余由 Vellune 原创的代码，可以在清楚记录这一边界后单独授权。

## 免责声明

本项目仅供研究与开发使用，不对兼容性、可靠性或特定用途适用性提供任何保证。
Apple 可能随时更改或移除 Vellune 所依赖的私有行为。
