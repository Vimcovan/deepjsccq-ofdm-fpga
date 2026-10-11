-- pandoc filter for the competition .docx (see build_docx.ps1)
--   * a paragraph holding only an image -> centred "FigurePara"; width from the title "w=NN%" (default 100%)
--   * a paragraph starting with "图n-m" -> "CaptionPara", with "表n-m" -> "TableCaption"
--   * the markdown keeps plain ![alt](path) images and caption paragraphs, so it also reads well on GitHub

local function starts_with_label(para, label)
  -- caption paragraphs start with e.g. "图2-1" (no space between the label and the number)
  local first = para.content[1]
  if not first or first.t ~= "Str" then return false end
  return first.text:sub(1, #label) == label and first.text:sub(#label + 1, #label + 1):match("%d") ~= nil
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
