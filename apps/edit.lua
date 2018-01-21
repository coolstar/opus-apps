local colors     = _G.colors
local fs         = _G.fs
local keys       = _G.keys
local multishell = _ENV.multishell
local os         = _G.os
local shell      = _ENV.shell
local term       = _G.term
local textutils  = _G.textutils

shell.setCompletionFunction(shell.getRunningProgram(), function(_, index, text)
  if index == 1 then
    return fs.complete(text, shell.dir(), true, false)
  end
end)

local tArgs = { ... }
if #tArgs == 0 then
  error( "Usage: edit <path>" )
end

-- Error checking
local sPath = shell.resolve(tArgs[1])
local bReadOnly = fs.isReadOnly(sPath)
if fs.exists(sPath) and fs.isDir(sPath) then
  error( "Cannot edit a directory." )
end

if multishell then
  multishell.setTitle(multishell.getCurrent(), fs.getName(sPath))
end

local x, y      = 1, 1
local w, h      = term.getSize()
local scrollX   = 0
local scrollY   = 0
local lastPos   = { x = 1, y = 1 }
local tLines    = { }
local input     = { pressed = { } }
local bRunning  = true
local sStatus   = ""
local isError
local fileInfo
local lastAction

local dirty     = { y = 1, ey = h }
local mark      = { }
local searchPattern
local undo      = { chain = { }, pointer = 0 }
local complete  = { }
local clipboard

-- do we need a clipboard shim
if not multishell or not _G.kernel then -- is this OpusOS ?
debug('nope')
  if _G.clipboard then -- has it been installed already
    clipboard = _G.clipboard
  else
    clipboard = { }

    function clipboard.setData(data)
      clipboard.data = data
    end

    function clipboard.getText()
      if clipboard.data then
        return tostring(clipboard.data)
      end
    end

    _G.clipboard = clipboard
  end
end

local color = {
  textColor       = '0',
  keywordColor    = '4',
  commentColor    = 'd',
  stringColor     = 'e',
  bgColor         = colors.black,
  highlightColor  = colors.orange,
  cursorColor     = colors.lime,
  errorBackground = colors.red,
}

if not term.isColor() then
  color = {
    textColor       = '0',
    keywordColor    = '8',
    commentColor    = '8',
    stringColor     = '8',
    bgColor         = colors.black,
    highlightColor  = colors.lightGray,
    cursorColor     = colors.white,
    errorBackground = colors.gray,
  }
end

local keyMapping = {
  -- movement
  up                        = 'up',
  down                      = 'down',
  left                      = 'left',
  right                     = 'right',
  pageUp                    = 'pageUp',
  [ 'control-b'           ] = 'pageUp',
  pageDown                  = 'pageDown',
--  [ 'control-f'           ] = 'pageDown',
  home                      = 'home',
  [ 'end'                 ] = 'toend',
  [ 'control-home'        ] = 'top',
  [ 'control-end'         ] = 'bottom',
  [ 'control-right'       ] = 'word',
  [ 'control-left'        ] = 'backword',
  [ 'scrollUp'            ] = 'scroll_up',
  [ 'control-up'          ] = 'scroll_up',
  [ 'scrollDown'          ] = 'scroll_down',
  [ 'control-down'        ] = 'scroll_down',
  [ 'mouse_click'         ] = 'go_to',
  [ 'control-l'           ] = 'goto_line',

  -- marking
  [ 'shift-up'            ] = 'mark_up',
  [ 'shift-down'          ] = 'mark_down',
  [ 'shift-left'          ] = 'mark_left',
  [ 'shift-right'         ] = 'mark_right',
  [ 'mouse_drag'          ] = 'mark_to',
  [ 'shift-mouse_click'   ] = 'mark_to',
  [ 'control-a'           ] = 'mark_all',
  [ 'control-shift-right' ] = 'mark_word',
  [ 'control-shift-left'  ] = 'mark_backword',
  [ 'shift-end'           ] = 'mark_end',
  [ 'shift-home'          ] = 'mark_home',

  -- editing
  delete                    = 'delete',
  backspace                 = 'backspace',
  enter                     = 'enter',
  char                      = 'char',
  paste                     = 'paste',
  tab                       = 'tab',
  [ 'control-z'           ] = 'undo',
  [ 'control-space'       ] = 'autocomplete',

  -- copy/paste
  [ 'control-x'           ] = 'cut',
  [ 'control-c'           ] = 'copy',
  [ 'control-shift-paste' ] = 'paste_internal',

  -- file
  [ 'control-s'           ] = 'save',
  [ 'control-q'           ] = 'exit',
  [ 'control-enter'       ] = 'run',

  -- search
  [ 'control-f'           ] = 'find_prompt',
  [ 'control-slash'       ] = 'find_prompt',
  [ 'control-n'           ] = 'find_next',

  -- misc
  [ 'control-g'           ] = 'status',
  [ 'control-r'           ] = 'refresh',
  [ 'control'             ] = 'menu',
}

