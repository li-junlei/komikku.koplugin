"""Run protocol and KOReader boundary checks with LuaJIT (lupa); no real accounts."""
from pathlib import Path
import json
import random
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.reference' / 'python'))
from lupa.luajit21 import LuaRuntime


def varint(n):
    if n < 0:
        n += 1 << 64
    out = bytearray()
    while n > 127:
        out.append((n & 127) | 128)
        n >>= 7
    out.append(n)
    return bytes(out)


def field(n, value, wire=None):
    if wire is None:
        wire = 0 if isinstance(value, int) else 2
    if wire == 0:
        value = varint(value)
    elif isinstance(value, str):
        value = value.encode()
    return varint(n * 8 + wire) + (varint(len(value)) if wire == 2 else b'') + value


def chapter(version=3, page=2, read=0, extra=b''):
    return (field(1, 'https://old.example/api/v1/books/BOOK1') + field(2, '第一话')
            + field(4, read) + field(5, 1) + field(6, page) + field(9, struct.pack('<f', 1.5), 5)
            + field(10, 8) + field(11, 100) + field(12, version) + field(13, b'{"memo":"keep"}') + extra)


def backup(ch=None, extra=b'', favorite=1):
    ch = chapter() if ch is None else ch
    manga = (field(1, -(2**62) + 77) + field(2, 'https://old.example/api/v1/series/SERIES1')
             + field(3, '漫画') + field(16, ch) + field(17, varint(1) + varint(128), 2)
             + field(100, favorite) + field(109, 9) + field(805, 'untouched'))
    return (field(1, manga) + field(2, field(1, '分类') + field(2, 1))
            + field(104, b'opaque-settings') + field(610, b'opaque-feeds') + extra)


