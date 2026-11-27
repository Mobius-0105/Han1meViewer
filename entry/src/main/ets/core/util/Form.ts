/**
 * application/x-www-form-urlencoded 表单编码（纯 TypeScript，可在 Node 中测试）。
 *
 * 站点是 Laravel/PHP，对 `+` 与 `%20` 都按空格解析；这里遵循浏览器行为把空格编码成
 * `+`，其余交给 encodeURIComponent，保证中文（如搜索词、评论内容）能正确提交。
 */

/** 单个值编码：encodeURIComponent 之后把 %20 换成 + */
function encodeComponent(value: string): string {
  return encodeURIComponent(value).replace(/%20/g, '+');
}

/**
 * 把 `Record<string,string>` 编码成 `a=1&b=2`。
 * 键按对象插入顺序输出；空对象返回空串。
 */
export function encodeForm(form: Record<string, string>): string {
  const keys: string[] = Object.keys(form);
  const parts: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const key: string = keys[i];
    parts.push(encodeComponent(key) + '=' + encodeComponent(form[key]));
  }
  return parts.join('&');
}
