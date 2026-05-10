-- study-flow.lua
-- Quarto shortcode that renders CONSORT, STROBE, and PRISMA flow diagrams
-- from structured YAML in document frontmatter. Pure Lua: SVG for HTML,
-- TikZ for LaTeX/PDF. No external dependencies.

-- ===========================================================================
-- Text utilities
-- ===========================================================================

local function xml_escape(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub('"', "&quot;")
  s = s:gsub("'", "&apos;")
  return s
end

local function tex_escape(s)
  s = tostring(s or "")
  -- Backslash MUST be replaced first to avoid double-escaping
  s = s:gsub("\\", "\\textbackslash{}")
  s = s:gsub("&", "\\&")
  s = s:gsub("%%", "\\%%")
  s = s:gsub("%$", "\\$")
  s = s:gsub("#", "\\#")
  s = s:gsub("_", "\\_")
  s = s:gsub("{", "\\{")
  s = s:gsub("}", "\\}")
  s = s:gsub("~", "\\textasciitilde{}")
  s = s:gsub("%^", "\\textasciicircum{}")
  -- Normalise common Unicode glyphs to LaTeX commands so plain pdflatex works
  s = s:gsub("\226\128\162", "\\textbullet{}")  -- U+2022 BULLET
  s = s:gsub("\226\137\165", "$\\geq$")          -- U+2265
  s = s:gsub("\226\137\164", "$\\leq$")          -- U+2264
  s = s:gsub("\226\128\147", "--")               -- U+2013 EN DASH
  s = s:gsub("\226\128\148", "---")              -- U+2014 EM DASH
  return s
end

-- Greedy word-wrap to a maximum number of characters per line.
local function wrap_text(s, max_chars)
  s = tostring(s or "")
  max_chars = max_chars or 36
  local lines = {}
  for paragraph in (s .. "\n"):gmatch("(.-)\n") do
    local words = {}
    for w in paragraph:gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then
      -- skip empty paragraphs entirely
    else
      local current = ""
      for _, w in ipairs(words) do
        if #current == 0 then
          current = w
        elseif #current + 1 + #w <= max_chars then
          current = current .. " " .. w
        else
          lines[#lines + 1] = current
          current = w
        end
      end
      if #current > 0 then lines[#lines + 1] = current end
    end
  end
  if #lines == 0 then lines[1] = "" end
  return lines
end

-- ===========================================================================
-- Pandoc Meta -> plain Lua tables
-- ===========================================================================

local INLINE_TAGS = {
  Str = true, Space = true, Emph = true, Strong = true, Code = true,
  Link = true, Math = true, SoftBreak = true, LineBreak = true,
  RawInline = true, Quoted = true, Subscript = true, Superscript = true,
  Underline = true, Strikeout = true, SmallCaps = true,
}

local function meta_to_value(v)
  if v == nil then return nil end
  local tv = type(v)
  if tv == "string" or tv == "number" or tv == "boolean" then return v end
  if tv ~= "table" and tv ~= "userdata" then return tostring(v) end

  local tag = v.t or v.tag
  if tag == "MetaInlines" or tag == "MetaBlocks" or tag == "Inlines" or tag == "Blocks" then
    return pandoc.utils.stringify(v)
  end
  if tag == "MetaString" then
    return v.c or v[1] or ""
  end
  if tag == "MetaBool" then
    if v.c ~= nil then return v.c end
    return v[1]
  end
  if tag == "MetaList" then
    local out = {}
    for i, item in ipairs(v.c or v) do out[i] = meta_to_value(item) end
    return out
  end
  if tag == "MetaMap" then
    local out = {}
    for k, item in pairs(v.c or v) do
      if k ~= "t" and k ~= "tag" and k ~= "c" then
        out[k] = meta_to_value(item)
      end
    end
    return out
  end
  -- A bare Pandoc Inline element (e.g. Str passed without an enclosing list)
  if tag and INLINE_TAGS[tag] then
    return pandoc.utils.stringify(v)
  end

  -- Untagged table or Pandoc List/Inlines userdata
  local has_array = false
  if tv == "table" then
    has_array = #v > 0
  else
    local ok, len = pcall(function() return #v end)
    has_array = ok and (len or 0) > 0
  end

  if has_array then
    local first = v[1]
    if type(first) == "table" or type(first) == "userdata" then
      local ftag = first.t or first.tag
      if ftag and INLINE_TAGS[ftag] then
        return pandoc.utils.stringify(v)
      end
    end
    local out = {}
    for i, item in ipairs(v) do out[i] = meta_to_value(item) end
    return out
  end

  local out = {}
  for k, item in pairs(v) do
    if k ~= "t" and k ~= "tag" and k ~= "c" then
      out[k] = meta_to_value(item)
    end
  end
  return out
end

local function as_str(v, default)
  if v == nil then return default or "" end
  if type(v) == "table" then
    local ok, s = pcall(pandoc.utils.stringify, v)
    if ok then return s end
    return default or ""
  end
  return tostring(v)
end

-- ===========================================================================
-- Layout primitives
-- ===========================================================================

local FONT_SIZE   = 13
local LINE_HEIGHT = 17
local PAD_X       = 12
local PAD_Y       = 12
local MIN_BOX_H   = 50

local BOX_W   = 280
local SPACE_X = 40
local SPACE_Y = 50
local MARGIN  = 30

local WRAP_DEFAULT = 32

local function box_height(lines)
  return math.max(MIN_BOX_H, #lines * LINE_HEIGHT + 2 * PAD_Y)
end

local function new_diagram()
  return { width = 0, height = 0, elements = {} }
end

local function add_box(d, x, y, w, h, lines)
  table.insert(d.elements, { kind = "box", x = x, y = y, w = w, h = h, lines = lines })
end

local function add_line(d, x1, y1, x2, y2)
  table.insert(d.elements, { kind = "line", x1 = x1, y1 = y1, x2 = x2, y2 = y2 })
end

local function add_arrow(d, x1, y1, x2, y2)
  table.insert(d.elements, { kind = "arrow", x1 = x1, y1 = y1, x2 = x2, y2 = y2 })
end

-- Borderless text region (used for axis labels, e.g. STARD 2x2 headers)
local function add_label(d, x, y, w, h, lines)
  table.insert(d.elements, { kind = "label", x = x, y = y, w = w, h = h, lines = lines })
end

-- Append wrapped bullet items to an existing line list
local function append_bullets(lines, items, wrap_w)
  if not items then return end
  for _, r in ipairs(items) do
    local wrapped = wrap_text("\226\128\162 " .. as_str(r), wrap_w or WRAP_DEFAULT)
    for _, ln in ipairs(wrapped) do table.insert(lines, ln) end
  end
end

-- ===========================================================================
-- CONSORT layout (RCT: Enrolment -> Allocation -> Follow-up -> Analysis)
-- ===========================================================================

local function build_consort(data)
  local d = new_diagram()
  local enrol = data.enrollment or data.enrolment or {}
  local groups = data.groups or {}
  local n = #groups
  if n < 1 then
    quarto.log.warning("study-flow: CONSORT requires at least one group")
    return d
  end

  local assessed_lines = wrap_text(
    "Assessed for eligibility (n=" .. as_str(enrol.assessed, "?") .. ")",
    WRAP_DEFAULT)

  local excluded_lines = { "Excluded (n=" .. as_str(enrol.excluded, "?") .. ")" }
  append_bullets(excluded_lines, enrol.exclusion_reasons)

  local randomised = data.randomised or data.randomized
  local rand_lines = wrap_text(
    "Randomised (n=" .. as_str(randomised, "?") .. ")", WRAP_DEFAULT)

  local alloc_lines, follow_lines, analysis_lines = {}, {}, {}
  for i, g in ipairs(groups) do
    local label = as_str(g.label, "Group " .. i)
    local al = { "Allocated to " .. label .. " (n=" .. as_str(g.allocated, "?") .. ")" }
    if g.received ~= nil then
      table.insert(al, "Received intervention (n=" .. as_str(g.received) .. ")")
    end
    if g.not_received ~= nil then
      table.insert(al, "Did not receive (n=" .. as_str(g.not_received) .. ")")
    end
    alloc_lines[i] = al

    local fl = { "Lost to follow-up (n=" .. as_str(g.lost_followup, "0") .. ")" }
    append_bullets(fl, g.lost_reasons)
    if g.discontinued ~= nil then
      table.insert(fl, "Discontinued intervention (n=" .. as_str(g.discontinued) .. ")")
      append_bullets(fl, g.discontinued_reasons)
    end
    follow_lines[i] = fl

    local an = { "Analysed (n=" .. as_str(g.analysed, "?") .. ")" }
    if g.excluded_analysis ~= nil then
      table.insert(an, "Excluded from analysis (n=" .. as_str(g.excluded_analysis) .. ")")
      append_bullets(an, g.excluded_analysis_reasons)
    end
    analysis_lines[i] = an
  end

  local h_assessed = box_height(assessed_lines)
  local h_excluded = box_height(excluded_lines)
  local h_rand     = box_height(rand_lines)
  local h_alloc, h_follow, h_analysis = 0, 0, 0
  for i = 1, n do
    h_alloc    = math.max(h_alloc, box_height(alloc_lines[i]))
    h_follow   = math.max(h_follow, box_height(follow_lines[i]))
    h_analysis = math.max(h_analysis, box_height(analysis_lines[i]))
  end

  local groups_w = n * BOX_W + (n - 1) * SPACE_X
  -- Width must be wide enough that a CENTERED Assessed box does not overlap
  -- a RIGHT-ALIGNED Excluded box: assessed.right + SPACE_X <= excluded.left
  -- => W >= 3*BOX_W + 2*SPACE_X + 2*MARGIN
  local min_enrolment_w = 3 * BOX_W + 2 * SPACE_X + 2 * MARGIN
  local W = math.max(groups_w + 2 * MARGIN, min_enrolment_w)
  d.width = W
  local cx = W / 2

  local groups_start_x = (W - groups_w) / 2
  local function col_x(i)  return groups_start_x + (i - 1) * (BOX_W + SPACE_X) end
  local function col_cx(i) return col_x(i) + BOX_W / 2 end

  local row1_h    = math.max(h_assessed, h_excluded)
  local y_assessed = MARGIN
  local y_rand     = y_assessed + row1_h + SPACE_Y
  local y_alloc    = y_rand + h_rand + SPACE_Y
  local y_follow   = y_alloc + h_alloc + SPACE_Y
  local y_analysis = y_follow + h_follow + SPACE_Y
  d.height = y_analysis + h_analysis + MARGIN

  -- Enrolment row: assessed centred, excluded on the right
  add_box(d, cx - BOX_W / 2, y_assessed, BOX_W, h_assessed, assessed_lines)
  local x_excl = W - MARGIN - BOX_W
  add_box(d, x_excl, y_assessed, BOX_W, h_excluded, excluded_lines)

  -- Main vertical down to randomised, with branch arrow to excluded
  add_arrow(d, cx, y_assessed + h_assessed, cx, y_rand)
  local cy_excluded = y_assessed + h_excluded / 2
  local branch_y = math.max(cy_excluded, y_assessed + h_assessed + 8)
  if branch_y < y_rand then
    add_arrow(d, cx, branch_y, x_excl, branch_y)
  end

  -- Randomised box
  add_box(d, cx - BOX_W / 2, y_rand, BOX_W, h_rand, rand_lines)

  -- Split into N group columns
  if n == 1 then
    add_arrow(d, cx, y_rand + h_rand, col_cx(1), y_alloc)
  else
    local y_split = (y_rand + h_rand + y_alloc) / 2
    add_line(d, cx, y_rand + h_rand, cx, y_split)
    add_line(d, col_cx(1), y_split, col_cx(n), y_split)
    for i = 1, n do
      add_arrow(d, col_cx(i), y_split, col_cx(i), y_alloc)
    end
  end

  -- Per-group rows
  for i = 1, n do
    add_box(d, col_x(i), y_alloc,    BOX_W, h_alloc,    alloc_lines[i])
    add_box(d, col_x(i), y_follow,   BOX_W, h_follow,   follow_lines[i])
    add_box(d, col_x(i), y_analysis, BOX_W, h_analysis, analysis_lines[i])
    add_arrow(d, col_cx(i), y_alloc + h_alloc,   col_cx(i), y_follow)
    add_arrow(d, col_cx(i), y_follow + h_follow, col_cx(i), y_analysis)
  end

  return d
end

-- ===========================================================================
-- STROBE layout (observational: Source -> Eligible -> Enrolled -> Groups)
-- ===========================================================================

local function build_strobe(data)
  local d = new_diagram()

  local function make_top_stage(stage_data, default_label)
    if not stage_data then return nil end
    local label = as_str(stage_data.label, default_label)
    local main = wrap_text(label .. " (n=" .. as_str(stage_data.n, "?") .. ")", WRAP_DEFAULT)
    local excl = nil
    if stage_data.excluded ~= nil or stage_data.exclusion_reasons then
      excl = { "Excluded (n=" .. as_str(stage_data.excluded, "?") .. ")" }
      append_bullets(excl, stage_data.exclusion_reasons)
    end
    return { main = main, excluded = excl }
  end

  local top_stages = {}
  local s = make_top_stage(data.source,   "Source population"); if s then top_stages[#top_stages+1] = s end
  s        = make_top_stage(data.eligible, "Eligible");          if s then top_stages[#top_stages+1] = s end
  s        = make_top_stage(data.enrolled, "Enrolled");          if s then top_stages[#top_stages+1] = s end

  local groups = data.groups or {}
  local n = #groups
  local group_alloc, group_followup, group_analysed = {}, {}, {}
  local has_followup = false
  for i, g in ipairs(groups) do
    local label = as_str(g.label, "Group " .. i)
    group_alloc[i] = wrap_text(label .. " (n=" .. as_str(g.n, "?") .. ")", WRAP_DEFAULT)

    if g.lost_followup ~= nil or g.lost_reasons then
      has_followup = true
      local fl = { "Lost to follow-up (n=" .. as_str(g.lost_followup, "0") .. ")" }
      append_bullets(fl, g.lost_reasons)
      group_followup[i] = fl
    end

    local an = { "Analysed (n=" .. as_str(g.analysed, "?") .. ")" }
    if g.excluded_analysis ~= nil then
      table.insert(an, "Excluded (n=" .. as_str(g.excluded_analysis) .. ")")
      append_bullets(an, g.excluded_analysis_reasons)
    end
    group_analysed[i] = an
  end

  -- Backfill missing follow-up rows when at least one group has follow-up
  if has_followup then
    for i = 1, n do
      if not group_followup[i] then
        group_followup[i] = { "Lost to follow-up (n=0)" }
      end
    end
  end

  if #top_stages == 0 and n == 0 then
    quarto.log.warning("study-flow: STROBE requires at least one stage or group")
    return d
  end

  -- Compute heights
  local top_h = {}
  for i, st in ipairs(top_stages) do
    local hm = box_height(st.main)
    local he = st.excluded and box_height(st.excluded) or 0
    top_h[i] = { main = hm, excl = he, row = math.max(hm, he) }
  end
  local h_g_alloc, h_g_follow, h_g_analysed = 0, 0, 0
  for i = 1, n do
    h_g_alloc = math.max(h_g_alloc, box_height(group_alloc[i]))
    if has_followup then
      h_g_follow = math.max(h_g_follow, box_height(group_followup[i]))
    end
    h_g_analysed = math.max(h_g_analysed, box_height(group_analysed[i]))
  end

  -- Layout: ensure centered main box does not overlap right-aligned
  -- excluded sidebar (same constraint as CONSORT enrolment row)
  local groups_w = n > 0 and (n * BOX_W + (n - 1) * SPACE_X) or 0
  local min_w_with_sidebar = 3 * BOX_W + 2 * SPACE_X + 2 * MARGIN
  local W = math.max(groups_w + 2 * MARGIN, min_w_with_sidebar)
  d.width = W
  local cx = W / 2
  local groups_start_x = (W - groups_w) / 2
  local function col_x(i)  return groups_start_x + (i - 1) * (BOX_W + SPACE_X) end
  local function col_cx(i) return col_x(i) + BOX_W / 2 end

  -- Compute Y positions
  local y_top = {}
  local y = MARGIN
  for i, h in ipairs(top_h) do
    y_top[i] = y
    y = y + h.row
    if i < #top_h then y = y + SPACE_Y end
  end

  local y_alloc, y_follow, y_analysed
  if n > 0 then
    if #top_h > 0 then y = y + SPACE_Y end
    y_alloc = y
    y = y + h_g_alloc + SPACE_Y
    if has_followup then
      y_follow = y
      y = y + h_g_follow + SPACE_Y
    end
    y_analysed = y
    y = y + h_g_analysed
  end
  d.height = y + MARGIN

  -- Place top stages
  for i, st in ipairs(top_stages) do
    local h  = top_h[i]
    local sy = y_top[i]
    add_box(d, cx - BOX_W / 2, sy, BOX_W, h.main, st.main)
    if st.excluded then
      local x_excl = W - MARGIN - BOX_W
      add_box(d, x_excl, sy, BOX_W, h.excl, st.excluded)
      local cy_excl = sy + h.excl / 2
      local branch_y = math.max(cy_excl, sy + h.main + 8)
      local next_y = (i < #top_h) and y_top[i+1] or (n > 0 and y_alloc or nil)
      if next_y and branch_y < next_y then
        add_arrow(d, cx, branch_y, x_excl, branch_y)
      else
        -- fall back to side-of-box arrow
        add_arrow(d, cx + BOX_W / 2, cy_excl, x_excl, cy_excl)
      end
    end
    if i < #top_h then
      add_arrow(d, cx, sy + h.main, cx, y_top[i+1])
    end
  end

  -- Connect last top stage to groups
  if n > 0 and #top_h > 0 then
    local last_i = #top_h
    local bot_y  = y_top[last_i] + top_h[last_i].main
    if n == 1 then
      add_arrow(d, cx, bot_y, col_cx(1), y_alloc)
    else
      local y_split = (bot_y + y_alloc) / 2
      add_line(d, cx, bot_y, cx, y_split)
      add_line(d, col_cx(1), y_split, col_cx(n), y_split)
      for i = 1, n do
        add_arrow(d, col_cx(i), y_split, col_cx(i), y_alloc)
      end
    end
  end

  -- Place group rows
  for i = 1, n do
    add_box(d, col_x(i), y_alloc, BOX_W, h_g_alloc, group_alloc[i])
    if has_followup then
      add_box(d, col_x(i), y_follow, BOX_W, h_g_follow, group_followup[i])
      add_arrow(d, col_cx(i), y_alloc + h_g_alloc,   col_cx(i), y_follow)
      add_arrow(d, col_cx(i), y_follow + h_g_follow, col_cx(i), y_analysed)
    else
      add_arrow(d, col_cx(i), y_alloc + h_g_alloc, col_cx(i), y_analysed)
    end
    add_box(d, col_x(i), y_analysed, BOX_W, h_g_analysed, group_analysed[i])
  end

  return d
end

-- ===========================================================================
-- TRIPOD+AI 2024 layout (clinical prediction model studies)
-- Optional Source/Eligible spine, then 1+ parallel cohort columns
-- (e.g., development + external validation). Each cohort: identity row +
-- outcome (events / no events) row.
-- ===========================================================================

local function build_tripod(data)
  local d = new_diagram()

  -- Optional top spine
  local top_stages = {}
  if data.source then
    local s = data.source
    local label = as_str(s.label, "Source population")
    local main = wrap_text(label .. " (n=" .. as_str(s.n, "?") .. ")", WRAP_DEFAULT)
    top_stages[#top_stages+1] = { main = main, side = nil }
  end
  if data.eligibility then
    local e = data.eligibility
    local label = as_str(e.label, "Eligible")
    local main = wrap_text(label .. " (n=" .. as_str(e.n, "?") .. ")", WRAP_DEFAULT)
    local side = nil
    if e.excluded ~= nil or e.exclusion_reasons then
      side = { "Excluded (n=" .. as_str(e.excluded, "?") .. ")" }
      append_bullets(side, e.exclusion_reasons)
    end
    top_stages[#top_stages+1] = { main = main, side = side }
  end

  local cohorts = data.cohorts or {}
  local n = #cohorts
  if n < 1 then
    quarto.log.warning("study-flow: TRIPOD requires at least one cohort")
    return d
  end

  -- Per-cohort text: identity row + outcome row
  local cohort_top, cohort_outcome = {}, {}
  for i, c in ipairs(cohorts) do
    local label = as_str(c.label, "Cohort " .. i)
    local top = { label .. " (n=" .. as_str(c.n, "?") .. ")" }
    if c.excluded_missing ~= nil or c.excluded_missing_reasons then
      table.insert(top, "Excluded for missing data (n=" .. as_str(c.excluded_missing, "?") .. ")")
      append_bullets(top, c.excluded_missing_reasons)
    end
    cohort_top[i] = top

    local out = {}
    if c.analysed ~= nil then
      table.insert(out, "Analysed (n=" .. as_str(c.analysed) .. ")")
    end
    if c.events ~= nil then
      table.insert(out, "With outcome (n=" .. as_str(c.events) .. ")")
    end
    if c.no_events ~= nil then
      table.insert(out, "Without outcome (n=" .. as_str(c.no_events) .. ")")
    end
    if #out == 0 then table.insert(out, "Final analysis sample") end
    cohort_outcome[i] = out
  end

  -- Heights
  local top_h = {}
  for i, st in ipairs(top_stages) do
    local hm = box_height(st.main)
    local hs = st.side and box_height(st.side) or 0
    top_h[i] = { main = hm, side = hs, row = math.max(hm, hs) }
  end
  local h_c_top, h_c_out = 0, 0
  for i = 1, n do
    h_c_top = math.max(h_c_top, box_height(cohort_top[i]))
    h_c_out = math.max(h_c_out, box_height(cohort_outcome[i]))
  end

  -- Layout: must avoid centred-spine / right-sidebar overlap (same rule as
  -- CONSORT enrolment row)
  local groups_w = n * BOX_W + (n - 1) * SPACE_X
  local min_w_with_sidebar = 3 * BOX_W + 2 * SPACE_X + 2 * MARGIN
  local W = math.max(groups_w + 2 * MARGIN, min_w_with_sidebar)
  d.width = W
  local cx = W / 2
  local groups_start_x = (W - groups_w) / 2
  local function col_x(i)  return groups_start_x + (i - 1) * (BOX_W + SPACE_X) end
  local function col_cx(i) return col_x(i) + BOX_W / 2 end

  -- Y positions
  local y_top = {}
  local y = MARGIN
  for i, h in ipairs(top_h) do
    y_top[i] = y
    y = y + h.row
    if i < #top_h then y = y + SPACE_Y end
  end
  if #top_h > 0 then y = y + SPACE_Y end
  local y_cohort_top = y
  y = y + h_c_top + SPACE_Y
  local y_cohort_out = y
  y = y + h_c_out
  d.height = y + MARGIN

  -- Spine
  for i, st in ipairs(top_stages) do
    local h = top_h[i]
    local sy = y_top[i]
    add_box(d, cx - BOX_W / 2, sy, BOX_W, h.main, st.main)
    if st.side then
      local x_side = W - MARGIN - BOX_W
      add_box(d, x_side, sy, BOX_W, h.side, st.side)
      local cy_side = sy + h.side / 2
      local branch_y = math.max(cy_side, sy + h.main + 8)
      local next_y = (i < #top_h) and y_top[i+1] or y_cohort_top
      if branch_y < next_y then
        add_arrow(d, cx, branch_y, x_side, branch_y)
      else
        add_arrow(d, cx + BOX_W / 2, cy_side, x_side, cy_side)
      end
    end
    if i < #top_h then
      add_arrow(d, cx, sy + h.main, cx, y_top[i+1])
    end
  end

  -- Connect spine to cohort columns
  if #top_h > 0 then
    local last_i = #top_h
    local bot_y = y_top[last_i] + top_h[last_i].main
    if n == 1 then
      add_arrow(d, cx, bot_y, col_cx(1), y_cohort_top)
    else
      local y_split = (bot_y + y_cohort_top) / 2
      add_line(d, cx, bot_y, cx, y_split)
      add_line(d, col_cx(1), y_split, col_cx(n), y_split)
      for i = 1, n do
        add_arrow(d, col_cx(i), y_split, col_cx(i), y_cohort_top)
      end
    end
  end

  -- Cohort rows
  for i = 1, n do
    add_box(d, col_x(i), y_cohort_top, BOX_W, h_c_top, cohort_top[i])
    add_box(d, col_x(i), y_cohort_out, BOX_W, h_c_out, cohort_outcome[i])
    add_arrow(d, col_cx(i), y_cohort_top + h_c_top, col_cx(i), y_cohort_out)
  end

  return d
end

-- ===========================================================================
-- STARD 2015 layout (diagnostic accuracy studies)
-- Four-row spine (Assessed, Enrolled, Index test, Reference standard) with
-- optional right-side excluded/not-received sidebars, plus a 2x2 contingency
-- grid (TP/FP/FN/TN) below with axis labels.
-- ===========================================================================

local function build_stard(data)
  local d = new_diagram()

  -- Spine row text
  local assessed_lines = wrap_text(
    "Assessed for eligibility (n=" .. as_str(data.assessed, "?") .. ")", WRAP_DEFAULT)

  local excluded_lines = nil
  if data.excluded ~= nil or data.exclusion_reasons then
    excluded_lines = { "Excluded (n=" .. as_str(data.excluded, "?") .. ")" }
    append_bullets(excluded_lines, data.exclusion_reasons)
  end

  local enrolled_lines = wrap_text(
    "Enrolled (n=" .. as_str(data.enrolled, "?") .. ")", WRAP_DEFAULT)

  local idx_n = data.index_test or data.enrolled
  local index_lines = wrap_text(
    "Received index test (n=" .. as_str(idx_n, "?") .. ")", WRAP_DEFAULT)

  local not_idx_lines = nil
  if data.not_index ~= nil or data.not_index_reasons then
    not_idx_lines = { "Did not receive index test (n=" .. as_str(data.not_index, "?") .. ")" }
    append_bullets(not_idx_lines, data.not_index_reasons)
  end

  local ref_n = data.reference_standard or idx_n
  local ref_lines = wrap_text(
    "Received reference standard (n=" .. as_str(ref_n, "?") .. ")", WRAP_DEFAULT)

  local not_ref_lines = nil
  if data.not_reference ~= nil or data.not_reference_reasons then
    not_ref_lines = { "Did not receive reference standard (n=" .. as_str(data.not_reference, "?") .. ")" }
    append_bullets(not_ref_lines, data.not_reference_reasons)
  end

  -- Outcomes (2x2)
  local out = data.outcomes or {}
  if not (out.true_positive or out.false_positive or out.false_negative or out.true_negative) then
    quarto.log.warning("study-flow: STARD requires outcomes (true_positive, false_positive, false_negative, true_negative)")
  end
  local tp_text = "True positive (n=" .. as_str(out.true_positive, "?") .. ")"
  local fp_text = "False positive (n=" .. as_str(out.false_positive, "?") .. ")"
  local fn_text = "False negative (n=" .. as_str(out.false_negative, "?") .. ")"
  local tn_text = "True negative (n=" .. as_str(out.true_negative, "?") .. ")"

  local spine_rows = {
    { main = assessed_lines, side = excluded_lines },
    { main = enrolled_lines, side = nil },
    { main = index_lines,    side = not_idx_lines },
    { main = ref_lines,      side = not_ref_lines },
  }

  local row_h = {}
  for i, r in ipairs(spine_rows) do
    local hm = box_height(r.main)
    local hs = r.side and box_height(r.side) or 0
    row_h[i] = { main = hm, side = hs, row = math.max(hm, hs) }
  end

  -- 2x2 grid dimensions
  local CELL_W = 200
  local CELL_H = 60
  local ROW_HDR_W = 140
  local COL_HDR_H = 28
  local grid_w = 2 * CELL_W
  local grid_h = 2 * CELL_H
  local grid_block_w = ROW_HDR_W + grid_w
  local grid_block_h = COL_HDR_H + grid_h

  local min_spine_w = 3 * BOX_W + 2 * SPACE_X + 2 * MARGIN
  local min_grid_w  = grid_block_w + 2 * MARGIN
  local W = math.max(min_spine_w, min_grid_w)
  d.width = W
  local cx = W / 2

  -- Y positions
  local y_pos = {}
  local y = MARGIN
  for i, h in ipairs(row_h) do
    y_pos[i] = y
    y = y + h.row + SPACE_Y
  end
  local y_grid = y
  d.height = y + grid_block_h + MARGIN

  -- Spine
  for i, r in ipairs(spine_rows) do
    local sy = y_pos[i]
    local h  = row_h[i]
    add_box(d, cx - BOX_W / 2, sy, BOX_W, h.main, r.main)
    if r.side then
      local x_side = W - MARGIN - BOX_W
      add_box(d, x_side, sy, BOX_W, h.side, r.side)
      local cy_side = sy + h.side / 2
      local next_y = (i < #spine_rows) and y_pos[i+1] or y_grid
      local branch_y = math.max(cy_side, sy + h.main + 8)
      if branch_y < next_y then
        add_arrow(d, cx, branch_y, x_side, branch_y)
      else
        add_arrow(d, cx + BOX_W / 2, cy_side, x_side, cy_side)
      end
    end
    if i < #spine_rows then
      add_arrow(d, cx, sy + h.main, cx, y_pos[i+1])
    end
  end

  -- 2x2 grid block centred under spine
  local grid_x_start = cx - grid_block_w / 2
  local rh_x   = grid_x_start
  local cell_x1 = rh_x + ROW_HDR_W
  local cell_x2 = cell_x1 + CELL_W
  local col_y   = y_grid
  local cell_y1 = col_y + COL_HDR_H
  local cell_y2 = cell_y1 + CELL_H
  local cx_tp = cell_x1 + CELL_W / 2
  local cx_fp = cell_x2 + CELL_W / 2

  -- Connection: spine → T-split into top of TP and FP cells
  local last_i = #spine_rows
  local bot_y  = y_pos[last_i] + row_h[last_i].main
  local y_split = (bot_y + col_y) / 2
  add_line(d, cx, bot_y, cx, y_split)
  local left_x  = math.min(cx, cx_tp)
  local right_x = math.max(cx, cx_fp)
  add_line(d, left_x, y_split, right_x, y_split)
  -- Arrows stop at the top of the column header strip so the header text
  -- isn't overprinted by the arrow line.
  add_arrow(d, cx_tp, y_split, cx_tp, col_y)
  add_arrow(d, cx_fp, y_split, cx_fp, col_y)

  -- Column headers (above cells)
  add_label(d, cell_x1, col_y, CELL_W, COL_HDR_H, { "Reference standard +" })
  add_label(d, cell_x2, col_y, CELL_W, COL_HDR_H, { "Reference standard \xe2\x88\x92" })
  -- Row headers (left of cells)
  add_label(d, rh_x, cell_y1, ROW_HDR_W, CELL_H, { "Index test +" })
  add_label(d, rh_x, cell_y2, ROW_HDR_W, CELL_H, { "Index test \xe2\x88\x92" })
  -- 2x2 cells (touching, no gap)
  add_box(d, cell_x1, cell_y1, CELL_W, CELL_H, { tp_text })
  add_box(d, cell_x2, cell_y1, CELL_W, CELL_H, { fp_text })
  add_box(d, cell_x1, cell_y2, CELL_W, CELL_H, { fn_text })
  add_box(d, cell_x2, cell_y2, CELL_W, CELL_H, { tn_text })

  return d
end

-- ===========================================================================
-- PRISMA 2020 layout (systematic review)
-- ===========================================================================

local function build_prisma(data)
  local d = new_diagram()
  local ident  = data.identification or {}
  local screen = data.screening      or {}
  local inc    = data.included       or {}

  local rows = {}  -- list of { main = lines, side = lines or nil }

  -- Row 1: Records identified
  local box1 = { "Records identified from:" }
  if ident.databases ~= nil then
    table.insert(box1, "Databases (n=" .. as_str(ident.databases) .. ")")
  end
  if ident.registers ~= nil then
    table.insert(box1, "Registers (n=" .. as_str(ident.registers) .. ")")
  end
  if #box1 == 1 then table.insert(box1, "(n=?)") end

  local side1 = nil
  if ident.duplicates_removed ~= nil
      or ident.ineligible_automation ~= nil
      or ident.other_removed ~= nil then
    side1 = { "Records removed before screening:" }
    if ident.duplicates_removed ~= nil then
      append_bullets(side1, { "Duplicate records removed (n=" .. as_str(ident.duplicates_removed) .. ")" })
    end
    if ident.ineligible_automation ~= nil then
      append_bullets(side1, { "Records marked ineligible by automation tools (n=" .. as_str(ident.ineligible_automation) .. ")" })
    end
    if ident.other_removed ~= nil then
      append_bullets(side1, { "Records removed for other reasons (n=" .. as_str(ident.other_removed) .. ")" })
    end
  end
  table.insert(rows, { main = box1, side = side1 })

  -- Row 2: Records screened
  if screen.screened ~= nil then
    local main = wrap_text("Records screened (n=" .. as_str(screen.screened) .. ")", WRAP_DEFAULT)
    local side = nil
    if screen.excluded ~= nil then
      side = wrap_text("Records excluded (n=" .. as_str(screen.excluded) .. ")", WRAP_DEFAULT)
    end
    table.insert(rows, { main = main, side = side })
  end

  -- Row 3: Reports sought for retrieval
  if screen.sought_retrieval ~= nil then
    local main = wrap_text("Reports sought for retrieval (n=" .. as_str(screen.sought_retrieval) .. ")", WRAP_DEFAULT)
    local side = nil
    if screen.not_retrieved ~= nil then
      side = wrap_text("Reports not retrieved (n=" .. as_str(screen.not_retrieved) .. ")", WRAP_DEFAULT)
    end
    table.insert(rows, { main = main, side = side })
  end

  -- Row 4: Reports assessed for eligibility
  if screen.assessed ~= nil then
    local main = wrap_text("Reports assessed for eligibility (n=" .. as_str(screen.assessed) .. ")", WRAP_DEFAULT)
    local side = nil
    if screen.excluded_with_reasons then
      side = { "Reports excluded:" }
      append_bullets(side, screen.excluded_with_reasons)
    end
    table.insert(rows, { main = main, side = side })
  end

  -- Row 5: Studies included in review
  local box5 = nil
  if inc.studies ~= nil or inc.reports ~= nil then
    box5 = {}
    if inc.studies ~= nil then
      local w = wrap_text("Studies included in review (n=" .. as_str(inc.studies) .. ")", WRAP_DEFAULT)
      for _, ln in ipairs(w) do table.insert(box5, ln) end
    end
    if inc.reports ~= nil then
      local w = wrap_text("Reports of included studies (n=" .. as_str(inc.reports) .. ")", WRAP_DEFAULT)
      for _, ln in ipairs(w) do table.insert(box5, ln) end
    end
  end
  if box5 then table.insert(rows, { main = box5, side = nil }) end

  if #rows == 0 then
    quarto.log.warning("study-flow: PRISMA requires at least one populated row")
    return d
  end

  -- Layout
  local W = BOX_W * 2 + SPACE_X + 2 * MARGIN
  d.width = W
  local x_main  = MARGIN
  local x_side  = MARGIN + BOX_W + SPACE_X
  local cx_main = x_main + BOX_W / 2

  local row_h = {}
  for i, r in ipairs(rows) do
    local hm = box_height(r.main)
    local hs = r.side and box_height(r.side) or 0
    row_h[i] = { main = hm, side = hs, row = math.max(hm, hs) }
  end

  local y_pos = {}
  local y = MARGIN
  for i, h in ipairs(row_h) do
    y_pos[i] = y
    y = y + h.row + SPACE_Y
  end
  d.height = y - SPACE_Y + MARGIN

  for i, r in ipairs(rows) do
    local sy = y_pos[i]
    local h  = row_h[i]
    add_box(d, x_main, sy, BOX_W, h.main, r.main)
    if r.side then
      add_box(d, x_side, sy, BOX_W, h.side, r.side)
      local cy_side = sy + h.side / 2
      add_arrow(d, x_main + BOX_W, cy_side, x_side, cy_side)
    end
    if i < #rows then
      add_arrow(d, cx_main, sy + h.main, cx_main, y_pos[i+1])
    end
  end

  return d
end

-- ===========================================================================
-- SVG renderer
-- ===========================================================================

local function fmt_num(x)
  -- Avoid trailing zeros / locale decimal commas
  if x == math.floor(x) then return tostring(math.floor(x)) end
  return string.format("%.2f", x)
end

local function render_svg(d)
  local p = {}
  p[#p+1] = string.format(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="100%%" preserveAspectRatio="xMidYMid meet" font-family="Helvetica, Arial, sans-serif">',
    fmt_num(d.width), fmt_num(d.height))
  p[#p+1] = '<defs><marker id="sf-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" fill="#000"/></marker></defs>'

  for _, e in ipairs(d.elements) do
    if e.kind == "box" then
      p[#p+1] = string.format(
        '<rect x="%s" y="%s" width="%s" height="%s" fill="white" stroke="black" stroke-width="1.2" rx="2"/>',
        fmt_num(e.x), fmt_num(e.y), fmt_num(e.w), fmt_num(e.h))
      local total = #e.lines * LINE_HEIGHT
      local first_y = e.y + (e.h - total) / 2 + FONT_SIZE - 2
      for i, line in ipairs(e.lines) do
        p[#p+1] = string.format(
          '<text x="%s" y="%s" font-size="%d" text-anchor="middle" fill="black">%s</text>',
          fmt_num(e.x + e.w / 2), fmt_num(first_y + (i - 1) * LINE_HEIGHT),
          FONT_SIZE, xml_escape(line))
      end
    elseif e.kind == "label" then
      local total = #e.lines * LINE_HEIGHT
      local first_y = e.y + (e.h - total) / 2 + FONT_SIZE - 2
      for i, line in ipairs(e.lines) do
        p[#p+1] = string.format(
          '<text x="%s" y="%s" font-size="%d" text-anchor="middle" fill="black">%s</text>',
          fmt_num(e.x + e.w / 2), fmt_num(first_y + (i - 1) * LINE_HEIGHT),
          FONT_SIZE, xml_escape(line))
      end
    elseif e.kind == "line" then
      p[#p+1] = string.format(
        '<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="black" stroke-width="1.2"/>',
        fmt_num(e.x1), fmt_num(e.y1), fmt_num(e.x2), fmt_num(e.y2))
    elseif e.kind == "arrow" then
      p[#p+1] = string.format(
        '<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="black" stroke-width="1.2" marker-end="url(#sf-arrow)"/>',
        fmt_num(e.x1), fmt_num(e.y1), fmt_num(e.x2), fmt_num(e.y2))
    end
  end

  p[#p+1] = "</svg>"
  return table.concat(p, "\n")
end

-- ===========================================================================
-- TikZ renderer (LaTeX/PDF). Coordinates use SVG pixel space with the y-axis
-- flipped via [x=1pt, y=-1pt]; \resizebox{\linewidth}{!}{...} fits the page.
-- ===========================================================================

local function render_tikz(d)
  local p = {}
  p[#p+1] = "\\begin{center}"
  p[#p+1] = "\\resizebox{\\linewidth}{!}{%"
  p[#p+1] = "\\begin{tikzpicture}[x=1pt, y=-1pt, "
            .. "every node/.style={inner sep=0pt, outer sep=0pt}, "
            .. ">={Latex[length=2.4mm,width=1.8mm]}, line width=1pt]"
  -- Outer bounding box (transparent) ensures TikZ uses the full canvas
  p[#p+1] = string.format(
    "\\path[use as bounding box] (0,0) rectangle (%s, %s);",
    fmt_num(d.width), fmt_num(d.height))

  for _, e in ipairs(d.elements) do
    if e.kind == "box" then
      p[#p+1] = string.format(
        "\\draw[fill=white, rounded corners=1pt] (%s, %s) rectangle (%s, %s);",
        fmt_num(e.x), fmt_num(e.y),
        fmt_num(e.x + e.w), fmt_num(e.y + e.h))
      local escaped = {}
      for i, line in ipairs(e.lines) do escaped[i] = tex_escape(line) end
      local content = table.concat(escaped, " \\\\ ")
      p[#p+1] = string.format(
        "\\node[align=center, text width=%spt, font=\\fontsize{%d}{%d}\\selectfont] at (%s, %s) {%s};",
        fmt_num(e.w - 2 * PAD_X), FONT_SIZE, LINE_HEIGHT,
        fmt_num(e.x + e.w / 2), fmt_num(e.y + e.h / 2),
        content)
    elseif e.kind == "label" then
      local escaped = {}
      for i, line in ipairs(e.lines) do escaped[i] = tex_escape(line) end
      local content = table.concat(escaped, " \\\\ ")
      p[#p+1] = string.format(
        "\\node[align=center, text width=%spt, font=\\fontsize{%d}{%d}\\selectfont] at (%s, %s) {%s};",
        fmt_num(e.w - 2 * PAD_X), FONT_SIZE, LINE_HEIGHT,
        fmt_num(e.x + e.w / 2), fmt_num(e.y + e.h / 2),
        content)
    elseif e.kind == "line" then
      p[#p+1] = string.format(
        "\\draw (%s, %s) -- (%s, %s);",
        fmt_num(e.x1), fmt_num(e.y1), fmt_num(e.x2), fmt_num(e.y2))
    elseif e.kind == "arrow" then
      p[#p+1] = string.format(
        "\\draw[->] (%s, %s) -- (%s, %s);",
        fmt_num(e.x1), fmt_num(e.y1), fmt_num(e.x2), fmt_num(e.y2))
    end
  end

  p[#p+1] = "\\end{tikzpicture}%"
  p[#p+1] = "}"
  p[#p+1] = "\\end{center}"
  return table.concat(p, "\n")
end

-- ===========================================================================
-- Shortcode handler
-- ===========================================================================

local builders = {
  consort = build_consort,
  strobe  = build_strobe,
  prisma  = build_prisma,
  tripod  = build_tripod,
  stard   = build_stard,
}

local tikz_setup_done = false
local function ensure_tikz_setup()
  if tikz_setup_done then return end
  tikz_setup_done = true
  quarto.doc.use_latex_package("tikz")
  quarto.doc.use_latex_package("graphicx")
  quarto.doc.include_text("in-header", "\\usetikzlibrary{arrows.meta}")
end

return {
  ["study-flow"] = function(args, kwargs, meta)
    local raw = meta and meta["study-flow"]
    if not raw then
      quarto.log.warning("study-flow: no 'study-flow' metadata key found")
      return pandoc.Null()
    end

    local data = meta_to_value(raw)
    if type(data) ~= "table" or not data.type then
      quarto.log.warning("study-flow: 'type' field missing in metadata")
      return pandoc.Null()
    end

    local builder = builders[as_str(data.type):lower()]
    if not builder then
      quarto.log.warning("study-flow: unknown type '" .. as_str(data.type) .. "' (expected consort, strobe, prisma, tripod, or stard)")
      return pandoc.Null()
    end

    local diagram = builder(data)

    if quarto.doc.is_format("html") or quarto.doc.is_format("html:js") or quarto.doc.is_format("revealjs") then
      local svg = render_svg(diagram)
      return pandoc.RawBlock("html", '<div class="study-flow-figure">' .. svg .. "</div>")
    elseif quarto.doc.is_format("latex") or quarto.doc.is_format("pdf") or quarto.doc.is_format("beamer") then
      ensure_tikz_setup()
      return pandoc.RawBlock("latex", render_tikz(diagram))
    else
      -- Fallback: ship raw SVG and hope the writer accepts HTML passthrough
      return pandoc.RawBlock("html", render_svg(diagram))
    end
  end,
}
