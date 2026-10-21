from pathlib import Path
import sqlite3
import tempfile
from contextlib import closing


def install(Checks):
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