local messages = {
  menu    = '^s: save, ^q: quit, ^enter: run',
  wrapped = 'search hit BOTTOM, continuing at TOP',
}
if w < 32 then
  messages = {
    menu    = '^s = save, ^q = quit',
    wrapped = 'search wrapped',
  }
end

local function getFileInfo(path)
  local abspath = shell.resolve(path)

  local fi = {
    abspath = abspath,
    path = path,
    isNew = not fs.exists(abspath),
    dirExists = fs.exists(fs.getDir(abspath)),
    modified = false,
  }
  if fi.isDir then
    fi.isReadOnly = true
  else
    fi.isReadOnly = fs.isReadOnly(fi.abspath)
  end

  return fi
end

local function setStatus(pattern, ...)
  sStatus = string.format(pattern, ...)
end

local function setError(pattern, ...)
  setStatus(pattern, ...)
  isError = true
end

local function load(path)
  tLines = {}
  if fs.exists(path) then
    local file = io.open(path, "r")
    local sLine = file:read()
    while sLine do
      table.insert(tLines, sLine)
      sLine = file:read()
    end
    file:close()
  end

  if #tLines == 0 then
    table.insert(tLines, '')
  end

  fileInfo = getFileInfo(tArgs[1])

  local name = fileInfo.path
  if w < 32 then
    name = fs.getName(fileInfo.path)
  end
  if fileInfo.isNew then
    if not fileInfo.dirExists then
      setStatus('"%s" [New DIRECTORY]', name)
    else
      setStatus('"%s" [New File]', name)
    end
  elseif fileInfo.isReadOnly then
    setStatus('"%s" [readonly] %dL, %dC',
          name, #tLines, fs.getSize(fileInfo.abspath))
  else
    setStatus('"%s" %dL, %dC',
          name, #tLines, fs.getSize(fileInfo.abspath))
  end
end

local function save( _sPath )
  -- Create intervening folder
  local sDir = _sPath:sub(1, _sPath:len() - fs.getName(_sPath):len() )
  if not fs.exists( sDir ) then
    fs.makeDir( sDir )
  end

  -- Save
  local file = nil
  local function innerSave()
    file = fs.open( _sPath, "w" )
    if file then
      for _,sLine in ipairs( tLines ) do
        file.write(sLine .. "\n")
      end
    else
      error( "Failed to open ".._sPath )
    end
  end

  local ok, err = pcall( innerSave )
  if file then
    file.close()
  end
  return ok, err
end

local function split(str, pattern)
  pattern = pattern or "(.-)\n"
  local t = {}
  local function helper(line) table.insert(t, line) return "" end
  helper((str:gsub(pattern, helper)))
  return t
end

local tKeywords = {
  ["and"] = true,
  ["break"] = true,
  ["do"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["end"] = true,
  ["false"] = true,
  ["for"] = true,
  ["function"] = true,
  ["if"] = true,
  ["in"] = true,
  ["local"] = true,
  ["nil"] = true,
  ["not"] = true,
  ["or"] = true,
  ["repeat"] = true,
  ["return"] = true,
  ["then"] = true,
  ["true"] = true,
  ["until"]= true,
  ["while"] = true,
}

local function writeHighlighted(sLine, ny)
  local buffer = {
    fg = '',
    text = '',
  }

  local function tryWrite(line, regex, fgcolor)
    local match = line:match(regex)
    if match then
      local fg
      if type(fgcolor) == "string" then
        fg = fgcolor
      else
        fg = fgcolor(match)
      end
      buffer.text = buffer.text .. match
      buffer.fg = buffer.fg .. string.rep(fg, #match)
      return line:sub(#match + 1)
    end
    return nil
  end

  while #sLine > 0 do
    sLine =
      tryWrite(sLine, "^%-%-%[%[.-%]%]", color.commentColor ) or
      tryWrite(sLine, "^%-%-.*",         color.commentColor ) or
      tryWrite(sLine, "^\".-[^\\]\"",    color.stringColor  ) or
      tryWrite(sLine, "^\'.-[^\\]\'",    color.stringColor  ) or
      tryWrite(sLine, "^%[%[.-%]%]",     color.stringColor  ) or
      tryWrite(sLine, "^[%w_]+", function(match)
        if tKeywords[match] then
          return color.keywordColor
        end
        return color.textColor
      end) or
      tryWrite(sLine, "^[^%w_]", color.textColor)
  end

  buffer.fg = buffer.fg .. '7'
  buffer.text = buffer.text .. '.'

  if mark.active and ny >= mark.y and ny <= mark.ey then
    local sx = 1
    if ny == mark.y then
      sx = mark.x
    end
    local ex = #buffer.text
    if ny == mark.ey then
      ex = mark.ex
    end
    buffer.bg = string.rep('f', sx - 1) ..
                string.rep('7', ex - sx) ..
                string.rep('f', #buffer.text - ex + 1)

  else
    buffer.bg = string.rep('f', #buffer.text)
  end

  term.blit(buffer.text, buffer.fg, buffer.bg)
end

local function redraw()
  if dirty.y > 0 then
    term.setBackgroundColor(color.bgColor)
    for dy = 1, h do

      local sLine = tLines[dy + scrollY]
      if sLine ~= nil then
        if dy + scrollY >= dirty.y and dy + scrollY <= dirty.ey then
          term.setCursorPos(1 - scrollX, dy)
          term.clearLine()
          writeHighlighted(sLine, dy + scrollY)
        end
      else
        term.setCursorPos(1 - scrollX, dy)
        term.clearLine()
      end
    end
  end

  -- Draw status
  if #sStatus > 0 then
    if isError then
      term.setTextColor(colors.white)
      term.setBackgroundColor(color.errorBackground)
    else
      term.setTextColor(color.highlightColor)
      term.setBackgroundColor(colors.gray)
    end
    term.setCursorPos(1, h)
    term.clearLine()
    term.write(string.format(' %s ', sStatus))
  end

  if not (w < 32 and #sStatus > 0) then
    local modifiedIndicator = ' '
    if undo.chain[1] then
      modifiedIndicator = '*'
    end

    local str = string.format(' %d:%d %s',
      y, x, modifiedIndicator)
    term.setTextColor(color.highlightColor)
    term.setBackgroundColor(colors.gray)
    term.setCursorPos(w - #str + 1, h)
    term.write(str)
  end

  term.setTextColor(color.cursorColor)
  term.setCursorPos(x - scrollX, y - scrollY)

  dirty.y, dirty.ey = 0, 0
  if #sStatus > 0 then
    sStatus = ''
    dirty.y = scrollY + h
    dirty.ey = dirty.y
  end
  isError = false
end

local function nextWord(line, cx)
  local result = { line:find("(%w+)", cx) }
  if #result > 1 and result[2] > cx then
    return result[2] + 1
  elseif #result > 0 and result[1] == cx then
    result = { line:find("(%w+)", result[2] + 1) }
    if #result > 0 then
      return result[1]
    end
  end
end

local function hacky_read()
  local _oldSetCursorPos = term.setCursorPos
  local _oldGetCursorPos = term.getCursorPos

  term.setCursorPos = function(cx)
    return _oldSetCursorPos(cx, h)
  end
  term.getCursorPos = function()
    local cx = _oldGetCursorPos()
    return cx, 1
  end

  local s, m = pcall(function() return _G.read() end)
  term.setCursorPos = _oldSetCursorPos
  term.getCursorPos = _oldGetCursorPos
  if s then
    return m
  end
  if m == 'Terminated' then
    bRunning = false
  end
  return ''
end

local actions
local __actions = {

  input = function(prompt)
    term.setTextColor(color.highlightColor)
    term.setBackgroundColor(colors.gray)
    term.setCursorPos(1, h)
    term.clearLine()
    term.write(prompt)
    local str = hacky_read()
    term.setCursorBlink(true)
    input:reset()
    term.setCursorPos(x - scrollX, y - scrollY)
    actions.dirty_line(scrollY + h)
    return str
  end,

  undo = function()
    local last = table.remove(undo.chain)
    if last then
      undo.active = true
      actions[last.action](unpack(last.args))
      undo.active = false
    else
      setStatus('Already at oldest change')
    end
  end,

  addUndo = function(entry)
    local last = undo.chain[#undo.chain]
    if last and last.action == entry.action then
      if last.action == 'deleteText' then
        if last.args[3] == entry.args[1] and
           last.args[4] == entry.args[2] then
          last.args = {
            last.args[1], last.args[2], entry.args[3], entry.args[4],
            last.args[5] .. entry.args[5]
          }
        else
          table.insert(undo.chain, entry)
        end
      else
        -- insertText (need to finish)
        table.insert(undo.chain, entry)
      end
    else
      table.insert(undo.chain, entry)
    end
  end,

  autocomplete = function()
    if lastAction ~= 'autocomplete' or not complete.results then
      local sLine = tLines[y]:sub(1, x - 1)
      local nStartPos = sLine:find("[a-zA-Z0-9_%.]+$")
      if nStartPos then
        sLine = sLine:sub(nStartPos)
      end
      if #sLine > 0 then
        complete.results = textutils.complete(sLine)
      else
        complete.results = { }
      end
      complete.index = 0
      complete.x = x
    end

    if #complete.results == 0 then
      setError('No completions available')

    elseif #complete.results == 1 then
      actions.insertText(x, y, complete.results[1])
      complete.results = nil

    elseif #complete.results > 1 then
      local prefix = complete.results[1]
      for n = 1, #complete.results do
        local result = complete.results[n]
        while #prefix > 0 do
          if result:find(prefix, 1, true) == 1 then
            break
          end
          prefix = prefix:sub(1, #prefix - 1)
        end
      end
      if #prefix > 0 then
        actions.insertText(x, y, prefix)
        complete.results = nil
      else
        if complete.index > 0 then
          actions.deleteText(complete.x, y, complete.x + #complete.results[complete.index], y)
        end
        complete.index = complete.index + 1
        if complete.index > #complete.results then
          complete.index = 1
        end
        actions.insertText(complete.x, y, complete.results[complete.index])
      end
    end
  end,

  refresh = function()
    actions.dirty_all()
    mark.continue = mark.active
    setStatus('refreshed')
  end,

  menu = function()
    setStatus(messages.menu)
    mark.continue = mark.active
  end,

  goto_line = function()
    local lineNo = tonumber(actions.input('Line: '))
    if lineNo then
      actions.go_to(1, lineNo)
    else
      setStatus('Invalid line number')
    end
  end,

  find = function(pattern, sx)
    local nLines = #tLines
    for i = 1, nLines + 1 do
      local ny = y + i - 1
      if ny > nLines then
        ny = ny - nLines
      end
      local nx = tLines[ny]:lower():find(pattern, sx)
      if nx then
        if ny < y or ny == y and nx <= x then
          setStatus(messages.wrapped)
        end
        actions.go_to(nx, ny)
        actions.mark_to(nx + #pattern, ny)
        actions.go_to(nx, ny)
        return
      end
      sx = 1
    end
    setError('Pattern not found')
  end,

  find_next = function()
    if searchPattern then
      actions.unmark()
      actions.find(searchPattern, x + 1)
    end
  end,

  find_prompt = function()
    local text = actions.input('/')
    if #text > 0 then
      searchPattern = text:lower()
      if searchPattern then
        actions.unmark()
        actions.find(searchPattern, x)
      end
    end
  end,

  save = function()
    if bReadOnly then
      setError("Access denied")
    else
      local ok = save(sPath)
      if ok then
        setStatus('"%s" %dL, %dC written',
           fileInfo.path, #tLines, fs.getSize(fileInfo.abspath))
      else
        setError("Error saving to %s", sPath)
      end
    end
  end,

  exit = function()
    bRunning = false
  end,

  run = function()
    local sTempPath = "/.temp"
    local ok = save(sTempPath)
    if ok then
      local nTask = shell.openTab(sTempPath)
      if nTask then
        shell.switchTab(nTask)
      else
        setError("Error starting Task")
      end
      os.sleep(0)
      fs.delete(sTempPath)
    else
      setError("Error saving to %s", sTempPath)
    end
  end,

  status = function()
    local modified = ''
    if undo.chain[1] then
      modified = '[Modified] '
    end
    setStatus('"%s" %s%d lines --%d%%--',
         fileInfo.path, modified, #tLines,
         math.floor((y - 1) / (#tLines - 1) * 100))
  end,

  dirty_line = function(dy)
    if dirty.y == 0 then
      dirty.y = dy
      dirty.ey = dy
    else
      dirty.y = math.min(dirty.y, dy)
      dirty.ey = math.max(dirty.ey, dy)
    end
  end,

  dirty_range = function(dy, dey)
    actions.dirty_line(dy)
    actions.dirty_line(dey or #tLines)
  end,

  dirty = function()
    actions.dirty_line(y)
  end,

  dirty_all = function()
    actions.dirty_line(1)
    actions.dirty_line(#tLines)
  end,

  mark_begin = function()
    actions.dirty()
    if not mark.active then
      mark.active = true
      mark.anchor = { x = x, y = y }
    end
  end,

  mark_finish = function()
    if y == mark.anchor.y then
      if x == mark.anchor.x then
        mark.active = false
      else
        mark.x = math.min(mark.anchor.x, x)
        mark.y = y
        mark.ex = math.max(mark.anchor.x, x)
        mark.ey = y
      end
    elseif y < mark.anchor.y then
      mark.x = x
      mark.y = y
      mark.ex = mark.anchor.x
      mark.ey = mark.anchor.y
    else
      mark.x = mark.anchor.x
      mark.y = mark.anchor.y
      mark.ex = x
      mark.ey = y
    end
    actions.dirty()
    mark.continue = mark.active
  end,

  unmark = function()
    if mark.active then
      actions.dirty_range(mark.y, mark.ey)
      mark.active = false
    end
  end,

  mark_to = function(nx, ny)
    actions.mark_begin()
    actions.go_to(nx, ny)
    actions.mark_finish()
  end,

  mark_up = function()
    actions.mark_begin()
    actions.up()
    actions.mark_finish()
  end,

  mark_right = function()
    actions.mark_begin()
    actions.right()
    actions.mark_finish()
  end,

  mark_down = function()
    actions.mark_begin()
    actions.down()
    actions.mark_finish()
  end,

  mark_left = function()
    actions.mark_begin()
    actions.left()
    actions.mark_finish()
  end,

  mark_word = function()
    actions.mark_begin()
    actions.word()
    actions.mark_finish()
  end,

  mark_backword = function()
    actions.mark_begin()
    actions.backword()
    actions.mark_finish()
  end,

  mark_home = function()
    actions.mark_begin()
    actions.home()
    actions.mark_finish()
  end,

  mark_end = function()
    actions.mark_begin()
    actions.toend()
    actions.mark_finish()
  end,

  mark_all = function()
    mark.anchor = { x = 1, y = 1 }
    mark.active = true
    mark.continue = true
    mark.x = 1
    mark.y = 1
    mark.ey = #tLines
    mark.ex = #tLines[mark.ey] + 1
    actions.dirty_all()
  end,

  setCursor = function()
    lastPos.x = x
    lastPos.y = y

    local screenX = x - scrollX
    local screenY = y - scrollY

    if screenX < 1 then
      scrollX = x - 1
      actions.dirty_all()
    elseif screenX > w then
      scrollX = x - w
      actions.dirty_all()
    end

    if screenY < 1 then
      scrollY = y - 1
      actions.dirty_all()
    elseif screenY > h - 1 then
      scrollY = y - (h - 1)
      actions.dirty_all()
    end
  end,

  top = function()
    actions.go_to(1, 1)
  end,

  bottom = function()
    y = #tLines
    x = #tLines[y] + 1
  end,

  up = function()
    if y > 1 then
      x = math.min(x, #tLines[y - 1] + 1)
      y = y - 1
    end
  end,

  down = function()
    if y < #tLines then
      x = math.min(x, #tLines[y + 1] + 1)
      y = y + 1
    end
  end,

  tab = function()
    if mark.active then
      actions.delete()
    end
    actions.insertText(x, y, '  ')
  end,

  pageUp = function()
    actions.go_to(x, y - (h - 1))
  end,

  pageDown = function()
    actions.go_to(x, y + (h - 1))
  end,

  home = function()
    x = 1
  end,

  toend = function()
    x = #tLines[y] + 1
  end,

  left = function()
    if x > 1 then
      x = x - 1
    elseif y > 1 then
      x = #tLines[y - 1] + 1
      y = y - 1
    else
      return false
    end
    return true
  end,

  right = function()
    if x < #tLines[y] + 1 then
      x = x + 1
    elseif y < #tLines then
      x = 1
      y = y + 1
    end
  end,

  word = function()
    local nx = nextWord(tLines[y], x)
    if nx then
      x = nx
    elseif x < #tLines[y] + 1 then
      x = #tLines[y] + 1
    elseif y < #tLines then
      x = 1
      y = y + 1
    end
  end,

  backword = function()
    if x == 1 then
      actions.left()
    else
      local sLine = tLines[y]
      local lx = 1
      while true do
        local nx = nextWord(sLine, lx)
        if not nx or nx >= x then
          break
        end
        lx = nx
      end
      if not lx then
        x = 1
      else
        x = lx
      end
    end
  end,

  insertText = function(sx, sy, text)
    x = sx
    y = sy
    local sLine = tLines[y]

    if not text:find('\n') then
      tLines[y] = sLine:sub(1, x - 1) .. text .. sLine:sub(x)
      actions.dirty_line(y)
      x = x + #text
    else
      local lines = split(text)
      local remainder = sLine:sub(x)
      tLines[y] = sLine:sub(1, x - 1) .. lines[1]
      actions.dirty_range(y, #tLines + #lines)
      x = x + #lines[1]
      for k = 2, #lines do
        y = y + 1
        table.insert(tLines, y, lines[k])
        x = #lines[k] + 1
      end
      tLines[y] = tLines[y]:sub(1, x) .. remainder
    end

    if not undo.active then
      actions.addUndo(
        { action = 'deleteText', args = { sx, sy, x, y, text } })
    end
  end,

  deleteText = function(sx, sy, ex, ey)
    x = sx
    y = sy

    if not undo.active then
      local text = actions.copyText(sx, sy, ex, ey)
      actions.addUndo(
        { action = 'insertText', args = { sx, sy, text } })
    end

    local front = tLines[sy]:sub(1, sx - 1)
    local back = tLines[ey]:sub(ex, #tLines[ey])
    for _ = 2, ey - sy + 1 do
      table.remove(tLines, y + 1)
    end
    tLines[y] = front .. back
    if sy ~= ey then
      actions.dirty_range(y)
    else
      actions.dirty()
    end
  end,

  copyText = function(csx, csy, cex, cey)
    local count = 0
    local lines = { }

    for cy = csy, cey do
      local line = tLines[cy]
      if line then
        local cx = 1
        local ex = #line
        if cy == csy then
          cx = csx
        end
        if cy == cey then
          ex = cex - 1
        end
        local str = line:sub(cx, ex)
        count = count + #str
        table.insert(lines, str)
      end
    end
    return table.concat(lines, '\n'), count
  end,

  delete = function()
    if mark.active then
      actions.deleteText(mark.x, mark.y, mark.ex, mark.ey)
    else
      local nLimit = #tLines[y] + 1
      if x < nLimit then
        actions.deleteText(x, y, x + 1, y)
      elseif y < #tLines then
        actions.deleteText(x, y, 1, y + 1)
      end
    end
  end,

  backspace = function()
    if mark.active then
      actions.delete()
    elseif actions.left() then
      actions.delete()
    end
  end,

  enter = function()
    local sLine = tLines[y]
    local _,spaces = sLine:find("^[ ]+")
    if not spaces then
      spaces = 0
    end
    spaces = math.min(spaces, x - 1)
    if mark.active then
      actions.delete()
    end
    actions.insertText(x, y, '\n' .. string.rep(' ', spaces))
  end,

  char = function(ch)
    if mark.active then
      actions.delete()
    end
    actions.insertText(x, y, ch)
  end,

  copy_marked = function()
    local text = actions.copyText(mark.x, mark.y, mark.ex, mark.ey)
    if clipboard then
      clipboard.setData(text)
    else
debug(text)
      os.queueEvent('clipboard_copy', text)
    end
    setStatus('shift-^v to paste')
  end,

  cut = function()
    if mark.active then
      actions.copy_marked()
      actions.delete()
    end
  end,

  copy = function()
    if mark.active then
      actions.copy_marked()
      mark.continue = true
    end
  end,

  paste = function(text)
    if mark.active then
      actions.delete()
    end
    if text then
      actions.insertText(x, y, text)
      setStatus('%d chars added', #text)
    else
      setStatus('Clipboard empty')
    end
  end,

  paste_internal = function()
    if clipboard then
      actions.paste(clipboard.getText())
    end
  end,

  go_to = function(cx, cy)
    y = math.min(math.max(cy, 1), #tLines)
    x = math.min(math.max(cx, 1), #tLines[y] + 1)
  end,

  scroll_up = function()
    if scrollY > 0 then
      scrollY = scrollY - 1
      actions.dirty_all()
    end
    mark.continue = mark.active
  end,

  scroll_down = function()
    local nMaxScroll = #tLines - (h-1)
    if scrollY < nMaxScroll then
      scrollY = scrollY + 1
      actions.dirty_all()
    end
    mark.continue = mark.active
  end,
}

actions = __actions

local modifiers = {
  [ keys.leftCtrl   ] = true,
  [ keys.rightCtrl  ] = true,
  [ keys.leftShift  ] = true,
  [ keys.rightShift ] = true,
  [ keys.leftAlt    ] = true,
  [ keys.rightAlt   ] = true,
}

function input:modifierPressed()
  return self.pressed[keys.leftCtrl] or
         self.pressed[keys.rightCtrl] or
         self.pressed[keys.leftAlt] or
         self.pressed[keys.rightAlt]
end

function input:toCode(ch, code)
  local result = { }

  if self.pressed[keys.leftCtrl] or self.pressed[keys.rightCtrl] then
    table.insert(result, 'control')
  end

  if self.pressed[keys.leftAlt] or self.pressed[keys.rightAlt] then
    table.insert(result, 'alt')
  end

  if self.pressed[keys.leftShift] or self.pressed[keys.rightShift] then
    if code and modifiers[code] then
      table.insert(result, 'shift')
    elseif #ch == 1 then
      table.insert(result, ch:upper())
    else
      table.insert(result, 'shift')
      table.insert(result, ch)
    end
  elseif not code or not modifiers[code] then
    table.insert(result, ch)
  end

  return table.concat(result, '-')
end

function input:reset()
  self.pressed = { }
  self.fired = nil

  self.timer = nil
  self.mch = nil
  self.mfired = nil
end

function input:translate(event, code, p1, p2)
  if event == 'key' then
    if p1 then -- key is held down
      if not modifiers[code] then
        self.fired = true
        return input:toCode(keys.getName(code), code)
      end
    else
      self.pressed[code] = true
      if self:modifierPressed() and not modifiers[code] or code == 57 then
        self.fired = true
        return input:toCode(keys.getName(code), code)
      else
        self.fired = false
      end
    end

  elseif event == 'char' then
    if not self:modifierPressed() then
      self.fired = true
      return input:toCode(code)
    end

  elseif event == 'key_up' then
    if not self.fired then
      if self.pressed[code] then
        self.fired = true
        local ch = input:toCode(keys.getName(code), code)
        self.pressed[code] = nil
        return ch
      end
    end
    self.pressed[code] = nil

  elseif event == 'paste' then
    self.pressed[keys.leftCtrl] = nil
    self.pressed[keys.rightCtrl] = nil
    self.fired = true
    if clipboard then
      return 'paste'
    end
    return input:toCode('paste', 255)

  elseif event == 'mouse_click' then
    local buttons = { 'mouse_click', 'mouse_rightclick' }
    self.mch = buttons[code]
    self.mfired = nil

  elseif event == 'mouse_drag' then
    self.mfired = true
    self.fired = true
    return input:toCode('mouse_drag', 255)

  elseif event == 'mouse_up' then
    if not self.mfired then
      local clock = os.clock()
      if self.timer and
         p1 == self.x and p2 == self.y and
         (clock - self.timer < .5) then

        self.mch = 'mouse_doubleclick'
        self.timer = nil
      else
        self.timer = os.clock()
        self.x = p1
        self.y = p2
      end
      self.mfired = input:toCode(self.mch, 255)
    else
      self.mch = 'mouse_up'
      self.mfired = input:toCode(self.mch, 255)
    end
    self.fired = true
    return self.mfired

  elseif event == "mouse_scroll" then
    local directions = {
      [ -1 ] = 'scrollUp',
      [  1 ] = 'scrollDown'
    }
    self.fired = true
    return input:toCode(directions[code], 255)
  end
end

load(sPath)
term.setCursorBlink(true)
redraw()

while bRunning do
  local sEvent, param, param2, param3 = os.pullEventRaw()
  local action

  if sEvent == 'terminate' then
    action = 'exit'
  elseif sEvent == 'multishell_focus' then -- opus only event
    input:reset()
  elseif sEvent == "mouse_click" or sEvent == 'mouse_drag' or sEvent == 'mouse_up' then
    local ch = input:translate(sEvent, param, param2, param3)
    if param3 < h or sEvent == 'mouse_drag' then
      if ch then
        action = keyMapping[ch]
        param = param2 + scrollX
        param2 = param3 + scrollY
      end
    end
  else
    local ch = input:translate(sEvent, param, param2)
    if ch then
      if #ch == 1 then
        action = keyMapping.char
        param = ch
      else
        action = keyMapping[ch]
      end
    end
  end

  if action then
    if not actions[action] then
      error('Invaid action: ' .. action)
    end

    local wasMarking = mark.continue
    mark.continue = false

    actions[action](param, param2)
    if action ~= 'menu' then
      lastAction = action
    end

    if x ~= lastPos.x or y ~= lastPos.y then
      actions.setCursor()
    end
    if not mark.continue and wasMarking then
      actions.unmark()
    end

    redraw()

  elseif sEvent == "term_resize" then
    w,h = term.getSize()
    actions.setCursor(x, y)
    actions.dirty_all()
    redraw()
  end
end

-- Cleanup
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorBlink(false)
term.setCursorPos(1, 1)
