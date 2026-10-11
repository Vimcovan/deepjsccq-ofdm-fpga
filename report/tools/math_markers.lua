-- pandoc filter for the MathType build (build_docx.ps1 -MathType): instead of Word equations (OMML), every formula is
-- written as plain LaTeX between markers, which mathtype_convert.ps1 then turns into MathType objects in Word:
--   inline   @@MT{<latex>}MT@@
--   display  @@MTD{<latex>}MT@@   in its own centred paragraph (style "EquationPara")

local function tex(s)
  s = s:gsub("\\operatorname%s*{", "\\mathrm{")
  s = s:gsub("[\r\n]+", " ")
  -- MathType's TeX input: bare \lceil/\lfloor render as a missing glyph, \, is dropped
  s = s:gsub("\\[Bb]igg?\\{", "\\left\\{"):gsub("\\[Bb]igg?\\}", "\\right\\}")
  s = s:gsub("\\[Bb]igg?([%(%)%[%]|\\])", "%1")
  for _, d in ipairs({"ceil", "floor"}) do             -- (the sources use bare \lceil ... \rceil pairs only)
    s = s:gsub("\\l" .. d, "\\left\\l" .. d)
    s = s:gsub("\\r" .. d, "\\right\\r" .. d)
  end
  s = s:gsub("\\,", "\\;")
  return s
end

function Math(m)
  if m.mathtype == "DisplayMath" then
    return pandoc.Str("@@MTD{" .. tex(m.text) .. "}MT@@")
  end
  return pandoc.Str("@@MT{" .. tex(m.text) .. "}MT@@")
end

function Para(p)
  if #p.content == 1 and p.content[1].t == "Str" and p.content[1].text:sub(1, 6) == "@@MTD{" then
    return pandoc.Div({p}, {["custom-style"] = "EquationPara"})
  end
  -- a display formula inside a paragraph with other text: split it out into its own paragraph
  local out, cur = {}, {}
  local split = false
  for _, el in ipairs(p.content) do
    if el.t == "Str" and el.text:sub(1, 6) == "@@MTD{" then
      split = true
      if #cur > 0 then table.insert(out, pandoc.Para(cur)) end
      table.insert(out, pandoc.Div({pandoc.Para({el})}, {["custom-style"] = "EquationPara"}))
      cur = {}
    else
      table.insert(cur, el)
    end
  end
  if not split then return nil end
  while #cur > 0 and (cur[1].t == "Space" or cur[1].t == "SoftBreak") do table.remove(cur, 1) end
  if #cur > 0 then table.insert(out, pandoc.Para(cur)) end
  return out
end