class Checks(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.lua.execute(b"package.path = ... .. '/?.lua;' .. package.path", ROOT.as_posix().encode())
        self.P = self.lua.eval(b"require('km_proto')")
        self.S = self.lua.eval(b"require('km_sync')")

    def decode(self, data):
        s = self.S.decode(data)
        return s, s[b'mangas'][1], s[b'mangas'][1][b'chapters'][1]

    def pending(self, m, c, version=4, page=5, read=True):
        key = self.S.progressKey(m, c)
        p = self.lua.table_from({b'version': version, b'page': page, b'read': read, b'modified': 1234})
        return self.lua.table_from({key: p}), key

    def test_all_lua_files_parse_as_luajit(self):
        load = self.lua.eval(b"function(s,n) return assert(loadstring(s,n)) end")
        for path in ROOT.glob('*.lua'):
            load(path.read_bytes(), path.name.encode())

    def test_raw_roundtrip_unknown_fields_and_signed_int64(self):
        data = backup(extra=field(1000, b'\x00\xff\xfe') + field(999, b'abcdefgh', 1))
        self.assertEqual(self.P.encode(self.P.parse(data)), data)
        _, m, c = self.decode(data)
        self.assertEqual(m[b'categories'][1], 1)
        self.assertEqual(m[b'categories'][2], 128)
        self.assertTrue(m[b'key'].decode('utf8'))
        self.assertEqual(c[b'page'], 2)

    def test_empty_merge_is_byte_identical(self):
        data = backup()
        merged, settled, changed = self.S.merge(data, self.lua.table())
        self.assertEqual(merged, data)
        self.assertFalse(changed)

    def test_local_higher_and_tie_win_only_progress_fields(self):
        for version in (3, 4):
            data = backup(chapter(extra=field(400, b'future chapter metadata')))
            _, m, c = self.decode(data)
            pending, key = self.pending(m, c, version=version)
            merged, settled, changed = self.S.merge(data, pending)
            self.assertTrue(changed)
            self.assertTrue(settled[key])
            s, new_m, new_c = self.decode(merged)
            self.assertEqual(new_c[b'page'], 5)
            self.assertEqual(new_c[b'version'], version)
            self.assertTrue(new_c[b'read'])
            self.assertEqual(self.P.int(new_c[b'fields'], 5), 1)
            self.assertEqual(self.P.get(new_c[b'fields'], 400, None, 2), b'future chapter metadata')
            self.assertIn(field(104, b'opaque-settings'), merged)
            self.assertIn(field(610, b'opaque-feeds'), merged)
            self.assertEqual(self.P.int(new_m[b'fields'], 109), 9)

    def test_remote_higher_wins_and_deleted_manga_not_resurrected(self):
        data = backup(chapter(version=10))
        _, m, c = self.decode(data)
        pending, key = self.pending(m, c, version=4)
        merged, settled, changed = self.S.merge(data, pending)
        self.assertEqual(merged, data)
        self.assertFalse(changed)
        self.assertTrue(settled[key])
        pending[b'missing chapter'] = pending[key]
        _, settled, _ = self.S.merge(data, pending)
        self.assertIsNone(settled[b'missing chapter'])
        data2 = backup(favorite=0)
        merged, _, _ = self.S.merge(data2, pending)
        self.assertFalse(self.decode(merged)[1][b'favorite'])

    def test_progress_zero_based_version_counter_and_reread(self):
        _, m, c = self.decode(backup())
        self.assertIsNone(self.S.progress(c, 3, 20, None, 100))
        p = self.S.progress(c, 4, 20, None, 101)
        self.assertEqual(p[b'page'], 3)
        self.assertEqual(p[b'version'], 4)
        self.assertFalse(p[b'read'])
        p = self.S.progress(c, 20, 20, p, 102)
        self.assertTrue(p[b'read'])
        p = self.S.progress(c, 1, 20, p, 103)
        self.assertEqual(p[b'page'], 0)
        self.assertTrue(p[b'read'])

    def test_malformed_fails_closed(self):
        for data in (b'', b'\x0a\x80', b'\x0a\x09x', b'\x00', b'\x0b', b'\x08' + b'\xff' * 11):
            with self.subTest(data=data):
                with self.assertRaises(Exception):
                    self.S.decode(data)

    def test_wire_roundtrip_fuzz(self):
        rng = random.Random(19)
        for _ in range(150):
            data = b''.join(field(rng.randint(1, 10000), rng.randbytes(rng.randint(0, 100))) for _ in range(15))
            self.assertEqual(self.P.encode(self.P.parse(data)), data)

    def test_conditional_upload_and_no_put_on_invalid_data(self):
        data = backup()
        _, m, c = self.decode(data)
        pending, _ = self.pending(m, c)
        calls, saved = [], []
        def transport(method, url, body=None, headers=None):
            calls.append((method, body, headers))
            if method == b'GET':
                return data, 200, self.lua.table_from({b'etag': b'"version-1"'})
            self.assertEqual(headers[b'If-Match'], b'"version-1"')
            return b'', 204, self.lua.table()
        merged, settled = self.S.run(transport, b'https://dav/backup.proto', pending, saved.append)
        self.assertEqual([x[0] for x in calls], [b'GET', b'PUT'])
        self.assertEqual(saved, [data])
        self.assertEqual(self.decode(merged)[2][b'page'], 5)
        calls.clear()
        def invalid(method, *args):
            calls.append(method)
            return b'not protobuf', 200, self.lua.table_from({b'etag': b'"v"'})
        with self.assertRaises(Exception):
            self.S.run(invalid, b'https://dav/backup.proto', pending, saved.append)
        self.assertEqual(calls, [b'GET'])

    def test_conflict_missing_etag_and_uncertain_upload_keep_pending(self):
        data = backup()
        _, m, c = self.decode(data)
        pending, key = self.pending(m, c)
        for etag, status in ((None, 204), (b'W/"weak"', 204), (b'"v"', 412), (b'"v"', 500), (b'"v"', None)):
            calls = []
            def transport(method, *args):
                calls.append(method)
                if method == b'GET':
                    return data, 200, self.lua.table_from({b'etag': etag} if etag else {})
                return b'', status, self.lua.table()
            with self.assertRaises(Exception):
                self.S.run(transport, b'https://dav/backup.proto', pending, lambda _: None)
            self.assertIsNotNone(pending[key])
            self.assertEqual(len(calls), 1 if not etag or etag.startswith(b'W/') else 2)

    def test_history_scoped_and_does_not_change_previous_book(self):
        self.lua.execute(b'''
            local history = { hist = {{ time = 10 }}, added = {}, updates = 0 }
            function history:addItem(file) self.added[#self.added + 1] = file end
            function history:updateLastBookTime() self.updates = self.updates + 1; self.hist[1].time = 99 end
            local reader = {}
            package.loaded.readhistory = history
            package.loaded['ffi/util'] = { realpath = function(s) return s end }
            package.loaded['apps/reader/readerui'] = reader
            require('km_history').install('/data/komikku/chapters')
            history:addItem('/data/books/normal.epub')
            history:addItem('/data/komikku/chapters/123/chapter.kmk')
            history:addItem('/data/komikku/chapters-other/book.epub')
            assert(#history.added == 2)
            reader.instance = { document = {file='/data/komikku/chapters/123/chapter.kmk'} }
            history:updateLastBookTime()
            assert(history.hist[1].time == 10 and history.updates == 0)
            reader.instance.document.file = '/data/books/normal.epub'
            history:updateLastBookTime()
            assert(history.updates == 1)
            history.hist = {}
            history:updateLastBookTime()
            assert(history.updates == 1)
        ''')

    def test_tls_host_matching_and_komga_mapping(self):
        H = self.lua.eval(b"require('km_http')")
        self.assertTrue(H.matchesHost(b'a.example.org', self.lua.table_from([b'*.example.org'])))
        self.assertFalse(H.matchesHost(b'a.b.example.org', self.lua.table_from([b'*.example.org'])))
        self.assertFalse(H.matchesHost(b'example.org', self.lua.table_from([b'*.example.org'])))
        self.assertFalse(H.matchesHost(b'evil.org', self.lua.table_from([b'example.org\x00evil.org'])))
        K = self.lua.eval(b"require('km_komga')")
        self.assertEqual(K.id(b'https://old/api/v1/books/ABC-123', b'books'), b'ABC-123')

    def test_app_does_not_mark_resume_dirty_and_refreshes_versions(self):
        data = backup()
        shelf, m, c = self.decode(data)
        App = self.lua.eval(b"require('km_app')")
        App[b'shelf'] = shelf
        App[b'state'] = self.lua.eval(b"{pending={},positions={}}")
        App[b'cache'] = self.lua.eval(b"{hasPage=function() return true end}")
        App[b'saveState'] = self.lua.eval(b"function() end")
        App.record(App, m, c, 3, 20, b'/cache')
        key = self.S.progressKey(m, c)
        self.assertIsNone(App[b'state'][b'pending'][key])
        self.assertEqual(App[b'state'][b'last'][b'chapter'], c[b'key'])
        App.record(App, m, c, 4, 20, b'/cache')
        self.assertEqual(App[b'state'][b'pending'][key][b'version'], 4)
        self.assertEqual(App[b'state'][b'pending'][key][b'page'], 3)
        fresh_shelf, _, fresh_c = self.decode(backup(chapter(version=20, page=5)))
        App[b'shelf'] = fresh_shelf
        App.record(App, m, c, 7, 20, b'/cache')
        self.assertEqual(App[b'state'][b'pending'][key][b'version'], 21)

    def test_actual_protobuf_runtime_can_decode_output(self):
        from google.protobuf import descriptor_pb2, descriptor_pool, message_factory
        fd = descriptor_pb2.FileDescriptorProto(name='komikku.proto', package='km', syntax='proto2')
        def message(name, fields):
            m = fd.message_type.add(name=name)
            for number, name, typ, repeated, type_name in fields:
                f = m.field.add(number=number, name=name, type=typ, label=3 if repeated else 1)
                if type_name:
                    f.type_name = type_name
        I64, STRING, MSG, FLOAT, BOOL = 3, 9, 11, 2, 8
        message('Chapter', [(1,'url',STRING,False,''),(2,'name',STRING,False,''),
            (4,'read',BOOL,False,''),(6,'page',I64,False,''),(9,'number',FLOAT,False,''),
            (12,'version',I64,False,'')])
        message('Manga', [(1,'source',I64,False,''),(2,'url',STRING,False,''),
            (16,'chapters',MSG,True,'.km.Chapter'),(17,'categories',I64,True,'')])
        message('Backup', [(1,'mangas',MSG,True,'.km.Manga')])
        pool = descriptor_pool.DescriptorPool()
        pool.Add(fd)
        Backup = message_factory.GetMessageClass(pool.FindMessageTypeByName('km.Backup'))
        data = backup()
        _, m, c = self.decode(data)
        pending, _ = self.pending(m, c)
        encoded, _, _ = self.S.merge(data, pending)
        decoded = Backup.FromString(encoded)
        self.assertEqual(decoded.mangas[0].source, -(2**62) + 77)
        self.assertEqual(decoded.mangas[0].chapters[0].number, 1.5)
        self.assertEqual(decoded.mangas[0].chapters[0].version, 4)
        self.assertEqual(decoded.mangas[0].chapters[0].page, 5)
        self.assertEqual(list(decoded.mangas[0].categories), [1, 128])
        # Independent serializer retains unknowns through a second roundtrip.
        self.assertEqual(self.decode(decoded.SerializeToString())[2][b'page'], 5)

    def test_https_transport_auth_redirects_and_san_validation(self):
        self.lua.execute('''
            local requests, sent = 0, false
            local function parse(url)
                return {scheme=url:match('^(%w+):'),host='dav.example',path='/backup.proto'}
            end
            package.loaded['socket.url']={parse=parse,build=function() return 'http://dav.example:443/backup.proto' end}
            package.loaded.mime={b64=function(s) assert(s=='alice:secret');return 'encoded' end}
            package.loaded.ltn12={source={string=function(s) return s end}}
            local reset=false
            package.loaded.socketutil={set_timeout=function() end,reset_timeout=function() reset=true end}
            local cert_names={'dav.example'}
            package.loaded['ssl.https']={tcp=function(opts)
                assert(opts.verify=='peer' and opts.cafile=='data/ca-bundle.crt')
                return function() return {connect=function() return 1 end,close=function() end,
                    sock={getpeercertificate=function() return {extensions=function()
                        return {['2.5.29.17']={dNSName=cert_names}}
                    end} end}} end
            end}
            package.loaded['socket.http']={request=function(req)
                requests=requests+1
                assert(req.redirect==false and req.headers.Authorization=='Basic encoded')
                assert(req.headers.Host=='dav.example')
                local sock=req.create()
                local ok=sock:connect('dav.example',443)
                if not ok then return nil,'hostname mismatch' end
                sent=true
                req.sink('protobuf')
                req.sink(nil)
                return 1,200,{ETag='"abc"'}
            end}
            local H=require('km_http')
            local config={webdav_user='alice',webdav_password='secret',webdav_url='https://dav.example',webdav_folder='中文/a b'}
            assert(H.webdavUrl(config)=='https://dav.example/%E4%B8%AD%E6%96%87/a%20b/backup.proto')
            local body,code,headers=H.request(config,'webdav','GET','https://dav.example/backup.proto')
            assert(body=='protobuf' and code==200 and headers.etag=='"abc"' and reset and sent)
            cert_names={'evil.example'}; sent=false;reset=false
            assert(not pcall(H.request,config,'webdav','GET','https://dav.example/backup.proto'))
            assert(not sent and reset)
            assert(not pcall(H.validateBase,'http://dav.example'))
            package.loaded['socket.http'].request=function(req)
                assert(req.headers.Authorization==nil)
                req.sink('{}');return 1,200,{}
            end
            assert(H.request(config,'github','GET','https://dav.example/release')=='{}')
        '''.encode())

    def test_cache_offline_download_survives_interruption_and_eviction(self):
        self.lua.execute(b'''
            local files={}
            local function add(p,bytes) files[p]={size=#bytes,modification=10,mode='file',bytes=bytes} end
            local function attrs(p,k)
                local a=files[p]
                if not a then return nil end
                return k and a[k] or a
            end
            package.loaded['libs/libkoreader-lfs']={attributes=attrs,touch=function() end,dir=function(dir)
                local names={'.','..'}
                for p in pairs(files) do
                    local n=p:match('^'..dir..'/([^/]+)$')
                    if n then names[#names+1]=n end
                end
                local i=0;return function() i=i+1;return names[i] end
            end}
            package.loaded.util={makePath=function() end}
            package.loaded.km_files={read=function(p) return files[p] and files[p].bytes end,write=add}
            local fail=true
            package.loaded.km_komga={downloadPage=function(_,_,p,path)
                if p.number==2 and fail then error('interrupted') end
                add(path,'image')
            end}
            package.loaded['ffi/sha2']={md5=function() return 'aaa' end}
            local remove=os.remove
            os.remove=function(path) files[path]=nil;return true end
            local C=require('km_cache').new('/cache',{})
            local m={address='book',pages={{number=1},{number=2}}}
            assert(not pcall(C.download,C,m,'/cache/aaa'))
            assert(files['/cache/aaa/offline'] and C:hasPage('/cache/aaa',1))
            add('/cache/aaa/00002.png.part',string.rep('x',4096))
            local done,total,current,bytes=C:downloadProgress(m,'/cache/aaa')
            assert(done==1 and total==2 and current==2 and bytes==4096)
            assert(not C:isOffline('/cache/aaa',2))
            fail=false;C:download(m,'/cache/aaa')
            assert(C:isOffline('/cache/aaa',2))
            done,total,current,bytes=C:downloadProgress(m,'/cache/aaa')
            assert(done==2 and total==2 and current==nil and bytes==0)
            files['/cache/aaa']={mode='directory'}
            files['/cache/bbb']={mode='directory'}
            add('/cache/bbb/00001.png','cached')
            files['/cache/bbb/00001.png'].size=200*1024*1024
            C:evict()
            assert(not files['/cache/bbb/00001.png'])
            assert(C:isOffline('/cache/aaa',2))
            C:remove('book')
            assert(not files['/cache/aaa/offline'] and not files['/cache/aaa/00001.png'])
            os.remove=remove
        ''')

    def test_native_document_page_lifetime_and_number_mapping(self):
        self.lua.execute(b'''
            local base = {}
            function base:extend(o) self.__index=self; return setmetatable(o or {},self) end
            function base:new(o) local x=self:extend(o); x.info={}; x.configurable={}; x:init(); return x end
            function base:updateColorRendering() self._document:setColorRendering(false) end
            function base:_readMetadata() self.info.number_of_pages=self._document:getPages() end
            package.loaded['document/pdfdocument'] = base
            package.loaded['document/document'] = base
            package.loaded['document/koptinterface'] = {setDefaultConfigurable=function() end}
            local App={ cache={directory=function() return '/cache/book' end,
                ensure=function(_,m,d,n) assert(n==2); return '/cache/book/00002.png' end} }
            function App:init() end
            package.loaded.km_app=App
            package.loaded.km_files={read=function() return 'manifest' end}
            package.loaded.json={decode=function() return {address='book',pages={{},{}}} end}
            package.loaded.socket={gettime=function() return 123.123 end}
            local closed_page, closed_doc = false,false
            package.loaded['ffi/mupdf']={openDocument=function(path)
                assert(path=='/cache/book/00002.png')
                return {setColorRendering=function() end,close=function() assert(closed_page);closed_doc=true end,
                  openPage=function(_,n) assert(n==1);return {
                    getSize=function() return 758,1024 end,
                    close=function() closed_page=true end} end}
            end}
            local doc=require('km_document'):new{file='/cache/book/chapter.kmk'}
            assert(doc.info.number_of_pages==2 and doc.is_komikku)
            local p=doc._document:openPage(2)
            assert(p:getSize()==758 and not closed_doc)
            p:close()
            assert(closed_page and closed_doc)
        ''')

    def test_menu_settings_and_reader_lifecycle(self):
        shelf, m, c = self.decode(backup())
        self.lua.globals()[b'test_shelf'] = shelf
        self.lua.execute('''
            local base={}
            function base:extend(o) self.__index=self;return setmetatable(o or {},self) end
            function base:new(o) local x=self:extend(o);if x.init then x:init() end;return x end
            package.loaded['ui/widget/container/widgetcontainer']=base
            local shown, nextticks={},{}
            local ui={show=function(_,w) shown[#shown+1]=w end,close=function() end,
                nextTick=function(_,f) nextticks[#nextticks+1]=f end}
            package.loaded['ui/uimanager']=ui
            for _,name in ipairs({'ui/widget/menu','ui/widget/infomessage','ui/widget/multiinputdialog','ui/widget/inputdialog'}) do
                package.loaded[name]=base:extend{onShowKeyboard=function() end}
            end
            package.loaded['ui/trapper']={wrap=function(_,f) f() end,
                dismissableRunInSubprocess=function(_,f) return true,f() end}
            package.loaded['ui/network/manager']={isConnected=function() return false end}
            package.loaded['document/documentregistry']={known_providers={komikku=true}}
            package.loaded.device={screen={getWidth=function() return 758 end}}
            local App={root='/data',config={auto_sync=false},state={pending={},positions={}},shelf=test_shelf}
            function App:init() end
            function App:reloadShelf() return self.shelf end
            function App:current(m,c) return c end
            function App:saveConfig() end
            App.cache={stopPrefetch=function() end,prefetch=function() end}
            local registered=false
            local plugin=require('main'):new{ui={menu={registerToMainMenu=function() registered=true end}}}
        '''.replace("            local registered=false", "            package.loaded.km_app=App\n            local registered=false").encode())
        # Continue in a single chunk with persistent access to the plugin through the UI registry.
        self.lua.execute('''
            local base=package.loaded['ui/widget/container/widgetcontainer']
            local App=package.loaded.km_app
            local events={}
            local plugin=require('main'):new{ui={menu={registerToMainMenu=function() end}}}
            local menus={}
            function plugin:menu(title,items) menus[#menus+1]={title=title,items=items} end
            plugin:shelf()
            assert(#menus[1].items==5)
            menus[1].items[5].callback()
            assert(#menus[2].items==2)
            menus[2].items[2].callback()
            assert(#menus[3].items==3)
            function plugin:openChapter(m,c) events.open=c.url end
            menus[3].items[1].callback()
            assert(events.open==test_shelf.mangas[1].chapters[1].url)
            plugin:settings()
            assert(#menus[4].items==7)
            local mainitems={};plugin:addToMainMenu(mainitems)
            assert(mainitems.komikku and #mainitems.komikku.sub_item_table==9)
            local App=package.loaded.km_app
            function App:record(m,c,page,total,dir) events.saved=page end
            local doc={is_open=true,is_komikku=true,km_manifest={},km_dir='/cache',getPageCount=function() return 20 end}
            plugin.document=doc;plugin.manga=test_shelf.mangas[1];plugin.chapter=plugin.manga.chapters[1]
            plugin.ui.getCurrentPage=function() return 5 end
            local refreshes={}
            local ui=package.loaded['ui/uimanager']
            ui.setDirty=function(_,widget,mode) refreshes[#refreshes+1]={widget=widget,mode=mode} end
            plugin.ui.dialog={}
            G_reader_settings=setmetatable({}, {__index=function() error('must not touch global refresh settings') end})
            plugin:onReaderReady()
            assert(#refreshes==1 and refreshes[1].mode=='full' and refreshes[1].widget==plugin.ui.dialog)
            plugin:onPageUpdate(6)
            assert(#refreshes==2 and refreshes[2].mode=='full')
            plugin:onSuspend()
            assert(events.saved==5)
            plugin:onCloseDocument()
            assert(events.saved==5)
            plugin.chapter=nil;plugin.document={is_komikku=false}
            plugin:onReaderReady();plugin:onPageUpdate(7)
            assert(#refreshes==2)
            plugin.document=nil
            plugin:onReaderReady();plugin:onPageUpdate(8)
            assert(#refreshes==2)
        '''.encode())

    def test_thumbnail_grid_pagination_layout_callbacks_and_cleanup(self):
        self.lua.execute('''
            local W={kind='widget'}
            function W:extend(o) self.__index=self;return setmetatable(o or {},self) end
            function W:new(o)
                local x=self:extend(o)
                if x._init then x:_init() end
                if x.init then x:init() end
                return x
            end
            local G=W:extend{}
            function G:copy() return G:new{x=self.x,y=self.y,w=self.w,h=self.h} end
            function W:getSize()
                if self.dimen then return self.dimen end
                local w,h=0,0
                if self.kind=='text' then return {w=self.max_width or self.width or 100,h=self.height or 20} end
                if self.kind=='image' then return {w=self.width,h=self.height} end
                if self.kind=='buttons' then return {w=self.width,h=52} end
                for _,child in ipairs(self) do
                    local s=child:getSize()
                    if self.kind=='vertical' then w=math.max(w,s.w);h=h+s.h
                    elseif self.kind=='horizontal' then w=w+s.w;h=math.max(h,s.h)
                    else w=s.w;h=s.h;break end
                end
                if self.kind=='frame' then w=w+2*(self.padding or 0)+2*(self.bordersize or 0);h=h+2*(self.padding or 0)+2*(self.bordersize or 0) end
                return {w=w,h=h}
            end
            local freed=0
            function W:free() if self.kind=='image' then freed=freed+1 end;for _,c in ipairs(self) do c:free() end end
            local input=W:extend{_init=function(self) self.key_events={};self.ges_events={} end}
            package.loaded['ui/widget/container/inputcontainer']=input
            package.loaded['ui/widget/container/widgetcontainer']=W
            package.loaded['ui/widget/container/centercontainer']=W
            for _,v in ipairs({{'ui/widget/container/framecontainer','frame'},{'ui/widget/verticalgroup','vertical'},
                {'ui/widget/horizontalgroup','horizontal'},{'ui/widget/textboxwidget','text'},
                {'ui/widget/textwidget','text'},{'ui/widget/buttontable','buttons'},{'ui/widget/imagewidget','image'}}) do
                package.loaded[v[1]]=W:extend{kind=v[2]}
            end
            package.loaded['ui/geometry']=G
            package.loaded['ui/font']={getFace=function() return {} end}
            package.loaded['ui/gesturerange']=W
            package.loaded['ffi/blitbuffer']={COLOR_WHITE=255}
            local screen={w=758,h=1024,getSize=function(self) return G:new{w=self.w,h=self.h} end,
                scaleBySize=function(_,n) return n end}
            package.loaded.device={screen=screen,hasKeys=function() return true end,input={group={PgFwd={'next'},PgBack={'prev'},Back={'back'}}}}
            local closed=0
            package.loaded['ui/uimanager']={setDirty=function() end,close=function(_,g) closed=closed+1;g:onCloseWidget() end}
            local Grid=require('km_shelf')
            local mangas={}
            for i=1,13 do mangas[i]={title='Manga '..i} end
            local entries,p,total=Grid.page(mangas,1)
            assert(#entries==6 and p==1 and total==3 and entries[6]==mangas[6])
            entries,p,total=Grid.page(mangas,2)
            assert(#entries==6 and entries[1]==mangas[7] and entries[6]==mangas[12])
            entries,p,total=Grid.page(mangas,999)
            assert(#entries==1 and entries[1]==mangas[13] and p==3)
            entries,p,total=Grid.page({},-1)
            assert(#entries==0 and p==1 and total==1)
            for _,size in ipairs({{758,1024},{1024,758}}) do
                screen.w,screen.h=size[1],size[2]
                for _,count in ipairs({0,1,6}) do
                    local cards={}
                    for i=1,count do cards[i]={manga=mangas[i],status='0 / 10',file='cover.jpg'} end
                    local page,selected
                    local grid=Grid:new{entries=cards,page_number=1,page_count=3,on_page=function(p) page=p end,
                        on_select=function(m) selected=m end,on_list=function() end,on_categories=function() end,
                        on_sync=function() end,on_resume=function() end}
                    local layout=grid[1][1][1]
                    local bounds=layout:getSize()
                    assert(bounds.w<=screen.w and bounds.h<=screen.h)
                    assert(#layout==6)
                    if count>0 then
                        local tile=layout[3][1]
                        tile:onSelect()
                        assert(selected==mangas[1])
                        assert(tile:getSize().h>0 and tile[1]:getSize().h<=tile:getSize().h)
                    end
                    grid:onPrevPage();assert(page==nil)
                    grid:onNextPage();assert(page==2)
                    grid.page_number=3;page=nil;grid:onNextPage();assert(page==nil)
                    local before=freed
                    grid:onClose()
                    assert(grid.closed and freed-before==count)
                end
            end
        '''.encode())

    def test_thumbnail_urls_use_configured_origin_and_supported_identity(self):
        K = self.lua.eval(b"require('km_komga')")
        self.lua.execute(b"package.loaded['socket.url']={parse=function() return {scheme='https',host='configured.example'} end}")
        config = self.lua.table_from({b'komga_url': b'https://configured.example/prefix'})
        for kind in (b'series', b'books'):
            m = self.lua.table_from({b'url': b'https://old.example/api/v1/' + kind + b'/ABC', b'chapters': self.lua.table()})
            self.assertEqual(K.coverUrl(config, m), b'https://configured.example/prefix/api/v1/' + kind + b'/ABC/thumbnail')
        m = self.lua.table_from({b'url': b'https://old.example/api/v1/readlists/ABC', b'chapters': self.lua.table_from([
            self.lua.table_from({b'url': b'https://old.example/api/v1/books/FIRST'})])})
        self.assertEqual(K.coverUrl(config, m), b'https://configured.example/prefix/api/v1/readlists/ABC/thumbnail')

    def test_return_to_bookshelf_only_for_comic_browser_action(self):
        self.lua.execute(b'''
            local start='bookshelf'
            G_reader_settings={readSetting=function(_,k) assert(k=='start_with');return start end}
            local events={}
            local fm={bookshelf={show=function() events[#events+1]='show' end,
                _raiseInPlace=function() events[#events+1]='raise' end}}
            package.loaded['apps/filemanager/filemanager']={instance=fm}
            local N=require('km_navigation')
            local base={showFileManager=function(self,file,selected)
                events[#events+1]='browser';self.return_file=file;self.return_selected=selected;return 'native'
            end}
            local comic=setmetatable({}, {__index=base})
            local ordinary=setmetatable({}, {__index=base})
            N.install(ordinary,{is_komikku=false,file='/books/novel.epub'})
            assert(rawget(ordinary,'showFileManager')==nil)
            N.install(comic,{is_komikku=true,file='/cache/chapter.kmk'})
            local hook=comic.showFileManager
            N.install(comic,{is_komikku=true,file='/cache/chapter.kmk'})
            assert(comic.showFileManager==hook and base.showFileManager~=hook)
            assert(#events==0) -- Installing/closing/exiting alone never opens a home screen.
            comic:showFileManager('/cache/chapter.kmk')
            assert(table.concat(events,',')=='browser,raise,show' and comic.return_file==nil)
            events={}
            assert(ordinary:showFileManager('/books/novel.epub')=='native')
            assert(ordinary.return_file=='/books/novel.epub' and #events==1)
            events={};start='history'
            assert(comic:showFileManager('/cache/chapter.kmk')=='native')
            assert(comic.return_file=='/cache/chapter.kmk' and #events==1)
            events={};start='bookshelf'
            comic:showFileManager('/books/other.epub')
            assert(comic.return_file=='/books/other.epub' and #events==1)
            events={}
            local selected={book=true}
            comic:showFileManager('/cache/chapter.kmk',selected)
            assert(comic.return_selected==selected and #events==1)
            events={};fm.bookshelf._raiseInPlace=nil
            comic:showFileManager('/cache/chapter.kmk')
            assert(table.concat(events,',')=='browser,show') -- Older Bookshelf, public show only.
            events={};fm.bookshelf=nil
            comic:showFileManager('/cache/chapter.kmk')
            assert(#events==1 and comic.return_file==nil) -- Plugin unavailable: usable browser fallback.
        ''')

    def test_thumbnail_shelf_fetches_only_current_six_and_switches_to_list(self):
        self.lua.execute('''
            local W={}
            function W:extend(o) self.__index=self;return setmetatable(o or {},self) end
            function W:new(o) return self:extend(o) end
            package.loaded['ui/widget/container/widgetcontainer']=W
            package.loaded['ui/widget/menu']=W
            package.loaded['ui/widget/infomessage']=W
            local closed,shown=0,{}
            local ui={show=function(_,w) shown[#shown+1]=w end,close=function(_,g)
                closed=closed+1;g.closed=true;if g.on_closed then g.on_closed() end
            end}
            package.loaded['ui/uimanager']=ui
            local online=true
            package.loaded['ui/network/manager']={isConnected=function() return online end}
            package.loaded['ui/trapper']={wrap=function(_,f) f() end,dismissableRunInSubprocess=function(_,f) return true,f() end}
            package.loaded.util={makePath=function() end}
            local cached,downloads={},{}
            package.loaded['libs/libkoreader-lfs']={attributes=function(path) return cached[path] and 100 end}
            package.loaded['ffi/sha2']={md5=function(s) return s:match('m%d+$') end}
            package.loaded.km_komga={downloadCover=function(config,m,path)
                downloads[#downloads+1]=m.key;cached[path]=true;return true
            end}
            local Grid=W:extend{}
            function Grid.page(mangas,p)
                local result={};p=p or 1
                for i=(p-1)*6+1,math.min(p*6,#mangas) do result[#result+1]=mangas[i] end
                return result,p,math.ceil(#mangas/6)
            end
            package.loaded.km_shelf=Grid
            local App={root='/data',config={shelf_view='covers'},state={},shelf={mangas={}}}
            function App:reloadShelf() return self.shelf end
            function App:saveConfig() self.saved=true end
            function App:current(m,c) return c end
            for i=1,13 do App.shelf.mangas[i]={key='m'..i,title='Manga '..i,favorite=true,categories={},chapters={}} end
            package.loaded.km_app=App
            local P=require('main')
            P:shelf(nil,2)
            assert(#downloads==6 and downloads[1]=='m7' and downloads[6]=='m12')
            local grid=shown[#shown]
            assert(#grid.entries==6 and grid.page_number==2 and grid.entries[1].file)
            assert(#App.menus==1)
            grid.on_page(3)
            assert(#downloads==7 and downloads[7]=='m13')
            grid=shown[#shown];assert(#grid.entries==1 and grid.page_number==3)
            online=false
            grid.on_page(1)
            grid=shown[#shown]
            assert(#downloads==7 and grid.entries[1].file==nil and #grid.entries==6)
            function P:menu(title,items) self.list_items=items end
            grid.on_list()
            assert(App.saved and App.config.shelf_view=='list' and #P.list_items==17)
            assert(#App.menus==0)
        '''.encode())

    def test_download_progress_updates_and_cleans_up_on_all_exits(self):
        self.lua.execute('''
            local base={}
            function base:extend(o) self.__index=self;return setmetatable(o or {},self) end
            function base:new(o) local x=self:extend(o);if x.init then x:init() end;return x end
            package.loaded['ui/widget/container/widgetcontainer']=base
            package.loaded['ui/widget/infomessage']=base
            package.loaded['ui/widget/menu']=base
            package.loaded['ui/network/manager']={}
            local scheduled, messages, dialog, dirty
            local ui={
                show=function(_,w) if w.text then messages[#messages+1]=w.text else dialog=w end end,
                close=function(_,w) w:onCloseWidget() end,
                scheduleIn=function(_,seconds,fn) assert(seconds==1);scheduled=fn end,
                unschedule=function(_,fn) assert(fn==scheduled);scheduled=nil end,
                setDirty=function(_,w,mode) assert(w==dialog and mode=='ui');dirty=dirty+1 end,
            }
            package.loaded['ui/uimanager']=ui
            local Progress=base:extend{}
            function Progress:init()
                local group={{},{setText=function(w,s) w.text=s end},resetLayout=function() end}
                self[1]={group}
                self.progress_bar={setPercentage=function(w,p) w.percentage=p end}
            end
            function Progress:show() ui:show(self) end
            function Progress:close() ui:close(self) end
            function Progress:onCloseWidget()
                if self.dismiss_callback then self.dismiss_callback();self.dismiss_callback=nil end
            end
            package.loaded['ui/widget/progressbardialog']=Progress
            local App={cache={}}
            package.loaded.km_app=App
            local mode, completed, bytes, ran, resumed
            function App.cache:downloadProgress() return completed,3,completed<3 and completed+1 or nil,bytes end
            function App.cache:download()
                ran=true
                if mode=='failure' then error('download failed') end
                completed=2;bytes=16384
                scheduled()
                assert(dialog.progress_bar.percentage==2/3)
                assert(dialog[1][1][2].text:find('2 / 3') and dialog[1][1][2].text:find('16 KiB'))
                completed=3
            end
            local trap={}
            package.loaded['ui/trapper']=trap
            function trap:dismissableRunInSubprocess(task,w)
                assert(w==dialog and w.progress_max==3)
                assert(w.progress_bar.percentage==1/3)
                w.dismiss_callback=function() resumed=resumed+1 end
                if mode=='cancel' then w:close();return false end
                if mode=='exception' then error('unexpected worker error') end
                return true,task()
            end
            local Plugin=require('main')
            for _,scenario in ipairs({'success','cancel','failure','exception'}) do
                mode=scenario;completed=1;bytes=4096;ran=false;resumed=0;messages={};dirty=0
                Plugin:downloadWithProgress({pages={{},{},{}}},'/cache')
                assert(scheduled==nil and dialog.dismiss_callback==nil)
                assert(resumed==(mode=='cancel' and 1 or 0))
                assert(ran==(mode=='success' or mode=='failure'))
                assert(#messages==(mode=='cancel' and 0 or 1))
                if mode=='success' then assert(dirty>=2 and messages[1]:find('整章已下载')) end
            end
        '''.encode())


if __name__ == '__main__':
    from test_library import install
    install(Checks, backup, chapter, field)
    from test_update import install as install_update
    install_update(Checks)
    unittest.main(verbosity=2)
