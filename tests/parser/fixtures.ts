/**
 * 解析层测试的公共工具：读取 `fixtures/` 下的真实/合成快照。
 */

import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE: string = path.dirname(fileURLToPath(import.meta.url));

export const FIXTURE_DIR: string = path.join(HERE, '..', '..', 'fixtures');

/** 读取 fixtures 下的文本文件（HTML/JSON 均按 utf8 处理） */
export function readFixture(name: string): string {
  return fs.readFileSync(path.join(FIXTURE_DIR, name), 'utf8');
}

/** 读取 fixtures 下的 JSON 文件并转成 Record（仅供测试断言使用） */
export function readJsonFixture(name: string): Record<string, Object> {
  const text: string = readFixture(name);
  return JSON.parse(text) as Record<string, Object>;
}
