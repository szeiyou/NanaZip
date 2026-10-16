NanaZip Preview 自用 ZIP 优化版（Windows x64，现代界面）

安装：
1. 将整个 ZIP 解压到新目录。
2. 完成正在进行的压缩任务，关闭 NanaZip 窗口。
3. 右键 Install.cmd，选择“以管理员身份运行”。
4. 脚本核对 Bundle 哈希、身份、版本和公钥证书，然后导入本地测试证书并更新应用。

显示 Installed 表示已注册新版。
显示 Update accepted; registration is pending 表示更新已接受，旧版仍在使用。
关闭 NanaZip 后重新打开；若后台组件持续占用，可在方便时注销或重启后再确认版本。
本程序不会自动卸载应用、结束压缩任务、重启资源管理器或关机。
错误会记录在同目录的 Install-日期时间.log；请连同 .events.xml 保留。

升级时如果没有 NanaZip 任务/窗口，安装程序会仅释放已确认属于当前 NanaZip 包的
空闲右键 COM 宿主，避免关闭主窗口后仍一直 pending。它会核对 COM 类、会话、
可执行文件路径和已加载模块，不会结束其他 COM 进程或 Explorer。

本包复用现有 NanaZip Preview 的现代界面和中文资源，
从自用分支源码编译 ZIP 优化核心、匹配的 Codec 插件和现代右键扩展。
选中单个 ZIP、7z 或 RAR，在 NanaZip 右键面板中可查看带图标与缩进的内容树。
最多显示 3 层、12 项，较多内容用省略项提示；只读取目录，不解压，不弹密码对话框。
这不是完整 GUI 源码构建，主界面“关于”可能沿用界面来源版本。
实际包版本、源码提交、界面来源、测试状态及文件哈希见 build-info.json。
自定义更新记录见 CHANGELOG.md，官方更新记录参见官方项目。

本包为本地测试签名，非 Microsoft Store 官方签名。分发包只含公钥证书。
安装使用 .msixbundle，避免独立 MSIX 无法升级已安装 Bundle 的 0x80073CF3。
0x80073D02 表示资源占用，通常无需为此卸载。

恢复官方版：卸载自用测试包后，从 Microsoft Store 安装 NanaZip Preview。
不再使用本地证书时，可在 certlm.msc 的“受信任人/证书”中按 build-info.json
的指纹确认并移除对应证书。不要删除其他证书。
