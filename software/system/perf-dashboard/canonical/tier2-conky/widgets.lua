-- Managed by: software/system/perf-dashboard/canonical/tier2-conky/widgets.lua
-- Threshold-based color tags for the perf-dashboard Conky widget.

-- Tunable thresholds. mem_res values from `${top_mem mem_res N}` are like
-- "1234M" or "2.4G" — parsed below.
local CPU_YELLOW = 30   -- pct
local CPU_RED    = 50
local MEM_YELLOW_MB = 1024
local MEM_RED_MB    = 2048

-- Strip a trailing "%" if present and convert to number.
local function pct_to_num(s)
  if not s then return 0 end
  s = s:gsub('%%', '')
  return tonumber(s) or 0
end

-- Parse a value like "1.2G" or "850M" or "1234K" into MB.
local function mem_to_mb(s)
  if not s then return 0 end
  local n, unit = s:match('([%d%.]+)([KMGT]?)')
  n = tonumber(n) or 0
  unit = unit or ''
  if     unit == 'G' then return n * 1024
  elseif unit == 'M' then return n
  elseif unit == 'K' then return n / 1024
  elseif unit == 'T' then return n * 1024 * 1024
  else                    return n / (1024 * 1024)   -- bytes
  end
end

-- Conky hook: called as ${lua_parse cpu_color <pct>}.
function conky_cpu_color(pct_str)
  local pct = pct_to_num(pct_str)
  if pct >= CPU_RED    then return "${color red}"    end
  if pct >= CPU_YELLOW then return "${color yellow}" end
  return "${color white}"
end

-- Conky hook: called as ${lua_parse mem_color <mem_res>}.
function conky_mem_color(mem_str)
  local mb = mem_to_mb(mem_str)
  if mb >= MEM_RED_MB    then return "${color red}"    end
  if mb >= MEM_YELLOW_MB then return "${color yellow}" end
  return "${color white}"
end
