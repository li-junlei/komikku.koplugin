# 0.3.1

插件内 GitHub Release 更新，带下载字节数、百分比和进度条，可取消。

- 版本信息改为直接读取 Release 附带的 `update.json`，避免 GitHub API 匿名限额导致检查更新失败。
- 校验 SHA256、解压路径、Lua 语法和依赖，准备完成后才替换插件；保留旧版备份，配置与进度不变。
- 保留 Komga 封面/列表书库、筛选、手动指定手机来源、Komikku 书架同步及漫画阅读功能。

首次安装或旧版升级：将 **komikku-koplugin-0.3.1.zip** 解压至 `koreader/plugins/`，重启。以后通过 **Komikku 设置 → 检查插件更新（GitHub）** 更新。

36 项本地测试通过；Kindle Voyage 上的新更新流程尚未实机验证。安装时不要断电。
