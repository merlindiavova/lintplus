-- lint+ - an improved linter for lite
-- copyright (C) lqdev, 2020
-- licensed under the MIT license


--- INTRODUCTION ---

-- a few reasons for why this and not the existing linter plugin:
-- · it can only show warnings
-- · it doesn't show error messages after lines, you have to hover over the
--   warning first
-- · it spam-runs the linter command, but Nim (and possibly other languages)
--   compiles relatively slowly
-- · it is not async, so when the lint command takes its sweet time your editor
--   freezes completely
-- · it doesn't display the first or current error message on the status view
-- this linter aims to fix any and all of the above problems.
-- however, there are still some issues with it:
-- · despite its asyncness, it still lags your editor a tiny bit when linting.
--   this cannot be fixed easily due to the fact that io.popen operations are
--   blocking, so if the lint command doesn't output anything for a while the
--   linter thread will stall until it gets some output
-- · due to the fact that it shows the most important message at the end of the
--   line, displaying more than one message per line is really difficult with
--   the limited horizontal real estate, so it can only display one message per
--   line. usually this isn't a problem though
-- · it is unable to display the offending token, simply because linter error
--   messages do not contain that information. it will highlight the line and
--   column, though.

--- CONFIG ---

-- config.lint.kind_pretty_names: {hint: string, warning: string, error: string}
--   defines the pretty names for displaying messages on the status view

--- CREATING LINTERS ---

-- the lint+ API is fairly simple:
--
--   -- the following example is a Nim linter
--   local lintplus = require "plugins.lint+"
--   lintplus.add {
--     filename = "%.nim$",
--     -- the linting procedure is a special table containing info on how to
--     -- run the lint command and interpret its output
--     procedure = {
--       command = lintplus.command "nim --listFullPaths --stdout $filename",
--       interpreter = lintplus.interpreter {
--         -- for this example, we use the general hint/warning/error
--         -- interpreter. this field is a function that gets called for each
--         -- line of the lint command's output
--         hint = "(.-)%((%d+), (%d+)%) Hint: (.+)",
--         warning = hint = "(.-)%((%d+), (%d+)%) Warning: (.+)",
--         error = "(.-)%((%d+), (%d+)%) Error: (.+)",
--         -- we can also add a strip action. this will remove the specified
--         -- pattern from the output
--         strip = "%s%[%w+%]$",
--       }
--     },
--   }


--- STATIC CONFIG ---

-- note that due to the nature of how this linter displays errors,
-- messages with lower priorities get overwritten by messages with higher
-- priorities
local kind_priority = {
  hint = 0,
  warning = 1,
  error = 2,
}

local default_kind_pretty_names = {
  hint = "H",
  warning = "W",
  error = "E",
}


--- IMPLEMENTATION ---


local command = require "core.command"
local config = require "core.config"
local core = require "core"
local style = require "core.style"

local Doc = require "core.doc"
local DocView = require "core.docview"
local StatusView = require "core.statusview"


local lint = {}
lint.index = {}


local function match_any(str, patts)
  if type(patts) == "string" then
    patts = { patts }
  end

  for _, patt in ipairs(patts) do
    if str:match(patt) then
      return true
    end
  end
  return false
end


function lint.get_linter_for_doc(doc)
  if not doc.filename then
    return nil
  end

  local file = system.absolute_path(doc.filename)
  for _, linter in pairs(lint.index) do
    if match_any(file, linter.filename) then
      return linter
    end
  end
end


local function process_line(doc, linter, line)
  local lp = doc.__lintplus
  local file = system.absolute_path(doc.filename)
  local ok, outfile, lineno, columnno, kind, message =
    linter.procedure.interpreter(file, line)

  if not ok then return false end
  if outfile ~= file then return false end

  assert(type(outfile) == "string")
  assert(type(lineno) == "number")
  assert(type(columnno) == "number")
  assert(type(kind) == "string")
  assert(type(message) == "string")

  if lp.messages[lineno] == nil or
     kind_priority[lp.messages[lineno].kind] < kind_priority[kind]
  then
    lp.messages[lineno] = {
      kind = kind,
      column = columnno,
      message = message,
    }
    core.redraw = true
    return true
  end
  return false
