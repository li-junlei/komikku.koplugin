"""One bookshelf, with optional Komikku-compatible WebDAV exchange."""


def install(Checks):
    def setup(self):
        self.lua.execute(b'''
            files={}
            package.loaded['ffi/util']={orderedPairs=pairs}
            package.loaded['socket.url']={parse=function(url)
                local scheme,host,path=url:match('^(https)://([^/]+)(.*)$')
                return scheme and {scheme=scheme,host=host,path=path} or nil
            end}
            package.loaded.km_files={read=function(p) return files[p] end,write=function(p,b) files[p]=b end}
            package.loaded.datastorage={getFullDataDir=function() return '/data' end,
                getSettingsDir=function() return '/settings' end}
            package.loaded.util={makePath=function() end}
            package.loaded.km_history={install=function() end}
            package.loaded.km_cache={new=function() return {hasPage=function() return true end,
                stopPrefetch=function() end} end}
            package.loaded.dump=assert(loadfile('.reference/koreader-2026.07.2/frontend/dump.lua'))()
            config={komga_url='https://server',komga_user='user'}
            package.loaded.luasettings={open=function(_,path)
                return {file=path,data=files[path] and assert(loadstring(files[path]))()
                    or (path=='/settings/komikku.lua' and config or {})}
            end}
            App=require('km_app');App:init()
            C=require('km_catalog');P=require('km_proto');S=require('km_sync')
            function candidate(id,template)
                return C.build(config,template or C.defaultTemplate(config),{kind='series',id=id,title=id},
                    {metadata={title=id}},{{id=id..'BOOK',media={},metadata={number='1',title='Chapter'}}})
            end
            function worker(f) return f() end
        ''')

    def test_standalone_restart_categories_progress_and_remove_without_webdav(self):
        setup(self)
        self.lua.execute(b'''
            assert(#App:reloadShelf().mangas==0)
            local m=candidate('ONE')
            assert(C.sourceId(m.source)=='4508733312114627536')
            App:remember(m)
            local order=App:addCategory('Favorites')
            assert(App:addToShelf(m,order))
            local c=m.chapters[1]
            App:record(m,c,4,10,'/cache')
            local key=S.progressKey(m,c)
            assert(App:find(m.key).favorite and App.state.pending[key].page==3)
            package.loaded.km_app=nil
            App=require('km_app');App:init()
            local fresh,chapter=App:find(m.key,c.key)
            assert(fresh.favorite and fresh.categories[1]==order)
            assert(App:current(fresh,chapter).page==3 and App.state.last.manga==m.key)
            App:setFavorite(fresh,false)
            assert(not App:find(m.key).favorite and App:current(fresh,chapter).page==3)
            App:record(App:find(m.key),chapter,6,10,'/cache')
            App:addToShelf(App:find(m.key),-1)
            assert(App:find(m.key).favorite and #App:find(m.key).categories==0)
            App:record(App:find(m.key),chapter,7,10,'/cache')
            assert(App.state.pending[key].version==3 and App.state.pending[key].page==6)
            local new=candidate('ONE')
            new.chapters[1].fields=P.setint(new.chapters[1].fields,12,0)
            App:remember(new)
            assert(#App:reloadShelf().mangas==1 and App:find(m.key).favorite)
            assert(App:current(App:find(m.key),App:find(m.key).chapters[1]).page==6)
        ''')

    def test_first_sync_creates_backup_and_second_client_reads_same_shelf(self):
        setup(self)
        self.lua.execute(b'''
            local m=candidate('ONE');App:remember(m);App:addToShelf(m,App:addCategory('Mine'))
            App:record(m,m.chapters[1],5,10,'/cache')
            local H=require('km_http')
            config.webdav_url='https://dav';config.webdav_folder=''
            local remote,puts=nil,0
            H.request=function(_,service,method,url,body,headers)
                assert(service=='webdav')
                if method=='GET' then return remote,remote and 200 or 404,{etag='"v1"'} end
                assert(headers[remote and 'If-Match' or 'If-None-Match']==(remote and '"v1"' or '*'))
                remote=body;puts=puts+1;return '',204,{}
            end
            App:sync(worker)
            assert(puts==1 and next(App.state.pending)==nil and next(App.state.shelf_changes)==nil)
            local saved=S.decode(remote)
            assert(saved.mangas[1].favorite and saved.mangas[1].chapters[1].page==4)
            App:sync(worker);assert(puts==1)
            -- Another KOReader starts empty, downloads the same shelf, then removes the favorite.
            files={};package.loaded.km_app=nil;App=require('km_app');App:init()
            App:sync(worker)
            local downloaded=App:reloadShelf().mangas[1]
            assert(downloaded.favorite and downloaded.chapters[1].page==4 and #App.shelf.categories==1)
            App:setFavorite(downloaded,false);App:sync(worker)
            assert(not S.decode(remote).mangas[1].favorite)
            App:sync(worker);assert(not App:find(downloaded.key).favorite)
        ''')

    def test_phone_source_rebinding_keeps_other_sources_and_old_resume(self):
        setup(self)
        self.lua.execute(b'''
            local local_m=candidate('ONE');App:remember(local_m);App:addToShelf(local_m,-1)
            local local_c=local_m.chapters[1];App:record(local_m,local_c,6,10,'/cache')
            local phone=candidate('ONE',{source=C.sourceBytes('8074481155021144106'),url='https://old/api/v1/series/'})
            local fields=P.setint(phone.fields,100,1)
            local chapters={}
            for i,f in ipairs(fields) do
                if f.id==16 then fields[i]={id=16,wire=2,value=P.encode(P.set(P.parse(f.value),2,2,'Phone chapter name'))} end
            end
            local other=P.set(fields,1,0,C.sourceBytes('123'))
            other=P.set(other,2,2,'https://other-source/manga/OTHER')
            local opaque={id=1700,wire=2,value='unknown top-level data'}
            local remote=P.encode({{id=1,wire=2,value=P.encode(fields)},
                {id=1,wire=2,value=P.encode(other)},opaque})
            local other_bytes=P.encode(other)
            local H=require('km_http');config.webdav_url='https://dav'
            H.request=function(_,_,method,_,body)
                if method=='GET' then return remote,200,{etag='"v"'} end
                remote=body;return '',204,{}
            end
            App:sync(worker)
            local m,c=App:find(local_m.key,local_c.key)
            assert(m and c and m.source==phone.source and c.name=='Phone chapter name' and c.page==5)
            assert(App:find(App.state.last.manga,App.state.last.chapter))
            assert(App.state.cache_addresses[c.url]==local_c.url)
            assert(#App.shelf.mangas==1 and #S.decode(remote).mangas==2)
            assert(P.encode(S.decode(remote).mangas[2].fields)==other_bytes)
            assert(P.get(S.decode(remote).fields,1700)=='unknown top-level data')
            local before=remote;App:sync(worker);assert(before==remote)
        ''')

    def test_sync_failures_keep_book_favorite_and_queues(self):
        for code, etag, put in ((500, '"v"', 204), (200, None, 204), (200, 'W/"v"', 204),
                                (200, '"v"', 412), (200, '"v"', 500), (404, None, 412)):
            with self.subTest(code=code, etag=etag, put=put):
                # Each case starts with a fresh Lua state.
                self.setUp()
                setup(self)
                self.lua.globals()[b'status_get']=code
                self.lua.globals()[b'header_etag']=etag.encode() if etag else None
                self.lua.globals()[b'status_put']=put
                self.lua.execute(b'''
                    local m=candidate('ONE');App:remember(m);App:addToShelf(m,-1)
                    App:record(m,m.chapters[1],4,10,'/cache')
                    local before=files['/data/komikku/shelf.proto']
                    config.webdav_url='https://dav'
                    require('km_http').request=function(_,_,method)
                        if method=='GET' then return '',status_get,{etag=header_etag} end
                        return '',status_put,{}
                    end
                    assert(not pcall(App.sync,App,worker))
                    assert(files['/data/komikku/shelf.proto']==before)
                    assert(App:find(m.key).favorite and next(App.state.pending) and next(App.state.shelf_changes))
                ''')

    def test_source_id_encoding_rejects_overflow_and_preserves_signed_ids(self):
        self.lua.execute(b'''
            local C=require('km_catalog')
            for _,id in ipairs({'4508733312114627536','8074481155021144106','9223372036854775807',
                    '-9223372036854775808','-1','0'}) do assert(C.sourceId(C.sourceBytes(id))==id) end
            for _,id in ipairs({'9223372036854775808','18446744073709551616','-0','01','abc',''}) do
                assert(not pcall(C.sourceBytes,id))
            end
        ''')

    def test_library_select_and_favorite_do_not_require_webdav_or_phone(self):
        setup(self)
        self.lua.execute(b'''
            local requests=0
            package.loaded['ui/network/manager']={runWhenConnected=function(_,f) requests=requests+1;f() end,
                isConnected=function() error('No sync configured: must not test sync connectivity') end}
            package.loaded['ui/trapper']={wrap=function(_,f) f() end}
            package.loaded['ui/uimanager']={show=function() end}
            package.loaded['ui/widget/infomessage']={new=function(_,v) return v end}
            package.loaded.km_komga.json=function(_,path)
                if path:find('/books?',1,true) then
                    return {content={{id='BOOK',media={},metadata={number='1',title='One'}}}}
                end
                return {metadata={title='My comic'}}
            end
            local owner={menu=function(self,title,items) self.items=items end,
                chapters=function(self,m) self.reading=m end}
            local L=require('km_library')
            L.select({owner=owner,worker=worker},{kind='series',id='ONE',title='One'})
            owner.items[1].callback()
            assert(owner.reading and #owner.reading.chapters==1)
            owner.items[2].callback();owner.items[1].callback()
            assert(App:reloadShelf().mangas[1].favorite and requests==1)
        ''')

    def test_sync_keeps_new_page_turns_made_while_request_is_running(self):
        setup(self)
        self.lua.execute(b'''
            local m=candidate('ONE');App:remember(m);App:addToShelf(m,-1)
            local c=m.chapters[1];App:record(m,c,2,10,'/cache')
            config.webdav_url='https://dav'
            local H=require('km_http');local remote=nil
            H.request=function(_,_,method,_,body)
                if method=='GET' then return remote,remote and 200 or 404,{etag='"v"'} end
                remote=body;return '',204,{}
            end
            App:sync(function(f)
                local result=f()
                App:record(m,c,3,10,'/cache')
                return result
            end)
            local key=S.progressKey(m,c)
            assert(App.state.pending[key].page==2 and App.state.pending[key].version==2)
            App:sync(worker)
            assert(next(App.state.pending)==nil and S.decode(remote).mangas[1].chapters[1].page==2)
        ''')

    def test_remote_newer_favorite_and_progress_win_and_deleted_book_stays_out(self):
        setup(self)
        self.lua.execute(b'''
            local m=candidate('ONE');App:remember(m);App:addToShelf(m,-1)
            App:record(m,m.chapters[1],2,10,'/cache')
            local fields=P.setint(m.fields,109,50)
            for i,f in ipairs(fields) do
                if f.id==16 then
                    local cf=P.setint(P.parse(f.value),12,50)
                    cf=P.setint(cf,6,8)
                    fields[i]={id=16,wire=2,value=P.encode(cf)}
                end
            end
            local remote=P.encode({{id=1,wire=2,value=P.encode(fields)}})
            config.webdav_url='https://dav'
            require('km_http').request=function(_,_,method,_,body)
                if method=='GET' then return remote,200,{etag='"v"'} end
                remote=body;return '',204,{}
            end
            App:sync(worker)
            assert(not App:find(m.key).favorite and App:find(m.key).chapters[1].page==8)
            assert(next(App.state.shelf_changes)==nil and next(App.state.pending)==nil)
            remote='';App:sync(worker)
            assert(#App.shelf.mangas==0 and remote=='')
            local kept=App:find(m.key)
            assert(kept and not kept.favorite and kept.chapters[1].page==8)
        ''')

    def test_source_changes_before_first_sync_do_not_duplicate_favorites(self):
        setup(self)
        self.lua.execute(b'''
            local old=candidate('ONE');App:remember(old);App:addToShelf(old,-1)
            App:record(old,old.chapters[1],2,10,'/cache')
            config.komga_source_id='8074481155021144106'
            local m=candidate('ONE');App:remember(m);App:addToShelf(m,-1)
            App:record(m,m.chapters[1],3,10,'/cache')
            config.webdav_url='https://dav'
            local remote
            require('km_http').request=function(_,_,method,_,body)
                if method=='GET' then return remote,remote and 200 or 404,{etag='"v"'} end
                remote=body;return '',204,{}
            end
            App:sync(worker)
            assert(#S.decode(remote).mangas==1 and next(App.state.pending)==nil)
            assert(App:find(old.key).source==m.source and #App:allMangas()==1)
        ''')

    def test_download_manifest_reuses_cache_after_source_address_binding(self):
        setup(self)
        self.lua.execute(b'''
            package.loaded['libs/libkoreader-lfs']={}
            package.loaded['ffi/sha2']={md5=function(s) return s end}
            package.loaded.json={decode=function(v) return v end}
            package.loaded.km_cache=nil
            local cache=require('km_cache').new('/cache',config)
            local old='https://server/api/v1/books/BOOK'
            local new='https://old/api/v1/books/BOOK'
            cache.address_aliases={[new]=old}
            local dir=cache:directory(old)
            local manifest={address=old,pages={{number=1}}}
            files[dir..'/chapter.kmk']=manifest
            local result,path=cache:manifest(new)
            assert(result==manifest and path==dir and cache:directory(new)==dir)
        ''')

    def test_enabling_and_clearing_webdav_keeps_the_same_shelf_and_progress(self):
        setup(self)
        self.lua.execute(b'''
            local m=candidate('ONE');App:remember(m);App:addToShelf(m,-1)
            App:record(m,m.chapters[1],2,10,'/cache')
            local before=files['/data/komikku/shelf.proto']
            package.path=package.path..';.reference/koreader-2026.07.2/frontend/?.lua'
            package.loaded['ui/geometry']={}
            package.loaded['ui/uimanager']={show=function() end,close=function() end}
            package.loaded['ui/widget/infomessage']={new=function(_,v) return v end}
            package.loaded['ui/widget/menu']={}
            package.loaded['ui/trapper']={}
            package.loaded['ui/network/manager']={isConnected=function() return true end}
            package.loaded['document/documentregistry']={known_providers={komikku=true}}
            local values,dialog={'https://dav','user','password',''}
            package.loaded['ui/widget/multiinputdialog']={new=function(_,v)
                dialog=v;v.getFields=function() return values end;v.onShowKeyboard=function() end;return v
            end}
            local plugin=require('main'):new{ui={menu={registerToMainMenu=function() end}}}
            plugin:connectionSettings('webdav');dialog.buttons[1][2].callback()
            assert(config.webdav_url=='https://dav' and files['/data/komikku/shelf.proto']==before)
            assert(next(App.state.pending) and App:find(m.key).favorite)
            values={'','user','password',''}
            plugin:connectionSettings('webdav');dialog.buttons[1][2].callback()
            assert(config.webdav_url=='' and files['/data/komikku/shelf.proto']==before)
            assert(next(App.state.pending) and App:find(m.key).favorite)
            local opened=false
            plugin.shelf=function() opened=true end
            plugin.sync=function() error('No WebDAV: must not synchronize') end
            plugin:openShelf();assert(opened)
            plugin.chapter={};plugin:onNetworkConnected()
        ''')

    for name, fn in list(locals().items()):
        if name.startswith('test_'):
            setattr(Checks, name, fn)
