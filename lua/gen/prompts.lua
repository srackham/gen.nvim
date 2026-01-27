local utils = require("gen.utils")

local M = {}

-- TODO: fix duplicate field warnings, almost certainly due to prompts.lua being read via multiple search paths.
--- @class Prompt
--- @field prompt string|fun(context: table): string The prompt string or a function returning it.
--- @field replace boolean|string|nil Whether/how to replace matched content ('true', 'false', 'before', 'after').
--- @field extract string|nil A regex pattern to extract content from the model's response.
--- @field model string|nil The model name to use for this prompt.
--- @field source_file string|nil The file path where this prompt was defined, or "builtin".

--- @type table<string, Prompt>
local builtin_prompts = {
  Generate = { prompt = "$input", replace = true },
  Chat = { prompt = "$input" },
  Summarize = { prompt = "Summarize the following text:\n$text" },
  Ask = { prompt = "Regarding the following text, $input:\n$text" },
  Change = {
    prompt = "Change the following text, $input, just output the final text without additional quotes around it:\n$text",
    replace = true,
  },
  Enhance_Grammar_Spelling = {
    prompt = "Modify the following text to improve grammar and spelling, just output the final text without additional quotes around it:\n$text",
    replace = true,
  },
  Enhance_Wording = {
    prompt = "Modify the following text to use better wording, just output the final text without additional quotes around it:\n$text",
    replace = true,
  },
  Make_Concise = {
    prompt = "Modify the following text to make it as simple and concise as possible, just output the final text without additional quotes around it:\n$text",
    replace = true,
  },
  Make_List = {
    prompt = "Render the following text as a markdown list:\n$text",
    replace = true,
  },
  Make_Table = {
    prompt = "Render the following text as a markdown table:\n$text",
    replace = true,
  },
  Review_Code = {
    prompt = "Review the following code and make concise suggestions:\n```$filetype\n$text\n```",
  },
  Enhance_Code = {
    prompt = "Enhance the following code, only output the result in format ```$filetype\n...\n```:\n```$filetype\n$text\n```",
    replace = true,
    extract = "```$filetype\n(.-)```",
  },
  Change_Code = {
    prompt = "Regarding the following code, $input, only output the result in format ```$filetype\n...\n```:\n```$filetype\n$text\n```",
    replace = true,
    extract = "```$filetype\n(.-)```",
  },
}

--- Parses markdown-style prompt files into structured data.
-- Each prompt section starts and ends with either `---` or `___`.
-- Supported header options:
--   - name (string, required): Unique identifier for the prompt.
--   - model (string): Model name to use for this prompt.
--   - extract (string): A regex pattern to extract content from input.
--   - replace (string or boolean): Whether/how to replace matched content ('true', 'false', 'before', 'after').
--
-- @param file_content string The full content of the markdown prompt file as a string.
-- @return table|nil Returns a table mapping prompt names to their config+prompt text,
--                  or nil if parsing fails due to formatting errors.
local function parse_markdown_prompts(file_content)
  local result = {}
  local lines = vim.split(file_content, "\n")
  local i = 1

  while i <= #lines do
    -- Look for start of header (three hyphens or underscores)
    if lines[i]:match "^%-%-%-$" or lines[i]:match "^___$" then
      i = i + 1
      local options = {}
      local has_name = false

      -- Parse header options until ending delimiter
      local header_start_line = i - 1
      while i <= #lines and not (lines[i]:match "^%-%-%-$" or lines[i]:match "^___$") do
        -- Trim whitespace
        lines[i] = lines[i]:match "^%s*(.-)%s*$"

        -- Skip blank lines and HTML comment lines
        if not lines[i]:match "^%s*$" and not lines[i]:match "^<!--.-?-->$" then
          -- Check for malformed header option format
          local key, value = lines[i]:match "^([^:]+):%s*(.+)$"

          if not key or not value then
            vim.notify("Malformed header option format at line " .. i .. ": " .. lines[i], vim.log.levels.ERROR)
            return nil
          end

          -- Check option names
          if not (key == "name" or key == "model" or key == "extract" or key == "replace") then
            vim.notify(
              "Invalid option name '" .. key .. "' at line " .. i .. ". Must be: name, model, extract or replace",
              vim.log.levels.ERROR
            )
            return nil
          end

          -- Track if we have a name
          if key == "name" then
            has_name = true
          end

          -- Validate replace option
          if key == "replace" and value ~= "true" and value ~= "false" and value ~= "after" and value ~= "before" then
            vim.notify(
              "Invalid replace value '" .. value .. "' at line " .. i .. ". Must be 'true','false','after' or 'before'",
              vim.log.levels.ERROR
            )
            return nil
          end

          -- Convert values
          if key == "replace" and (value == "true" or value == "false") then
            options[key] = value == "true"
          elseif key == "extract" then
            value = utils.unescape_string(value) -- Translate escaped characters
            local success, _ = pcall(string.match, "", value) -- Validate regex by attempting to compile it
            if not success then
              vim.notify("Invalid regex in extract option at line " .. i .. ": " .. value, vim.log.levels.ERROR)
              return nil
            end
            options[key] = value
          else
            options[key] = value
          end
        end
        i = i + 1
      end

      -- Check for missing closing header line
      if i > #lines or (not lines[i]:match "^%-%-%-$" and not lines[i]:match "^___$") then
        vim.notify("Missing closing header line after header starting at line " .. header_start_line, vim.log.levels.ERROR)
        return nil
      end

      -- Check for missing name option
      if not has_name then
        vim.notify("Missing required 'name' option in header starting at line " .. header_start_line, vim.log.levels.ERROR)
        return nil
      end

      -- Skip the ending delimiter
      i = i + 1

      -- Collect the prompt text until next header or EOF
      local prompt_lines = {}
      while i <= #lines and not (lines[i]:match "^%-%-%-$" or lines[i]:match "^___$") do
        -- Skip HTML comment lines
        if not lines[i]:match "^<!--.-?-->$" then
          table.insert(prompt_lines, lines[i])
        end
        i = i + 1
      end

      -- Create the prompt entry
      local key = options.name:gsub("%s+", "_")
      options.name = nil -- Remove name from options since it's used as key
      options.prompt = table.concat(prompt_lines, "\n")
      result[key] = options
    else
      i = i + 1
    end
  end

  return result
