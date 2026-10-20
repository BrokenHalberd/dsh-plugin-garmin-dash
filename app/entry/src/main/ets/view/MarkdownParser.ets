/**
 * 轻量 Markdown 渲染（表格 / 标题 / 列表 / 代码块 / 引用 / 粗体 / 行内代码）
 * 只用 ArkUI 基础组件，不依赖三方可渲染库。
 */
export interface MdBlock {
  kind: string; // h1 | h2 | h3 | li | oli | code | quote | table | p | gap
  text: string;
  level: number;
  rows: string[][]; // 表格内容（含表头）
}

export function parseMarkdown(src: string): MdBlock[] {
  const out: MdBlock[] = [];
  const lines: string[] = src.split('\n');
  let i = 0;
  while (i < lines.length) {
    const raw = lines[i];
    const line = raw.trimEnd();
    const t = line.trim();
    // 代码块
    if (t.startsWith('```')) {
      const buf: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        buf.push(lines[i]);
        i++;
      }
      i++;
      out.push({ kind: 'code', text: buf.join('\n'), level: 0, rows: [] });
      continue;
    }
    // 表格：当前行含 | 且下一行是分隔行
    if (t.includes('|') && i + 1 < lines.length && /^\s*\|?[\s:-]+\|[\s:|-]*$/.test(lines[i + 1])) {
      const rows: string[][] = [];
      const split = (s: string): string[] => {
        let x = s.trim();
        if (x.startsWith('|')) {
          x = x.slice(1);
        }
        if (x.endsWith('|')) {
          x = x.slice(0, x.length - 1);
        }
        return x.split('|').map((c) => c.trim());
      };
      rows.push(split(t));
      i += 2;
      while (i < lines.length && lines[i].includes('|') && lines[i].trim().length > 0) {
        rows.push(split(lines[i]));
        i++;
      }
      out.push({ kind: 'table', text: '', level: 0, rows: rows });
      continue;
    }
    // 标题
    if (/^#{1,6}\s+/.test(t)) {
      const m = t.match(/^(#{1,6})\s+(.*)$/);
      const lv = m !== null ? m[1].length : 1;
      out.push({ kind: lv === 1 ? 'h1' : (lv === 2 ? 'h2' : 'h3'), text: m !== null ? m[2] : t, level: lv, rows: [] });
      i++;
      continue;
    }
    // 引用
    if (t.startsWith('> ')) {
      out.push({ kind: 'quote', text: t.slice(2), level: 0, rows: [] });
      i++;
      continue;
    }
    // 无序列表
    if (/^[-*+]\s+/.test(t)) {
      out.push({ kind: 'li', text: t.replace(/^[-*+]\s+/, ''), level: 0, rows: [] });
      i++;
      continue;
    }
    // 有序列表
    if (/^\d+[.)]\s+/.test(t)) {
      const m = t.match(/^(\d+)[.)]\s+(.*)$/);
      out.push({ kind: 'oli', text: (m !== null ? m[1] : '1') + '. ' + (m !== null ? m[2] : t), level: 0, rows: [] });
      i++;
      continue;
    }
    // 空行
    if (t.length === 0) {
      out.push({ kind: 'gap', text: '', level: 0, rows: [] });
      i++;
      continue;
    }
    // 普通段落（合并连续非空行）
    const buf2: string[] = [t];
    i++;
    while (i < lines.length && lines[i].trim().length > 0 && !/^(#{1,6}\s|[-*+]\s|\d+[.)]\s|> |```)/.test(lines[i].trim()) && !lines[i].includes('|')) {
      buf2.push(lines[i].trim());
      i++;
    }
    out.push({ kind: 'p', text: buf2.join(' '), level: 0, rows: [] });
  }
  return out;
}

/** 行内：把 **粗体** 与 `代码` 拆成 span 片段 */
export interface MdSpan {
  text: string;
  bold: boolean;
  code: boolean;
}

export function parseInline(src: string): MdSpan[] {
  const out: MdSpan[] = [];
  let i = 0;
  let buf = '';
  const flush = () => {
    if (buf.length > 0) {
      out.push({ text: buf, bold: false, code: false });
      buf = '';
    }
  };
  while (i < src.length) {
    if (src.startsWith('**', i)) {
      const end = src.indexOf('**', i + 2);
      if (end > i) {
        flush();
        out.push({ text: src.slice(i + 2, end), bold: true, code: false });
        i = end + 2;
        continue;
      }
    }
    if (src[i] === '`') {
      const end = src.indexOf('`', i + 1);
      if (end > i) {
        flush();
        out.push({ text: src.slice(i + 1, end), bold: false, code: true });
        i = end + 1;
        continue;
      }
    }
    buf += src[i];
    i++;
  }
  flush();
  return out;
}