end


function lint.check(doc)
  if doc.filename == nil then
    return
  end

  local linter = lint.get_linter_for_doc(doc)
  if linter == nil then
    core.error("no linter available for the given filetype")
    return
  end

  doc.__lintplus = {
    line_count = #doc.lines
  }
  local lp = doc.__lintplus
  lp.messages = {}

  local line_count = 0
  core.add_thread(function ()
    local file = system.absolute_path(doc.filename)
    local lc = io.popen(linter.procedure.command(file), 'r')
    local line_buffer = {}
    local restrained = true

    for char in lc:lines(1) do
      if char == '\n' then
        if process_line(doc, linter, table.concat(line_buffer)) then
          restrained = false
        end
        line_buffer = {}
        line_count = line_count + 1
        if restrained or line_count % 32 == 0 then
          coroutine.yield(0)
          line_count = 0
        end
      elseif char ~= '\r' then
        table.insert(line_buffer, char)
        -- this slows the linting process a bit but should help reduce the
        -- lagginess due to blocking I/O
        if restrained and #line_buffer % 32 == 0 then
          coroutine.yield(0)
        end
      end
    end

    -- i always forget to close files :p
    lc:close()
  end)
end


-- inject hooks to Doc.insert and Doc.remove to shift messages around
local Doc_insert = Doc.insert
function Doc:insert(line, column, text)
  Doc_insert(self, line, column, text)

  if line == math.huge then return end

  local lp = self.__lintplus
  if lp ~= nil and #self.lines > lp.line_count then
    local shift = #self.lines - lp.line_count
    -- this sucks
    for i = #self.lines, line, -1 do
      if lp.messages[i] ~= nil then
        lp.messages[i + shift] = lp.messages[i]
        lp.messages[i] = nil
      end
    end
    lp.line_count = #self.lines
  end
end


local Doc_remove = Doc.remove
function Doc:remove(line1, column1, line2, column2)
  Doc_remove(self, line1, column1, line2, column2)

  if line2 == math.huge then return end

  local lp = self.__lintplus
  if line1 ~= line2 and lp ~= nil then
    local shift = lp.line_count - #self.lines
    -- remove all messages in this range
    local min, max = math.min(line1, line2), math.max(line1, line2)
    for i = min, max do
      lp.messages[i] = nil
    end
    -- shift all of them up
    for i = min, #self.lines do
      if lp.messages[i] ~= nil then
        lp.messages[i - shift] = lp.messages[i]
        lp.messages[i] = nil
      end
    end
    lp.line_count = #self.lines
  end
end


local function dup_color(color)
  return { color[1], color[2], color[3], color[4] }
end


local function draw_fading_rect(x, y, w, h, color, invert)
  local col = dup_color(color)
  for xx = x, x + w do
    local dx = xx - x
    local t = dx / w
    if invert then
      t = 1 - t
    end
    col[4] = color[4] * t
    renderer.draw_rect(xx, y, 1, h, col)
  end
end