end

--- Get prompts from builtin sources and custom markdown files
-- This function collects prompts from both builtin sources and custom
-- markdown files located in the specified prompts directory.
-- Custom prompts will override builtin prompts when they have the same key.
-- @param opts table: Configuration options containing:
--   - custom_prompts_only (boolean, optional): If true, only custom prompts are returned
--   - prompts_dir (string): Directory path where custom .prompts.md files are located
-- @return table<string, Prompt> A dictionary of prompts where keys are prompt names and values are prompt content
function M.get_prompts(opts)
  local result = {}
  if not opts.custom_prompts_only then
    result = builtin_prompts
  end
  -- Read and merge prompts from all .prompts.md files
  local prompts_dir = opts.prompts_dir
  local glob_pattern = prompts_dir .. "/*.prompts.md"
  local prompt_files = vim.fn.glob(glob_pattern, false, true)

  for _, file_path in ipairs(prompt_files) do
    if vim.fn.filereadable(file_path) == 1 then
      local file_content = vim.fn.readfile(file_path)
      if file_content then
        local prompts = parse_markdown_prompts(table.concat(file_content, "\n"))
        if prompts then
          for key, value in pairs(prompts) do
            value.source_file = file_path
            result[key] = value
          end
        else
          vim.notify("Failed to parse prompts from '" .. file_path .. "', skipping.", vim.log.levels.ERROR)
        end
      end
    end
  end
  return result
end

local prompt_syntax_rules = {
  {
    group = "MarkdownDirectiveRed",
    cmd = [[match MarkdownDirectiveRed /\v^(name|model|extract|replace|prompt):/]],
  },
  {
    group = "MarkdownVariableGreen",
    cmd = [[match MarkdownVariableGreen /\v\$(text|input|select|clipboard|yanked|filetype|register_.|register)|\$\{input:.{-}\}/]],
  },
}

vim.cmd([[
  highlight default MarkdownDirectiveRed  gui=NONE  cterm=NONE  guifg=#ff5f5f ctermfg=Red
  highlight default MarkdownVariableGreen gui=NONE  cterm=NONE  guifg=#5fff87 ctermfg=Green
]])

--- Add extra syntax prompt file highlighting rules to a specific buffer
-- **NOTE**: Markdown Treesitter syntax highlighting takes precedence over custom syntax rules.
-- @param bufnr integer
function M.add_prompt_syntax_highlighting_rules(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    for _, rule in ipairs(prompt_syntax_rules) do
      vim.cmd("syntax " .. rule.cmd) -- Define syntax group
    end
  end)
end

