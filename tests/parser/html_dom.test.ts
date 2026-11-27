/**
 * HtmlDom 单元测试：实体、容错解析、选择器、text/ownText、absUrl 等。
 *
 * 这些用例不依赖站点快照，纯手工 HTML 字符串，保证 DOM 行为对齐 Jsoup。
 */

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import { HtmlDocument, HtmlNode, parseHtml } from '../../entry/src/main/ets/core/parser/HtmlDom';
import { readFixture } from './fixtures';

test('解析基础文档：body()/tagName/属性大小写不敏感', () => {
  const doc: HtmlDocument = parseHtml(
    '<!DOCTYPE html><html><head><title>T</title></head><body>'
      + '<DIV CLASS="Wrap Main" DATA-X="1"><p ID="p1">hi</p></DIV>'
      + '</body></html>',
    'https://hanime1.me/'
  );
  const body: HtmlNode = doc.body();
  assert.equal(body.tagName, 'body');
  const div: HtmlNode = doc.selectFirst('div') as HtmlNode;
  assert.equal(div.tagName, 'div');
  assert.equal(div.attr('CLASS'), 'Wrap Main');
  assert.equal(div.attr('data-x'), '1');
  assert.equal(div.hasClass('Main'), true);
  assert.equal(div.hasClass('main'), false);
  assert.deepEqual(div.classes(), ['Wrap', 'Main']);
  assert.equal(div.id(), '');
  assert.equal(doc.getElementById('p1')?.tagName, 'p');
  assert.equal(doc.getElementsByClass('Wrap').length, 1);
});

test('HTML 实体解码：命名 / 十进制 / 十六进制 / 属性中的实体', () => {
  const doc: HtmlDocument = parseHtml(
    '<div title="a&amp;b">A &amp; B &lt;x&gt; &quot;q&quot; &#39;s&#39; '
      + '&#x4E2D;&#25991; &nbsp; 100&percnt; &unknown;</div>',
    'https://hanime1.me/'
  );
  const div: HtmlNode = doc.selectFirst('div') as HtmlNode;
  assert.equal(div.attr('title'), 'a&b');
  assert.equal(div.text(), 'A & B <x> "q" \'s\' 中文 100&percnt; &unknown;');
});

test('void 元素 + 自闭合：img/br/input/source 没有子节点', () => {
  const doc: HtmlDocument = parseHtml(
    '<div><img src="//cdn/x.jpg"><br><input type="checkbox" checked>'
      + '<source size="1080" src="/a.m3u8"><span>after</span></div>',
    'https://hanime1.me/'
  );
  const div: HtmlNode = doc.selectFirst('div') as HtmlNode;
  const children: HtmlNode[] = div.children();
  assert.deepEqual(children.map((c: HtmlNode): string => c.tagName), [
    'img', 'br', 'input', 'source', 'span'
  ]);
  assert.equal(children[2].hasAttr('checked'), true);
  assert.equal(children[0].children().length, 0);
  assert.equal(doc.selectFirst('span')?.text(), 'after');
});

test('容错：未闭合标签、同名标签自动闭合、错配结束标签', () => {
  const doc: HtmlDocument = parseHtml(
    '<div><p>第一段<p>第二段</div><ul><li>a<li>b</ul><section><b>bold</div>',
    'https://hanime1.me/'
  );
  const paragraphs: HtmlNode[] = doc.select('p');
  assert.equal(paragraphs.length, 2);
  assert.equal(paragraphs[0].text(), '第一段');
  assert.equal(paragraphs[1].text(), '第二段');
  const lis: HtmlNode[] = doc.select('li');
  assert.equal(lis.length, 2);
  assert.equal(lis[1].text(), 'b');
  // 错配的 </div> 不应把 <section> 之外的东西吞掉
  assert.equal(doc.selectFirst('b')?.text(), 'bold');
});

