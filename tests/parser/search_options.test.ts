/**
 * 搜索筛选项解析测试。
 *
 * 数据取自上游 Android `assets/search_options/*.json` 的原样拷贝
 * （fixtures/search_options/），覆盖列表形态与 tags.json 映射形态。
 */

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import {
  parseOptionList,
  parseOptionMap
} from '../../entry/src/main/ets/core/parser/SearchOptionParser';
import { SearchOptionItem } from '../../entry/src/main/ets/core/model/Models';
import { readFixture } from './fixtures';

test('genre.json：数量、多语言 label、key 为 search_key', () => {
  const zhCN: SearchOptionItem[] = parseOptionList(readFixture('search_options/genre.json'), 'zh-rCN');
  assert.equal(zhCN.length, 11);
  assert.deepEqual(zhCN[0], { label: '全部', key: '全部' });
  assert.deepEqual(zhCN[1], { label: '里番', key: '裏番' });

  const zhTW: SearchOptionItem[] = parseOptionList(readFixture('search_options/genre.json'), 'zh-rTW');
  assert.deepEqual(zhTW[1], { label: '裏番', key: '裏番' });

  const en: SearchOptionItem[] = parseOptionList(readFixture('search_options/genre.json'), 'en');
  assert.deepEqual(en[1], { label: 'Hentai', key: '裏番' });

  const ja: SearchOptionItem[] = parseOptionList(readFixture('search_options/genre.json'), 'ja');
  assert.equal(ja[1].label, '裏番');
  // 不支持的语言：回退 zh-rTW
  const unknown: SearchOptionItem[] = parseOptionList(readFixture('search_options/genre.json'), 'ko');
  assert.equal(unknown[1].label, '裏番');
});

test('duration.json / release_date.json：search_key 为 null 时 key 为空串', () => {
  const durations: SearchOptionItem[] = parseOptionList(
    readFixture('search_options/duration.json'), 'zh-rTW'
  );
  assert.equal(durations.length, 9);
  assert.deepEqual(durations[0], { label: '全部', key: '' });
  assert.deepEqual(durations[1], { label: '1分鐘以上', key: '1 分鐘 +' });

  const dates: SearchOptionItem[] = parseOptionList(
    readFixture('search_options/release_date.json'), 'zh-rTW'
  );
  assert.equal(dates.length, 7);
  assert.deepEqual(dates[0], { label: '全部', key: '' });
  assert.equal(dates[1].key, '過去 24 小時');
});

test('sort_option.json：排序项 label 随语言变化', () => {
  const zhTW: SearchOptionItem[] = parseOptionList(
    readFixture('search_options/sort_option.json'), 'zh-rTW'
  );
  assert.equal(zhTW.length, 9);
  assert.equal(zhTW[0].label, '最新上市');
  assert.equal(zhTW[0].key, '最新上市');
  const ja: SearchOptionItem[] = parseOptionList(
    readFixture('search_options/sort_option.json'), 'ja'
  );
  assert.equal(ja[0].label, '新着発売');
});

test('brands.json：没有 lang 字段时 label 回退 name', () => {
  const brands: SearchOptionItem[] = parseOptionList(
    readFixture('search_options/brands.json'), 'zh-rCN'
  );
  assert.equal(brands.length, 65);
  assert.deepEqual(brands[0], { label: '妄想実現めでぃあ', key: '妄想実現めでぃあ' });
  assert.equal(brands[10].label, brands[10].key);
});

test('tags.json（映射形态）：作用域数量、子项 label/key', () => {
  const map: Record<string, SearchOptionItem[]> = parseOptionMap(
    readFixture('search_options/tags.json'), 'zh-rTW'
  );
  const keys: string[] = Object.keys(map);
  assert.equal(keys.length, 7);
  assert.equal(keys.indexOf('video_attributes') >= 0, true);
  assert.equal(keys.indexOf('character_relationships') >= 0, true);

  const attributes: SearchOptionItem[] = map['video_attributes'];
  assert.equal(attributes.length, 9);
  assert.deepEqual(attributes[0], { label: '無碼', key: '無碼' });

  const zhCN: Record<string, SearchOptionItem[]> = parseOptionMap(
    readFixture('search_options/tags.json'), 'zh-rCN'
  );
  assert.equal(zhCN['video_attributes'][0].label, '无码');

  const en: Record<string, SearchOptionItem[]> = parseOptionMap(
    readFixture('search_options/tags.json'), 'en'
  );
  assert.equal(en['video_attributes'][0].label, 'Uncensored');
});

test('非法/非数组 JSON：返回空结果，不抛异常', () => {
  assert.deepEqual(parseOptionList('not-json', 'zh-rCN'), []);
  assert.deepEqual(parseOptionList('{}', 'zh-rCN'), []);
  assert.deepEqual(parseOptionList('', 'zh-rCN'), []);
  assert.deepEqual(parseOptionMap('[]', 'zh-rCN'), {});
  assert.deepEqual(parseOptionMap('not-json', 'zh-rCN'), {});
  // 数组形态传给 map 解析：返回空 Record
  assert.deepEqual(parseOptionMap(readFixture('search_options/genre.json'), 'zh-rCN'), {});
});