--- Displays a telescope picker for selecting prompts
-- @param callback function Callback function that receives the selected prompt key
-- @param gen_opts table Options table containing configuration
-- @param gen_opts.prompts table Table of prompt configurations keyed by prompt name
-- @param gen_opts.prompt_picker_layout table Layout configuration for the telescope picker
function M.prompt_picker(callback, gen_opts)
    local actions = require "telescope.actions"
    local action_state = require "telescope.actions.state"
    local finders = require "telescope.finders"
    local pickers = require "telescope.pickers"
    local previewers = require "telescope.previewers"
    local sorters = require "telescope.sorters"

    -- Prepare prompt data for telescope
    local prompt_list = {}
    local prompt_keys = {}
    for key, value in pairs(gen_opts.prompts) do
        table.insert(prompt_keys, key)
        prompt_list[key] = value
    end
    table.sort(prompt_keys)

    -- Create previewer that shows the prompt value
    local prompt_previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry)
            local prompt_key = entry.value
            local prompt_data = prompt_list[prompt_key]

            if prompt_data then
                local content = string.rep("─", 40) .. "\n"
                content = content .. "name: " .. prompt_key:gsub("_", " ") .. "\n"
                if prompt_data.model then content = content .. "model: " .. prompt_data.model .. "\n" end
                if prompt_data.extract then content = content .. "extract: " .. prompt_data.extract .. "\n" end
                if prompt_data.replace ~= nil then content = content .. "replace: " .. tostring(prompt_data.replace) .. "\n" end
                content = content .. string.rep("─", 40) .. "\n"
                if type(prompt_data.prompt) == "function" then
                    content = content .. "Prompt function (cannot display)"
                else
                    content = content .. utils.trim_string(prompt_data.prompt)
                end
                vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(content, "\n"))
                -- vim.api.nvim_set_option_value("filetype", "markdown", { buf = self.state.bufnr })
                M.add_prompt_syntax_highlighting_rules(self.state.bufnr)
            end
        end
    })

    -- Create and run the telescope picker
    pickers.new({}, {
        prompt_title = "Select Prompt",
        finder = finders.new_table {
            results = prompt_keys,
            entry_maker = function(entry)
                return {
                    value = entry,
                    display = table.concat(vim.split(entry, "_"), " "),
                    ordinal = entry,
                }
            end
        },
        sorter = sorters.get_generic_fuzzy_sorter(),
        previewer = prompt_previewer,
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if selection then
                    callback(selection.value)
                end
            end)

            vim.keymap.set("n", "e", function()
              local selection = action_state.get_selected_entry()
              if selection then
                local prompt_key = selection.value
                --- @type Prompt
                local prompt_data = prompt_list[prompt_key]
                if prompt_data and prompt_data.source_file then
                  actions.close(prompt_bufnr)
                  vim.cmd("edit " .. vim.fn.fnameescape(prompt_data.source_file))
                else
                  vim.notify("No file associated with built-in prompt '" .. prompt_key .. "'", vim.log.levels.INFO)
                end
              end
            end, { buffer = prompt_bufnr, desc = "Edit prompt source file" })

            return true
        end,
        layout_config = gen_opts.prompt_picker_layout
    }):find()
end

-- Helper to get full path for a prompt name
local function get_prompt_file_path(prompts_dir, name)
  return prompts_dir .. "/" .. name .. ".prompts.md"
end

-- Helper to validate new prompts file name
local function is_valid_filename(name)
  -- Allowed characters: alphanumeric, '+', '-', ' ', '.', '_'
  return name:match("^[a-zA-Z0-9%+%-% ._]+$") ~= nil
end

-- Helper to create a new prompts file with a basic template
local function create_new_prompts_file_template(filepath, name)
  local f, err = io.open(filepath, "w")
  if not f then
      utils.notify("Error creating file '" .. filepath .. "': " .. (err or "unknown error"), vim.log.levels.ERROR)
    return false
  end
  local display_name = name:gsub("_", " ")
  local template_content = string.format(
    "---\nname: %s\n---\n\nPrompt text for %s: $text",
    display_name,
    display_name
  )
  f:write(template_content)
  f:close()
  return true
end