local DocView_draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(idx, x, y)
  DocView_draw_line_text(self, idx, x, y)

  local lp = self.doc.__lintplus
  if lp == nil then return end

  local yy = y + self:get_line_text_y_offset() + self:get_line_height() - 1
  local msg = lp.messages[idx]
  if msg == nil then return end

  local font = self:get_font()
  local color = style.syntax["literal"]
  if style.lint ~= nil then
    color = style.lint[msg.kind]
  end
  local colx = font:get_width(self.doc.lines[idx]:sub(1, msg.column - 1))
  local w = font:get_width('w')

  local msgx = font:get_width(self.doc.lines[idx]) + w * 3
  local text = msg.message
  local textw = font:get_width(text)
  local linew = msgx + textw
  local lens_style = config.lint.lens_style or "dots"

  if lens_style == "dots" then
    for px = x + colx, x + linew, 2 do
      renderer.draw_rect(px, yy, 1, 1, color)
    end
  elseif lens_style == "fade" then
    local fadew = 48 * SCALE
    local transparent = dup_color(color)
    transparent[4] = transparent[4] * 0.1
    draw_fading_rect(x + colx, yy, fadew, 1, color, true)
    draw_fading_rect(x + msgx - fadew, yy, fadew, 1, color, false)
    renderer.draw_rect(x + msgx, yy, textw, 1, color)
    renderer.draw_rect(x + colx, yy, msgx, 1, transparent)
  end
  renderer.draw_text(font, text, x + msgx, y, color)
end


local function table_add(t, d)
  for _, v in ipairs(d) do
    table.insert(t, v)
  end
end


local function kind_pretty_name(kind)
  return (config.kind_pretty_names or default_kind_pretty_names)[kind]
end


local StatusView_get_items = StatusView.get_items
function StatusView:get_items()
  local left, right = StatusView_get_items(self)

  if getmetatable(core.active_view) == DocView and
     lint.get_linter_for_doc(core.active_view.doc)
  then
    local doc = core.active_view.doc
    local line1, _, line2, _ = doc:get_selection()
    local lp = doc.__lintplus
    if lp then
      if lp.messages[line1] and line1 == line2 then
        local msg = lp.messages[line1]
        table_add(left, {
          style.dim, self.separator2,
          kind_pretty_name(msg.kind), ": ",
          style.text, msg.message,
        })
      else
        local line, message = math.huge, nil
        for ln, msg in pairs(lp.messages) do
          if msg.kind == "error" and ln < line  then
            line, message = ln, msg
          end
        end
        if message ~= nil then
          table_add(left, {
            style.dim, self.separator2,
            "line ", tostring(line), " ", kind_pretty_name(message.kind), ": ",
            style.text, message.message,
          })
        end
      end
    end
  end

  return left, right
end


command.add(DocView, {
  ["lint+:check"] = function ()
    lint.check(core.active_view.doc)
  end
})


--- LINTER PLUGINS ---

function lint.add(name)
  return function (linter)
    lint.index[name] = linter
  end
end


--- SETUP ---

lint.setup = {}

function lint.setup.lint_on_doc_load()

  local Doc_load = Doc.load
  function Doc:load(...)
    Doc_load(self, ...)
    if lint.get_linter_for_doc(self) ~= nil then
      lint.check(self)
    end
  end

end

function lint.setup.lint_on_doc_save()

  local Doc_save = Doc.save
  function Doc:save(...)
    Doc_save(self, ...)
    if lint.get_linter_for_doc(self) ~= nil then
      lint.check(self)
    end
  end

end


--- LINTER CREATION UTILITIES ---


function lint.command(cmd)
  return function (filename)
    local c = cmd
    if type(cmd) == "function" then
      c = cmd()
    end
    return c:gsub('$filename', filename)
  end
end


function lint.args_command(cmd, config_option)
  return lint.command(function ()
    return cmd:gsub("$args", lint.config[config_option] or "")
  end)
end


function lint.interpreter(i)
  local patterns = {
    hint = i.hint,
    warning = i.warning,
    error = i.error,
  }
  local strip_pattern = i.strip

  return function (_, line)
    for kind, patt in pairs(patterns) do
      assert(
        type(patt) == "string",
        "lint+: interpreter pattern must be a string")
      local file, ln, column, message = line:match(patt)
      if file then
        if strip_pattern then
          message = message:gsub(strip_pattern, "")
        end
        return true, file, tonumber(ln), tonumber(column), kind, message
      end
    end
    return false
  end
end

if type(config.lint) ~= "table" then
  config.lint = {}
end
lint.config = config.lint


--- END ---

return lint
