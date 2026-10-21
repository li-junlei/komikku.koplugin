from pathlib import Path
import sqlite3
import tempfile
from contextlib import closing


def install(Checks):
    def test_statistics_exclusion_survives_consumed_settings_event(self):
        root = Path(__file__).resolve().parents[1]
        reference = root / '.reference/koreader-2026.07.2'
        # Use KOReader's real event propagation, consuming plugin and statistics handlers.
        sources = [root / 'main.lua', reference / 'plugins/docsettingtweak.koplugin/main.lua',
                   reference / 'plugins/statistics.koplugin/main.lua']
        import re
        modules = set()
        for source in sources:
            modules.update(re.findall(rb'require\("([^"]+)"\)', source.read_bytes()))
        native = {b'ui/widget/widget', b'ui/widget/container/widgetcontainer', b'ui/event'}
        for module in modules - native:
            self.lua.globals().package.loaded[module] = self.lua.table()
        self.lua.execute(b'''
            local reference=...
            table.pack=table.pack or function(...) return {n=select('#',...),...} end
            package.path=package.path..';'..reference..'/frontend/?.lua'
            package.loaded['ui/geometry']={}
            package.loaded.datastorage={getDataDir=function() return '/data' end,
                getSettingsDir=function() return '/settings' end}
            package.loaded.gettext=setmetatable({}, {__call=function(_,s) return s end})
            package.loaded['km_app']={init=function() end,find=function() end}
            package.loaded['km_navigation']={install=function() end}
            package.loaded['km_statistics']=nil
            package.loaded.logger={dbg=function() end}
            package.loaded['document/documentregistry']={known_providers={komikku=true}}
            local Plugin=assert(loadfile('main.lua'))()
            local Tweak=assert(loadfile(reference..'/plugins/docsettingtweak.koplugin/main.lua'))()
            local Stats=assert(loadfile(reference..'/plugins/statistics.koplugin/main.lua'))()
            local Container=require('ui/widget/container/widgetcontainer')
            local Event=require('ui/event')
            local settings={is_enabled=true,min_sec=0,max_sec=120}
            local config={readSetting=function(_,key,default) return default end}
            local opens=0
            package.loaded['lua-ljsqlite3/init'].open=function() opens=opens+1;error('Unexpected statistics DB access') end
            for _,stats_first in ipairs({true,false}) do
                local doc={is_komikku=true,km_manifest={}}
                local ui=Container:new{postInitCallback={},menu={registerToMainMenu=function() end}}
                function ui:registerPostInitCallback(f) table.insert(self.postInitCallback,f) end
                ui[1]=Tweak:extend{document=doc}
                local stats=Stats:extend{document=doc,settings=settings,is_doc=false,is_doc_not_frozen=false,
                    ui=ui,view={footer={maybeUpdateFooter=function() end}}}
                stats:resetVolatileStats()
                if stats_first then ui.statistics=stats;table.insert(ui,stats) end
                local plugin=Plugin:new{ui=ui,document=doc}
                table.insert(ui,plugin)
                if not stats_first then ui.statistics=stats;table.insert(ui,stats) end
                assert(ui:handleEvent(Event:new('DocSettingsLoad',config,doc))==true)
                assert(not stats._komikku_excluded) -- The consumed event cannot install our guard.
                assert(#ui.postInitCallback==1)
                for _,f in ipairs(ui.postInitCallback) do f() end
                assert(stats._komikku_excluded)
                stats:handleEvent(Event:new('ReaderReady',config))
                for page=1,60 do stats:handleEvent(Event:new('PageUpdate',page)) end
                for _,event in ipairs({'SaveSettings','Suspend','Resume','CloseDocument'}) do
                    stats:handleEvent(Event:new(event))
                end
                stats:initData();stats:getIdBookDB();stats:insertDB()
                assert(opens==0 and not stats.id_curr_book and next(stats.page_stat)==nil)
                assert(not stats:isEnabled() and not stats:isEnabledAndNotFrozen())
            end
            local created,writes=0,0
            local novel=Stats:extend{document={},settings=settings,view={footer={maybeUpdateFooter=function() end}},
                initData=function(self) self.is_doc=true;self.is_doc_not_frozen=true;created=created+1 end,
                insertDB=function() writes=writes+1 end}
            require('km_statistics').exclude({statistics=novel},novel.document)
            novel:resetVolatileStats()
            novel:handleEvent(Event:new('ReaderReady',config))
            novel:handleEvent(Event:new('CloseDocument'))
            assert(created==1 and writes==1 and settings.is_enabled)
        ''', reference.as_posix().encode())

    def test_statistics_exclusion_is_instance_only(self):
        self.lua.execute(b'''
            local writes,created=0,0
            local settings={is_enabled=true}
            local base={settings=settings,is_doc=false,is_doc_not_frozen=false}
            function base:initData() self.is_doc=true;self.is_doc_not_frozen=true;created=created+1 end
            function base:onReaderReady() self:initData() end
            function base:isEnabled() return self.is_doc and self.settings.is_enabled end
            function base:isEnabledAndNotFrozen() return self.is_doc_not_frozen and self.settings.is_enabled end
            function base:insertDB() if self:isEnabled() then writes=writes+1 end end
            local comic=setmetatable({}, {__index=base})
            local novel=setmetatable({}, {__index=base})
            local S=require('km_statistics')
            S.exclude({statistics=comic},{is_komikku=true})
            comic:onReaderReady();comic:initData();comic:insertDB()
            assert(not comic:isEnabled() and not comic:isEnabledAndNotFrozen() and created==0 and writes==0)
            assert(settings.is_enabled and base.initData~=comic.initData)
            S.exclude({statistics=novel},{is_komikku=false})
            novel:onReaderReady();novel:insertDB();assert(created==1 and writes==1)
            S.exclude({},{is_komikku=true})
        ''')

    def test_history_and_collection_record_isolation(self):
        self.lua.execute(b'''
            local flushes,updates=0,0
            local history={hist={}}
            function history:_flush() flushes=flushes+1 end
            function history:_read()
                self.hist={{file='/cache/chapters/aa/chapter.kmk'},
                    {file='/cache/chapters-other/book.epub',time=12},{file='/books/novel.epub',time=11}}
                return true
            end
            function history:addItem() end
            function history:updateLastBookTime() end
            local collection={updateLastBookTime=function() updates=updates+1 end}
            package.loaded.readhistory=history;package.loaded.readcollection=collection
            package.loaded['ffi/util']={realpath=function(s) return s end}
            require('km_history').install('/cache/chapters')
            history:_read()
            assert(#history.hist==2 and flushes==1 and history.hist[1].time==12 and history.hist[2].time==11)
            collection:updateLastBookTime('/cache/chapters/aa/chapter.kmk')
            collection:updateLastBookTime('/books/novel.epub');assert(updates==1)
        ''')

    def test_cleanup_real_sqlite_backup_and_rollback(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1] / 'dist') as tmp:
                folder = Path(tmp)
                path = folder / 'statistics.sqlite3'
                with closing(sqlite3.connect(path)) as db:
                    db.executescript('''CREATE TABLE book(id INTEGER PRIMARY KEY, md5 TEXT, title TEXT);
                        CREATE TABLE page_stat_data(id_book INTEGER, duration INTEGER);
                        INSERT INTO book VALUES(1, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'Same title'),
                            (2, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'Same title'),
                            (3, 'cccccccccccccccccccccccccccccccc', 'Unknown old entry');
                        INSERT INTO page_stat_data VALUES(1, 30),(2, 60),(3, 90);''')
                    if fail:
                        db.execute("CREATE TRIGGER refuse BEFORE DELETE ON book WHEN OLD.id=1 BEGIN SELECT RAISE(ABORT, 'refuse'); END")
                    db.commit()
                opened = {}

                def open_db(name):
                    opened[name] = sqlite3.connect(name.decode(), isolation_level=None)
                    return name

                def execute(name, sql, args):
                    cur = opened[name].execute(sql.decode(), tuple(v.decode() if isinstance(v, bytes) else v for v in args.values()))
                    row = cur.fetchone()
                    cur.close()
                    return self.lua.table_from(row) if row else None

                def close(name):
                    opened.pop(name).close()

                for name, value in ((b'open_db', open_db), (b'execute_sql', execute), (b'close_db', close),
                                    (b'folder', folder.as_posix().encode()), (b'should_fail', fail)):
                    self.lua.globals()[name] = value
                self.lua.execute(b'''
                    package.loaded.datastorage={getSettingsDir=function() return folder end}
                    package.loaded['libs/libkoreader-lfs']={attributes=function(p,k)
                        if p:find('statistics.sqlite3',1,true) then return true end
                        if p=='/cache/aa' then return k and 'directory' or {} end
                    end,dir=function() local i=0;local v={'.','..','aa'};return function() i=i+1;return v[i] end end}
                    package.loaded.docsettings={open=function(_,p)
                        assert(p=='/cache/aa/chapter.kmk')
                        return {readSetting=function() return string.rep('a',32) end}
                    end}
                    package.loaded['lua-ljsqlite3/init']={open=function(path)
                        local key=open_db(path)
                        local conn={}
                        function conn:prepare(sql)
                            local args={}
                            local stmt={}
                            function stmt:reset() args={};return self end
                            function stmt:bind(...) args={...};return self end
                            function stmt:step() return execute_sql(key,sql,args) end
                            function stmt:close() end
                            return stmt
                        end
                        function conn:exec(sql) return execute_sql(key,sql,{}) end
                        function conn:close() close_db(key) end
                        return conn
                    end}
                    local ok,count,backup=pcall(require('km_statistics').clean,'/cache',folder)
                    assert(ok~=should_fail)
                    if ok then assert(count==1 and backup) end
                ''')
                self.assertFalse(opened)
                with closing(sqlite3.connect(path)) as db:
                    self.assertEqual(db.execute('SELECT id FROM book ORDER BY id').fetchall(),
                                     [(1,), (2,), (3,)] if fail else [(2,), (3,)])
                    self.assertEqual(db.execute('SELECT SUM(duration) FROM page_stat_data').fetchone()[0], 180 if fail else 150)
                backups = list(folder.glob('statistics-before-clean-*.sqlite3'))
                self.assertEqual(len(backups), 1)
                with closing(sqlite3.connect(backups[0])) as db:
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM book').fetchone()[0], 3)

    for name, fn in list(locals().items()):
        if name.startswith('test_'):
            setattr(Checks, name, fn)
