local M = {}

--- Strip leading and trailing whitespace from a string
-- @param s string The input string to trim
-- @return string The trimmed string
function M.trim(s)
    return s:match("^%s*(.-)%s*$")
end

--- Remove empty/whitespace-only elements from the beginning and end of a table
-- This function modifies the table in-place by removing empty strings or 
-- strings containing only whitespace from the start and end of the table.
-- @param tbl table The table to trim (modified in-place)
-- @return table The same table reference after trimming
function M.trim_table(tbl)
    local function is_whitespace(str) return str:match("^%s*$") ~= nil end

    while #tbl > 0 and (tbl[1] == "" or is_whitespace(tbl[1])) do
        table.remove(tbl, 1)
    end

    while #tbl > 0 and (tbl[#tbl] == "" or is_whitespace(tbl[#tbl])) do
        table.remove(tbl, #tbl)
    end

    return tbl
end

--- Move cursor to the end of the content in a Neovim window and focus it
-- Positions the cursor at the last character of the last line in the window's buffer,
-- then sets the window as the current (focused) window.
-- @param win_id integer|nil The window ID to move cursor to, or nil if invalid
function M.cursor_to_end(win_id)
    if win_id ~= nil and vim.api.nvim_win_is_valid(win_id) then
        -- Move the cursor to the last character in the response buffer
        local buf = vim.api.nvim_win_get_buf(win_id)
        local last_row = vim.api.nvim_buf_line_count(buf)
        local last_line = vim.api.nvim_buf_get_lines(buf, last_row - 1, last_row, false)[1] or ""
        local last_col = math.max(#last_line - 1, 0)
        vim.api.nvim_win_set_cursor(win_id, { last_row, last_col })
        -- Focus response window
        vim.api.nvim_set_current_win(win_id)
    end
end

return M
