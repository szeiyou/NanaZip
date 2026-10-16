# NanaZip 自用构建

`codex/custom` 管理本地 ZIP 性能修改和构建；`main` 只保留上游代码。

- [更新日志](CHANGELOG.md)：本地功能、修复和限制，也随新安装 ZIP 分发。
- [上游合并方法](UPSTREAM.md)：更新 main，再合并进自用分支。
- [性能记录](../Documents/ZipPerformance.md)与[安装故障记录](../Documents/WindowsInstallation.md)。

## 日常构建

在仓库根目录的 Windows PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Custom\Build.ps1
```

依次编译 Core、匹配 Codec 和测试用命令行，运行 ZIP 集成、API 回调、
版本选择与安装状态测试，再生成已签名 Bundle。打包前还会验证保留的官方命令行
搭配新核心的兼容性。任何失败均停止，latest 仅在产物验证完成后更新。

```text
Output/Custom/latest.json                         最近一次完整产物的路径与来源
Output/Custom/<版本>/NanaZipPreview-Custom-...zip   安装 ZIP
Output/Custom/<版本>/Distribution/                安装文件
Output/Custom/<版本>/Payload/                     本次打包暂存文件
Output/Custom/Logs/                               MSBuild 日志
Output/Custom/Tests/                              回调测试及生成样本
```

默认版本高于 `7.0.1870.0`、当前安装版、界面来源和已有本地构建，每次递增最后一段。
也可指定更高的四段版本；`-Rebuild` 重新编译，保留其他安装包。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Custom\Build.ps1 -Version 7.0.1900.0
```

`-SkipTests` 只供排查问题，构建记录会标为未跑回归，不建议日常安装。

## 环境及现代界面来源

- Windows 11 x64、Windows PowerShell 5.1、.NET Framework 4.8。
- Visual Studio 2026 Build Tools，包含 v145 x64 C++、汇编工具及 ATL；
  Windows SDK 10.0.26100.0 或更新版本，包含 MakeAppx、SignTool。
- Git、Python 3.9+ 在 PATH；首次依赖还原需访问 NuGet 源。
- 已安装 x64 NanaZip Preview，或提供完整解包的现代 Preview 目录。

脚本通过 vswhere、SDK 注册表和 PATH 找工具，不使用本机固定安装路径。
构建通常不需管理员；安装时导入测试公钥证书需要管理员。

**当前流程编译优化核心，复用已有 GUI，并非完整 GUI 源码构建。**
当前 Build Tools 缺少可用的 DesktopBridge/UWP XAML 构建支持，完整现代 GUI 构建此前未通过。
因此保留来源包的 GUI、中文资源、Shell 扩展、K7Base、原版命令行，只替换新编译的
Core、Codecs、ZS.Codecs 三个 DLL。“关于”可能仍显示来源版本，包版本以 build-info.json 为准。

可以固定一个界面来源目录，保留该目录及版本以便复现：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Custom\Build.ps1 -InterfaceDirectory 'D:\Packages\NanaZipPreview-x64-unpacked'
```

跨上游大版本后先准备匹配的新版 GUI 包，检查接口兼容，再安装。命令行兼容测试不能替代 GUI 实测。
上游完整构建仍使用原解决方案及工具，需要完整 GUI 工具链。
原 `BuildAllTargets*.cmd` 和 `BuildTestingBinaries.cmd` 会删除整个 Output，
使用前另存安装产物；Custom 脚本不执行这类清理。

## 安装和确认

打开 latest.json 指向的 Distribution，右键 `Install.cmd` 以管理员身份运行，
也可完整解压对应 ZIP 后安装。

- **Installed**：应用和 Bundle 均注册为目标版本。
- **pending**：Windows 接受更新，但等待旧资源释放。完成任务后关闭并重新打开；
  持续占用时，在方便时注销或重启，再确认版本。
- 失败：保留安装目录内的 `.log`、`.events.xml` 按具体原因排查。

构建不会自动安装、导入证书、结束任务、注销或关机。
此前 7.0.1870.0 的注册及核心哈希已确认；本流程的新包不会自动安装，
现代 GUI 启动仍需实测，每份 build-info.json 初始标记未做安装测试。

## 单独测试、打包、校验

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Custom\Test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Custom\Package.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Custom\Verify.ps1 -DistributionDirectory '.\Output\Custom\7.0.1870.1\Distribution'
```

单独 Package 核对编译记录、源码指纹和三个 DLL 的哈希；缺少记录、源码改动或 DLL 被替换时会拒绝。
未通过完整回归也不能被标记为通过。修改源码后请先用 Build，避免拿旧 DLL 打包。
校验包括身份、架构、版本、块哈希、运行时及保留界面哈希、Windows SIP 内容验证、
内外两层签名与证书指纹，并拒绝块映射和清单未包含的额外成员。
签名数学正确不等于系统已信任证书，信任由安装程序单独处理。

`.custom-local/Signing/<包身份>/` 保存 PFX、公钥及 DPAPI 保护的密码，后续构建复用，
不写入系统证书库或提交 Git。密码绑定当前 Windows 用户和机器，不能只复制 DPAPI 文件跨机器迁移。
证书接近到期或文件不完整时会停止。请自行安全备份，不要把密钥目录放入分发包。

每次构建记录提交、分支、未提交状态、GUI 来源、文件哈希和回归状态；
干净且已提交的工作区便于追溯，但不保证字节级可重复构建。
`Output/`、`.benchmarks/`、`.custom-local/` 均不受 Git 管理，现有实验数据和旧安装包保留。
