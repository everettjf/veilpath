<p align="center">
  <img src="Veilpath/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Veilpath 应用图标">
</p>

<h1 align="center">Veilpath</h1>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

<p align="center">
  一款适用于 iPhone 和 iPad 的原生容器浏览器与受保护文件工作区，<br>
  基于 <a href="https://github.com/forcequitOS/bad_query"><code>bad_query</code></a> 沙盒逃逸技术构建。
</p>

<p align="center">
  <a href="https://xnu.app/veilpath/">网站</a> ·
  <a href="#兼容性">兼容性</a> ·
  <a href="#构建">构建</a> ·
  <a href="#致谢">致谢</a>
</p>

> [!IMPORTANT]
> **支持版本：iOS / iPadOS 26 至 27 beta 3。** 完整的 `bad_query` 访问路径
> 已在运行 **iPadOS 27 beta 3（`24A5380l`）** 的 iPad Air 真机上验证。
> 实际功能必须使用真机，模拟器只能验证编译和界面。上游概念验证项目标注支持
> 至 iOS 26.6.1 和 iOS 27 beta 4，但这些额外版本尚未全部经过 Veilpath 验证。

<table>
  <tr>
    <td width="68%"><img src="docs/assets/ipad-ui.png" alt="Veilpath 在 iPad 上显示分组应用容器和文件列表"></td>
    <td width="32%"><img src="docs/assets/iphone-ui.png" alt="Veilpath 在 iPhone 上显示紧凑文件浏览界面"></td>
  </tr>
</table>

## Veilpath 是什么？

Veilpath 将 `bad_query` 概念验证项目转化为一个专注于文件探索的界面，
适用于该技术能够生效的 iOS 和 iPadOS 版本。它可以发现通常无法访问的容器、
解析容器标识符，并可查看、导出文件，或在具备校验、备份与恢复路径的前提下，
有意识地替换单个文件。

**Veilpath** 结合了 **veil**（面纱）与 **path**（路径）：它是一条通往 App
沙盒边界之后、通常不可见数据的路径。这个名字也呼应项目的核心原则——探索应当
有意识地进行，而每一次写入都必须受到保护并且可以恢复。

## 主要特性

- 原生 SwiftUI 界面，自适应 iPad 和 iPhone。
- 以 App 资源库作为首页，可在直观网格与紧凑列表之间切换，并记住用户选择。
- 索引应用、App Group、PluginKit、内部守护进程、系统数据和系统组容器。
- 通过容器元数据将容器 UUID 解析为易读的 Bundle ID。
- 当容器根目录无法直接打开时，使用 `fsgetpath` 进行 inode 回退发现。
- 每次操作单独获取沙盒扩展，并在操作完成后立即释放。
- 提供目录历史、后退/前进/上一级导航、当前目录筛选、容器递归搜索，以及按名称、
  日期和大小排序。
- 支持可搜索的 plist 与 JSON 树、XML、文本、图片、十六进制，以及 Mach-O 架构、
  依赖库、签名和 Entitlements 信息。
- iPad 进入 App 专属文件工作区：左侧保留当前文件列表，右侧先展示文件属性；
  打开预览后可在 60%–90% 之间拖动调整，也可全屏打开。
- iPhone 使用聚焦的推进式动线：App 资源库、文件列表、全屏预览，文件信息独立呈现。
- 导出前可查看文件元数据和 SHA-256。
- 文件可按需准备分享；大文件使用 1 MiB 分块流式复制，并提供进度、取消、结果校验
  和分享缓存自动过期清理。
- 可将当前文件夹或选定文件夹导出为 ZIP，保留空目录、遵循隐藏文件设置，并跳过
  符号链接。
- 提供多选、复制、剪切、粘贴、Duplicate、批量 ZIP 压缩、ZIP/IPA 解压和受保护
  删除；删除前会先生成名称唯一的可恢复安全归档。批量操作会逐项报告失败，并保留
  失败的选择或剪切来源，方便重试。
- stored 与 Deflate ZIP 均采用有界分块流式解压；解压会校验路径、大小与 CRC-32，
  预检可用空间，拦截加密项、符号链接、超大展开内容及异常压缩比，并在取消后清理
  未完成输出。
- 可将一个 Application 容器完整导出为包含 `Documents`、`Library`、`tmp` 和
  `manifest.json` 的 App 备份；manifest 为每个文件记录 SHA-256。
- 完整恢复前会校验 Bundle ID、精确根目录结构、声明的归档内容、文件大小和全部
  SHA-256；新备份写完后还会重新解包验证。恢复会拦截 Veilpath 自身活动容器、预检
  staging 空间，并先为当前容器创建安全备份；目录交换失败时自动回滚。