test('script/style 原始文本：data() 保留原文，text() 不包含脚本内容', () => {
  const doc: HtmlDocument = parseHtml(
    '<body><script>if (a < b) { x = "</div>"; } // watch?v=123</script>'
      + '<style>.a { color: red; }</style><div>可见文本</div></body>',
    'https://hanime1.me/'
  );
  const script: HtmlNode = doc.selectFirst('script') as HtmlNode;
  assert.equal(script.data().indexOf('a < b') >= 0, true);
  assert.equal(script.data().indexOf('"</div>"') >= 0, true);
  assert.equal(script.data().indexOf('watch?v=123') >= 0, true);
  const style: HtmlNode | null = doc.selectFirst('style');
  assert.notEqual(style, null);
  assert.equal(style !== null && style.data().indexOf('color: red') >= 0, true);
  assert.equal(doc.body().text(), '可见文本');
  assert.equal(doc.body().text().indexOf('watch?v=123'), -1);
});

test('注释节点：保留且可通过 commentTexts() 取出（banner 兜底需要）', () => {
  const doc: HtmlDocument = parseHtml(
    '<div id="x">前<!-- watch?v=888 -->后</div>',
    'https://hanime1.me/'
  );
  const div: HtmlNode = doc.getElementById('x') as HtmlNode;
  assert.equal(div.text(), '前后');
  assert.deepEqual(div.commentTexts(), [' watch?v=888 ']);
  // select() 只返回元素：注释不算元素；select('div') 会包含上下文根自身（与 Jsoup 一致）
  assert.equal(div.select('div').length, 1);
});

test('text() 与 ownText() 语义对齐 Jsoup', () => {
  const doc: HtmlDocument = parseHtml(
    '<div id="t">  a  <span>b <i>c</i></span>  d <br> e </div>',
    'https://hanime1.me/'
  );
  const div: HtmlNode = doc.getElementById('t') as HtmlNode;
  assert.equal(div.text(), 'a b c d e');
  assert.equal(div.ownText(), 'a d e');
  // 块级元素之间补空格
  const blocks: HtmlDocument = parseHtml('<div>a<div>b</div>c</div>', '');
  assert.equal(blocks.body().text(), 'a b c');
});

test('选择器：tag / #id / .class / tag.class / [attr] / 四种属性匹配', () => {
  const doc: HtmlDocument = parseHtml(
    '<body>'
      + '<div id="home-rows-wrapper">'
      + '<div class="horizontal-card is-large" data-role="card" title="T">A</div>'
      + '<div class="horizontal-card" data-role="ad">B</div>'
      + '</div>'
      + '<input name="_token" value="x">'
      + '<span class="tab active">C</span>'
      + '</body>',
    'https://hanime1.me/'
  );
  assert.equal(doc.select('div').length >= 2, true);
  assert.equal(doc.select('#home-rows-wrapper').length, 1);
  assert.equal(doc.select('.horizontal-card').length, 2);
  assert.equal(doc.select('div.horizontal-card').length, 2);
  assert.equal(doc.select('div[class^=horizontal-card]').length, 2);
  assert.equal(doc.select('div[class$=large]').length, 1);
  assert.equal(doc.select('div[class*=is-]').length, 1);
  assert.equal(doc.select('div[class~=is-large]').length, 1);
  assert.equal(doc.select('div[class~=horizontal-card]').length, 2);
  assert.equal(doc.select('[attr]').length, 0);
  assert.equal(doc.select('input[name=_token]').length, 1);
  assert.equal(doc.select('[name=_token]').length, 1);
  assert.equal(doc.select('input#skip-page-input').length, 0);
  assert.equal(doc.select('span.tab.active').length, 1);
});

test('选择器：后代 / 子代 / 逗号分组 / 多级组合', () => {
  const doc: HtmlDocument = parseHtml(
    '<body><div id="home-rows-wrapper"><div><a class="x">1</a></div></div>'
      + '<div class="video-details-wrapper"><div><a href="/u/1"><div>'
      + '<img style="position: absolute; border-radius: 50%;" src="a.png"></div></a></div></div>'
      + '<div class="lvl1"><div class="lvl2"><div class="lvl3">deep</div></div></div>'
      + '<p class="one">p1</p><span class="two">s2</span></body>',
    'https://hanime1.me/'
  );
  assert.equal(doc.select('div[id=home-rows-wrapper] > div').length, 1);
  // a 不是 home-rows-wrapper 的直接子元素（隔了一层 div）
  assert.equal(doc.select('div[id=home-rows-wrapper] > a').length, 0);
  assert.equal(doc.select('div[id=home-rows-wrapper] > div > a').length, 1);
  assert.equal(doc.select('div[id=home-rows-wrapper] div > a').length, 1);
  // 三级 div 链（div > div > div）只匹配最内层
  assert.equal(doc.select('div > div > div').length, 1);
  assert.equal(doc.selectFirst('div > div > div')?.attr('class'), 'lvl3');
  assert.equal(doc.select('p.one, span.two').length, 2);
  assert.equal(
    doc.select("div.video-details-wrapper > div > a > div > img[style*='border-radius: 50%']").length,
    1
  );
});

