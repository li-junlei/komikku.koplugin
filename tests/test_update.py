"""Updater boundaries: untrusted release data, staged files, rollback and progress."""


def install(Checks):
    def test_update_versions_release_and_redirect_boundaries(self):
        self.lua.execute(b'''
            package.loaded['socket.url']={parse=function(s)
                local scheme,host=s:match('^(%w+)://([^/]+)')
                return {scheme=scheme,host=host}
            end}
            local calls={}
            local release={tag_name='v0.3.1',assets={{name='komikku-koplugin-0.3.1.zip',size=123,
                digest='sha256:'..string.rep('a',64),browser_download_url=
                'https://github.com/li-junlei/komikku.koplugin/releases/download/v0.3.1/komikku-koplugin-0.3.1.zip'}}}
            package.loaded.json={decode=function() return release end}
            package.loaded.km_http={request=function(_,service,method,address,_,headers,destination)
                assert(service=='github' and method=='GET' and headers.Authorization==nil)
                calls[#calls+1]=address
                if address:find('/releases/latest/download/update.json',1,true) then return '{}',200,{} end
                if address:find('github.com/',1,true) then
                    return 0,302,{location='https://release-assets.githubusercontent.com/file?signature=abc'}
                end
                return 123,200,{}
            end}
            local U=require('km_update')
            assert(U.newer('v0.10.0','0.3.0') and not U.newer('0.3.0','0.3.0'))
            assert(not U.newer('0.2.99','0.3.0') and not pcall(U.newer,'v1.0.0-beta','0.3.0'))
            local result=U.check({},'0.3.0')
            assert(result.available and result.size==123 and result.sha256==string.rep('a',64))
            assert(U.get({},result.url,'/tmp/update.zip')==123 and #calls==3)
            assert(not pcall(U.get,{},'https://evil.example/package.zip'))
            assert(not pcall(U.get,{},'http://github.com/package.zip'))
            release.assets[1].digest=nil
            assert(not pcall(U.check,{},'0.3.0'))
            release.tag_name='v0.3.0'
            assert(not U.check({},'0.3.0').available)
        ''')

    def test_update_stage_validates_checksum_paths_and_dependencies(self):
        self.lua.execute(b'''
            local files,dirs={},{}
            package.loaded.km_files={read=function(p) return files[p] end,write=function(p,v) files[p]=v end}
            package.loaded['libs/libkoreader-lfs']={symlinkattributes=function(p,k)
                if dirs[p] then return k and 'directory' or {mode='directory'} end
            end}
            package.loaded.util={makePath=function(p) dirs[p]=true end}
            package.loaded['ffi/util']={purgeDir=function(p)
                for k in pairs(files) do if k:sub(1,#p+1)==p..'/' then files[k]=nil end end
                dirs[p]=nil;return true
            end}
            package.loaded['ffi/sha2']={sha256=function(s) assert(s=='zip');return 'hash' end}
            local content,entries
            local function set(entries_)
                entries=entries_;content={}
                for _,e in ipairs(entries) do
                    e.mode=e.mode or 'file';e.size=e.size or #e.bytes;content[e.path]=e.bytes
                end
            end
            package.loaded['ffi/archiver']={Reader={new=function()
                return {open=function() return true end,close=function() end,
                    iterate=function() local i=0;return function() i=i+1;return entries[i] end end,
                    extractToMemory=function(_,key) return content[key] end}
            end}}
            local U=require('km_update')
            U.get=function(_,url,zip) files[zip]='zip';return 3 end
            local release={url='github',size=3,sha256='hash',version='0.3.0'}
            local function entry(name,bytes,mode) return {path='komikku.koplugin/'..name,bytes=bytes,mode=mode} end
            local good={entry('main.lua','return {}'),entry('_meta.lua','return {version="0.3.0"}'),
                entry('km_update.lua','return {}')}
            set(good)
            assert(U.stage({},release,'/zip','/plugins/komikku.koplugin'))
            assert(files['/plugins/komikku.koplugin.update/main.lua']=='return {}')
            release.sha256='bad';assert(not pcall(U.stage,{},release,'/zip','/plugins/komikku.koplugin'))
            release.sha256='hash'
            for _,bad in ipairs({entry('../escape.lua','return {}'),entry('main.lua','return {}','link'),
                entry('extra.lua','invalid lua !!!'),entry('extra.lua','return require("km_missing")')}) do
                local fixture={good[1],good[2],good[3],bad};set(fixture)
                assert(not pcall(U.stage,{},release,'/zip','/plugins/komikku.koplugin'))
                assert(not dirs['/plugins/komikku.koplugin.update'])
            end
            set({good[1],good[2]})
            assert(not pcall(U.stage,{},release,'/zip','/plugins/komikku.koplugin'))
        ''')

    def test_update_install_rollback_preserves_old_plugin(self):
        self.lua.execute(b'''
            local dirs={['/plugins/komikku.koplugin']='old',['/plugins/komikku.koplugin.update']='new'}
            package.loaded.km_files={read=function(p) return p:find('.update/',1,true) and 'data' end}
            package.loaded['libs/libkoreader-lfs']={symlinkattributes=function(p,k)
                return dirs[p] and (k and 'directory' or {mode='directory'})
            end}
            package.loaded['ffi/util']={purgeDir=function(p) dirs[p]=nil;return true end,fsyncDirectory=function() end}
            local U=require('km_update')
            local fail=true
            os.rename=function(a,b)
                if fail and a:match('%.update$') then return nil end
                if not dirs[a] or dirs[b] then return nil end
                dirs[b]=dirs[a];dirs[a]=nil;return true
            end
            assert(not pcall(U.install,'/plugins/komikku.koplugin'))
            assert(dirs['/plugins/komikku.koplugin']=='old')
            fail=false;U.install('/plugins/komikku.koplugin')
            assert(dirs['/plugins/komikku.koplugin']=='new' and dirs['/plugins/komikku.koplugin.previous']=='old')
            assert(not pcall(U.paths,'/unrelated/path'))
        ''')

    def test_update_progress_success_cancel_and_failure(self):
        self.lua.execute(b'''
            local App={root='/data',config={}}
            package.loaded.km_app=App
            local scheduled,dialog,messages,size,installed
            local UI={show=function(_,w) if w.text then messages[#messages+1]=w.text end end,
                close=function(_,w) if w.onCloseWidget then w:onCloseWidget() end end,
                scheduleIn=function(_,_,fn) scheduled=fn end,unschedule=function(_,fn) assert(fn==scheduled);scheduled=nil end,
                setDirty=function() end}
            package.loaded['ui/uimanager']=UI
            local simple={new=function(_,v) return v end}
            package.loaded['ui/widget/infomessage']=simple;package.loaded['ui/widget/confirmbox']=simple
            local Progress={}
            function Progress:new(o)
                local group={{},{setText=function(_,s) o.subtitle=s end},resetLayout=function() end}
                o[1]={group};o.progress_bar={setPercentage=function(_,p) o.percent=p end}
                setmetatable(o,{__index=self});dialog=o;return o
            end
            function Progress:show() end
            function Progress:close() self:onCloseWidget() end
            function Progress:onCloseWidget() if self.dismiss_callback then self.dismiss_callback() end end
            package.loaded['ui/widget/progressbardialog']=Progress
            package.loaded['libs/libkoreader-lfs']={attributes=function() return size end}
            local U=require('km_update')
            U.clean=function() end
            U.install=function() installed=true end
            for _,mode in ipairs({'success','cancel','failure'}) do
                scheduled=nil;messages={};size=0;installed=false
                local worker=function(task,d)
                    size=50;scheduled();assert(d.percent==0.5 and d.subtitle:find('50%%'))
                    if mode=='cancel' then d:close();return nil end
                    if mode=='failure' then error('download failed') end
                    size=100;scheduled();assert(d.percent==1);return true
                end
                U.download({path='/plugins/komikku.koplugin'},worker,{size=100,version='0.3.1'})
                assert(not App.updating and not scheduled)
                assert(installed==(mode=='success'))
                assert(#messages==(mode=='cancel' and 0 or 1))
            end
        ''')

    for name, fn in list(locals().items()):
        if name.startswith('test_'):
            setattr(Checks, name, fn)
