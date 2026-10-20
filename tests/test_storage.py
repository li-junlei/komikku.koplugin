def install(Checks):
    def test_cache_limit_uses_read_order_preserves_offline_and_current(self):
        self.lua.execute(b'''
            local files={}
            local function add(p,size,bytes,mode,time)
                files[p]={size=size or 0,bytes=bytes,mode=mode or 'file',modification=time or 999}
            end
            local function attrs(p,k) local a=files[p];if a then return k and a[k] or a end end
            local function dir(p)
                local names={'.','..'}
                for path in pairs(files) do
                    if path:sub(1,#p+1)==p..'/' then
                        local name=path:sub(#p+2)
                        if not name:find('/',1,true) then names[#names+1]=name end
                    end
                end
                local i=0;return function() i=i+1;return names[i] end
            end
            package.loaded['libs/libkoreader-lfs']={attributes=attrs,dir=dir}
            package.loaded.util={makePath=function(p) add(p,0,nil,'directory') end}
            package.loaded.km_files={read=function(p) return files[p] and files[p].bytes end,
                write=function(p,bytes) add(p,#bytes,bytes) end}
            package.loaded.socket={gettime=function() return 500 end}
            os.remove=function(p) files[p]=nil;return true end
            local C=require('km_cache').new('/cache',{online_cache_limit_mb=4})
            for _,name in ipairs({'a','b','c','d'}) do
                add('/cache/'..name,0,nil,'directory')
                add('/cache/'..name..'/00001.png',2*1024*1024,'image')
            end
            add('/cache/a/read-order',3,'300');add('/cache/b/read-order',3,'100');add('/cache/c/read-order',3,'200')
            add('/cache/d/offline',1,'pinned')
            local entries=C:entries()
            assert(#entries==4 and entries[1].dir=='/cache/b' and entries[1].done==1)
            C.active_dir='/cache/c';C:evict('/cache/a')
            assert(not files['/cache/b/00001.png'])
            assert(files['/cache/a/00001.png'] and files['/cache/c/00001.png'] and files['/cache/d/00001.png'])
            C.config.online_cache_limit_mb=0;C:evict()
            assert(files['/cache/a/00001.png'])
            C.config.online_cache_limit_mb=1;C:evict()
            assert(not files['/cache/a/00001.png'] and files['/cache/c/00001.png'] and files['/cache/d/00001.png'])
            C:markRead('/cache/c');assert(tonumber(files['/cache/c/read-order'].bytes)==500)
            assert(not pcall(C.removeDir,C,'/cache/../other'))
        ''')

    def test_storage_groups_deletion_protection_and_limit_settings(self):
        self.lua.execute('''
            local online={dir='/cache/a',bytes=1024,done=1,offline=false,
                manifest={title='Online',pages={{},{}}}}
            local pinned={dir='/cache/b',bytes=2048,done=2,offline=true,
                manifest={title='Offline',pages={{},{}}}}
            local entries={online,pinned};local deleted={}
            local App={config={},cache={}}
            function App.cache:entries() return entries end
            function App.cache:isOffline() return true end
            function App.cache:removeDir(dir)
                deleted[#deleted+1]=dir
                for i,e in ipairs(entries) do if e.dir==dir then table.remove(entries,i);break end end
            end
            function App.cache:evict(protected) self.protected=protected end
            function App:saveConfig() self.saved=true end
            function App:find() return nil end
            package.loaded.km_app=App
            local dialog
            package.loaded['ui/uimanager']={show=function(_,v) dialog=v end,close=function() end}
            local plain={new=function(_,v) return v end}
            package.loaded['ui/widget/infomessage']=plain;package.loaded['ui/widget/confirmbox']=plain
            local doc={is_komikku=true,is_open=true,km_dir='/cache/a'}
            package.loaded['apps/reader/readerui']={instance={document=doc}}
            local owner={menu=function(self,title,items) self.items=items;self.title=title end}
            local S=require('km_storage')
            S.show(owner);assert(#owner.items==4 and owner.items[1].text=='手动离线下载')
            owner.items[2].callback();assert(#owner.items==1 and owner.items[1].mandatory:find('1 / 2'))
            owner.items[1].callback();owner.items[3].callback()
            assert(dialog.text and not dialog.ok_callback and #deleted==0)
            doc.is_open=false;owner.items[3].callback()
            assert(dialog.ok_callback);dialog.ok_callback()
            assert(deleted[1]=='/cache/a' and #entries==1)
            entries={online,pinned};S.show(owner);owner.items[4].callback();dialog.ok_callback()
            assert(#entries==1 and entries[1].offline)
            local input
            package.loaded['ui/widget/inputdialog']={new=function(_,v)
                v.getInputText=function() return input end;v.onShowKeyboard=function() end;return v
            end}
            S.limit(owner);local form=dialog
            input='-1';form.buttons[1][2].callback();assert(not App.saved)
            input='5000';form.buttons[1][2].callback();assert(not App.saved)
            input='0';form.buttons[1][2].callback();assert(App.saved and App.config.online_cache_limit_mb==0)
        '''.encode())

    for name, fn in list(locals().items()):
        if name.startswith('test_'):
            setattr(Checks, name, fn)
