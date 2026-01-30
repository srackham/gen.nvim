local M = {}

--- Strip leading and trailing whitespace from a string
--- @param s string The input string to trim
--- @return string The trimmed string
function M.trim_string(s)
    return s:match("^%s*(.-)%s*$")
end

--- Escapes special characters in a string
--- @param s string The string to escape
--- @return string The escaped string
function M.escape_string(s)
    local map = {
        ['\n'] = '\\n',
        ['\r'] = '\\r',
        ['\t'] = '\\t',
        ['\\'] = '\\\\',
        ['"'] = '\\"',
        ["'"] = "\\'"
    }
    return s:gsub("[\n\r\t\\\"']", function(char)
        return map[char] or char
    end)
end

--- Unescapes escape sequences in a string
--- @param s string The string to unescape
--- @return string The unescaped string
function M.unescape_string(s)
    local map = {
        ["n"] = "\n",
        ["r"] = "\r",
        ["t"] = "\t",
        ["\\"] = "\\",
        ['"'] = '"',
        ["'"] = "'"
    }
    return s:gsub("\\(.)", function(char)
        return map[char] or char
    end)
end

function M.table_size(tbl)
    local count = 0
    for _ in pairs(tbl) do
      count = count + 1
    end
    return count
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
    return function(done_message, done_opts)
        kill = true
        M.message(done_message or "Done!", vim.tbl_deep_extend("force", opts, done_opts or {}))
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
        -- Move the cursor to the last character in the Responses buffer
        local buf = vim.api.nvim_win_get_buf(win_id)
        local last_row = vim.api.nvim_buf_line_count(buf)
        local last_line = vim.api.nvim_buf_get_lines(buf, last_row - 1, last_row, false)[1] or ""
        local last_col = math.max(#last_line - 1, 0)
        vim.api.nvim_win_set_cursor(win_id, { last_row, last_col })
        -- Focus Responses window
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

--- Opens a floating window with the specified file
---@param path string The file path to open in the float
---@param opts table|nil Optional configuration parameters
---  - `width` number Width of the float as a percentage of editor width (default: 0.8)
---  - `height` number Height of the float as a percentage of editor height (default: 0.8)
---  - `border` string Border style ("single", "double", "rounded", etc.) (default: "single")
---  - `style` string Window style (default: "minimal")
function M.open_float(path, opts)
  -- Set default options
  opts = vim.tbl_deep_extend("force", {
      width = 0.8,
      height = 0.8,
      border = "single",
      style = "minimal",
  }, opts or {})

  -- Check if buffer for path already exists
  local existing_buf = nil
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      existing_buf = buf
      break
    end
  end

  local buf = existing_buf or vim.api.nvim_create_buf(false, true)

  -- Check if window for buffer already exists
  local existing_win = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      existing_win = win
      break
    end
  end

  if existing_win then
    vim.api.nvim_set_current_win(existing_win)
    return
  end

  local ui = vim.api.nvim_list_uis()[1]
  local width = math.floor(ui.width * opts.width)
  local height = math.floor(ui.height * opts.height)
  local col = math.floor((ui.width - width) / 2)
  local row = math.floor((ui.height - height) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = opts.style,
    border = opts.border,
    width = width,
    height = height,
    col = col,
    row = row,
    title = opts.title,
    title_pos = opts.title_pos,
  })

  vim.api.nvim_win_call(win, function()
    if not existing_buf then
      vim.cmd.edit(path)
    end
  end)
end

--- Creates a window to display a file based on the specified display mode
---@param path string The file path to open
---@param opts table Configuration options containing display_mode and other settings
---  - `display_mode` string How to display the file:
---      - `float` - opens in a floating window
---      - `no-split` or nil - opens in current window
---      - `horizontal-split` - splits horizontally
---      - `vertical-split` - splits vertically
---      - `horizontal-split-bottom` - splits horizontally at bottom
---      - `vertical-split-right` - splits vertically at right
---  Any Other options are passed to the underlying window creation function
function M.create_window(path, opts)
    local display_mode = opts.display_mode
    if display_mode == "float" then
        M.open_float(path, opts)
    elseif display_mode == nil or display_mode == "no-split" then
      vim.cmd("edit " .. vim.fn.fnameescape(path))
    elseif display_mode == "horizontal-split" then
        vim.cmd("split " .. vim.fn.fnameescape(path))
    elseif display_mode == "vertical-split" then
        vim.cmd("vsplit " .. vim.fn.fnameescape(path))
    elseif display_mode == "horizontal-split-bottom" then
        vim.cmd("botright split " .. vim.fn.fnameescape(path))
    elseif display_mode == "vertical-split-right" then
        vim.cmd("botright vsplit " .. vim.fn.fnameescape(path))
    else
        vim.notify("Gen.nvim: Invalid display mode '" .. display_mode .. "'", vim.log.levels.WARN)
    end
end

return M
