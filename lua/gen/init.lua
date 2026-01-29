local prompts = require("gen.prompts")
local utils = require("gen.utils")
local M = {}

vim.cmd([[
    highlight default GenSpinner  gui=NONE  cterm=NONE  guifg=#a6e3a1 ctermfg=157
    highlight default GenPromptProperty  gui=NONE  cterm=NONE  guifg=#f38ba8 ctermfg=211
    highlight default GenPromptPlaceholder gui=NONE  cterm=NONE  guifg=#94e2d5 ctermfg=116
]])

local globals = {}

local function jobstop(msg, opts)
    if globals.job_id then
        vim.fn.jobstop(globals.job_id)
        globals.job_id = nil
    end
    if globals.stop_spinner then
        globals.stop_spinner(msg, opts)
        globals.stop_spinner = nil
    end
end

local function reset(keep_selection_and_context)
    if not keep_selection_and_context then
        globals.curr_buffer = nil -- Replacement buffer number
        globals.start_pos = nil
        globals.end_pos = nil
        globals.context = {}
        globals.response_lines = {}
    end
    if globals.job_id then
        jobstop()
        globals.job_id = nil
    end
    if globals.result_buffer ~= nil then
        -- Clear the buffer.
        vim.api.nvim_set_option_value("modifiable", true, {buf = globals.result_buffer})
        vim.api.nvim_buf_set_lines(globals.result_buffer, 0, -1, false, { "", })
        vim.api.nvim_set_option_value("modifiable", false, {buf = globals.result_buffer})
    end
    globals.result_string = ""
    globals.context_buffer = nil
    if globals.temp_filename then
        os.remove(globals.temp_filename)
        globals.temp_filename = nil
    end
    globals.server_cmd = nil -- The most recent curl command to the Ollama server.
end
reset()

local default_options = {
    model = "mistral",
    host = "localhost",
    port = "11434",
    file = false,
    debug = false,
    body = {stream = true},
    show_prompt = false,
    quit_map = "q",
    accept_map = "<c-cr>",
    retry_map = "<c-r>",
    close_map = "<c-x>",
    hidden = false,
    command = function(options)
        return "curl -q --silent --no-buffer -X POST http://" .. options.host ..
                   ":" .. options.port .. "/api/chat -d $body"
    end,
    json_response = true,
    display_mode = "float",
    no_auto_close = false,
    init = function() pcall(io.popen, "ollama serve > /dev/null 2>&1 &") end,
    list_models = function(options)
        local response = vim.fn.systemlist(
                             "curl -q --silent --no-buffer http://" .. options.host ..
                                 ":" .. options.port .. "/api/tags")
        local list = vim.fn.json_decode(response)
        local models = {}
        for key, _ in pairs(list.models) do
            table.insert(models, list.models[key].name)
        end
        table.sort(models)
        return models
    end,
    result_filetype = "markdown",
    custom_prompts_only = false,
    prompts_dir = vim.fn.stdpath "data" .. "/gen_nvim/prompts",
    response_register = nil,
    prompt_register = 'p', -- The most recent submitted prompt
    text_selection_only = false,
    logs_dir = vim.fn.stdpath "data" .. "/gen_nvim/logs",
    log_file = function (opts)
        if opts.log_rollover == "daily" then
            return opts.logs_dir .. "/" .. os.date("%Y-%m-%d") ..".log.md"
        else
            return opts.logs_dir .. "/gen.log.md"
        end
     end,
    log_rollover = nil, -- nil (default) or "daily"
    response_window_layout = { width = 0.8, height = 0.5, border = "single", }, -- Floating response window layout
    prompt_picker_layout = { width = 0.8, height = 0.5, },
    scratchpad_layout = {},
}
for k, v in pairs(default_options) do M[k] = v end

M.setup = function(opts)
  for k, v in pairs(opts) do M[k] = v end
  M.prompts = prompts.get_prompts(M)
end

local function append_file(path, text)
  local f,err = io.open(path, "a+")
  if f then
    f:write(text)
    f:close()
    return true
  else
    utils.notify("Error opening '" .. path .. "': " .. (err or "unknown error"), vim.log.levels.ERROR)
    return false
  end
