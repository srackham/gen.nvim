local M = {}

--- Strip leading and trailing whitespace from a string
--- @param s string The input string to trim
--- @return string The trimmed string
function M.trim(s)
    return s:match("^%s*(.-)%s*$")
end

--- Unescapes escape sequences in a string
--- @param str string The string to unescape
--- @return string The unescaped string
function M.unescape(str)
    local map = {
        ["n"] = "\n",
        ["r"] = "\r",
        ["t"] = "\t",
        ["\\"] = "\\",
        ['"'] = '"',
        ["'"] = "'"
    }
    return str:gsub("\\(.)", function(char)
        return map[char] or char
    end)
end

--- Scheduled `vim.notify`.
function M.notify(...)
    vim.schedule_wrap(vim.notify)(...)
end

--- Display a message using vim's echo interface
--- Shows a message in the command line area with optional highlighting.
--- This function wraps vim.api.nvim_echo with simplified parameter handling.
--- @param msg string The message text to display
--- @param opts table|nil Optional configuration table forwarded to vim.api.nvim_echo
--- @param opts.hl_group string Highlight group name for the message (default: "Normal")
--- @param opts.history boolean Whether to save the message to command history (default: false)
--- @param opts.* any Additional options passed directly to vim.api.nvim_echo
--- @usage
--- M.message("Hello World")  -- displays with Normal highlight
--- M.message("Error occurred", {hl_group = "ErrorMsg"})  -- displays with ErrorMsg highlight
--- M.message("Command output", {history = true})  -- saves to command history
function M.message(msg, opts)
    opts = opts or {}
    -- Copy `opts` to `echo_opts` and delete non vim.api.nvim_echo options
    local echo_opts = vim.tbl_deep_extend("force", {}, opts)
    echo_opts.hl_group=nil
    echo_opts.history=nil
    vim.api.nvim_echo({{ msg, opts.hl_group or "Normal" }}, opts.history or false, echo_opts)
end

--- Display a notification message with an animated spinner
--- Creates a visual spinner animation that runs while processing occurs,
--- and returns a function to stop the animation and display a completion message.
--- The spinner uses Unicode braille characters for smooth animation.
--- @param message string The message to display alongside the spinner
--- @param opts table|nil Optional configuration table forwarded to M.message
--- @param opts.interval number Animation frame interval in milliseconds (default: 100)
--- @return function A stop function that halts the spinner and shows completion message
--- @usage
--- local stop_spinner = notify_with_spinner("Loading...", {interval = 50})
--- -- ... some async work ...
--- stop_spinner("Load complete!")
function M.notify_with_spinner(message, opts)
    opts = opts or {}
    local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
    local kill = false
    local interval = opts.interval or 100
    opts.interval = nil -- delete from opts because it is passed to M.message

    -- 1. Create the coroutine logic
    local co = coroutine.create(function()
        local i = 1
        while not kill do
            local frame = spinner_frames[i]
            M.message(frame .. " " .. message, opts)
            i = i % #spinner_frames + 1
            coroutine.yield()
        end
    end)

    -- 2. Define the animation loop
    local function run_animation()
        if coroutine.status(co) ~= "dead" then
            coroutine.resume(co)
            -- Adjust the 100ms for faster/slower rotation
            vim.defer_fn(run_animation, interval)
        end
    end

    -- Start the animation
    run_animation()

    -- 3. Return a "stop" function to kill the loop
    return function(done_message)
        kill = true
        M.message(done_message or "Done!", opts)
    end
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

--- Checks if the current Vim mode is Visual ('v' or 'V').
--- @return boolean true if in visual mode, false otherwise.
function M.is_visual_mode()
  return vim.fn.mode() == "v" or vim.fn.mode() == "V"
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

--- Synchronously select an item from a list using vim.ui.select
-- This function wraps the asynchronous vim.ui.select API to provide
-- a synchronous interface using coroutines.
-- @param items table: List of items to choose from
-- @param opts table|nil: Optional configuration options for the selector
-- @return any|nil: The selected item, or nil if selection was cancelled
-- @return number|nil: The index of the selected item, or nil if cancelled
-- @throws error if not called from within a coroutine
function M.ui_select_sync(items, opts)
  local co = coroutine.running()
  if not co then
    error("ui_select_sync must be called from a coroutine")
  end

  vim.ui.select(items, opts, function(choice, idx)
    coroutine.resume(co, choice, idx)
  end)

  return coroutine.yield()
end

return M
