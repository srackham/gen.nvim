local prompts = {
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

      -- Parse header options until ending delimiter
      while i <= #lines and not (lines[i]:match "^%-%-%-$" or lines[i]:match "^___$") do
        -- Skip lines beginning with #
        if not lines[i]:match "^%s*#" then
          local key, value = lines[i]:match "^([^:]+):%s*(.+)$"
          if key and value then
            -- Convert boolean values
            if value == "true" then
              options[key] = true
            elseif value == "false" then
              options[key] = false
            else
              options[key] = value
            end
          end
        end
        i = i + 1
      end

      -- Skip the ending delimiter
      if i <= #lines then
        i = i + 1
      end

      -- Collect the prompt text until next header or EOF
      local prompt_lines = {}
      while i <= #lines and not (lines[i]:match "^%-%-%-$" or lines[i]:match "^___$") do
        -- Skip lines beginning with #
        if not lines[i]:match "^%s*#" then
          table.insert(prompt_lines, lines[i])
        end
        i = i + 1
      end

      -- If we have a name option, create the prompt entry
      if options.name then
        -- Convert name to valid Lua table key (replace spaces with underscores)
        local key = options.name:gsub("%s+", "_")
        options.name = nil -- Remove name from options since it's used as key
        options.prompt = table.concat(prompt_lines, "\n")
        result[key] = options
      end
    else
      i = i + 1
    end
  end

  return result
end

-- Check if user prompts file exists and merge with default prompts
local user_prompts_path = vim.fn.stdpath "data" .. "/gen_nvim/defaults.prompts.md"
if vim.fn.filereadable(user_prompts_path) == 1 then
  local file_content = vim.fn.readfile(user_prompts_path)
  if file_content then
    local user_prompts = parse_markdown_prompts(table.concat(file_content, "\n"))
    if type(user_prompts) == "table" then
      for key, value in pairs(user_prompts) do
        prompts[key] = value
      end
    end
  end
end

return prompts