end

-- Static autocommand group for general plugin-wide autocmds
-- This group will be cleared once when the plugin is loaded
vim.api.nvim_create_augroup("GenStatic", { clear = true })

-- Reload prompts when a prompts file is saved
vim.api.nvim_create_autocmd("BufWritePost", {
  group = "GenStatic",
  pattern = M.prompts_dir .. "/*.prompts.md",
  callback = function()
    M.prompts = prompts.get_prompts(M)
    -- vim.notify("Gen.nvim prompts reloaded.", vim.log.levels.INFO)
  end,
})

-- Set prompts syntax highlighting
vim.api.nvim_create_autocmd({"BufReadPost", "BufNewFile"}, {
  group = "GenStatic",
  pattern = M.prompts_dir .. "/*.prompts.md",
  callback = function(event)
    prompts.add_prompt_syntax_highlighting_rules(event.buf)
  end,
})

local function response_header(opts)
    local header = {}
    table.insert(header,"___")
    table.insert(header, "_date_: " .. os.date("%Y-%m-%d %H:%M:%S"))
    table.insert(header, "_model_: " .. opts.model)
    if opts.extract then
        table.insert(header, "_extract_: " .. utils.escape_string(opts.extract))
    end
    if opts.show_prompt then
        if opts.show_prompt == true then opts.show_prompt = 3 end -- Default truncation size
        table.insert(header,"_prompt_:")
        local prompt_lines = vim.split(opts.prompt, "\n")
        local fenced = false
        for i = 1, #prompt_lines do
            table.insert(header, prompt_lines[i])
            if prompt_lines[i]:sub(1, 3) == "```" then
                fenced = not fenced
            end
            if type(opts.show_prompt) == "number" then
                if i >= opts.show_prompt then
                    if #prompt_lines > i then
                        table.insert(header, "...")
                        if fenced then table.insert(header, "```") end
                    end
                    break
                end
            end
        end
    end

    header = utils.trim_table(header)
    table.insert(header,"___")
    return header
end

local function close_response_window()
    if globals.float_win ~= nil and vim.api.nvim_win_is_valid(globals.float_win) then
        local wins = vim.api.nvim_list_wins()
        if #wins > 1 then
            vim.api.nvim_win_hide(globals.float_win)
            globals.float_win = nil
        end
    end
end