- 可将当前目录导出为 Markdown，并可选择是否递归列出子目录。
- 浏览默认只读，同时支持受保护的 JSON/plist 编辑、版本化备份与替换、SHA-256
  校验，以及恢复前再次创建安全备份。
- 内置真机诊断套件，可生成结构化 JSON 报告。

## 兼容性

Veilpath 只对已经完成适配和测试的系统范围作出支持声明。**不能因为项目可以编译，
就认为更新的 beta 或正式版同样兼容。** 安装后应运行 App 内置的真机自检；
Container Manager 的私有行为可能在不同系统构建版本之间发生变化。

| 平台 | 目标版本 | 验证情况 |
| --- | --- | --- |
| iPadOS | 27 beta 3（`24A5380l`） | 已在 iPad Air（`iPad15,3`）真机完整测试 |
| iOS / iPadOS | 26.x | 部署目标及 App Group 兼容路径 |
| iPhone | 27 beta 3（`24A5390f`） | 已在 iPhone 17 Pro（`iPhone18,1`）真机完整测试 |
| 模拟器 | 26–27 | 仅验证界面；`bad_query` 需要真机 |

上游项目目前说明支持至 iOS 26.6.1 和 iOS 27 beta 4。Veilpath 在此有意只记录
已经实现并验证的较窄范围：**iOS/iPadOS 26 至 27 beta 3**。超出这个范围的版本，
在完成真机测试之前均视为不受支持。

### 真机诊断

Veilpath 内置真机回归套件，用于验证沙盒访问、容器发现、结构化预览、文件分析、
Mach-O 解析、流式分享、ZIP 策略、stored/Deflate 解压、多项文件操作、取消清理、
Markdown 导出、安全编辑、完整 App 备份、可回滚恢复及本地搜索。结果会写入 Veilpath 自身数据容器内的
`Documents/veilpath-self-test.json`。容器数量完全取决于每台设备安装的应用和
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
   git clone https://github.com/everettjf/veilpath.git
   cd veilpath
   ```

2. 打开 `Veilpath.xcodeproj`。
3. 选择 `Veilpath` scheme 和一个 iPhone 或 iPad 目标设备。
4. 在 **Signing & Capabilities** 中选择你的开发团队。
5. 构建并运行。

Veilpath 在 iOS 26 的 App Group 访问路径中使用
`group.com.eevv.Veilpath`。如果你使用不同的 Bundle ID 或开发团队构建，
请在 `Veilpath/Veilpath.entitlements` 和
`Veilpath/Core/BadQueryClient.swift` 中将其替换为你的账户所拥有的
App Group。

## 项目结构

```text
Veilpath.xcodeproj/          Xcode 工程
Veilpath/
  BadQuery/                 C 桥接与沙盒扩展原语
  Containers/               容器索引与元数据解析
  Core/                     文件访问、预览与导出
  Diagnostics/              真机回归测试套件
  Model/                    Observable 应用状态
  ContentView.swift         自适应 iPad/iPhone 界面
docs/                       GitHub Pages 网站
```

## 安全与范围

Veilpath 是实验性安全研究软件。它依赖私有 API 以及可能随系统版本变化的行为。
请仅在你拥有的设备和数据上使用，或在获得明确授权的环境中进行测试。

浏览、预览、搜索和导出仍然是只读操作，所有写入都必须由用户明确触发。结构化
编辑使用临时草稿、格式校验、Version Vault 历史和 SHA-256 写入校验；删除文件前
会先创建可恢复 ZIP。操作安全归档最多保留 30 天，每个类别最多保留 10 份。完整 App 恢复会验证 manifest 和每个文件的哈希，保存当前
`Documents`、`Library` 与 `tmp`，在 staging 目录准备替换内容，再执行可回滚的目录
交换。App 内备份可以降低风险，但不能替代完整的设备备份。诊断功能会明确报告失败，
而不会假定某条路径可以访问。

## 致谢

Veilpath 的诞生离不开原始的
[`forcequitOS/bad_query`](https://github.com/forcequitOS/bad_query)
沙盒逃逸概念验证项目。感谢 **forcequitOS** 及该项目的贡献者研究这一问题，
并为社区公开了清晰的实现。

Veilpath 的底层容器查询方式源自该项目。复用或扩展相关实现时，请注明并支持
上游项目。

## 许可状态

上游 `bad_query` 仓库目前没有声明开源许可证。因此，
`Veilpath/BadQuery/` 下的衍生文件**不会**自动获得宽松许可证的授权，
本仓库也不会作出相反声明。

在为整个仓库指定统一的开源许可证之前，应先取得上游作者的许可或明确其许可
方式。其余由 Veilpath 原创的代码，可以在清楚记录这一边界后单独授权。

## 免责声明

本项目仅供研究与开发使用，不对兼容性、可靠性或特定用途适用性提供任何保证。
Apple 可能随时更改或移除 Veilpath 所依赖的私有行为。