--- Implements a file management menu for custom prompt files.
-- @param gen_opts table: The main Gen.nvim configuration table (M from init.lua)
function M.manage_prompts_files(gen_opts)
  local prompts_dir = gen_opts.prompts_dir

  -- Ensure prompts directory exists
  vim.fn.mkdir(prompts_dir, "p")

  local function get_prompt_names_for_select_menu()
    local names = {}
    local glob_pattern = prompts_dir .. "/*.prompts.md"
    local prompt_files = vim.fn.glob(glob_pattern, false, true)

    for _, file_path in ipairs(prompt_files) do
      -- Extract base name without path and ".prompts.md" extension
      local base_name = file_path:match(".*/(.-)%.prompts%.md$")
      if base_name then
        table.insert(names, base_name)
      end
    end
    table.sort(names)
    table.insert(names,  string.rep("─", 100)) -- Full-width visual break
    table.insert(names, "__NEW_FILE__")
    return names
  end

  vim.ui.select(get_prompt_names_for_select_menu(), {
    prompt = "Manage prompts files",
    format_item = function(item)
      if item == "__NEW_FILE__" then
        return "Create new prompts file…"
      end
      return item
    end,
  },
  function(selected_item)
    if not selected_item or selected_item == "" then
      vim.notify("Prompt file management cancelled.", vim.log.levels.INFO)
      return
    end

    if selected_item == "__NEW_FILE__" then
      vim.ui.input({ prompt = "Enter prompts file name:" }, function(new_name)
        if not new_name or new_name == "" then
          vim.notify("New prompts file creation cancelled.", vim.log.levels.INFO)
          return
        end

        if not is_valid_filename(new_name) then
          vim.notify("Invalid file name. Only alphanumeric, '+', '-', ' ', '.', '_' allowed.", vim.log.levels.ERROR)
          return
        end

        local file_path = get_prompt_file_path(prompts_dir, new_name)
        if vim.fn.filereadable(file_path) == 1 then
          vim.notify("File '" .. file_path .. "' already exists.", vim.log.levels.ERROR)
          return
        end

        if create_new_prompts_file_template(file_path, new_name) then
          vim.notify("Created new prompts file: '" .. new_name .. "'", vim.log.levels.INFO)
          vim.cmd("edit " .. vim.fn.fnameescape(file_path))
        end
        gen_opts.prompts = M.get_prompts(gen_opts) -- Reload prompts after changes
      end)
    else -- Existing prompts file selected
      local selected_file_path = get_prompt_file_path(prompts_dir, selected_item)

      vim.ui.select(
        {
          "Edit '" .. selected_item .. "' prompts file",
          "Rename '" .. selected_item .. "' prompts file",
          "Delete '" .. selected_item .. "' prompts file",
          string.rep("─", 100), -- Full-width visual break
          "__CANCEL__",
        },
        { prompt = "Action",
          format_item = function(item)
            if item == "__CANCEL__" then
              return "Cancel (or press Esc)"
            end
            return item
          end,
        },
        function(action)
          if not action then -- User cancelled
            return
          end

          if action:match("^Edit") then -- Edit
            vim.cmd("edit " .. vim.fn.fnameescape(selected_file_path))
            local bufnr = vim.api.nvim_get_current_buf()
            M.add_prompt_syntax_highlighting_rules(bufnr)
          elseif action:match("^Rename") then -- Rename
            vim.ui.input({ prompt = "Rename '" .. selected_item .. "' to: ", },
              function(new_name)
                if not new_name or new_name == "" or new_name == selected_item then
                  return
                end

                if not is_valid_filename(new_name) then
                  vim.notify("Invalid file name. Only alphanumeric, '+', '-', ' ', '.', '_' allowed.", vim.log.levels.ERROR)
                  return
                end

                local new_file_path = get_prompt_file_path(prompts_dir, new_name)
                if vim.fn.filereadable(new_file_path) == 1 then
                  vim.notify("File '" .. new_file_path .. "' already exists.", vim.log.levels.ERROR)
                  return
                end

                local success, err = os.rename(selected_file_path, new_file_path)
                if not success then
                  vim.notify("Failed to rename file '" .. selected_item .. "': " .. (err or "unknown error"), vim.log.levels.ERROR)
                else
                  vim.notify("Renamed '" .. selected_item .. "' to '" .. new_name .. "'", vim.log.levels.INFO)
                end
                gen_opts.prompts = M.get_prompts(gen_opts) -- Reload prompts after changes
              end)
          elseif action:match("^Delete") then -- Delete
            local confirm_result = vim.fn.confirm("Delete '" .. selected_item .. "'?", "&Yes\n&No", 2)
            if confirm_result == 1 then -- User selected 'Yes'
              local success, err = os.remove(selected_file_path)
              if success then
                vim.notify("'" .. selected_item .. "' deleted", vim.log.levels.INFO)
              else
                vim.notify("Failed to delete file '" .. selected_item .. "': " .. (err or "unknown error"), vim.log.levels.ERROR)
              end
              gen_opts.prompts = M.get_prompts(gen_opts) -- Reload prompts after changes
            end
          end
        end
      )
    end
  end)
end

return M
