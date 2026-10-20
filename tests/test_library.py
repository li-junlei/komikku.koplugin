"""Additional Komga library tests, executed by run_tests.py with the same LuaJIT runtime."""
import struct
import urllib.parse


def install(Checks, backup, chapter, field):
    def test_komga_filter_query_matches_extension_rules(self):
        C = self.lua.eval(b"require('km_catalog')")
        filters = self.lua.table_from({b'kind': b'books', b'collection': b'COL 1', b'search': '中文 + test'.encode(),
            b'unread': True, b'in_progress': True, b'read': True, b'sort': b'title', b'descending': True,
            b'library_id': self.lua.table_from([b'L1', b'L2']), b'status': self.lua.table_from([b'ONGOING', b'HIATUS']),
            b'genre': self.lua.table_from(['科幻'.encode()]), b'tag': self.lua.table_from([b'A&B']),
            b'publisher': self.lua.table_from([b'P1']), b'author': self.lua.table_from([
                self.lua.table_from({b'name': b'A, B', b'role': b'writer'}),
                self.lua.table_from({b'name': b'C', b'role': b'penciller'})])})
        path, kind = C.path(filters, 3)
        u = urllib.parse.urlsplit(path.decode())
        q = urllib.parse.parse_qs(u.query)
        self.assertEqual(kind, b'series')
        self.assertEqual(u.path, '/api/v1/collections/COL%201/series')
        self.assertEqual(q['page'], ['2'])
        self.assertEqual(q['size'], ['6'])
        self.assertEqual(q['read_status'], ['UNREAD', 'IN_PROGRESS', 'IN_PROGRESS', 'READ'])
        self.assertEqual(q['library_id'], ['L1,L2'])
        self.assertEqual(q['status'], ['ONGOING,HIATUS'])
        self.assertEqual(q['search'], ['中文 + test'])
        self.assertEqual(q['author'], ['A, B,writer', 'C,penciller'])
        self.assertEqual(q['sort'], ['name,desc'])
        filters[b'collection'] = b''
        filters[b'kind'] = b'series'
        self.assertIn(b'metadata.titleSort', C.path(filters, 1)[0])
        filters[b'kind'] = b'readlists'
        self.assertIn(b'/readlists?', C.path(filters, 1)[0])

    def test_catalog_chapter_mapping_and_float32(self):
        _, template, _ = self.decode(backup())
        self.lua.globals()[b'template'] = template
        self.lua.execute('''
            local C=require('km_catalog')
            local P=require('km_proto')
            local item={kind='series',id='NEW',title='Fallback'}
            local dto={metadata={title='New series',summary='Summary',status='ENDED',totalBookCount=3,genres={'SF'},tags={'X'}},
                booksCount=2,booksMetadata={authors={{name='Writer',role='writer'},{name='Artist',role='penciller'}}}}
            local books={
                {id='B1',seriesTitle='New series',size='1 MiB',media={},metadata={number='1',numberSort=1,title='First',authors={}}},
                {id='SKIP',media={mediaProfile='EPUB',epubDivinaCompatible=false},metadata={}},
                {id='B2',seriesTitle='New series',size='2 MiB',media={},metadata={number='1.5',numberSort=1.5,title='Second',authors={{name='T',role='translator'}}}},
            }
            local m=C.build({},template,item,dto,books)
            assert(m.source==template.source and m.url=='https://old.example/api/v1/series/NEW')
            assert(m.favorite==false and #m.chapters==2)
            assert(P.get(m.fields,5)== 'Writer' and P.int(m.fields,8)==4)
            assert(m.chapters[1].name=='1.5 - Second (2 MiB)' and m.chapters[1].order==0)
            assert(m.chapters[2].order==1 and P.get(m.chapters[1].fields,3)=='T')
            assert(P.get(m.chapters[1].fields,9)==P.float32(1.5))
            item.kind='readlists';dto={name='Reading list'}
            m=C.build({},template,item,dto,books)
            assert(m.chapters[1].name=='New series 1.5 - Second (2 MiB)')
            assert(P.get(m.chapters[1].fields,9)==P.float32(2))
            assert(P.get(m.fields,5)==nil)
        '''.encode())
        encoded = self.P.float32(1.5)
        self.assertEqual(encoded, struct.pack('<f', 1.5))

    def test_add_new_favorite_preserves_remote_and_is_idempotent(self):
        data = backup(extra=field(1700, b'future opaque data'))
        _, old, _ = self.decode(data)
        new_fields = self.P.set(old[b'fields'], 2, 2, b'https://old.example/api/v1/series/NEW')
        new_fields = self.P.set(new_fields, 3, 2, b'New manga')
        candidate_bytes = self.P.encode(self.lua.table_from([self.lua.table_from({b'id': 1, b'wire': 2, b'value': self.P.encode(new_fields)})]))
        _, candidate, _ = self.decode(candidate_bytes)
        calls, saved = [], []
        def transport(method, url, body=None, headers=None):
            calls.append(method)
            if method == b'GET':
                return data, 200, self.lua.table_from({b'etag': b'"v1"'})
            self.assertEqual(headers[b'If-Match'], b'"v1"')
            return b'', 204, self.lua.table()
        output = self.S.add(transport, b'https://dav/backup.proto', candidate, 1, self.lua.table(), saved.append)
        self.assertEqual(calls, [b'GET', b'PUT'])
        self.assertEqual(saved, [data])
        out = self.S.decode(output)
        self.assertEqual(len(out[b'mangas']), 2)
        new = out[b'mangas'][2]
        self.assertEqual(new[b'source'], old[b'source'])
        self.assertTrue(new[b'favorite'])
        self.assertEqual(new[b'categories'][1], 1)
        self.assertEqual(self.P.int(new[b'fields'], 109), 10)
        self.assertIn(field(1700, b'future opaque data'), output)
        self.assertEqual(self.P.encode(out[b'mangas'][1][b'fields']), self.P.encode(old[b'fields']))
        calls.clear()
        def retry(method, *args):
            calls.append(method)
            return output, 200, self.lua.table_from({b'etag': b'"v2"'})
        self.assertEqual(self.S.add(retry, b'https://dav/file', candidate, 1, self.lua.table(), saved.append), output)
        self.assertEqual(calls, [b'GET'])

    def test_refavorite_retains_existing_chapters_notes_and_versions(self):
        data = backup(chapter(version=20, page=17, extra=field(800, b'preserve-note')), favorite=0)
        _, candidate, _ = self.decode(backup(chapter(version=1, page=0)))
        def transport(method, *args):
            if method == b'GET': return data, 200, self.lua.table_from({b'etag': b'"v1"'})
            return b'', 204, self.lua.table()
        output = self.S.add(transport, b'https://dav/file', candidate, -1, self.lua.table(), lambda _: None)
        _, m, c = self.decode(output)
        self.assertTrue(m[b'favorite'])
        self.assertEqual(len(m[b'categories']), 0)
        self.assertEqual(c[b'version'], 20)
        self.assertEqual(c[b'page'], 17)
        self.assertEqual(self.P.get(c[b'fields'], 800), b'preserve-note')

    def test_add_rejects_concurrent_category_change_unknown_source_and_412(self):
        data = backup(favorite=0)
        _, candidate, _ = self.decode(data)
        for category, etag, status in ((99, b'"v"', 204), (1, None, 204), (1, b'"v"', 412), (1, b'"v"', 500)):
            calls = []
            def transport(method, *args):
                calls.append(method)
                if method == b'GET': return data, 200, self.lua.table_from({b'etag': etag} if etag else {})
                return b'', status, self.lua.table()
            with self.assertRaises(Exception):
                self.S.add(transport, b'https://dav/file', candidate, category, self.lua.table(), lambda _: None)
            self.assertEqual(len(calls), 1 if category == 99 or not etag else 2)
        candidate[b'source'] = b'unknown'
        with self.assertRaises(Exception):
            self.S.add(lambda *args: (data, 200, self.lua.table()), b'https://dav/file', candidate, 1, self.lua.table(), lambda _: None)

    def test_library_ui_filters_and_view_modes(self):
        self.lua.execute('''
            local C={}
            local requests={}
            function C.browse(config,filters,page)
                requests[#requests+1]=page
                return {items={{title='Book',key='k',chapters={}}},page=page,pages=3}
            end
            function C.options() return {libraries={{id='L',name='Library'}},collections={{id='C',name='Collection'}},
                genres={'SF'},tags={'T'},publishers={'P'},authors={{name='W',role='writer'}}} end
            function C.sources() return {{manga={key='source',url='url'}}} end
            package.loaded.km_catalog=C
            package.loaded['ui/uimanager']={show=function() end,close=function() end}
            package.loaded['ui/network/manager']={runWhenConnected=function(_,fn) fn() end}
            package.loaded['ui/trapper']={wrap=function(_,fn) fn() end}
            local App={config={},shelf=nil}
            function App:reloadShelf() return self.shelf end
            function App:saveConfig() end
            package.loaded.km_app=App
            local owner={}
            function owner:menu(title,items) self.title,self.items=title,items end
            function owner:coverShelf(items,category,page,cached,context) self.context=context end
            local L=require('km_library')
            local function worker(fn) return fn() end
            L.open(owner,worker)
            assert(requests[1]==1 and #owner.items==5)
            owner.items[1].callback()
            assert(App.config.library_view=='covers' and owner.context.pages==3)
            owner.context.on_page(2)
            assert(requests[2]==2 and owner.context.page==2)
            owner.context.buttons[3].callback()
            assert(owner.title:find('Komga') and #owner.items>=16)
            local function click(text)
                for _,item in ipairs(owner.items) do if item.text==text then item.callback();return end end
                error('missing item '..text)
            end
            click('未读（含阅读中）')
            assert(App.config.library_filters.unread)
            click('书库');click('Library');click('返回筛选')
            assert(App.config.library_filters.library_id[1]=='L')
            click('作者 · writer');click('W');click('返回筛选')
            assert(App.config.library_filters.author[1].role=='writer')
            click('应用筛选')
            assert(requests[#requests]==1)
        '''.encode())

    def test_catalog_local_read_then_add_publishes_progress(self):
        data = backup()
        shelf, old, _ = self.decode(data)
        new_fields = self.P.set(old[b'fields'], 2, 2, b'https://old.example/api/v1/series/NEW')
        new_fields = self.P.setint(new_fields, 100, 0)
        new_bytes = self.P.encode(self.lua.table_from([
            self.lua.table_from({b'id': 1, b'wire': 2, b'value': self.P.encode(new_fields)})]))
        _, candidate, c = self.decode(new_bytes)
        self.lua.globals()[b'shelf'] = shelf
        self.lua.globals()[b'candidate'] = candidate
        self.lua.globals()[b'remote_bytes'] = data
        self.lua.execute(b'''
            local files={}
            package.loaded.km_files={read=function(path) return files[path] end,write=function(path,bytes) files[path]=bytes end}
            local puts=0
            package.loaded.km_http={webdavUrl=function() return 'https://dav/backup.proto' end,
                request=function(config,service,method,url,body,headers)
                    if method=='GET' then return remote_bytes,200,{etag='"etag"'} end
                    assert(headers['If-Match']=='"etag"')
                    puts=puts+1;remote_bytes=body;return '',204,{}
                end}
            local App=require('km_app')
            App.root='/data';App.config={komga_url='https://configured.example',komga_user='user'}
            App.state={pending={},positions={},local_progress={}};App.shelf=shelf
            App.cache={hasPage=function() return true end}
            function App:saveState() end
            App:remember(candidate)
            local m,c=App:find(candidate.key,candidate.chapters[1].key)
            assert(m and c and m.favorite==false)
            App:record(m,c,6,20,'/cache')
            local k=require('km_sync').progressKey(m,c)
            assert(App.state.pending[k]==nil and App.state.local_progress[k].page==5)
            assert(App:addToShelf(m,1,function(fn) return fn() end))
            m,c=App:find(m.key,c.key)
            assert(m.favorite and c.page==5 and c.version==4 and puts==1)
            assert(App.state.pending[k]==nil)
            App:record(m,c,7,20,'/cache')
            assert(App.state.pending[k].page==6 and App.state.pending[k].version==5)
            assert(#App:allMangas()==2)
            App.config.komga_user='different'
            local found=App:find('missing')
            assert(found==nil)
        ''')

    def test_library_browse_and_facets_use_expected_endpoints(self):
        self.lua.execute(b'''
            local calls={}
            local K={json=function(config,path)
                calls[#calls+1]=path
                if path:find('/series?') then return {content={{id='S1',metadata={title='Series'},unused=function() end}},totalPages=4} end
                if path:find('/collections?') then return {content={{id='C',name='Collection',unused=function() end}}} end
                if path=='/api/v1/libraries' then return {{id='L',name='Library',unused=function() end}} end
                if path=='/api/v1/authors' then return {{name='Writer',role='writer',unused=function() end}} end
                return {'Value'}
            end}
            package.loaded.km_komga=K
            package.loaded['socket.url']={parse=function() return {scheme='https',host='server'} end}
            local C=require('km_catalog')
            local result=C.browse({komga_url='https://server/prefix'},{},2)
            assert(result.page==2 and result.pages==4 and result.items[1].url=='https://server/prefix/api/v1/series/S1')
            assert(calls[1]:find('page=1') and calls[1]:find('size=6'))
            local facets=C.options({})
            assert(#calls==7 and facets.libraries[1].id=='L' and facets.authors[1].role=='writer')
            local buffer=require('string.buffer')
            assert(buffer.encode(result) and buffer.encode(facets))
            local a={source='a',title='A',url='https://other/api/v1/series/A'}
            local b={source='b',title='B',url='https://server/prefix/api/v1/series/B'}
            assert(C.template({komga_url='https://server/prefix'},{mangas={a,b}})==b)
            assert(C.template({komga_url='https://server/prefix'},{mangas={a}})==a)
            assert(C.template({komga_url='https://server/prefix'},nil)==nil)
        ''')

    def test_manual_source_selection_preserves_full_int64(self):
        self.lua.execute(b'''
            local C=require('km_catalog')
            local P=require('km_proto')
            local function raw(bytes) return string.char(unpack(bytes)) end
            local high=raw({255,255,255,255,255,255,255,255,127})
            local negative=raw({255,255,255,255,255,255,255,255,255,1})
            assert(C.sourceId(high)=='9223372036854775807')
            assert(C.sourceId(negative)=='-1')
            local m={source=high,title='Phone comic',url='/series/S1'}
            local shelf={mangas={m}}
            local config={komga_source_id='9223372036854775807',komga_url='https://server'}
            assert(C.template(config,shelf)==m)
            assert(C.template({komga_source_id='123'},shelf)==nil)
            assert(C.template(config,nil)==nil)
            package.loaded['ui/uimanager']={show=function() end,close=function() end}
            package.loaded['ui/network/manager']={}
            package.loaded['ui/trapper']={}
            package.loaded['ui/widget/infomessage']={new=function(_,v) return v end}
            local App={config={}}
            function App:reloadShelf() return shelf end
            function App:saveConfig() self.saved=true end
            package.loaded.km_app=App
            local owner={menu=function(self,title,items) self.items=items end}
            local L=require('km_library')
            L.sourceSettings(owner)
            assert(#owner.items==3 and owner.items[3].text:find('9223372036854775807'))
            owner.items[3].callback()
            assert(App.saved and App.config.komga_source_id=='9223372036854775807')
            assert(C.template(App.config,shelf)==m)
            owner.items[1].callback()
            assert(App.config.komga_source_id==nil)
            local input,dialog
            package.loaded['ui/widget/inputdialog']={new=function(_,v)
                dialog=v
                v.getInputText=function() return input end
                v.onShowKeyboard=function() end
                return v
            end}
            owner.items[2].callback()
            input=''
            dialog.buttons[1][2].callback()
            assert(App.config.komga_source_id==nil)
            input='123'
            dialog.buttons[1][2].callback()
            assert(App.config.komga_source_id==nil)
            input=' 9223372036854775807 '
            dialog.buttons[1][2].callback()
            assert(App.config.komga_source_id=='9223372036854775807')
        ''')

    for name, fn in list(locals().items()):
        if name.startswith('test_'):
            setattr(Checks, name, fn)
