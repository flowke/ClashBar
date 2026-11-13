# ClashBar 项目协作规范

本文件记录 ClashBar 项目开发、验证、安装和发布时需要遵守的约定。执行相关任务前应先阅读适用章节。

## 测试约定

- 发布本地版或正式版时，默认不运行测试套件；测试不是发布前置门槛。
- 只有用户明确要求，或当前发布问题需要通过测试定位时，才运行相关测试，并在交付结果中说明测试范围和结果。
- 即使不运行测试，仍必须执行构建产物、架构、版本字段、代码签名、DMG 校验和本地启动验证。

## 发布流程与要求

- 每次正式发布都必须使用新的语义化版本号；已有版本号不能原地覆盖或重复发布。
- 发布前确认工作区干净，或明确区分本次发布包含的改动；不要丢弃用户已有的未提交改动。
- 提交当前版本并推送到当前工作分支后，再创建对应的 `vX.Y.Z` 标签和 GitHub Release。
- 不要 force-push，不要擅自创建分支、PR、GitHub Release 草稿或额外的发布标签。
- Release 说明必须准确反映本次版本内容，不得把未实现的功能写进说明。

## Helper 约束

- 发布前检查 `Sources/ProxyHelperShared/ProxyHelperProtocol.swift` 中的 `helperVersion`，并与 `/Library/PrivilegedHelperTools/com.clashbar.helper.version` 对照。
- 只有 Proxy Helper 协议、daemon 行为或 Helper 版本确实发生变化时，才升级或重装系统 Helper。
- 如果 Helper 没有变化，应用发布不得触发 Helper 升级；保留现有系统 Helper 版本，并在交付结果中明确说明。
- 不要为了验证应用而删除、替换或绕过现存的系统 Helper，也不要擅自请求管理员密码。

## 构建与架构

- 使用 `Scripts/preprocess.sh`、`Scripts/package_app.sh` 和 `Scripts/make_dmg.sh` 生成发布包；不要手工拼装 App bundle。
- 内置 Mihomo 的发布包必须使用 Apple Silicon 对应的 `arm64` 核心，不得捆绑 `x86_64` 核心。
- 正式发布仅生成 Apple Silicon（`arm64`）架构，提供内置 Mihomo 和无内核两个变体；不生成 Intel（`x86_64`）发布包。
- 内置核心的版本必须在 Release 说明中写明；无内核包必须确认没有捆绑 Mihomo。
- 发布前验证 App 与 Helper 的 Mach-O 架构、`CFBundleShortVersionString`、`CFBundleVersion` 和代码签名。
- 每个 DMG 都要通过 `hdiutil verify` 和对应的 `.sha256` 校验。

## 本地安装

- 替换正式安装前，先优雅退出正在运行的 ClashBar，确保内核和代理状态完成清理。
- 正式安装位置固定为 `/Applications/ClashBar.app`。安装后验证版本、签名和实际启动进程路径。
- 安装完成后保持新版本运行；不要把 `dist/ClashBar.app` 当作最终安装位置。
- 不要遗留本地安装包、DMG、PKG、ZIP 或临时核心文件。发布完成后清理 `dist` 和临时构建产物；保留仓库中的设计稿、PNG、ICNS、iconset 等设计资产。
- 清理旧安装包时只删除明确属于 ClashBar 的产物，不要删除用户配置、设计文件、Xcode 缓存或其他软件文件。

## GitHub Release

- Release 必须绑定本次提交和对应的 `vX.Y.Z` 标签，且发布后核验为非 draft、非 prerelease（除非用户明确要求测试版）。
- 上传两个 Apple Silicon 安装资产及两个校验文件：
  - `ClashBar-X.Y.Z-apple-silicon.dmg` 和 `.sha256`
  - `ClashBar-X.Y.Z-apple-silicon-no-core.dmg` 和 `.sha256`
- 上传后检查 Release 页面上的资产名称、大小、下载链接和校验文件内容。
- 如果 GitHub Actions workflow 不可用，可以使用已认证的 `gh release create` 完成发布，但仍必须执行相同的构建、校验和清理步骤。

## 最终验收

发布交付前必须报告：版本号、提交和标签、GitHub Release URL、安装路径、测试/构建结果、两种 Apple Silicon DMG 资产、Helper 是否升级，以及本地安装包清理结果。
