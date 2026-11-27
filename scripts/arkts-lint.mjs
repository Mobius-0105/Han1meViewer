#!/usr/bin/env node
/**
 * 轻量静态检查（无 HarmonyOS SDK 时的替代品）：
 *  1. ArkTS 受限语法/禁用 API 扫描（any、enum、动态属性访问风险、对象展开等）
 *  2. 相对路径 import 的文件是否存在（.ets / .ts / index）
 *  3. $r('app.media.xxx') 引用的媒体资源是否存在
 *  4. 重复导出名检查（同一入口 Index.ets 直接 import 的 struct 是否重名）
 *
 * 用法：node scripts/arkts-lint.mjs [--json]
 * 退出码：有 error 时为 1。
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(process.cwd());
const ETS_DIR = path.join(ROOT, 'entry/src/main/ets');
const MEDIA_DIR = path.join(ROOT, 'entry/src/main/resources/base/media');
const JSON_OUT = process.argv.includes('--json');

/** @typedef {{ file: string, line: number, rule: string, message: string }} Finding */

/** @type {Finding[]} */
const findings = [];

function addFinding(file, line, rule, message) {
  findings.push({ file: path.relative(ROOT, file), line, rule, message });
}

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) {
    return out;
  }
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full, out);
    } else if (entry.isFile() && (entry.name.endsWith('.ets') || entry.name.endsWith('.ts'))) {
      out.push(full);
    }
  }
  return out;
}

function lineOf(text, index) {
  return text.slice(0, index).split('\n').length;
}

