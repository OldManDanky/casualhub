#!/usr/bin/env python3
"""Converts the simple Markdown in docs/curseforge-description.md to HTML for CurseForge's visual editor.

    python3 tools/md2html.py docs/curseforge-description.md docs/curseforge-description.html

Handles headings, paragraphs, bullet and numbered lists, tables, rules, bold, italics, code and links.
"""
import html
import re
import sys


def inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    s = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', s)
    s = re.sub(r'\*([^*]+)\*', r'<em>\1</em>', s)
    s = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', r'<a href="\2">\1</a>', s)
    s = re.sub(r'(?<!href=")(https?://[^\s<]+)', r'<a href="\1">\1</a>', s)
    return s


def convert(text):
    out, lines, i = [], text.split('\n'), 0
    block = re.compile(r'(#|\||---|\d+\. |- )')
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m = re.match(r'(#{1,6}) (.*)', line)
        if m:
            n = len(m.group(1))
            out.append(f'<h{n}>{inline(m.group(2))}</h{n}>')
            i += 1
            continue
        if line.strip() == '---':
            out.append('<hr>')
            i += 1
            continue
        if line.startswith('|'):
            rows = []
            while i < len(lines) and lines[i].startswith('|'):
                cells = [c.strip() for c in lines[i].strip().strip('|').split('|')]
                if not all(re.fullmatch(r'-+', c) for c in cells):
                    rows.append(cells)
                i += 1
            t = ['<table>', '<tr>' + ''.join(f'<th>{inline(c)}</th>' for c in rows[0]) + '</tr>']
            t += ['<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>' for r in rows[1:]]
            out.append('\n'.join(t + ['</table>']))
            continue
        m = re.match(r'(\d+\.|-) ', line)
        if m:
            tag = 'ol' if m.group(1)[0].isdigit() else 'ul'
            items = []
            while i < len(lines) and re.match(r'(\d+\.|-) ', lines[i]):
                items.append('<li>' + inline(re.sub(r'^(\d+\.|-) ', '', lines[i])) + '</li>')
                i += 1
            out.append(f'<{tag}>\n' + '\n'.join(items) + f'\n</{tag}>')
            continue
        para = []
        while i < len(lines) and lines[i].strip() and not block.match(lines[i]):
            para.append(lines[i])
            i += 1
        out.append('<p>' + inline(' '.join(para)) + '</p>')
    return '\n'.join(out) + '\n'


if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding='utf-8') as f:
        result = convert(f.read())
    with open(dst, 'w', encoding='utf-8') as f:
        f.write(result)
