/**
 * Form 编码（纯逻辑）单元测试。
 * 运行：npx tsx --test tests/net
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encodeForm } from '../../entry/src/main/ets/core/util/Form';

test('encodeForm: 空表单', () => {
  assert.equal(encodeForm({}), '');
});

test('encodeForm: 空格编码为 +，保留字符被转义', () => {
  const form: Record<string, string> = {
    'query': 'hello world',
    'comment-text': 'a&b=c'
  };
  assert.equal(encodeForm(form), 'query=hello+world&comment-text=a%26b%3Dc');
});

test('encodeForm: 中文与多空格', () => {
  const form: Record<string, string> = {
    'comment-text': '真好 看 啊',
    'genre': '裏番'
  };
  const encoded: string = encodeForm(form);
  assert.equal(
    encoded,
    'comment-text=%E7%9C%9F%E5%A5%BD+%E7%9C%8B+%E5%95%8A&genre=%E8%A3%8F%E7%95%AA'
  );
  // 不应残留未编码的 %20
  assert.equal(encoded.includes('%20'), false);
});

test('encodeForm: 加号、斜杠、百分号等特殊字符', () => {
  const form: Record<string, string> = {
    'a': '1+1',
    'b': 'a/b',
    'c': '100%',
    'd': 'x=y'
  };
  assert.equal(encodeForm(form), 'a=1%2B1&b=a%2Fb&c=100%25&d=x%3Dy');
});

test('encodeForm: 键也做编码，保持插入顺序，空值也输出', () => {
  const form: Record<string, string> = {};
  form['_token'] = '';
  form['like-status'] = '';
  form['comment-user-id'] = '42';
  assert.equal(encodeForm(form), '_token=&like-status=&comment-user-id=42');

  const withSpaceKey: Record<string, string> = {};
  withSpaceKey['a b'] = 'c d';
  assert.equal(encodeForm(withSpaceKey), 'a+b=c+d');
});