/** ArkTS 禁止 / 高风险语法 */
const FORBIDDEN = [
  { rule: 'no-any', re: /(?::\s*any\b|<any>|,\s*any\b)/g, message: '禁止使用 any 类型' },
  { rule: 'no-as-any', re: /\bas\s+any\b/g, message: '禁止 as any' },
  { rule: 'no-enum', re: /(^|\n)\s*(export\s+)?enum\s+[A-Za-z_$]/g, message: 'ArkTS 禁止 enum，请用字符串字面量联合类型 + const' },
  { rule: 'no-object-assign', re: /\bObject\.assign\s*\(/g, message: 'ArkTS 禁止 Object.assign' },
  { rule: 'no-delete', re: /(^|[^.\w])delete\s+[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*\s*[;\n]/g, message: 'ArkTS 禁止 delete 操作符' },
  { rule: 'no-for-in', re: /\bfor\s*\(\s*(?:const|let|var)?[^)]*\bin\s+[^)]*\)/g, message: 'ArkTS 禁止 for...in，请用 Object.keys / Map / 数组遍历' },
  { rule: 'no-require', re: /\brequire\s*\(/g, message: '禁止 CommonJS require' },
  { rule: 'no-namespace', re: /(^|\n)\s*(export\s+)?namespace\s+[A-Za-z_$]/g, message: 'ArkTS 禁止 namespace' },
  { rule: 'no-object-spread', re: /\{\s*\.\.\.[A-Za-z_$]/g, message: 'ArkTS 不支持对象展开，请显式赋值' },
  { rule: 'no-eval', re: /\beval\s*\(/g, message: '禁止 eval' },
  { rule: 'no-function-bind', re: /\.bind\s*\(\s*this\b/g, message: 'ArkTS 不支持 Function.bind(this)' },
  { rule: 'no-ts-ignore', re: /@ts-(ignore|nocheck|expect-error)/g, message: '禁止使用 ts-ignore 掩盖错误' },
  { rule: 'no-router-pushUrl', re: /router\.pushUrl\s*\(/g, message: '本项目使用 Navigation，请勿使用 @ohos.router 的 pushUrl' },
  { rule: 'no-dynamic-index', re: /\bthis\.[A-Za-z_$][\w$]*\[['"]/g, message: '疑似动态属性访问（ArkTS 禁止，Record 除外）' }
];

/** 排除检查的文件（第三方/生成代码） */
function isExcluded(file) {
  const rel = path.relative(ETS_DIR, file);
  return rel.startsWith('..');
}

function checkFile(file) {
  const text = fs.readFileSync(file, 'utf8');

  for (const rule of FORBIDDEN) {
    rule.re.lastIndex = 0;
    let match;
    while ((match = rule.re.exec(text)) !== null) {
      const line = lineOf(text, match.index);
      // 跳过注释行
      const lineText = text.split('\n')[line - 1] ?? '';
      if (/^\s*(\/\/|\*|\/\*)/.test(lineText)) {
        continue;
      }
      addFinding(file, line, rule.rule, rule.message);
    }
  }

  // import 路径检查
  const importRe = /(?:import|export)\s+(?:[^'"]*?\s+from\s+)?['"]([^'"]+)['"]/g;
  let m;
  while ((m = importRe.exec(text)) !== null) {
    const spec = m[1];
    if (!spec.startsWith('.')) {
      continue;
    }
    const resolved = resolveRelative(file, spec);
    if (resolved === null) {
      addFinding(file, lineOf(text, m.index), 'import-missing', `import 无法解析: ${spec}`);
    }
  }

  // 媒体资源检查
  const resRe = /\$r\(\s*['"]app\.media\.([A-Za-z0-9_]+)['"]\s*\)/g;
  while ((m = resRe.exec(text)) !== null) {
    const name = m[1];
    if (!mediaExists(name)) {
      addFinding(file, lineOf(text, m.index), 'media-missing', `媒体资源不存在: app.media.${name}`);
    }
  }

  // 顶层 import 的 struct 名去重由单独检查做
}

function mediaExists(name) {
  if (!fs.existsSync(MEDIA_DIR)) {
    return false;
  }
  const files = fs.readdirSync(MEDIA_DIR);
  return files.some((f) => f.replace(/\.[^.]+$/, '') === name);
}

function resolveRelative(fromFile, spec) {
  const base = path.resolve(path.dirname(fromFile), spec);
  const candidates = [base, `${base}.ets`, `${base}.ts`, `${base}.d.ts`,
    path.join(base, 'index.ets'), path.join(base, 'index.ts')];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
      return candidate;
    }
  }
  return null;
}

/** 检查 Index.ets 引入的页面 struct 是否都存在 */
function checkIndexPages() {
  const indexFile = path.join(ETS_DIR, 'pages/Index.ets');
  if (!fs.existsSync(indexFile)) {
    return;
  }
  const text = fs.readFileSync(indexFile, 'utf8');
  const importRe = /import\s*\{([^}]+)\}\s*from\s*['"]([^'"]+)['"]/g;
  let m;
  const seen = new Map();
  while ((m = importRe.exec(text)) !== null) {
    const names = m[1].split(',').map((s) => s.trim()).filter((s) => s.length > 0);
    for (const name of names) {
      if (seen.has(name)) {
        addFinding(indexFile, lineOf(text, m.index), 'duplicate-import',
          `重复导入 / 重名导出: ${name}（也来自 ${seen.get(name)}）`);
      } else {
        seen.set(name, m[2]);
      }
    }
  }
}

const files = walk(ETS_DIR).filter((f) => !isExcluded(f));
for (const file of files) {
  checkFile(file);
}
checkIndexPages();

const errors = findings.filter((f) => !f.rule.startsWith('warn-'));
if (JSON_OUT) {
  console.log(JSON.stringify({ fileCount: files.length, findings }, null, 2));
} else {
  if (findings.length === 0) {
    console.log(`arkts-lint: ${files.length} files checked, no problems.`);
  } else {
    for (const f of findings) {
      console.log(`${f.file}:${f.line}  [${f.rule}] ${f.message}`);
    }
    console.log(`\narkts-lint: ${files.length} files checked, ${findings.length} problem(s).`);
  }
}
process.exit(errors.length > 0 ? 1 : 0);
