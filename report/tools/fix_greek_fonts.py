"""Force Times New Roman on the Greek-letter runs of the built report (character style "Greek", set by docx_filter.lua).

Word classifies Greek letters in a Chinese paragraph as East Asian text and, when it saves the document (MathType
conversion), adds a direct <w:rFonts w:eastAsia="宋体"/> to those runs, which overrides the style. This rewrites the run
fonts of every "Greek" run to Times New Roman in all four slots.

    python fix_greek_fonts.py design_report.docx
"""
import re
import shutil
import sys
import tempfile
import zipfile

TNR = ('<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="Times New Roman" '
       'w:cs="Times New Roman" w:hint="default"/>')


def fix(xml):
    def run_props(m):
        rest = re.sub(r'<w:rFonts\b[^>]*/>', '', m.group(1))
        return '<w:rPr><w:rStyle w:val="Greek"/>' + TNR + rest + '</w:rPr>'
    return re.subn(r'<w:rPr><w:rStyle w:val="Greek"\s*/>(.*?)</w:rPr>', run_props, xml)


def main(path):
    tmp = tempfile.mktemp(suffix='.docx')
    n = 0
    with zipfile.ZipFile(path) as zin, zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename == 'word/document.xml':
                xml, n = fix(data.decode('utf-8'))
                data = xml.encode('utf-8')
            zout.writestr(item, data)
    shutil.move(tmp, path)
    print(f'Greek runs set to Times New Roman: {n}')


if __name__ == '__main__':
    main(sys.argv[1])