-- Process the response (`globals.result_string`).
-- Handles optional extraction (`opts.extract`) replacement (`opts.replace`), logging (`opts.logs_dir`),
local function close_window(opts)
    local lines = {}
    if opts.extract then
        local extracted

        if type(opts.extract) == "function" then
            extracted = opts.extract({
                result_string = globals.result_string,
                model = opts.model,
            })
        else
            extracted = globals.result_string:match(opts.extract)
        end

        if not extracted then
            if not opts.no_auto_close then
                vim.api.nvim_win_hide(globals.float_win)
                if globals.result_buffer ~= nil then
                    vim.api.nvim_buf_delete(globals.result_buffer,
                                            {force = true})
                end
                reset()
            end
            return
        end
        lines = vim.split(extracted, "\n", {trimempty = true})
    else
        lines = vim.split(globals.result_string, "\n", {trimempty = true})
    end
    lines = utils.trim_table(lines)

    -- Copy result string to register if response_register is set
    if opts.response_register ~= nil then
        vim.fn.setreg(opts.response_register, table.concat(lines, "\n"))
    end

    if opts.logs_dir then
        local log_file = opts.log_file(opts)
        append_file(log_file, "\n" .. table.concat(response_header(opts), "\n") .. "\n" .. table.concat(lines, "\n") .. "\n")
    end

    -- Handle different replace options
    if not opts.replace then
        return
    end
    if opts.replace == "before" or opts.replace == "after" then -- fence the result with rulers
        table.insert(lines, 1, "___")
        table.insert(lines, "___")
    end
    if opts.replace == true then
        -- Original behavior: replace selected text
        vim.api.nvim_buf_set_text(globals.curr_buffer, globals.start_pos[2] - 1,
                                  globals.start_pos[3] - 1, globals.end_pos[2] - 1,
                                  globals.end_pos[3] > globals.start_pos[3] and
                                      globals.end_pos[3] or globals.end_pos[3] - 1,
                                  lines)
        -- in case another replacement happens
        globals.end_pos[2] = globals.start_pos[2] + #lines - 1
        globals.end_pos[3] = string.len(lines[#lines])
    elseif opts.replace == "before" then
        -- Insert before the selected text (line-wise)
        local start_line = globals.start_pos[2] - 1
        vim.api.nvim_buf_set_lines(globals.curr_buffer, start_line, start_line, false, lines)
        -- Update end position to account for inserted lines
        globals.end_pos[2] = globals.end_pos[2] + #lines
    elseif opts.replace == "after" then
        -- Insert after the selected text (line-wise)
        local end_line = globals.end_pos[2]
        vim.api.nvim_buf_set_lines(globals.curr_buffer, end_line, end_line, false, lines)
    end

    if not opts.no_auto_close then
        close_response_window()
        reset()
    end
end

local function get_window_options(win_config)
    -- Get editor dimensions
    ---@diagnostic disable-next-line: undefined-field
    local editor_width = vim.opt.columns:get()
    ---@diagnostic disable-next-line: undefined-field
    local editor_height = vim.opt.lines:get()

    -- Calculate target dimensions for the floating window
    local float_width = math.floor(editor_width * win_config.width)
    local float_height = math.floor(editor_height * win_config.height)

    -- Ensure dimensions are at least 1
    float_width = math.max(1, float_width)
    float_height = math.max(1, float_height)

    -- Calculate row and column for centering
    local float_row = math.floor((editor_height - float_height) / 2)
    local float_col = math.floor((editor_width - float_width) / 2)

    -- Update the floating window configuration
    local result = {
      width = float_width,
      height = float_height,
      row = float_row,
      col = float_col,
      relative = 'editor', -- Relative to the main editor area
      style = "minimal",
      border = win_config.border,
      title = ' Responses ',
      title_pos = 'center',

    }

    return result
end

local function write_to_buffer(lines)
    if not globals.result_buffer or
        not vim.api.nvim_buf_is_valid(globals.result_buffer) then return end

    local all_lines = vim.api.nvim_buf_get_lines(globals.result_buffer, 0, -1,
                                                 false)

    local last_row = #all_lines
    local last_row_content = all_lines[last_row]
    local last_col = string.len(last_row_content)

    local text = table.concat(lines or {}, "\n")

    vim.api.nvim_set_option_value("modifiable", true,
                                  {buf = globals.result_buffer})
    vim.api.nvim_buf_set_text(globals.result_buffer, last_row - 1, last_col,
                              last_row - 1, last_col, vim.split(text, "\n"))

    if globals.float_win ~= nil and vim.api.nvim_win_is_valid(globals.float_win) then
        -- Move the cursor to the last character in the buffer
        local buf = vim.api.nvim_win_get_buf(globals.float_win)
        last_row = vim.api.nvim_buf_line_count(buf)
        local last_line = vim.api.nvim_buf_get_lines(buf, last_row - 1, last_row, false)[1] or ""
        last_col = math.max(#last_line - 1, 0)
        vim.api.nvim_win_set_cursor(globals.float_win, { last_row, last_col })
    end

    vim.api.nvim_set_option_value("modifiable", false,
                                  {buf = globals.result_buffer})

    -- Save response window lines.
    for _, v in pairs(lines) do
        table.insert(all_lines, v)
    end
    globals.response_lines = all_lines
end

local function create_window(cmd, opts)
    local function setup_window()
        globals.result_buffer = vim.fn.bufnr("%")
        vim.api.nvim_set_option_value("modifiable", true, {buf = globals.result_buffer})
        vim.api.nvim_buf_set_lines(globals.result_buffer, 0, -1, false, globals.response_lines)
        vim.api.nvim_set_option_value("modifiable", false, {buf = globals.result_buffer})
        globals.float_win = vim.fn.win_getid()
        utils.cursor_to_end(globals.float_win)
        vim.api.nvim_set_option_value("filetype", opts.result_filetype,
                                      {buf = globals.result_buffer})
        vim.api.nvim_set_option_value("buftype", "nofile",
                                      {buf = globals.result_buffer})
        vim.api.nvim_set_option_value("wrap", true, {win = globals.float_win})
        vim.api.nvim_set_option_value("linebreak", true,
                                      {win = globals.float_win})
        vim.api.nvim_set_option_value("swapfile", false, {buf = globals.result_buffer})
    end

    local display_mode = opts.display_mode or M.display_mode
    local WIN_NAME = "gen.nvim"
    if display_mode == "float" then
        if globals.result_buffer then
            vim.api.nvim_buf_delete(globals.result_buffer, {force = true})
        end
        globals.result_buffer = vim.api.nvim_create_buf(false, true)
        local win_config = get_window_options(opts.response_window_layout)
        globals.float_win = vim.api.nvim_open_win(globals.result_buffer, true, win_config)
    elseif display_mode == "horizontal-split" then
        vim.cmd("split " .. WIN_NAME)
    elseif display_mode == "vertical-split" then
        vim.cmd("vnew " .. WIN_NAME)
    elseif display_mode == "horizontal-split-bottom" then
        vim.cmd("botright split " .. WIN_NAME)
    elseif display_mode == "vertical-split-right" then
        vim.cmd("botright vnew " .. WIN_NAME)
    elseif display_mode == "no-split" then
        vim.cmd("edit " .. WIN_NAME)
    else
        vim.notify("Gen.nvim warning : Invalid display mode specified.", vim.log.levels.WARN)
        vim.cmd("edit " .. WIN_NAME)
    end
    setup_window()
    vim.keymap.set("n", "<Esc>", function()
        jobstop("User aborted!", { hl_group = "WarningMsg" })
    end, {buffer = globals.result_buffer})
    vim.keymap.set("n", M.quit_map, "<cmd>quit<cr>",
                   {buffer = globals.result_buffer})
    vim.keymap.set("n", M.accept_map, function()
        opts.replace = true
        close_window(opts)
    end, {buffer = globals.result_buffer})
    vim.keymap.set("n", M.retry_map, function()
        local buf = 0 -- Current buffer i.e. response buffer
        jobstop()
          vim.api.nvim_set_option_value("modifiable", true, {buf = buf})
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", })
          vim.api.nvim_set_option_value("modifiable", false, {buf = buf})
        -- vim.api.nvim_win_close(0, true)
        M.run_command(cmd, opts)
    end, {buffer = globals.result_buffer})
    vim.keymap.set("n", M.close_map, function()
        close_response_window()
        reset()
    end, {buffer = globals.result_buffer, desc = "Close the response window and clear the model context"})
end

M.exec = function(options)
coroutine.wrap(function()
    local dot_prompt = vim.tbl_deep_extend("force", {}, options)
    local opts = vim.tbl_deep_extend("force", M, options)
    if opts.hidden then
        -- the only reasonable thing to do if no output can be seen
        opts.display_mode = 'float' -- uses the `hide` option
        opts.replace = true
    end

    if type(opts.init) == 'function' then opts.init(opts) end

    if globals.result_buffer ~= vim.fn.winbufnr(0) then
        globals.curr_buffer = vim.fn.winbufnr(0)
        local mode = opts.mode or vim.fn.mode()
        if mode == "v" or mode == "V" then
            globals.start_pos = vim.fn.getpos("'<")
            globals.end_pos = vim.fn.getpos("'>")
            local max_col = vim.api.nvim_win_get_width(0)
            if globals.end_pos[3] > max_col then
                globals.end_pos[3] = vim.fn.col("'>") - 1
            end -- in case of `V`, it would be maxcol instead
        else
            local cursor = vim.fn.getpos(".")
            globals.start_pos = cursor
            globals.end_pos = globals.start_pos
        end
    end

    local selected_text = ""
    if globals.curr_buffer ~= nil then
        if globals.start_pos == globals.end_pos then
            -- get text from whole buffer
            selected_text = table.concat(vim.api.nvim_buf_get_lines(globals.curr_buffer,
                                                              0, -1, false), "\n")
        else
            selected_text = table.concat(vim.api.nvim_buf_get_text(globals.curr_buffer,
                                                             globals.start_pos[2] -
                                                                 1,
                                                             globals.start_pos[3] -
                                                                 1,
                                                             globals.end_pos[2] - 1,
                                                             globals.end_pos[3], {}),
                                                            "\n")
        end
        if selected_text:match("^%s*$") then selected_text = "" end
    end

    --- Substitutes placeholders in the prompt with actual values.
    -- This function processes a prompt string and replaces special placeholders
    -- with their corresponding values from the current context.
    --
    -- NOTE: Must be called from a coroutine.
    --
    -- Placeholders processed:
    -- - `$input`: Prompts user for input and substitutes the value
    -- - `$clipboard`: Substitutes content of system clipboard (alias for `$register_+`)
    -- - `$yanked`: Substitutes most recently yanked text (alias for `$register_0`)
    -- - `$register_<name>`: Substitutes content of specified register
    -- - `$register`: Substitutes content of default (unnamed) register
    -- - `$text`: Substitutes selected text content
    -- - `$filetype`: Substitutes current buffer's filetype
    --
    -- @param input string: The prompt string containing placeholders to substitute
    -- @return string|nil: The prompt with placeholders substituted, or nil if processing should abort
    local function substitute_placeholders(input)
        if not input then return nil end

        local text = input

        -- Handle the $select placeholder first
        if string.find(text, "%$select") then
            local choice

            local items_map = {
                ["$clipboard"] = "Clipboard ($clipboard)",
                ["$text"] = "Selected text ($text)",
                ["$input"] = "User input` ($input)",
                ["$yanked"] = "Yanked text ($yanked)",
                ["__CANCEL__"] = "Cancel (or press Esc)",
            }
            choice, _ = utils.ui_select_sync(
              {
                "$clipboard",
                "$text",
                "$input",
                "$yanked",
                string.rep("─", 100), -- Full-width visual break
                "__CANCEL__",
              },
              { prompt = "Select input source",
                format_item = function(item)
                  local item_text = items_map[item]
                  if item_text ~= nil then
                    return item_text
                  end
                  return item
                end,
              })

            -- Arrive here after the user selection.
            if not choice or choice == "__CANCEL__" then
                return nil
            end
            text = string.gsub(text, "%$select", choice)
            dot_prompt.prompt = text -- Remember the $select source in the dot prompt
        end

        M.prompts["."] = dot_prompt -- Save the dot-prompt after the $select placeholder has been substituted

        -- Handle the ${input:<prompt>} syntax
        local cancelled = false
        text = string.gsub(text, "%${input:(.-)}", function(prompt_text)
          local answer = vim.fn.input(prompt_text .. ": ")
          if answer == "" then
            cancelled = true
          end
          return answer
        end)

        if cancelled then
            return nil
        end

        -- Handle the $input syntax
        if string.find(text, "%$input") then
          local answer = vim.fn.input "Input: "
          if answer == "" then
            return nil
          end
          text = string.gsub(text, "%$input", answer)
        end

        text = string.gsub(text, "%$clipboard", "$register_+")
        text = string.gsub(text, "%$yanked", "$register_0")

        local register_error = false
        text = string.gsub(text, "%$register_([%w*+:/\"])", function(r_name)
            local register = vim.fn.getreg(r_name)
            if not register or register:match("^%s*$") then
                utils.notify("Prompt uses $register_" .. r_name .. " but register " .. r_name .. " is empty", vim.log.levels.ERROR)
                register_error = true
                return ""
            end
            return register
        end)

        if register_error then
            return nil
        end

        if string.find(text, "%$register") then
            local register = vim.fn.getreg('"')
            if not register or register:match("^%s*$") then
                utils.notify("Prompt uses $register but yank register is empty", vim.log.levels.ERROR)
                return nil
            end
            text = string.gsub(text, "%$register", register)
        end

        if string.find(text, "%$text") then
            -- Check if text_selection_only is enabled and we're not in visual mode
            if opts.text_selection_only and (globals.start_pos == globals.end_pos) then
                utils.notify("No visual mode text selection (select $text in visual mode)", vim.log.levels.ERROR)
                return nil
            end

            if selected_text == "" then
                utils.notify("Prompt uses $text but no text is selected", vim.log.levels.ERROR)
                return nil
            end

            selected_text = string.gsub(selected_text, "%%", "%%%%")
            text = string.gsub(text, "%$text", selected_text)
        end

        text = string.gsub(text, "%$filetype", vim.bo.filetype)
        return text
    end

    ---@type string|nil
    local prompt = opts.prompt

    if type(prompt) == "function" then
        prompt = prompt({content = selected_text, filetype = vim.bo.filetype})
        if type(prompt) ~= 'string' or string.len(prompt) == 0 then
            return
        end
    end

    prompt = substitute_placeholders(prompt)
    if prompt == nil then return end

    -- substitute placeholders in the prompt `extract` field
    if type(opts.extract) == "string" then
        opts.extract = substitute_placeholders(opts.extract)
        if opts.extract == nil then return end
    end

    prompt = string.gsub(prompt, "%%", "%%%%")

    globals.result_string = ""

    local cmd

    opts.json = function(body, shellescape)
        local json = vim.fn.json_encode(body)
        if shellescape then
            json = vim.fn.shellescape(json)
            if vim.o.shell == 'cmd.exe' then
                json = string.gsub(json, '\\\"\"', '\\\\\\\"')
            end
        end
        return json
    end

    opts.prompt = prompt

    if type(opts.command) == 'function' then
        cmd = opts.command(opts)
    else
        cmd = M.command
    end

    if string.find(cmd, "%$prompt") then
        local prompt_escaped = vim.fn.shellescape(prompt)
        cmd = string.gsub(cmd, "%$prompt", prompt_escaped)
    end
    cmd = string.gsub(cmd, "%$model", opts.model)
    if string.find(cmd, "%$body") then
        local body = vim.tbl_extend("force",
                                    {model = opts.model, stream = true},
                                    opts.body)
        -- Add new prompt to the context
        globals.context = globals.context or {}
        table.insert(globals.context, {role = "user", content = prompt})
        body.messages = globals.context
        if M.model_options ~= nil then -- llamacpp server - model options: eg. temperature, top_k, top_p
            body = vim.tbl_extend("force", body, M.model_options)
        end
        if opts.model_options ~= nil then -- override model options from gen command (if exist)
            body = vim.tbl_extend("force", body, opts.model_options)
        end

        if opts.file ~= nil then
            local json = opts.json(body, false)
            globals.temp_filename = os.tmpname()
            local fhandle, err = io.open(globals.temp_filename, "w")
            if not fhandle then
                utils.notify("Error opening '" .. globals.temp_filename .. "': " .. (err or "unknown error"), vim.log.levels.ERROR)
                return nil
            end
            fhandle:write(json)
            fhandle:close()
            cmd = string.gsub(cmd, "%$body", "@" .. globals.temp_filename)
        else
            local json = opts.json(body, true)
            cmd = string.gsub(cmd, "%$body", json)
        end
    end

    -- Copy prompt string to register if primpt_register is set
    if opts.prompt_register ~= nil then
        vim.fn.setreg(opts.prompt_register, opts.prompt)
    end

    M.run_command(cmd, opts)
end)()
end

-- Run curl command
M.run_command = function(cmd, opts)
    globals.server_cmd = cmd
    if globals.result_buffer == nil or globals.float_win == nil or
        not vim.api.nvim_win_is_valid(globals.float_win) then
        create_window(cmd, opts)
    end
    local partial_data = ""
    if opts.debug then vim.print(cmd) end

    globals.stop_spinner = utils.notify_with_spinner("Generating...", { interval = 100, hl_group = "GenSpinner" })

    globals.job_id = vim.fn.jobstart(cmd, {
        -- stderr_buffered = opts.debug,
        on_stdout = function(_, data, _)
            -- window was closed, so cancel the job
            if not globals.float_win or
                not vim.api.nvim_win_is_valid(globals.float_win) then
                jobstop("Aborted (window closed)!", { hl_group = "WarningMsg" })
                if globals.result_buffer then
                    vim.api.nvim_buf_delete(globals.result_buffer,
                                            {force = true})
                end
                reset()
                return
            end
            if opts.debug then vim.print('Response data: ', data) end
            for _, line in ipairs(data) do
                partial_data = partial_data .. line
                if line:sub(-1) == "}" then
                    partial_data = partial_data .. "\n"
                end
            end

            local lines = vim.split(partial_data, "\n", {trimempty = true})

            partial_data = table.remove(lines) or ""

            for _, line in ipairs(lines) do
                Process_response(line, globals.job_id)
            end

            if partial_data:sub(-1) == "}" then
                Process_response(partial_data, globals.job_id)
                partial_data = ""
            end
        end,
        on_stderr = function(_, data, _)
            if opts.debug then
                -- window was closed, so cancel the job
                if not globals.float_win or not vim.api.nvim_win_is_valid(globals.float_win) then
                    jobstop("Aborted (window closed)!", { hl_group = "WarningMsg" })
                    return
                end

                if data == nil or #data == 0 then return end

                globals.result_string = globals.result_string ..
                                            table.concat(data, "\n")
                local lines = vim.split(globals.result_string, "\n")
                table.insert(lines,"")
                write_to_buffer(lines)
            end
        end,
        on_exit = function(_, b)
            if b == 0 and globals.result_buffer then
                close_window(opts)
            end
        end
    })

    -- Define a transient autocommand group for window-specific autocmds
    -- This group MUST be cleared every time M.run_command is called to prevent duplicate WinClosed autocmds
    local augroup = vim.api.nvim_create_augroup("GenTransient", { clear = true })
    vim.api.nvim_create_autocmd('WinClosed', {
        buffer = globals.result_buffer,
        group = augroup,
        callback = function()
            jobstop("Aborted (window closed)!", { hl_group = "WarningMsg" })
            if globals.result_buffer then
                vim.api.nvim_buf_delete(globals.result_buffer, {force = true})
            end
            reset(true) -- keep selection and context
        end
    })

    write_to_buffer(response_header(opts))
    write_to_buffer { "", "" }

    vim.api.nvim_buf_attach(globals.result_buffer, false, {
        on_detach = function() globals.result_buffer = nil end
    })
end

local function select_prompt(cb)
    -- Check if telescope is available
    local has_telescope = pcall(require, "telescope")
    if not has_telescope then
        -- Fallback to vim.ui.select if telescope is not available
        local promptKeys = {}
        for key, _ in pairs(M.prompts) do table.insert(promptKeys, key) end
        table.sort(promptKeys)
        vim.ui.select(promptKeys, {
            prompt = "Prompt:",
            format_item = function(item)
                return table.concat(vim.split(item, "_"), " ")
            end
        }, function(item) cb(item) end)
        return
    else
        prompts.prompt_picker(cb, M)
    end
end

vim.api.nvim_create_user_command("Gen", function(arg)
    local mode
    if arg.range == 0 then
        mode = "n"
    else
        mode = "v"
    end
    if arg.args ~= "" then
        if arg.args == "/reset" then
            reset()
            return
        elseif arg.args == "/responses" then
            if globals.float_win ~= nil and vim.api.nvim_win_is_valid(globals.float_win) then
                close_response_window()
                return
            else
                create_window(globals.server_cmd, M)
                return
            end
        elseif arg.args == "/prompts" then
            prompts.manage_prompts_files(M)
            return
        elseif arg.args == "/models" then
            M.select_model()
            return
        elseif arg.args == "/scratchpad" then
            local scratchpad_filename = M.prompts_dir .. "/Scratchpad.prompts.md"
            prompts.open_scratchpad(scratchpad_filename, M.scratchpad_layout)
            return
        else
            local prompt = M.prompts[arg.args]
            if not prompt then
                vim.notify("Invalid " .. (arg.args:sub(1, 1) == "/" and "command" or "prompt") .. "'" .. arg.args .. "'", vim.log.levels.ERROR)
                return
            end
            local p = vim.tbl_deep_extend("force", {mode = mode}, prompt)
            return M.exec(p)
        end
    end
    select_prompt(function(item)
        if not item then return end
        local p = vim.tbl_deep_extend("force", {mode = mode}, M.prompts[item])
        M.exec(p)
    end)
end, {
    range = true,
    nargs = "?",
    complete = function(ArgLead)
        local completion_candidates = {}
        local gen_args = {}

        for k, _ in pairs(M.prompts) do
            table.insert(gen_args, k)
        end
        table.insert(gen_args, "/reset")
        table.insert(gen_args, "/responses")
        table.insert(gen_args, "/prompts")
        table.insert(gen_args, "/models")
        table.insert(gen_args, "/scratchpad")

        for _, arg in pairs(gen_args) do
            if arg:lower():match("^" .. ArgLead:lower()) then
                table.insert(completion_candidates, arg)
            end
        end
        table.sort(completion_candidates)
        return completion_candidates
    end
})

function Process_response(str, json_response)
    if string.len(str) == 0 then return end
    local text

    if json_response then
        -- llamacpp response string -- 'data: {"content": "hello", .... }' -- remove 'data: ' prefix, before json_decode
        if string.sub(str, 1, 6) == "data: " then
            str = string.gsub(str, "data: ", "", 1)
        end
        local success, result = pcall(function()
            return vim.fn.json_decode(str)
        end)

        if success then
            if result.message and result.message.content then -- ollama chat endpoint
                local content = result.message.content
                text = content

                globals.context = globals.context or {}
                globals.context_buffer = globals.context_buffer or ""
                globals.context_buffer = globals.context_buffer .. content

                -- When the message sequence is complete, add it to the context
                if result.done then
                    write_to_buffer {"", "", ""}
                    table.insert(globals.context, {
                        role = "assistant",
                        content = globals.context_buffer
                    })
                    -- Clear the buffer as we're done with this sequence of messages
                    globals.context_buffer = ""
                    jobstop()
                end
            elseif result.choices then -- groq chat endpoint
                local choice = result.choices[1]
                local content = choice.delta.content
                text = content

                if content ~= nil then
                    globals.context = globals.context or {}
                    globals.context_buffer = globals.context_buffer or ""
                    globals.context_buffer = globals.context_buffer .. content
                end

                -- When the message sequence is complete, add it to the context
                if choice.finish_reason == "stop" then
                    table.insert(globals.context, {
                        role = "assistant",
                        content = globals.context_buffer
                    })
                    -- Clear the buffer as we're done with this sequence of messages
                    globals.context_buffer = ""
                end
            elseif result.content then -- llamacpp version
                text = result.content
                if result.content then
                    globals.context = result.content
                end
            elseif result.response then -- ollama generate endpoint
                text = result.response
                if result.context then
                    globals.context = result.context
                end
            end
        else
            write_to_buffer({"", "====== ERROR ====", str, "-------------", ""})
            jobstop("Aborted (JSON response parse error)!", { hl_group = "Error" })
        end
    else
        text = str
    end

    if text == nil then return end

    globals.result_string = globals.result_string .. text
    local lines = vim.split(text, "\n")
    write_to_buffer(lines)
end

M.select_model = function()
    local models = M.list_models(M)
    for i, v in pairs(models) do
        if v == M.model then -- Highlight current model
            models[i] = "* " .. v
        else
            models[i] = "  " .. v
        end
    end
    vim.ui.select(models, {prompt = "Model:"}, function(item)
        if item ~= nil then
            item = string.sub(item, 3)
            vim.notify("Model set to " .. item, vim.log.levels.INFO)
            M.model = item
        end
    end)
end

return M
