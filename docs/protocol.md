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

认证为 HTTP Basic over TLS。手机实现会尝试 MKCOL；插件要求已有同步文件，不创建空远端书架，不把 404 当作上传空备份的许可。

插件每次执行 GET → 解析 → 备份 → 补写进度 → PUT。只有确实有待回传改动才 PUT。使用 GET 的原始强 ETag 作为 `If-Match`，不使用手机实现中去掉引号的行为。不自动重试 412；上传结果不确定时保留队列，以便下次完整重读。

## 字段

| 消息 | 字段编号 | 读取/写入 |
|---|---|---|
| Backup | 1 mangas、2 categories | 读取；仅替换有进度改动的漫画消息 |
| Manga | 1 source、2 url、3 title、16 chapters、17 categories、100 favorite | 读取；仅替换有改动的章节消息 |
| Chapter | 1 url、2 name、9 chapterNumber、10 sourceOrder | 读取与识别 |
| Chapter | 4 read、6 lastPageRead、11 lastModifiedAt、12 version | 常规进度同步主动修改的字段 |
| Category | 1 name、2 order、900 hidden | 读取，原始字节保留 |

其余字段全部按原始 wire 字节保留。`source` 可能超过 Lua double 的精确整数范围，不能先转为 number 再编码。本实现直接保留 varint，并把来源标识的字节转为十六进制供本地键使用。

支持 wire 0、1、2、5；支持 packed/unpacked 分类整数。截断数据、无效 varint、不支持的 wire 类型和缺少必要身份字段会拒绝同步写入。

## 合并

Komikku 源码的实际逻辑以 `version` 为准，部分注释写的是时间戳，但实现没有按时间戳比较。手机的数据库触发器在已读、书签、页码发生变化时递增章节和漫画版本。

插件只管理进度：实际页码变化或读完状态变化时递增章节版本，`lastModifiedAt` 使用秒；Komikku 的 `lastPageRead` 为从 0 开始的索引，KOReader 为从 1 开始的页码。

章节身份沿用 URL、名称、章节号组合；本地漫画身份使用来源原始 ID 和 URL。插件不改漫画元数据，所以不提升漫画版本，也不把旧标题、分类或书签覆盖到手机的新数据上。手机 SyncManager 会同时比较章节版本以决定恢复内容，因此漫画版本无需为了进度而提升。

匹配章节的本地版本大于或等于远端时回传进度；远端版本更高时保留远端并结清该待同步项。这与手机的章节版本优先及相同版本本地优先一致。区别在于只补写四个进度字段，不替换整个章节对象，从而保留远端书签及未知元数据。

手机的其他合并行为（重建分类列表、合并来源和设置）不在插件端重复执行：它们由手机管理，插件完整保留当次 GET 的远端消息。远端未匹配的漫画/章节不由旧本地书架复活。

## 0.2.0 书库与新增收藏

筛选对应 [KomgaFilters.kt](https://github.com/keiyoushi/extensions-source/blob/main/src/all/komga/src/eu/kanade/tachiyomi/extension/all/komga/KomgaFilters.kt) 以及 [Komga.kt](https://github.com/keiyoushi/extensions-source/blob/main/src/all/komga/src/eu/kanade/tachiyomi/extension/all/komga/Komga.kt) 的 `searchMangaUrl` / `fetchFilterData`，使用相同 API 路径、重复的 read_status/author 参数和逗号多选语义，封面模式 size 为 6，列表模式 size 为 50。参考的是扩展当前源码，不代表读取到了用户安装 APK 的版本或手机当前筛选状态。

新增漫画的 source varint 直接沿用用户选择的手机来源；身份 URL 使用该来源已同步的原始 base，而 HTTP 请求仍发送到插件配置的地址。浮点章节号编码为 IEEE754 float32。章节命名、阅读列表前缀、章节倒序及过滤不可兼容 EPUB 的规则对应扩展；自定义名称模板和译者分隔符由设置入口配置。

新增收藏是用户明确触发的一次 GET→检查来源/分类/重复项→备份→条件 PUT。新条目增加完整的漫画及章节消息；已有非收藏条目保留原始字段与章节，仅更改 favorite、dateAdded、lastModifiedAt、favoriteModifiedAt、version 和所选分类。已有收藏不覆盖、不另建，也不移动分类。普通同步仍只补写进度，删除的收藏不会自动复活。

未收藏漫画的结构保存在本地 catalog.proto，阅读进度保存在 local_progress，不发送到远端；明确加入时一并按版本合并这些进度。强 ETag 缺失、412、分类失效或上传结果未确认都不会返回“加入成功”；重试先重新读取，因此已完成但未确认的加入不会重复插入。

## 原生阅读和历史

每章一个本地 `chapter.kmk` 清单。文档提供器继承 KOReader PdfDocument 的阅读接口，以 MuPDF 单张图片页面组成一章；页面关闭时同时释放对应图片文档，避免把整章解码图像留在 Voyage 的内存中。原生渲染缓存仍由 KOReader 管理。

历史规则只对 `koreader/komikku/chapters/` 生效：不执行 `ReadHistory:addItem`；关闭该文档时也不执行 `updateLastBookTime`，避免更新上一本文字书的时间，或空历史时访问第一项报错。普通路径仍调用原方法。

## 已知验证范围

0.1.3 的返回兼容参考 [Bookshelf main.lua](https://github.com/AndyHazz/bookshelf.koplugin/blob/master/main.lua) 的来源区分逻辑：非 Bookshelf 打开的文档默认不由其关闭事件接管。插件仅包装当前漫画实例的 `showFileManager`，在 `start_with == "bookshelf"` 且返回本章时，先以无漫画路径的原入口恢复文件管理器，再调用已加载的 `fm.bookshelf:show()`；提供 `_raiseInPlace` 的版本会先抬起保留的首页。无需修改 Bookshelf 源码或伪造打开来源。参考的是读取时的 master，并未确认用户安装的 Bookshelf 版本。

自检使用 LuaJIT 2.1 执行真实插件 Lua 代码，辅以模拟 KOReader、TLS socket 和文件系统接口；另用 Python Protobuf 独立解码验证序列化。没有真实账号、WebDAV 提供商、Kindle 原生库或硬件验收结果。KOReader / Komikku 升级后需要重新核对这些接入点。
