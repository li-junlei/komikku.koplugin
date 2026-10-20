# 0.3.0

Komga 阅读、Komikku WebDAV 书架同步及 GitHub Release 更新测试版。

- 新增插件设置内的 GitHub 更新入口，下载显示进度条、字节数和百分比，支持取消。
- 下载后校验 SHA256、文件路径、Lua 语法及依赖，再替换插件；保留旧版备份，替换失败尝试回退。
- 保留封面/列表书架、每页六本、Komga 书库筛选、加入手机书架、来源 ID 手动指定。
- 漫画阅读不进入 KOReader 历史，每页全屏刷新，返回文件管理器时适配 Bookshelf 首页。

首次安装：将下方 **komikku-koplugin-0.3.0.zip** 解压至 `koreader/plugins/`，重启 KOReader。旧版覆盖更新，保留原设置和进度。以后通过 **设置 → 检查插件更新（GitHub）** 升级。

36 项本地测试及安装包检查通过；尚未在 Kindle Voyage 上验证新更新流程。安装过程中请勿断电。
