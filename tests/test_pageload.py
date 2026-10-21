def install(Checks):
    def test_page_wait_reuses_prefetch_reports_progress_and_cancels(self):
        self.lua.execute('''
            local scheduled,dialog,messages={},nil,{}
            local UI={scheduleIn=function(_,_,fn) scheduled[fn]=true end,
                unschedule=function(_,fn) scheduled[fn]=nil end,setDirty=function() end,
                show=function(_,v) if v.text then messages[#messages+1]=v.text end end}
            package.loaded['ui/uimanager']=UI
            package.loaded['ui/widget/infomessage']={new=function(_,v) return v end}
            package.loaded['ui/event']={new=function(_,name) return name end}
            local Progress={}
            function Progress:new(o)
                o[1]={{{},{setText=function(_,s) o.subtitle=s end},resetLayout=function() end}}
                o.progress_bar={setPercentage=function(_,p) o.percent=p end}
                setmetatable(o,{__index=self});dialog=o;return o
            end
            function Progress:show() self.shown=true end
            function Progress:close() self:onCloseWidget() end
            function Progress:onCloseWidget() end
            package.loaded['ui/widget/progressbardialog']=Progress
            local files,starts,stops={},0,0
            local bytes,total=25,100
            local cache={pid=42,prefetch_dir='/cache/a',prefetch_pages={[2]=true,[3]=true},prefetch_order={2,3}}
            function cache:hasPage(dir,n) return files[n] end
            function cache:pageProgress(dir,n) return bytes,total,files[n] end
            function cache:startPages(m,dir,pages)
                starts=starts+1;assert(pages[1]==2 and pages[2]==4)
                self.pid=43;return true
            end
            function cache:stopPrefetch() stops=stops+1;self.pid=nil end
            package.loaded.km_app={cache=cache}
            local page,redraws=2,0
            local doc={is_open=true,km_dir='/cache/a',mod_time='original',km_original_mod_time='original',
                km_manifest={pages={{},{},{},{}}}}
            local owner={document=doc,ui={getCurrentPage=function() return page end,
                handleEvent=function(_,event) assert(event=='RedrawCurrentPage');redraws=redraws+1 end}}
            local P=require('km_pageload')
            P.start(owner);assert(starts==0 and dialog.shown and dialog.percent==0.25)
            local tick;for fn in pairs(scheduled) do tick=fn end
            bytes=50;tick();assert(dialog.percent==0.5 and dialog.subtitle:find('50%%'))
            P.start(owner);assert(starts==0 and owner.page_wait)
            dialog:close();assert(not owner.page_wait and stops==1 and owner.blocked_page==2 and redraws==1)
            P.start(owner);assert(starts==0)
            page=3;files[3]=true;assert(P.start(owner))
            page=2;bytes=12;total=nil
            P.start(owner);assert(starts==1 and dialog.subtitle:find('未提供总大小'))
            tick=nil;for fn in pairs(scheduled) do tick=fn end
            files[2]=true;tick()
            assert(not owner.page_wait and stops==1 and redraws==2 and doc.mod_time~='original')
            assert(#messages==0)
            assert(P.start(owner)==true)
        '''.encode())

    def test_page_wait_failure_and_reader_close_release_jobs(self):
        self.lua.execute(b'''
            local scheduled,dialog,message
            package.loaded['ui/event']={new=function(_,name) return name end}
            package.loaded['ui/uimanager']={scheduleIn=function(_,_,fn) scheduled=fn end,
                unschedule=function(_,fn) assert(fn==scheduled);scheduled=nil end,
                setDirty=function() end,show=function(_,v) message=v.text end}
            package.loaded['ui/widget/infomessage']={new=function(_,v) return v end}
            local Progress={}
            function Progress:new(o)
                o[1]={{{},{setText=function() end},resetLayout=function() end}}
                o.progress_bar={setPercentage=function() end};setmetatable(o,{__index=self});dialog=o;return o
            end
            function Progress:show() end
            function Progress:close() self:onCloseWidget() end
            function Progress:onCloseWidget() end
            package.loaded['ui/widget/progressbardialog']=Progress
            local cache={}
            function cache:hasPage() return false end
            function cache:pageProgress() return 100,200,false end
            function cache:startPages() self.pid=77;return true end
            function cache:stopPrefetch() self.pid=nil end
            package.loaded.km_app={cache=cache}
            local doc={is_open=true,mod_time='original',km_dir='/cache/a',km_manifest={pages={{}}}}
            local owner={document=doc,ui={getCurrentPage=function() return 1 end,handleEvent=function() end}}
            local P=require('km_pageload')
            P.start(owner);assert(owner.page_wait and scheduled)
            cache.pid=nil;scheduled()
            assert(not owner.page_wait and not scheduled and message and owner.blocked_page==1)
            owner.blocked_page=nil;message=nil
            P.start(owner);doc.is_open=false;scheduled()
            assert(not owner.page_wait and not scheduled and not cache.pid and not message)
            doc.is_open=true
            function cache:startPages() return nil end
            P.start(owner);assert(not owner.page_wait and message)
        ''')

    def test_page_download_keeps_jpeg_and_png_and_reports_content_length(self):
        self.lua.execute(b'''
            local writes,calls={},{}
            package.loaded.km_files={write=function(path,value) writes[path]=value end}
            package.loaded['socket.url']={parse=function() return {scheme='https',host='server'} end}
            local H=require('km_http')
            H.request=function(config,service,method,url,body,headers,path,on_headers)
                calls[#calls+1]=url
                on_headers(200,{['content-length']='10485760'})
                assert(writes[path..'.total']=='10485760')
                return 10485760,200,{}
            end
            local K=require('km_komga')
            local config={komga_url='https://server'}
            K.downloadPage(config,'/api/v1/books/B',{number=1,mediaType='image/jpeg'},'/not-a-file')
            K.downloadPage(config,'/api/v1/books/B',{number=2,mediaType='image/png'},'/not-a-file')
            K.downloadPage(config,'/api/v1/books/B',{number=3,mediaType='image/avif'},'/not-a-file')
            assert(calls[1]=='https://server/api/v1/books/B/pages/1')
            assert(calls[2]=='https://server/api/v1/books/B/pages/2')
            assert(calls[3]=='https://server/api/v1/books/B/pages/3?convert=png')
        ''')

    def test_prefetch_starts_without_network_on_ui_and_tracks_partial_page(self):
        self.lua.execute(b'''
            local files,child,poll={},nil,nil
            package.loaded['libs/libkoreader-lfs']={attributes=function(p,k) return files[p] end}
            package.loaded.util={makePath=function() end}
            package.loaded.km_files={read=function(p) if p:match('%.total$') then return '10240' end end}
            package.loaded['ui/uimanager']={preventStandby=function() end,allowStandby=function() end,
                scheduleIn=function(_,_,fn) poll=fn end,unschedule=function() end}
            local finished=false
            package.loaded['ffi/util']={runInSubProcess=function(fn) child=fn;return 42 end,
                isSubProcessDone=function() return finished end}
            local calls=0
            package.loaded.km_komga={downloadPage=function(_,_,page,path)
                calls=calls+1;files[path]=10240
            end}
            os.rename=function(a,b) files[b]=files[a];files[a]=nil;return true end
            local C=require('km_cache').new('/cache',{})
            C.evict=function() end
            assert(C:startPages({address='book',pages={{number=1},{number=2},{number=3}}},'/cache/a',{2,3}))
            assert(calls==0 and C.pid==42 and C.prefetch_pages[2] and C.prefetch_pages[3])
            files['/cache/a/00002.png.prefetch-42.part']=5120
            local bytes,total,complete=C:pageProgress('/cache/a',2)
            assert(bytes==5120 and total==10240 and not complete)
            child(42)
            assert(calls==2)
            bytes,total,complete=C:pageProgress('/cache/a',2)
            assert(bytes==10240 and total==10240 and complete)
            finished=true;poll();assert(C.pid==nil and C.prefetch_pages==nil)
        ''')

    for name, fn in list(locals().items()):
        if name.startswith('test_'):
            setattr(Checks, name, fn)
