# 本地现代界面版本的安装格式

2026-10-16 排查本地优化包升级失败，错误码 `0x80073CF3`，部署 ActivityId
`3657a5a7-5d70-0001-fd54-6936705ddd01`。

本机 Microsoft Store 安装的 NanaZip Preview 是 Bundle：
`40174MouriNaruto.NanaZipPreview_7.0.1845.0_neutral_~_gnj4mf6z9tkrc`。
此前生成的更新文件是独立 `.msix`。部署事件 401 的原始 XML 中，
`DetailedMessageInfo` 指向 `Replacing bundle`，失败发生在依赖/冲突解析阶段。
原包的 Authenticode 签名状态为 `Valid`。

[Microsoft 的更新约束](https://learn.microsoft.com/en-us/windows/msix/app-package-updates)
明确规定：安装过 MSIXBundle 后，后续更新必须保持 Bundle 格式，不能改成独立 MSIX。
因此应将 x64 应用包放入同身份、同发布者、同目标版本的 `.msixbundle`，签名后分发。
无需为了这个格式冲突卸载现有应用，也无需切换为经典界面。

本次修正只重新封装和签名既有应用包，逐项验证所有非签名成员与此前验证包相同，
并检查 Bundle 和内部 MSIX 的签名、清单、块哈希、优化核心哈希。
本地测试证书只分发公钥，私钥在签名后删除。构建与静态验证不等同于实际部署成功，
实际安装与现代界面启动需要单独确认。

## 资源占用导致的延迟更新

后续部署 ActivityId `3657a5a7-5d70-0007-3269-9136705ddd01` 中，Bundle 的
依赖解析和暂存成功，随后在 `ResolvedDeferredRegistrations` 阶段返回 `0x80073D02`。
事件 638 记录运行中的应用为 `NanaZip.Modern`，`forceUpdateDeferredByPackage=true`。
已安装清单包含 uap16/uap17 的 `UpdateWhileInUse=defer`。

安装程序改用 `Add-AppxPackage -DeferRegistrationWhenPackagesAreInUse`，允许 Windows
接受更新并在旧应用资源释放后完成注册，避免为了更新终止正在进行的压缩任务。
如果 Windows 接受部署但注册版本仍旧，脚本明确显示 pending，不宣称安装成功。
应用退出后重新启动会应用更新；后台占用持续时，可由用户自行注销或重启后确认版本。
参见 [Add-AppxPackage 的延迟注册示例](https://learn.microsoft.com/en-us/powershell/module/appx/add-appxpackage#example-2-update-an-app-but-defer-registration-until-the-app-has-closed)。

后续只读核查确认本机 7.0.1870.0 已注册且 Status=Ok，已安装 Core 的 SHA-256 为
`66D0B710B5C074DAE1A4E0E518A354E4832090CD95F3C465DBE3F51939DCA03E`，
与此前构建记录一致，说明该次延迟更新已生效。现代 GUI 启动仍需单独实测。
长期维护入口现为 `Custom/Build.ps1`，不再依赖忽略目录内的临时构建脚本。

## 主窗口已关闭但反复 pending

7.0.1870.4 更新时连续事件 638 仍列出 NanaZip.Modern。Restart Manager 指认占用者为 COM Surrogate；
核对该进程的命令行为 NanaZip Shell COM 类 `469D94E9-6AF4-4395-B396-99B1308F8CE5`，
模块包含旧 7.0.1870.0 的 ShellExtension、Modern、K7Base 和 K7User DLL，Explorer 本身未加载这些模块。
因此关闭主窗口和重复提交延迟更新都不能立即释放后台菜单宿主。

在确认没有 NanaZip 任务后，仅结束这个已核实的宿主并重新提交原 Bundle，
7.0.1870.4 的应用和 Bundle 注册成功、Status=Ok，四个运行时 DLL 哈希与构建记录匹配。
安装模板已加入相同的严格身份核对和空闲检查，无需重启 Explorer 或系统。
核对失败/有任务运行时仍保留延迟更新；不结束其他 COM 服务，也不卸载应用。
