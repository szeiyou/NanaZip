# 主分支与自用分支

- `origin`：官方仓库 `https://github.com/M2Team/NanaZip.git`。
- `main`：只保留上游提交，跟踪 `origin/main`，仅快进更新。
- `codex/custom`：自用修改及维护脚本，日常构建、开发和提交都在这里。

整理起点为上游 `2b279b3c`；本次不同时合入新的官方更新。
自定义提交不要向官方 origin 推送；如需异机备份，可另加自己的远程仓库。

## 合并官方更新

先确认自用修改已提交且工作区干净，再执行：

```powershell
git switch codex/custom
git status
git switch main
git pull --ff-only origin main
git switch codex/custom
git merge --no-edit main
```

使用 merge 保留本地修改历史。main 无法快进时先查明原因，不强制覆盖。
出现冲突时解决后 `git add <已解决文件>`、`git commit`；
决定暂不升级可用 `git merge --abort`。不使用 reset/clean 丢弃未提交工作。

## 合并后的验证

重点检查：

- `NanaZip.Core/SevenZip/CPP/7zip/Archive/Zip/ZipHandler.cpp`、`ZipExtractMt.h`：
  输入流位置、取消、回调顺序和并行条件。
- 同目录 `ZipUpdate.cpp`：压缩缓冲和内存上限。
- Core 的 vcxproj / filters：新增头文件是否保留。
- `Tests/`：IArchive/IStream 等接口是否变化。
- `Custom/`：官方身份、清单、依赖、运行时和工具链是否变化。

准备匹配新版的现代 GUI 包，执行 `Custom/Build.ps1`，检查来源记录、安装状态、
中文界面、右键菜单和代表性文件压缩/解压后的内容哈希。保留上次验证过的安装包。
在 CHANGELOG 中记录上游提交/版本、冲突处理及实际验证情况，随修改一起提交到自用分支。
不要把自定义修改合回 main。

只查看上游变化可使用：

```powershell
git fetch origin
git log --oneline main..origin/main
git diff --stat main origin/main
git log --oneline main..codex/custom
```

fetch 只更新远程跟踪引用，不会自动改变自用分支。
