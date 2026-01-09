local M = {}

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

-- Defer vim.notify until the event loop. Because calling vim.notify directly at the top level of a plugin
-- triggers a stack trace because the Neovim UI hasn't fully initialized yet.
local function notify(msg, level, opts)
  vim.schedule(function()
    vim.notify(msg, level, opts)
  end)
end

-- Function to parse prompts from Markdown file
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
            notify("Malformed header option format at line " .. i .. ": " .. lines[i], vim.log.levels.ERROR)
            return nil
          end

          -- Check option names
          if not (key == "name" or key == "model" or key == "extract" or key == "replace") then
            notify(
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
            notify(
              "Invalid replace value '" .. value .. "' at line " .. i .. ". Must be 'true','false','after' or 'before'",
              vim.log.levels.ERROR
            )
            return nil
          end

          -- Convert values
          if key == "replace" and (value == "true" or value == "false") then
            options[key] = value == "true"
          elseif key == "extract" then
            -- Validate regex by attempting to compile it
            local success, _ = pcall(string.match, "", value)
            if not success then
              notify("Invalid regex in extract option at line " .. i .. ": " .. value, vim.log.levels.ERROR)
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
        notify("Missing closing header line after header starting at line " .. header_start_line, vim.log.levels.ERROR)
        return nil
      end

      -- Check for missing name option
      if not has_name then
        notify("Missing required 'name' option in header starting at line " .. header_start_line, vim.log.levels.ERROR)
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

function M.get_prompts(opts)
  local prompts = {}
  if not opts.custom_prompts_only then
    print "CHECKPOINT 1"
    prompts = builtin_prompts
  end
  -- Read and merge prompts from all .prompts.md files
  local prompts_dir = vim.fn.stdpath "data" .. "/gen_nvim/"
  local glob_pattern = prompts_dir .. "*.prompts.md"
  local prompt_files = vim.fn.glob(glob_pattern, false, true)

  for _, file_path in ipairs(prompt_files) do
    if vim.fn.filereadable(file_path) == 1 then
      local file_content = vim.fn.readfile(file_path)
      if file_content then
        local custom_prompts = parse_markdown_prompts(table.concat(file_content, "\n"))
        if custom_prompts then
          for key, value in pairs(custom_prompts) do
            prompts[key] = value
          end
        else
          notify("Failed to parse prompts from '" .. file_path .. "', skipping.", vim.log.levels.ERROR)
        end
      end
    end
  end
  return prompts
end

return M
