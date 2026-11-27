/**
 * search_options 纯逻辑解析测试。
 *
 * 数据是上游 Android `assets/search_options/*.json` 的原样拷贝，放在
 * `tests/db/data/search_options/`，保证本测试不依赖 android-src 路径；
 * 另外校验 `rawfile/search_options/` 与夹具一致，防止某次复制漏文件。
 */

import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  parseOptionList,
  parseOptionMap,
  scopeKeys,
  SEARCH_OPTION_SCOPES
} from '../../entry/src/main/ets/core/util/SearchOptions';
import { SearchOptionItem } from '../../entry/src/main/ets/core/model/Models';

const HERE: string = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR: string = path.join(HERE, 'data', 'search_options');
const RAWFILE_DIR: string = path.join(
  HERE,
  '..',
  '..',
  'entry',
  'src',
  'main',
  'resources',
  'rawfile',
  'search_options'
);

function readData(name: string): string {
  return fs.readFileSync(path.join(DATA_DIR, name), 'utf8');
}

test('fixtures 与 rawfile 中的 7 个 JSON 完全一致', () => {
  const files: string[] = [
    'brands.json',
    'duration.json',
    'genre_av.json',
    'genre.json',
    'release_date.json',
    'sort_option.json',
    'tags.json'
  ];
  for (const name of files) {
    const fixture: string = fs.readFileSync(path.join(DATA_DIR, name), 'utf8');
    const rawfile: string = fs.readFileSync(path.join(RAWFILE_DIR, name), 'utf8');
    assert.equal(rawfile, fixture, `${name} 的 rawfile 拷贝与测试夹具不一致`);
  }
});

test('genre.json：数量、中文标签与 search_key', () => {
  const items: SearchOptionItem[] = parseOptionList(readData('genre.json'), 'zh-rCN');
  assert.equal(items.length, 11);

  assert.equal(items[0].label, '全部');
  assert.equal(items[0].key, '全部');
  assert.equal(items[1].label, '里番');
  assert.equal(items[1].key, '裏番');
  assert.equal(items[4].label, '3D动画');
  assert.equal(items[4].key, '3DCG');
});

test('label 回退：请求语言缺失时回退 zh-rTW（对齐上游 SearchOption.value）', () => {
  const items: SearchOptionItem[] = parseOptionList(readData('genre.json'), 'en');
  assert.equal(items[1].label, 'Hentai');

  // genre_av.json 没有 ja 键：请求 ja 时回退到 zh-rTW，而不是空白
  const av: SearchOptionItem[] = parseOptionList(readData('genre_av.json'), 'ja');
  assert.equal(av.length, 7);
  assert.equal(av[0].label, '全部');
  assert.equal(av[1].label, '日本AV');
  assert.equal(av[1].key, '日本AV');

  // 未知语言同样回退 zh-rTW
  const fr: SearchOptionItem[] = parseOptionList(readData('genre.json'), 'fr');
  assert.equal(fr[1].label, '裏番');
});

test('brands.json：无 lang 时 label 取 name，key 取 search_key', () => {
  const items: SearchOptionItem[] = parseOptionList(readData('brands.json'), 'zh-rCN');
  assert.equal(items.length, 65);
  assert.equal(items[0].label, '妄想実現めでぃあ');
  assert.equal(items[0].key, '妄想実現めでぃあ');
  // 65 项全部有 name（用于回退测试的兜底不会产出空 label）
  for (const item of items) {
    assert.ok(item.label.length > 0, 'brand label 不应为空');
    assert.ok(item.key.length > 0, 'brand search_key 不应为空');
  }
});

test('duration.json / release_date.json：search_key 为 null 时 key 为空串', () => {
  const durations: SearchOptionItem[] = parseOptionList(readData('duration.json'), 'zh-rCN');
  assert.equal(durations.length, 9);
  assert.equal(durations[0].label, '全部');
  assert.equal(durations[0].key, '');
  assert.equal(durations[1].key, '1 分鐘 +');
  assert.equal(durations[1].label, '1分钟以上');

  const dates: SearchOptionItem[] = parseOptionList(readData('release_date.json'), 'zh-rCN');
  assert.equal(dates.length, 7);
  assert.equal(dates[0].label, '全部');
  assert.equal(dates[0].key, '');
  assert.equal(dates[1].label, '过去24小时');
  assert.equal(dates[1].key, '過去 24 小時');
});

test('sort_option.json：9 项且 label/key 正确', () => {
  const items: SearchOptionItem[] = parseOptionList(readData('sort_option.json'), 'zh-rCN');
  assert.equal(items.length, 9);
  assert.equal(items[0].label, '最新上市');
  assert.equal(items[0].key, '最新上市');
  assert.equal(items[8].label, '时长最长');
  assert.equal(items[8].key, '時長最長');
});

test('tags.json：作用域顺序、各作用域数量与语言回退', () => {
  const map = parseOptionMap(readData('tags.json'), 'zh-rCN');
  const scopes: string[] = scopeKeys(map);

  assert.deepEqual(scopes, [
    'video_attributes',
    'character_relationships',
    'characteristics',
    'appearance_and_figure',
    'story_location',
    'story_plot',
    'sex_positions'
  ]);
  // 契约里作用域列表的顺序可能与 JSON 不同，但内容必须一致
  assert.deepEqual([...scopes].sort(), [...SEARCH_OPTION_SCOPES].sort());

  assert.equal(map['video_attributes'].length, 9);
  assert.equal(map['character_relationships'].length, 9);
  assert.equal(map['characteristics'].length, 47);
  assert.equal(map['appearance_and_figure'].length, 47);
  assert.equal(map['story_location'].length, 24);
  assert.equal(map['story_plot'].length, 45);
  assert.equal(map['sex_positions'].length, 54);

  let total: number = 0;
  for (const scope of scopes) {
    total += map[scope].length;
  }
  assert.equal(total, 235);

  const first: SearchOptionItem = map['video_attributes'][0];
  assert.equal(first.label, '无码');
  assert.equal(first.key, '無碼');

  // 请求 ja：tags.json 有 ja 键，直接使用
  const jaMap = parseOptionMap(readData('tags.json'), 'ja');
  assert.equal(jaMap['video_attributes'][0].label, '無修正');
});

test('非法/非预期 JSON 不抛异常，返回空结果', () => {
  assert.deepEqual(parseOptionList('', 'zh-rCN'), []);
  assert.deepEqual(parseOptionList('not json', 'zh-rCN'), []);
  assert.deepEqual(parseOptionList('null', 'zh-rCN'), []);
  assert.deepEqual(parseOptionList('{}', 'zh-rCN'), []);
  assert.deepEqual(parseOptionList('{"a":1}', 'zh-rCN'), []);

  assert.deepEqual(parseOptionMap('', 'zh-rCN'), {});
  assert.deepEqual(parseOptionMap('not json', 'zh-rCN'), {});
  assert.deepEqual(parseOptionMap('[]', 'zh-rCN'), {});
  assert.deepEqual(parseOptionMap('{"scope": []}', 'zh-rCN'), { scope: [] });
  assert.deepEqual(scopeKeys({}), []);

  // 数组里混入 null 元素时跳过而不是崩溃
  const withNull: SearchOptionItem[] = parseOptionList(
    '[{"lang":{"zh-rTW":"A"},"search_key":"a"},null,{"name":"B","search_key":null}]',
    'zh-rTW'
  );
  assert.equal(withNull.length, 2);
  assert.equal(withNull[0].label, 'A');
  assert.equal(withNull[1].label, 'B');
  assert.equal(withNull[1].key, '');
});
