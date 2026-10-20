local N = {}

function N.install(ui, document)
    if not document or not document.is_komikku or ui._komikku_navigation then return end
    ui._komikku_navigation = true
    local show_file_manager = ui.showFileManager
    local comic_file = document.file
    function ui:showFileManager(file, selected_files)
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