test('absUrl：//host、/x、相对、?q 与空值', () => {
  const doc: HtmlDocument = parseHtml(
    '<div>'
      + '<a id="a" href="//t26.cdn2020.com/v/i.m3u8">1</a>'
      + '<a id="b" href="/search?q=1">2</a>'
      + '<a id="c" href="watch?v=2">3</a>'
      + '<a id="d" href="?q=9">4</a>'
      + '<a id="e">5</a>'
      + '<img id="f" src="https://cdn/x.jpg">'
      + '</div>',
    'https://hanime1.me/watch?v=1'
  );
  assert.equal(doc.getElementById('a')?.absUrl('href'), 'https://t26.cdn2020.com/v/i.m3u8');
  assert.equal(doc.getElementById('b')?.absUrl('href'), 'https://hanime1.me/search?q=1');
  assert.equal(doc.getElementById('c')?.absUrl('href'), 'https://hanime1.me/watch?v=2');
  assert.equal(doc.getElementById('d')?.absUrl('href'), 'https://hanime1.me/watch?q=9');
  assert.equal(doc.getElementById('e')?.absUrl('href'), '');
  assert.equal(doc.getElementById('f')?.absUrl('src'), 'https://cdn/x.jpg');
  // 没有 baseUrl 时：绝对地址原样、//host 补 https、相对地址返回空
  const noBase: HtmlDocument = parseHtml(
    '<a id="x" href="/a"></a><a id="y" href="//h/p"></a>', ''
  );
  assert.equal(noBase.getElementById('x')?.absUrl('href'), '');
  assert.equal(noBase.getElementById('y')?.absUrl('href'), 'https://h/p');
});

test('children / childOrNull / previousElementSibling / nextElementSibling', () => {
  const doc: HtmlDocument = parseHtml(
    '<div id="r"><a>1</a><b>2</b><i>3</i></div>', ''
  );
  const root: HtmlNode = doc.getElementById('r') as HtmlNode;
  assert.equal(root.children().length, 3);
  assert.equal(root.childOrNull(1)?.tagName, 'b');
  assert.equal(root.childOrNull(5), null);
  const b: HtmlNode = root.childOrNull(1) as HtmlNode;
  assert.equal(b.previousElementSibling()?.tagName, 'a');
  assert.equal(b.nextElementSibling()?.tagName, 'i');
  assert.equal(root.childOrNull(0)?.previousElementSibling(), null);
  assert.equal(root.childOrNull(2)?.nextElementSibling(), null);
  assert.equal(b.parent()?.id(), 'r');
});

test('body() 对 HTML 片段自动包裹 body（评论 HTML 片段场景）', () => {
  const doc: HtmlDocument = parseHtml('<div class="comment-item-block">x</div>', '');
  assert.notEqual(doc.body(), null);
  assert.equal(doc.body().tagName, 'body');
  assert.equal(doc.body().select('.comment-item-block').length, 1);
  assert.equal(doc.select('.comment-item-block').length, 1);
});

test('性能：解析 214KB 真实首页 + 12 个分区选择在 1s 内', () => {
  const html: string = readFixture('home.html');
  const started: number = Date.now();
  const doc: HtmlDocument = parseHtml(html, 'https://hanime1.me/');
  const sections: HtmlNode[] = doc.select('div[id=home-rows-wrapper] > div');
  for (let i: number = 0; i < sections.length; i++) {
    sections[i].select('div[class^=horizontal-card]');
  }
  const elapsed: number = Date.now() - started;
  assert.equal(sections.length >= 12, true);
  assert.equal(elapsed < 1000, true, `解析耗时 ${elapsed}ms，超过 1s 预算`);
});
