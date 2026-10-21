# 协议证据与兼容边界

## 对应源码

源码按标签核对，参考资料仅保存在开发目录 `.reference/`，不进入安装包。

- [Komikku v1.14.1 WebDavSyncService.kt](https://github.com/komikku-app/komikku/blob/v1.14.1/app/src/main/java/eu/kanade/tachiyomi/data/sync/service/WebDavSyncService.kt)
- [Komikku v1.14.1 SyncService.kt](https://github.com/komikku-app/komikku/blob/v1.14.1/app/src/main/java/eu/kanade/tachiyomi/data/sync/service/SyncService.kt)
- [Backup.kt](https://github.com/komikku-app/komikku/blob/v1.14.1/app/src/main/java/eu/kanade/tachiyomi/data/backup/models/Backup.kt)、[BackupManga.kt](https://github.com/komikku-app/komikku/blob/v1.14.1/app/src/main/java/eu/kanade/tachiyomi/data/backup/models/BackupManga.kt)、[BackupChapter.kt](https://github.com/komikku-app/komikku/blob/v1.14.1/app/src/main/java/eu/kanade/tachiyomi/data/backup/models/BackupChapter.kt)、[BackupCategory.kt](https://github.com/komikku-app/komikku/blob/v1.14.1/app/src/main/java/eu/kanade/tachiyomi/data/backup/models/BackupCategory.kt)
- [章节版本触发器](https://github.com/komikku-app/komikku/blob/v1.14.1/data/src/main/sqldelight/tachiyomi/data/chapters.sq)
- [KOReader v2026.07.2 ReaderUI](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/apps/reader/readerui.lua)、[ReadHistory](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/readhistory.lua)、[PdfDocument](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/document/pdfdocument.lua)
- [Komga 扩展 URL / 页面映射参考](https://github.com/keiyoushi/extensions-source/blob/main/src/all/komga/src/eu/kanade/tachiyomi/extension/all/komga/Komga.kt)（读取时的 main 分支，用于核对 API 地址约定，不是 Komikku 版本的一部分）
- [Rakuyomi 历史排除补丁参考](https://github.com/cramoisi/koreader.patches/blob/main/2-ignore-rakuyomi-history.lua)：按目录拦截 `addItem` 的思路。本实现额外保护 `updateLastBookTime`，不安装全局用户补丁。
- [Komga SeriesController 封面端点](https://github.com/gotson/komga/blob/master/komga/src/main/kotlin/org/gotson/komga/interfaces/api/rest/SeriesController.kt)：封面书架使用配置的服务地址请求 `/api/v1/series/{id}/thumbnail`；单本条目使用 `/api/v1/books/{id}/thumbnail`。不向备份中原始封面地址发送认证信息。

## WebDAV

文件地址为 `base/folder/backup.proto`，folder 可为空。内容是 `ProtoBuf.encodeToByteArray(Backup.serializer(), backup)` 的原始字节，**没有 gzip，也没有 SyncData 外层**。

认证为 HTTP Basic over TLS。WebDAV 为可选功能，未配置时不发起同步请求。同步目录需已存在；GET 返回 404 时只允许以 `If-None-Match: *` 条件创建实际设备书架，禁止覆盖并发创建的文件。正常同步始终先读取并合并远端。

插件每次执行 GET → 解析 → 合并 Komga 收藏和分类 → 备份 → 补写进度 → 条件 PUT。只有确实有待回传改动才 PUT。使用 GET 的原始强 ETag 作为 `If-Match`，不使用手机实现中去掉引号的行为。不自动重试 412；上传结果不确定时保留队列，以便下次完整重读。

## 字段

| 消息 | 字段编号 | 读取/写入 |
|---|---|---|
| Backup | 1 mangas、2 categories | 读取；合并明确改动的 Komga 漫画，按名称补充分类 |
| Manga | 1 source、2 url、3 title、16 chapters、17 categories、100 favorite | 读取；新收藏包含漫画和章节，收藏变更按漫画版本合并 |
| Manga | 13 dateAdded、106 lastModifiedAt、107 favoriteModifiedAt、109 version | 收藏或分类改动更新；未知字段沿用远端 |
| Chapter | 1 url、2 name、9 chapterNumber、10 sourceOrder | 读取与识别 |
| Chapter | 4 read、6 lastPageRead、11 lastModifiedAt、12 version | 常规进度同步主动修改的字段 |
| Category | 1 name、2 order、900 hidden | 读取，原始字节保留 |

其余字段全部按原始 wire 字节保留。`source` 可能超过 Lua double 的精确整数范围，不能先转为 number 再编码。本实现直接保留 varint，并把来源标识的字节转为十六进制供本地键使用。

支持 wire 0、1、2、5；支持 packed/unpacked 分类整数。截断数据、无效 varint、不支持的 wire 类型和缺少必要身份字段会拒绝同步写入。

## 合并

Komikku 源码的实际逻辑以 `version` 为准，部分注释写的是时间戳，但实现没有按时间戳比较。手机的数据库触发器在已读、书签、页码发生变化时递增章节和漫画版本。

插件只管理进度：实际页码变化或读完状态变化时递增章节版本，`lastModifiedAt` 使用秒；Komikku 的 `lastPageRead` 为从 0 开始的索引，KOReader 为从 1 开始的页码。

持久章节身份沿用 URL、名称、章节号组合，漫画身份使用来源原始 ID 和 URL。收藏或分类变更递增漫画版本，按 Komikku 的高版本优先、相同版本本地优先规则合并；进度变化只递增章节版本。已有远端漫画的标题、作者及未知字段仍沿用远端，不以旧设备元数据整对象覆盖。

匹配章节的本地版本大于或等于远端时回传进度；远端版本更高时保留远端并结清该待同步项。这与手机的章节版本优先及相同版本本地优先一致。区别在于只补写四个进度字段，不替换整个章节对象，从而保留远端书签及未知元数据。

分类按名称对应编号，仅补充不存在的分类，不重排或重建远端分类。非 Komga 漫画、来源信息、设置等原始消息保留。远端已移出或删除的收藏不会仅因设备上保留旧快照而复活，只有用户新产生的收藏改动才参与写回。章节可从 Komga 刷新，合并时保留双方已知章节及远端字段。

## 书库、书架与可选同步

筛选对应 Komga 扩展的 `searchMangaUrl` / `fetchFilterData`，使用相同 API 路径、重复的 read_status/author 参数和逗号多选语义。封面模式 size 为 6，列表模式 size 为 50。

只有一个书架，持久化到 `shelf.proto`。加入收藏、移出收藏和调整分类先在设备提交，改动记入 `progress.lua` 的 `shelf_changes`。不配置 WebDAV 时同样工作，不建立第二套书架；同步失败时不将远端快照覆盖到设备书架。

独立使用默认采用参考 Komga 源码的第一个官方实例 ID `4508733312114627536`。与已有手机书架同步时，优先使用选中或自动匹配的真实 Komga 来源及身份 URL；支持手动指定完整有符号 64 位来源 ID，通过 FFI 整数编码和回读校验避免 Lua double 精度损失。

同步阶段按对应 Komga 漫画和章节 URL 映射身份，复用远端的章节名称及键，将设备进度翻译后再执行版本合并。源键变动的重定向持久保存，旧章节清单和继续阅读仍能找到对应漫画；章节地址变动时，缓存目录别名保留旧下载，不移动或重新下载已有页面。

未收藏漫画仍可直接阅读，结构保存在 `catalog.proto`，进度保存在 `local_progress`；加入收藏后，同步会一并合并已有进度。移出书架保留浏览条目、进度及图片。同步仅处理可识别的 Komga 条目，非 Komga 源不加入书架、不翻译其待同步进度，也不改写其远端消息。

同步成功只结清本次提交的进度版本；请求期间产生的更高版本继续保留。已有文件缺少强 ETag、返回 412、上传失败或取消时，设备收藏与待同步改动保留；下次重新 GET 后合并。设备上“加入成功”表示收藏已在设备提交，不等于跨设备同步已成功。

## 原生阅读和历史

每章一个本地 `chapter.kmk` 清单。文档提供器继承 KOReader PdfDocument 的阅读接口，以 MuPDF 单张图片页面组成一章；页面关闭时同时释放对应图片文档，避免把整章解码图像留在 Voyage 的内存中。原生渲染缓存仍由 KOReader 管理。

历史规则只对 `koreader/komikku/chapters/` 生效：不执行 `ReadHistory:addItem`；关闭该文档时也不执行 `updateLastBookTime`，避免更新上一本文字书的时间，或空历史时访问第一项报错。普通路径仍调用原方法。

## 已知验证范围

0.1.3 的返回兼容参考 [Bookshelf main.lua](https://github.com/AndyHazz/bookshelf.koplugin/blob/master/main.lua) 的来源区分逻辑：非 Bookshelf 打开的文档默认不由其关闭事件接管。插件仅包装当前漫画实例的 `showFileManager`，在 `start_with == "bookshelf"` 且返回本章时，先以无漫画路径的原入口恢复文件管理器，再调用已加载的 `fm.bookshelf:show()`；提供 `_raiseInPlace` 的版本会先抬起保留的首页。无需修改 Bookshelf 源码或伪造打开来源。参考的是读取时的 master，并未确认用户安装的 Bookshelf 版本。

自检使用 LuaJIT 2.1 执行真实插件 Lua 代码，辅以模拟 KOReader、TLS socket 和文件系统接口；另用 Python Protobuf 独立解码验证序列化。没有真实账号、WebDAV 提供商、Kindle 原生库或硬件验收结果。KOReader / Komikku 升级后需要重新核对这些接入点。
