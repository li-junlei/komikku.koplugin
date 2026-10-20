local N = {}

function N.install(ui, document, owner)
    if not document or not document.is_komikku or ui._komikku_navigation then return end
    ui._komikku_navigation = true
    if owner and ui.toc then
        local show_toc = ui.toc.onShowToc
        function ui.toc:onShowToc(...)
            if ui.document == document and document.is_open then owner:readerContents(); return true end
            return show_toc(self, ...)
        end
    end
    local show_file_manager = ui.showFileManager
    local comic_file = document.file
    function ui:showFileManager(file, selected_files)
        if self.document == document and document.is_open then self:onClose() end
        if file ~= comic_file or selected_files
                or G_reader_settings:readSetting("start_with") ~= "bookshelf" then
            return show_file_manager(self, file, selected_files)
        end
        -- Restore the normal browser location underneath Bookshelf, not the chapter cache.
        show_file_manager(self, nil)
        local fm = require("apps/filemanager/filemanager").instance
        local bookshelf = fm and fm.bookshelf
        if bookshelf and type(bookshelf.show) == "function" then
            -- Recent Bookshelf versions keep their widget underneath the reader/browser.
            if type(bookshelf._raiseInPlace) == "function" then bookshelf:_raiseInPlace() end
            bookshelf:show()
        end
    end
end

return N
