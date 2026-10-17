-- pandoc filter for the competition .docx (see build_docx.ps1)
--   * a paragraph holding only an image -> centred "FigurePara"; width from the title "w=NN%" (default 100%)
--   * a paragraph starting with "图n-m" -> "CaptionPara", with "表n-m" -> "TableCaption"
--   * the markdown keeps plain ![alt](path) images and caption paragraphs, so it also reads well on GitHub

local function starts_with_label(para, label)
  -- caption paragraphs start with e.g. "图2-1" or, in the appendices, "图B-1" (no space before the number)
  local first = para.content[1]
  if not first or first.t ~= "Str" then return false end
  local rest = first.text:sub(#label + 1)
  return first.text:sub(1, #label) == label and (rest:match("^%d") ~= nil or rest:match("^%u%-%d") ~= nil)
end

local function only_image(para)
  local img = nil
  for _, el in ipairs(para.content) do
    if el.t == "Image" then
      if img then return nil end
      img = el
    elseif el.t ~= "Space" and el.t ~= "SoftBreak" then
      return nil
    end
  end
  return img
end

function Para(para)
  local img = only_image(para)
  if img then
    local w = img.title and img.title:match("^w=(%d+%%)$")
    img.title = ""
    if not img.attributes.width then img.attributes.width = w or "100%" end
    return pandoc.Div({pandoc.Para({img})}, {["custom-style"] = "FigurePara"})
  end
  if starts_with_label(para, "图") then
    return pandoc.Div({para}, {["custom-style"] = "CaptionPara"})
  end
  if starts_with_label(para, "表") then
    return pandoc.Div({para}, {["custom-style"] = "TableCaption"})
  end
  return nil
end

-- let Word size the columns from their content (pipe tables would otherwise get equal widths)
function Table(tbl)
  for i, spec in ipairs(tbl.colspecs) do
    tbl.colspecs[i] = {spec[1], pandoc.ColWidthDefault}
  end
  return tbl
end

-- Greek letters (U+0370..U+03FF) in plain text -> character style "Greek" (Times New Roman), since Word renders these
-- ambiguous-width characters with the East Asian font in a Chinese paragraph
local function is_greek(cp) return cp >= 0x370 and cp <= 0x3FF end

function Str(el)
  local parts, buf, greek = {}, {}, nil
  local function flush()
    if #buf == 0 then return end
    local txt = table.concat(buf)
    if greek then
      table.insert(parts, pandoc.Span({pandoc.Str(txt)}, {["custom-style"] = "Greek"}))
    else
      table.insert(parts, pandoc.Str(txt))
    end
    buf = {}
  end
  local found = false
  for _, cp in utf8.codes(el.text) do
    local g = is_greek(cp)
    if g then found = true end
    if g ~= greek then flush(); greek = g end
    table.insert(buf, utf8.char(cp))
  end
  if not found then return nil end
  flush()
  return parts
end
