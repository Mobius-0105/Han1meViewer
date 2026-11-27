/**
 * 迷你 HTML DOM + CSS 选择器（纯 TypeScript、零依赖、ArkTS 兼容）。
 *
 * 为什么自研：HarmonyOS 上没有 Jsoup，而站点解析大量依赖 Jsoup 的语义
 * （`Element.text()` / `ownText()` / `absUrl()` / `select()`），所以这里实现
 * 一个"够用"的容错 HTML 解析器，语义对齐 Jsoup：
 *
 *  - 容错解析：未闭合/错配标签、void 元素、`<script>`/`<style>` 原始文本、
 *    注释、大小写不敏感的标签名、引号/无引号属性、HTML 实体；
 *  - `text()`：后代全部文本（不含 script/style 的原始数据），空白压缩；
 *  - `ownText()`：只取直接文本子节点，空白压缩；
 *  - `absUrl()`：按文档 baseUrl 解析相对地址（`//host/x`、`/x`、`x`、`?q`）；
 *  - 属性名大小写不敏感（HTML 语义），属性值匹配区分大小写（Jsoup 默认）；
 *  - CSS 选择器子集：`tag`、`#id`、`.class`、`tag.class`、`[attr]`、`[attr=v]`、
 *    `[attr^=v]`、`[attr$=v]`、`[attr*=v]`、`[attr~=v]`、后代空格、子代 `>`、
 *    逗号分组、多级组合（如 `div[id=x] > div`）。
 *
 * ArkTS 限制（见 docs/ARKTS_GUIDE.md 第 1 节）：不用 any / enum / 对象展开 /
 * delete / for...in / 动态属性访问。因此属性用"平行数组"保存而不是
 * Record<string, string> 索引（避免动态属性访问与 undefined 比较的类型问题）。
 */

import { resolveUrl } from '../util/Urls';

/** 节点类型（用 number 常量代替 enum） */
export const NODE_TYPE_ELEMENT: number = 0;
export const NODE_TYPE_TEXT: number = 1;
export const NODE_TYPE_COMMENT: number = 2;
/** script/style 的原始文本（Jsoup 里是 DataNode，不参与 text()） */
export const NODE_TYPE_DATA: number = 3;

/** HTML void 元素：没有闭合标签 */
const VOID_TAGS: string[] = [
  'area', 'base', 'br', 'col', 'command', 'embed', 'hr', 'img', 'input',
  'keygen', 'link', 'meta', 'param', 'source', 'track', 'wbr'
];

/** 原始文本元素：内容不做实体解码、不当子元素解析 */
const RAW_TEXT_TAGS: string[] = ['script', 'style'];

/** RCDATA 元素：内容当文本，但需要解码实体 */
const RCDATA_TAGS: string[] = ['textarea', 'title'];

/** 块级元素：Jsoup text() 在块级元素前补空格 */
const BLOCK_TAGS: string[] = [
  'address', 'article', 'aside', 'blockquote', 'dd', 'div', 'dl', 'dt',
  'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3',
  'h4', 'h5', 'h6', 'header', 'hr', 'li', 'main', 'nav', 'ol', 'p', 'pre',
  'section', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'ul', 'br'
];

/** 同名兄弟标签自动闭合的集合（浏览器语义的简化：li 套 li、td 套 td 等） */
const SELF_CLOSING_SIBLINGS: string[] = ['li', 'option', 'tr', 'td', 'th', 'dt', 'dd'];

/** 这些块级标签会隐式关闭前一个未闭合的 <p> */
const P_CLOSERS: string[] = [
  'address', 'article', 'aside', 'blockquote', 'div', 'dl', 'fieldset',
  'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5',
  'h6', 'header', 'hr', 'li', 'main', 'nav', 'ol', 'p', 'pre', 'section',
  'table', 'ul'
];

/** 自定义实体表：站点 HTML 里常见的命名实体（其余用数字实体/原样保留） */
const NAMED_ENTITY_NAMES: string[] = [
  'amp', 'lt', 'gt', 'quot', 'apos', 'nbsp', 'ensp', 'emsp', 'thinsp', 'shy',
  'copy', 'reg', 'trade', 'hellip', 'mdash', 'ndash', 'lsquo', 'rsquo',
  'ldquo', 'rdquo', 'sbquo', 'bdquo', 'laquo', 'raquo', 'lsaquo', 'rsaquo',
  'middot', 'bull', 'times', 'divide', 'plusmn', 'deg', 'micro', 'para',
  'sect', 'dagger', 'Dagger', 'permil', 'prime', 'Prime', 'larr', 'rarr',
  'uarr', 'darr', 'harr', 'crarr', 'lArr', 'rArr', 'uArr', 'dArr', 'hArr',
  'spades', 'clubs', 'hearts', 'diams', 'loz', 'star', 'starf', 'check',
  'cross', 'euro', 'pound', 'yen', 'cent', 'curren', 'brvbar', 'uml',
  'ordf', 'ordm', 'not', 'macr', 'acute', 'cedil', 'sup1', 'sup2', 'sup3',
  'frac14', 'frac12', 'frac34', 'iquest', 'iexcl', 'szlig', 'agrave',
  'aacute', 'acirc', 'atilde', 'auml', 'aring', 'aelig', 'ccedil', 'egrave',
  'eacute', 'ecirc', 'euml', 'igrave', 'iacute', 'icirc', 'iuml', 'ntilde',
  'ograve', 'oacute', 'ocirc', 'otilde', 'ouml', 'oslash', 'ugrave',
  'uacute', 'ucirc', 'uuml', 'yacute', 'yuml', 'alpha', 'beta', 'gamma',
  'delta', 'epsilon', 'lambda', 'mu', 'pi', 'sigma', 'omega', 'infin',
  'ne', 'le', 'ge', 'asymp', 'equiv', 'sum', 'prod', 'int', 'radic',
  'there4', 'sim', 'cong', 'forall', 'part', 'exist', 'empty', 'nabla',
  'isin', 'notin', 'ni', 'and', 'or', 'cap', 'cup', 'sub', 'sup', 'sube',
  'supe', 'oplus', 'otimes', 'perp', 'sdot', 'lceil', 'rceil', 'lfloor',
  'rfloor', 'lang', 'rang', 'hearts', 'diamonds', 'clubs', 'spades'
];

const NAMED_ENTITY_VALUES: string[] = [
  '&', '<', '>', '"', "'", '\u00A0', '\u2002', '\u2003', '\u2009', '\u00AD',
  '\u00A9', '\u00AE', '\u2122', '\u2026', '\u2014', '\u2013', '\u2018', '\u2019',
  '\u201C', '\u201D', '\u201A', '\u201E', '\u00AB', '\u00BB', '\u2039', '\u203A',
  '\u00B7', '\u2022', '\u00D7', '\u00F7', '\u00B1', '\u00B0', '\u00B5', '\u00B6',
  '\u00A7', '\u2020', '\u2021', '\u2030', '\u2032', '\u2033', '\u2190', '\u2192',
  '\u2191', '\u2193', '\u2194', '\u21B5', '\u21D0', '\u21D2', '\u21D1', '\u21D3',
  '\u21D4', '\u2660', '\u2663', '\u2665', '\u2666', '\u25CA', '\u2606', '\u2605',
  '\u2713', '\u2717', '\u20AC', '\u00A3', '\u00A5', '\u00A2', '\u00A4', '\u00A6',
  '\u00A8', '\u00AA', '\u00BA', '\u00AC', '\u00AF', '\u00B4', '\u00B8', '\u00B9',
  '\u00B2', '\u00B3', '\u00BC', '\u00BD', '\u00BE', '\u00BF', '\u00A1', '\u00DF',
  '\u00E0', '\u00E1', '\u00E2', '\u00E3', '\u00E4', '\u00E5', '\u00E6', '\u00E7',
  '\u00E8', '\u00E9', '\u00EA', '\u00EB', '\u00EC', '\u00ED', '\u00EE', '\u00EF',
  '\u00F1', '\u00F2', '\u00F3', '\u00F4', '\u00F5', '\u00F6', '\u00F8', '\u00F9',
  '\u00FA', '\u00FB', '\u00FC', '\u00FD', '\u00FF', '\u03B1', '\u03B2', '\u03B3',
  '\u03B4', '\u03B5', '\u03BB', '\u03BC', '\u03C0', '\u03C3', '\u03C9', '\u221E',
  '\u2260', '\u2264', '\u2265', '\u2248', '\u2261', '\u2211', '\u220F', '\u222B',
  '\u221A', '\u2234', '\u223C', '\u2245', '\u2200', '\u2202', '\u2203', '\u2205',
  '\u2207', '\u2208', '\u2209', '\u220B', '\u2227', '\u2228', '\u2229', '\u222A',
  '\u2282', '\u2283', '\u2286', '\u2287', '\u2295', '\u2297', '\u22A5', '\u22C5',
  '\u2308', '\u2309', '\u230A', '\u230B', '\u27E8', '\u27E9', '\u2665', '\u2666',
  '\u2663', '\u2660'
];

/** 选择器里单个属性条件 */
interface AttrMatcher {
  name: string;
  /** '' = 只判断存在；其余：= ^= $= *= ~= |= */
  op: string;
  value: string;
}

/** 复合选择器（同一级上的 tag/#id/.class/[attr] 组合） */
interface CompoundSelector {
  tagName: string;
  idValue: string;
  classNames: string[];
  attrs: AttrMatcher[];
}

/** 组合选择器的一步：combinator 表示它与前一步的关系（' ' 后代、'>' 子代） */
interface SelectorStep {
  combinator: string;
  compound: CompoundSelector;
}

type CompiledGroup = SelectorStep[];
type CompiledSelector = CompiledGroup[];

/** 选择器编译缓存：站点页面解析时选择器字符串数量有限，缓存避免重复解析 */
const SELECTOR_CACHE: Map<string, CompiledSelector> = new Map<string, CompiledSelector>();

function isSpaceChar(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\f';
}

function isTagNameChar(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  return (code >= 97 && code <= 122) || (code >= 65 && code <= 90) ||
    (code >= 48 && code <= 57) || ch === '-' || ch === '_' || ch === ':';
}

function isIdentChar(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  return (code >= 97 && code <= 122) || (code >= 65 && code <= 90) ||
    (code >= 48 && code <= 57) || ch === '-' || ch === '_';
}

function decodeNamedEntity(name: string): string | null {
  let index: number = NAMED_ENTITY_NAMES.indexOf(name);
  if (index >= 0) {
    return NAMED_ENTITY_VALUES[index];
  }
  // HTML 实体名基本是小写，但站点偶尔写成 `&AMP;`、`&Nbsp;`，这里做一次大小写兜底
  index = NAMED_ENTITY_NAMES.indexOf(name.toLowerCase());
  if (index >= 0) {
    return NAMED_ENTITY_VALUES[index];
  }
  return null;
}

/**
 * 解码 HTML 实体：命名实体 + 十进制数字实体 + 十六进制数字实体。
 * 无法识别时保留原始 `&`，保证不会吃掉正常文本。
 */
export function decodeHtmlEntities(text: string): string {
  if (text.length === 0 || text.indexOf('&') < 0) {
    return text;
  }
  const out: string[] = [];
  let i: number = 0;
  const length: number = text.length;
  while (i < length) {
    const amp: number = text.indexOf('&', i);
    if (amp < 0) {
      out.push(text.substring(i));
      break;
    }
    if (amp > i) {
      out.push(text.substring(i, amp));
    }
    const semi: number = text.indexOf(';', amp + 1);
    // 实体名最长约 32 个字符，合理范围内找不到分号就不当实体
    if (semi < 0 || semi - amp > 34) {
      out.push('&');
      i = amp + 1;
      continue;
    }
    const body: string = text.substring(amp + 1, semi);
    let decoded: string = '';
    if (body.length > 1 && body.charAt(0) === '#') {
      const isHex: boolean = body.charAt(1) === 'x' || body.charAt(1) === 'X';
      const digits: string = isHex ? body.substring(2) : body.substring(1);
      const value: number = isHex ? parseInt(digits, 16) : parseInt(digits, 10);
      if (!isNaN(value) && value > 0 && value <= 0x10ffff) {
        decoded = String.fromCodePoint(value);
      }
    } else {
      const named: string | null = decodeNamedEntity(body);
      if (named !== null) {
        decoded = named;
      }
    }
    if (decoded.length > 0) {
      out.push(decoded);
      i = semi + 1;
    } else {
      out.push('&');
      i = amp + 1;
    }
  }
  return out.join('');
}

/** 压缩空白（Jsoup 的 normaliseWhitespace 语义） */
export function normalizeWhitespace(text: string): string {
  return text.replace(/\s+/g, ' ').trim();
}

/** 解析需要返回的标签结构 */
interface ParsedAttribute {
  name: string;
  value: string;
}

interface ParsedTag {
  name: string;
  attrs: ParsedAttribute[];
}

/** 解析 `<` 与 `>` 之间的内容（标签名 + 属性） */
function parseStartTagContent(content: string): ParsedTag | null {
  let i: number = 0;
  const length: number = content.length;
  while (i < length && isSpaceChar(content.charAt(i))) {
    i++;
  }
  const nameStart: number = i;
  while (i < length && isTagNameChar(content.charAt(i))) {
    i++;
  }
  if (i === nameStart) {
    return null;
  }
  const name: string = content.substring(nameStart, i).toLowerCase();
  const attrs: ParsedAttribute[] = [];
  while (i < length) {
    while (i < length && isSpaceChar(content.charAt(i))) {
      i++;
    }
    if (i >= length) {
      break;
    }
    const first: string = content.charAt(i);
    if (first === '/') {
      i++;
      continue;
    }
    const attrStart: number = i;
    while (i < length) {
      const ch: string = content.charAt(i);
      if (isSpaceChar(ch) || ch === '=' || ch === '/') {
        break;
      }
      i++;
    }
    if (i === attrStart) {
      // 非法字符（例如多余的引号），跳过一个字符继续，保证容错
      i++;
      continue;
    }
    const attrName: string = content.substring(attrStart, i).toLowerCase();
    while (i < length && isSpaceChar(content.charAt(i))) {
      i++;
    }
    let value: string = '';
    if (i < length && content.charAt(i) === '=') {
      i++;
      while (i < length && isSpaceChar(content.charAt(i))) {
        i++;
      }
      if (i < length) {
        const quote: string = content.charAt(i);
        if (quote === '"' || quote === '\'') {
          i++;
          const valueStart: number = i;
          const close: number = content.indexOf(quote, i);
          if (close < 0) {
            value = content.substring(valueStart);
            i = length;
          } else {
            value = content.substring(valueStart, close);
            i = close + 1;
          }
        } else {
          const valueStart: number = i;
          while (i < length) {
            // 无引号属性值同样允许出现 '/'（例如 URL），只以空白结束
            if (isSpaceChar(content.charAt(i))) {
              break;
            }
            i++;
          }
          value = content.substring(valueStart, i);
        }
      }
    }
    const attr: ParsedAttribute = { name: attrName, value: decodeHtmlEntities(value) };
    attrs.push(attr);
  }
  const tag: ParsedTag = { name: name, attrs: attrs };
  return tag;
}

/** 从 from 开始找标签结束的 `>`（跳过引号内的 `>`） */
function findTagEnd(html: string, from: number): number {
  let quote: string = '';
  const length: number = html.length;
  for (let i: number = from; i < length; i++) {
    const ch: string = html.charAt(i);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === '\'') {
      quote = ch;
      continue;
    }
    if (ch === '>') {
      return i;
    }
  }
  return -1;
}

/**
 * HTML 容器节点：元素 / 文本 / 注释 / 原始数据共用一套结构（与 Jsoup 的
 * Node 层级类似，只是只用一种 class），对外只把元素节点当作 HtmlNode。
 */
export class HtmlNode {
  /** 小写标签名；文本节点为 `#text`，注释为 `#comment`，数据为 `#data` */
  tagName: string = '';
  private nodeType: number = NODE_TYPE_ELEMENT;
  /** 文本/注释/数据节点的内容 */
  private nodeValue: string = '';
  /** 属性用平行数组保存，规避 ArkTS 动态属性访问限制 */
  private attrNames: string[] = [];
  private attrValues: string[] = [];
  private childNodes: HtmlNode[] = [];
  private parentNode: HtmlNode | null = null;
  private docRef: HtmlDocument | null = null;

  constructor(tagName: string) {
    this.tagName = tagName;
  }

  // ------------------------------------------------------------------
  // 解析器内部使用的方法（都做了容错，普通调用方不需要关心）
  // ------------------------------------------------------------------

  /** 追加子节点（会维护 parent 指针） */
  appendChild(child: HtmlNode): void {
    child.parentNode = this;
    this.childNodes.push(child);
  }

  /** 批量追加子节点（旧版评论结构合成分组时使用） */
  appendChildren(children: HtmlNode[]): void {
    for (let i: number = 0; i < children.length; i++) {
      this.appendChild(children[i]);
    }
  }

  /** 设置属性（同名覆盖；解析器按 HTML 规范用 setAttributeIfAbsent） */
  setAttribute(name: string, value: string): void {
    const lower: string = name.toLowerCase();
    const index: number = this.attrNames.indexOf(lower);
    if (index >= 0) {
      this.attrValues[index] = value;
      return;
    }
    this.attrNames.push(lower);
    this.attrValues.push(value);
  }

  /** 设置属性（同名时保留第一个，符合 HTML5 重复属性语义） */
  setAttributeIfAbsent(name: string, value: string): void {
    const lower: string = name.toLowerCase();
    if (this.attrNames.indexOf(lower) >= 0) {
      return;
    }
    this.attrNames.push(lower);
    this.attrValues.push(value);
  }

  private markNode(type: number, value: string): void {
    this.nodeType = type;
    this.nodeValue = value;
  }

  /** @internal 标记为文本节点 */
  markAsText(value: string): void {
    this.markNode(NODE_TYPE_TEXT, value);
  }

  /** @internal 标记为注释节点 */
  markAsComment(value: string): void {
    this.markNode(NODE_TYPE_COMMENT, value);
  }

  /** @internal 标记为 script/style 的原始数据节点 */
  markAsData(value: string): void {
    this.markNode(NODE_TYPE_DATA, value);
  }

  /** 是否元素节点 */
  isElement(): boolean {
    return this.nodeType === NODE_TYPE_ELEMENT;
  }

  /** 是否文本节点 */
  isTextNode(): boolean {
    return this.nodeType === NODE_TYPE_TEXT;
  }

  /** 是否注释节点 */
  isCommentNode(): boolean {
    return this.nodeType === NODE_TYPE_COMMENT;
  }

  /** 是否 script/style 的原始数据节点 */
  isDataNode(): boolean {
    return this.nodeType === NODE_TYPE_DATA;
  }

  /** 原始节点内容（文本/注释/数据），元素节点返回 '' */
  nodeText(): string {
    return this.nodeValue;
  }

  /** @internal 绑定文档（absUrl 需要 baseUrl） */
  bindDocument(doc: HtmlDocument): void {
    this.docRef = doc;
    for (let i: number = 0; i < this.childNodes.length; i++) {
      this.childNodes[i].bindDocument(doc);
    }
  }

  /** @internal 直接拿到子节点（含文本/注释），解析器内部使用 */
  rawChildren(): HtmlNode[] {
    return this.childNodes;
  }

  // ------------------------------------------------------------------
  // 契约方法
  // ------------------------------------------------------------------

  /** 属性值（名字大小写不敏感）；不存在返回 '' */
  attr(name: string): string {
    const lower: string = name.toLowerCase();
    const index: number = this.attrNames.indexOf(lower);
    return index >= 0 ? this.attrValues[index] : '';
  }

  hasAttr(name: string): boolean {
    const lower: string = name.toLowerCase();
    return this.attrNames.indexOf(lower) >= 0;
  }

  /** 所有属性名（小写），选择器内部使用 */
  attributeNames(): string[] {
    return this.attrNames;
  }

  id(): string {
    return this.attr('id');
  }

  classes(): string[] {
    const raw: string = this.attr('class');
    if (raw.length === 0) {
      return [];
    }
    const parts: string[] = raw.split(/\s+/);
    const result: string[] = [];
    for (let i: number = 0; i < parts.length; i++) {
      if (parts[i].length > 0) {
        result.push(parts[i]);
      }
    }
    return result;
  }

  hasClass(cls: string): boolean {
    const list: string[] = this.classes();
    return list.indexOf(cls) >= 0;
  }

  /**
   * 后代全部文本（Jsoup `Element.text()` 语义）：空白压缩为单个空格；
   * script/style 的原始数据不计入；块级元素之间补空格。
   */
  text(): string {
    const parts: string[] = [];
    this.collectText(parts, true);
    return normalizeWhitespace(parts.join(''));
  }

  private collectText(parts: string[], isRoot: boolean): void {
    if (this.nodeType === NODE_TYPE_TEXT) {
      parts.push(this.nodeValue);
      return;
    }
    if (this.nodeType === NODE_TYPE_COMMENT || this.nodeType === NODE_TYPE_DATA) {
      return;
    }
    const isBlock: boolean = !isRoot && BLOCK_TAGS.indexOf(this.tagName) >= 0;
    if (isBlock) {
      parts.push(' ');
    }
    for (let i: number = 0; i < this.childNodes.length; i++) {
      this.childNodes[i].collectText(parts, false);
    }
    if (isBlock) {
      parts.push(' ');
    }
  }

  /** 仅直接文本子节点（Jsoup `Element.ownText()` 语义） */
  ownText(): string {
    const parts: string[] = [];
    for (let i: number = 0; i < this.childNodes.length; i++) {
      const child: HtmlNode = this.childNodes[i];
      if (child.nodeType === NODE_TYPE_TEXT) {
        parts.push(child.nodeValue);
      }
    }
    return normalizeWhitespace(parts.join(''));
  }

  /** 元素子节点（文本/注释节点被过滤） */
  children(): HtmlNode[] {
    const result: HtmlNode[] = [];
    for (let i: number = 0; i < this.childNodes.length; i++) {
      if (this.childNodes[i].nodeType === NODE_TYPE_ELEMENT) {
        result.push(this.childNodes[i]);
      }
    }
    return result;
  }

  /** 第 index 个元素子节点；越界返回 null */
  childOrNull(index: number): HtmlNode | null {
    if (index < 0) {
      return null;
    }
    let count: number = 0;
    for (let i: number = 0; i < this.childNodes.length; i++) {
      const child: HtmlNode = this.childNodes[i];
      if (child.nodeType !== NODE_TYPE_ELEMENT) {
        continue;
      }
      if (count === index) {
        return child;
      }
      count++;
    }
    return null;
  }

  parent(): HtmlNode | null {
    return this.parentNode;
  }

  previousElementSibling(): HtmlNode | null {
    const parent: HtmlNode | null = this.parentNode;
    if (parent === null) {
      return null;
    }
    let previous: HtmlNode | null = null;
    for (let i: number = 0; i < parent.childNodes.length; i++) {
      const child: HtmlNode = parent.childNodes[i];
      if (child.nodeType !== NODE_TYPE_ELEMENT) {
        continue;
      }
      if (child === this) {
        return previous;
      }
      previous = child;
    }
    return null;
  }

  nextElementSibling(): HtmlNode | null {
    const parent: HtmlNode | null = this.parentNode;
    if (parent === null) {
      return null;
    }
    let found: boolean = false;
    for (let i: number = 0; i < parent.childNodes.length; i++) {
      const child: HtmlNode = parent.childNodes[i];
      if (child.nodeType !== NODE_TYPE_ELEMENT) {
        continue;
      }
      if (found) {
        return child;
      }
      if (child === this) {
        found = true;
      }
    }
    return null;
  }

  /**
   * 按文档 baseUrl 解析绝对地址（Jsoup `Element.absUrl()` 语义）。
   * 文档没有 baseUrl 时：绝对地址原样返回，`//host` 补 https，相对地址返回 ''。
   */
  absUrl(attrName: string): string {
    const raw: string = this.attr(attrName).trim();
    if (raw.length === 0) {
      return '';
    }
    const base: string = this.docRef !== null ? this.docRef.baseUrlValue() : '';
    if (base.length === 0) {
      if (raw.startsWith('http://') || raw.startsWith('https://')) {
        return raw;
      }
      if (raw.startsWith('//')) {
        return 'https:' + raw;
      }
      return '';
    }
    return resolveUrl(base, raw);
  }

  /** script/style 的内容文本（原始内容，不压缩空白） */
  data(): string {
    const parts: string[] = [];
    for (let i: number = 0; i < this.childNodes.length; i++) {
      const child: HtmlNode = this.childNodes[i];
      if (child.nodeType === NODE_TYPE_DATA) {
        parts.push(child.nodeValue);
      } else if (child.nodeType === NODE_TYPE_TEXT) {
        parts.push(child.nodeValue);
      }
    }
    return parts.join('');
  }

  /**
   * 后代注释节点的内容（文档顺序）。
   *
   * 这是超出契约的扩展：首页 banner 的 videoCode 有时只写在 HTML 注释里
   * （对应 Parser.kt `bannerCSS?.traverse { if (node is Comment) ... }`），
   * 而 Jsoup 的 `select()` 只返回元素，所以需要单独暴露注释文本。
   */
  commentTexts(): string[] {
    const result: string[] = [];
    this.collectComments(result);
    return result;
  }

  private collectComments(result: string[]): void {
    if (this.nodeType === NODE_TYPE_COMMENT) {
      result.push(this.nodeValue);
      return;
    }
    for (let i: number = 0; i < this.childNodes.length; i++) {
      this.childNodes[i].collectComments(result);
    }
  }

  /** CSS 选择器查询（文档顺序，含自身如果匹配——与 Jsoup 一致） */
  select(selector: string): HtmlNode[] {
    const compiled: CompiledSelector = compileSelector(selector);
    const result: HtmlNode[] = [];
    this.collectSelected(compiled, result);
    return result;
  }

  private collectSelected(compiled: CompiledSelector, result: HtmlNode[]): void {
    if (this.nodeType === NODE_TYPE_ELEMENT) {
      for (let g: number = 0; g < compiled.length; g++) {
        const group: CompiledGroup = compiled[g];
        if (group.length > 0 && matchesSteps(this, group, group.length - 1)) {
          result.push(this);
          break;
        }
      }
    }
    for (let i: number = 0; i < this.childNodes.length; i++) {
      this.childNodes[i].collectSelected(compiled, result);
    }
  }

  selectFirst(selector: string): HtmlNode | null {
    const list: HtmlNode[] = this.select(selector);
    return list.length > 0 ? list[0] : null;
  }

  getElementById(id: string): HtmlNode | null {
    if (this.nodeType === NODE_TYPE_ELEMENT && this.attr('id') === id) {
      return this;
    }
    for (let i: number = 0; i < this.childNodes.length; i++) {
      const found: HtmlNode | null = this.childNodes[i].getElementById(id);
      if (found !== null) {
        return found;
      }
    }
    return null;
  }

  getElementsByClass(cls: string): HtmlNode[] {
    const result: HtmlNode[] = [];
    this.collectByClass(cls, result);
    return result;
  }

  private collectByClass(cls: string, result: HtmlNode[]): void {
    if (this.nodeType === NODE_TYPE_ELEMENT && this.hasClass(cls)) {
      result.push(this);
    }
    for (let i: number = 0; i < this.childNodes.length; i++) {
      this.childNodes[i].collectByClass(cls, result);
    }
  }
}

// ----------------------------------------------------------------------
// 选择器编译与匹配
// ----------------------------------------------------------------------

function compileSelector(selector: string): CompiledSelector {
  const cached: CompiledSelector | undefined = SELECTOR_CACHE.get(selector);
  if (cached !== undefined) {
    return cached;
  }
  const compiled: CompiledSelector = [];
  const groupTexts: string[] = splitSelectorGroups(selector);
  for (let i: number = 0; i < groupTexts.length; i++) {
    const group: CompiledGroup = parseSelectorGroup(groupTexts[i]);
    if (group.length > 0) {
      compiled.push(group);
    }
  }
  SELECTOR_CACHE.set(selector, compiled);
  return compiled;
}

/** 按逗号切分选择器组（忽略 `[...]` 内与引号内的逗号） */
function splitSelectorGroups(selector: string): string[] {
  const result: string[] = [];
  let depth: number = 0;
  let quote: string = '';
  let start: number = 0;
  const length: number = selector.length;
  for (let i: number = 0; i < length; i++) {
    const ch: string = selector.charAt(i);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === '\'') {
      quote = ch;
      continue;
    }
    if (ch === '[') {
      depth++;
      continue;
    }
    if (ch === ']') {
      if (depth > 0) {
        depth--;
      }
      continue;
    }
    if (ch === ',' && depth === 0) {
      result.push(selector.substring(start, i));
      start = i + 1;
    }
  }
  result.push(selector.substring(start));
  return result;
}

function parseSelectorGroup(text: string): CompiledGroup {
  const steps: CompiledGroup = [];
  let i: number = 0;
  const length: number = text.length;
  let pendingCombinator: string = '';
  while (i < length) {
    while (i < length && isSpaceChar(text.charAt(i))) {
      i++;
    }
    if (i >= length) {
      break;
    }
    if (text.charAt(i) === '>') {
      pendingCombinator = '>';
      i++;
      continue;
    }
    const compound: CompoundSelector = { tagName: '', idValue: '', classNames: [], attrs: [] };
    let consumed: boolean = false;
    while (i < length) {
      const ch: string = text.charAt(i);
      if (isSpaceChar(ch) || ch === '>') {
        break;
      }
      if (ch === '*') {
        // 通配：tagName 留空即匹配任意标签
        i++;
        consumed = true;
        continue;
      }
      if (ch === '#') {
        i++;
        const start: number = i;
        while (i < length && isIdentChar(text.charAt(i))) {
          i++;
        }
        compound.idValue = text.substring(start, i);
        consumed = true;
        continue;
      }
      if (ch === '.') {
        i++;
        const start: number = i;
        while (i < length && isIdentChar(text.charAt(i))) {
          i++;
        }
        compound.classNames.push(text.substring(start, i));
        consumed = true;
        continue;
      }
      if (ch === '[') {
        i++;
        const parsed: ParsedAttrResult | null = parseAttrMatcher(text, i);
        if (parsed === null) {
          // 容错：跳到 `]` 之后
          const close: number = text.indexOf(']', i);
          i = close >= 0 ? close + 1 : length;
        } else {
          compound.attrs.push(parsed.matcher);
          i = parsed.nextIndex;
        }
        consumed = true;
        continue;
      }
      if (isTagNameChar(ch)) {
        const start: number = i;
        while (i < length && isTagNameChar(text.charAt(i))) {
          i++;
        }
        compound.tagName = text.substring(start, i).toLowerCase();
        consumed = true;
        continue;
      }
      // 非法字符：跳过，避免死循环
      i++;
    }
    if (!consumed) {
      continue;
    }
    const combinator: string = steps.length === 0
      ? ''
      : (pendingCombinator.length > 0 ? pendingCombinator : ' ');
    const step: SelectorStep = { combinator: combinator, compound: compound };
    steps.push(step);
    pendingCombinator = '';
  }
  return steps;
}

/** 解析结果：属性条件 + 下一个待解析下标 */
interface ParsedAttrResult {
  matcher: AttrMatcher;
  nextIndex: number;
}

function parseAttrMatcher(text: string, from: number): ParsedAttrResult | null {
  const length: number = text.length;
  let i: number = from;
  while (i < length && isSpaceChar(text.charAt(i))) {
    i++;
  }
  const nameStart: number = i;
  while (i < length) {
    const ch: string = text.charAt(i);
    if (isSpaceChar(ch) || ch === '=' || ch === ']' || ch === '^' ||
      ch === '$' || ch === '*' || ch === '~' || ch === '|') {
      break;
    }
    i++;
  }
  if (i === nameStart) {
    return null;
  }
  const name: string = text.substring(nameStart, i).toLowerCase();
  while (i < length && isSpaceChar(text.charAt(i))) {
    i++;
  }
  let op: string = '';
  if (i < length && text.charAt(i) === '=') {
    op = '=';
    i++;
  } else if (i + 1 < length && text.charAt(i + 1) === '=') {
    const candidate: string = text.charAt(i);
    if (candidate === '^' || candidate === '$' || candidate === '*' ||
      candidate === '~' || candidate === '|') {
      op = candidate + '=';
      i += 2;
    }
  }
  while (i < length && isSpaceChar(text.charAt(i))) {
    i++;
  }
  let value: string = '';
  if (op.length > 0 && i < length) {
    const quote: string = text.charAt(i);
    if (quote === '"' || quote === '\'') {
      i++;
      const close: number = text.indexOf(quote, i);
      if (close < 0) {
        value = text.substring(i);
        i = length;
      } else {
        value = text.substring(i, close);
        i = close + 1;
      }
    } else {
      const valueStart: number = i;
      while (i < length && text.charAt(i) !== ']') {
        i++;
      }
      value = text.substring(valueStart, i).trim();
    }
  }
  while (i < length && text.charAt(i) !== ']') {
    i++;
  }
  if (i < length) {
    i++;
  }
  const matcher: AttrMatcher = { name: name, op: op, value: value };
  const result: ParsedAttrResult = { matcher: matcher, nextIndex: i };
  return result;
}

function matchesCompound(node: HtmlNode, compound: CompoundSelector): boolean {
  if (compound.tagName.length > 0 && node.tagName !== compound.tagName) {
    return false;
  }
  if (compound.idValue.length > 0 && node.attr('id') !== compound.idValue) {
    return false;
  }
  for (let i: number = 0; i < compound.classNames.length; i++) {
    if (!node.hasClass(compound.classNames[i])) {
      return false;
    }
  }
  for (let i: number = 0; i < compound.attrs.length; i++) {
    if (!matchesAttr(node, compound.attrs[i])) {
      return false;
    }
  }
  return true;
}

function matchesAttr(node: HtmlNode, matcher: AttrMatcher): boolean {
  if (!node.hasAttr(matcher.name)) {
    return false;
  }
  if (matcher.op.length === 0) {
    return true;
  }
  const actual: string = node.attr(matcher.name);
  if (matcher.op === '=') {
    return actual === matcher.value;
  }
  if (matcher.op === '^=') {
    return matcher.value.length > 0 && actual.startsWith(matcher.value);
  }
  if (matcher.op === '$=') {
    return matcher.value.length > 0 && actual.endsWith(matcher.value);
  }
  if (matcher.op === '*=') {
    return matcher.value.length > 0 && actual.indexOf(matcher.value) >= 0;
  }
  if (matcher.op === '~=') {
    if (matcher.value.length === 0) {
      return false;
    }
    const tokens: string[] = actual.split(/\s+/);
    return tokens.indexOf(matcher.value) >= 0;
  }
  if (matcher.op === '|=') {
    return actual === matcher.value || actual.startsWith(matcher.value + '-');
  }
  return false;
}

function matchesSteps(node: HtmlNode, steps: CompiledGroup, index: number): boolean {
  if (!matchesCompound(node, steps[index].compound)) {
    return false;
  }
  if (index === 0) {
    return true;
  }
  const combinator: string = steps[index].combinator;
  let parent: HtmlNode | null = node.parent();
  if (combinator === '>') {
    return parent !== null && matchesSteps(parent, steps, index - 1);
  }
  // 后代组合器：祖先链任意一级匹配即可（与 Jsoup 一致，可以匹配到上下文根之外的祖先）
  while (parent !== null) {
    if (matchesSteps(parent, steps, index - 1)) {
      return true;
    }
    parent = parent.parent();
  }
  return false;
}

// ----------------------------------------------------------------------
// HTML 解析器
// ----------------------------------------------------------------------

interface ParseDocumentResult {
  root: HtmlNode;
  body: HtmlNode;
}

function appendTextNode(parent: HtmlNode, raw: string): void {
  if (raw.length === 0) {
    return;
  }
  // 纯空白文本（缩进）也保留：text()/ownText() 会压缩空白，但某些 ownText
  // 场景需要保留词间分开；这里只丢弃完全为空的文本。
  const textNode: HtmlNode = new HtmlNode('#text');
  textNode.markAsText(decodeHtmlEntities(raw));
  parent.appendChild(textNode);
}

/** 按浏览器语义在新标签前自动闭合一些可省略结束标签的元素 */
function autoCloseBeforeAppend(stack: HtmlNode[], newTag: string): void {
  while (stack.length > 1) {
    const top: HtmlNode = stack[stack.length - 1];
    const tag: string = top.tagName;
    let shouldClose: boolean = false;
    if (SELF_CLOSING_SIBLINGS.indexOf(newTag) >= 0 && tag === newTag) {
      shouldClose = true;
    } else if (tag === 'p' && P_CLOSERS.indexOf(newTag) >= 0) {
      shouldClose = true;
    } else if ((tag === 'td' || tag === 'th') &&
      (newTag === 'td' || newTag === 'th' || newTag === 'tr' ||
        newTag === 'tbody' || newTag === 'thead' || newTag === 'tfoot')) {
      shouldClose = true;
    } else if (tag === 'tr' &&
      (newTag === 'tr' || newTag === 'tbody' || newTag === 'thead' || newTag === 'tfoot')) {
      shouldClose = true;
    } else if ((tag === 'dt' || tag === 'dd') && (newTag === 'dt' || newTag === 'dd')) {
      shouldClose = true;
    } else if (tag === 'option' && (newTag === 'option' || newTag === 'optgroup')) {
      shouldClose = true;
    } else if (tag === 'thead' && (newTag === 'tbody' || newTag === 'tfoot')) {
      shouldClose = true;
    }
    if (!shouldClose) {
      break;
    }
    stack.pop();
  }
}

/** 处理结束标签：向上回溯到同名元素；找不到则忽略（容错） */
function handleEndTag(stack: HtmlNode[], name: string): void {
  if (name === 'html') {
    stack.length = 1;
    return;
  }
  // 忽略 </body>：真实站点会把 script 放在 </body> 之后，仍应归入 body
  if (name === 'body') {
    return;
  }
  for (let i: number = stack.length - 1; i >= 1; i--) {
    if (stack[i].tagName === name) {
      stack.length = i;
      return;
    }
  }
}

function parseHtmlInto(html: string, doc: HtmlDocument): ParseDocumentResult {
  const root: HtmlNode = new HtmlNode('html');
  const stack: HtmlNode[] = [root];
  let head: HtmlNode | null = null;
  let body: HtmlNode | null = null;
  let i: number = 0;
  const length: number = html.length;

  while (i < length) {
    const lt: number = html.indexOf('<', i);
    if (lt < 0) {
      appendTextNode(stack[stack.length - 1], html.substring(i));
      break;
    }
    if (lt > i) {
      appendTextNode(stack[stack.length - 1], html.substring(i, lt));
    }
    i = lt;

    // 注释
    if (html.startsWith('<!--', i)) {
      const end: number = html.indexOf('-->', i + 4);
      const commentNode: HtmlNode = new HtmlNode('#comment');
      if (end < 0) {
        commentNode.markAsComment(html.substring(i + 4));
        stack[stack.length - 1].appendChild(commentNode);
        break;
      }
      commentNode.markAsComment(html.substring(i + 4, end));
      stack[stack.length - 1].appendChild(commentNode);
      i = end + 3;
      continue;
    }

    // <!DOCTYPE ...> / <![CDATA[ ... ]]> / 其它声明
    if (html.charAt(i + 1) === '!') {
      if (html.startsWith('<![CDATA[', i)) {
        const end: number = html.indexOf(']]>', i + 9);
        if (end < 0) {
          appendTextNode(stack[stack.length - 1], html.substring(i + 9));
          break;
        }
        appendTextNode(stack[stack.length - 1], html.substring(i + 9, end));
        i = end + 3;
        continue;
      }
      const gt: number = html.indexOf('>', i + 2);
      if (gt < 0) {
        break;
      }
      i = gt + 1;
      continue;
    }

    // 处理指令 <?xml ... ?>
    if (html.charAt(i + 1) === '?') {
      const gt: number = html.indexOf('>', i + 2);
      if (gt < 0) {
        break;
      }
      i = gt + 1;
      continue;
    }

    // 结束标签
    if (html.charAt(i + 1) === '/') {
      const gt: number = html.indexOf('>', i + 2);
      if (gt < 0) {
        break;
      }
      const raw: string = html.substring(i + 2, gt).trim().toLowerCase();
      const space: number = raw.search(/\s/);
      const name: string = space >= 0 ? raw.substring(0, space) : raw;
      handleEndTag(stack, name);
      i = gt + 1;
      continue;
    }

    // 开始标签
    const tagEnd: number = findTagEnd(html, i + 1);
    if (tagEnd < 0) {
      appendTextNode(stack[stack.length - 1], html.substring(i));
      break;
    }
    let tagContent: string = html.substring(i + 1, tagEnd);
    let selfClosing: boolean = false;
    if (tagContent.length > 0 && tagContent.charAt(tagContent.length - 1) === '/') {
      selfClosing = true;
      tagContent = tagContent.substring(0, tagContent.length - 1);
    }
    const parsedTag: ParsedTag | null = parseStartTagContent(tagContent);
    i = tagEnd + 1;
    if (parsedTag === null) {
      continue;
    }
    const name: string = parsedTag.name;

    // <html> 直接复用解析根节点，避免出现嵌套 html
    if (name === 'html') {
      for (let a: number = 0; a < parsedTag.attrs.length; a++) {
        root.setAttributeIfAbsent(parsedTag.attrs[a].name, parsedTag.attrs[a].value);
      }
      continue;
    }

    autoCloseBeforeAppend(stack, name);

    let node: HtmlNode;
    if (name === 'head' && head !== null) {
      node = head;
    } else if (name === 'body' && body !== null) {
      node = body;
    } else {
      node = new HtmlNode(name);
      for (let a: number = 0; a < parsedTag.attrs.length; a++) {
        node.setAttributeIfAbsent(parsedTag.attrs[a].name, parsedTag.attrs[a].value);
      }
      stack[stack.length - 1].appendChild(node);
      if (name === 'head') {
        head = node;
      } else if (name === 'body') {
        body = node;
      }
    }

    if (VOID_TAGS.indexOf(name) >= 0 || selfClosing) {
      continue;
    }

    // script/style：原始文本直到对应结束标签
    if (RAW_TEXT_TAGS.indexOf(name) >= 0) {
      const closeIndex: number = html.toLowerCase().indexOf('</' + name, i);
      if (closeIndex < 0) {
        const dataNode: HtmlNode = new HtmlNode('#data');
        dataNode.markAsData(html.substring(i));
        node.appendChild(dataNode);
        break;
      }
      const dataNode: HtmlNode = new HtmlNode('#data');
      dataNode.markAsData(html.substring(i, closeIndex));
      node.appendChild(dataNode);
      const gt: number = html.indexOf('>', closeIndex);
      i = gt < 0 ? length : gt + 1;
      continue;
    }

    // textarea/title：RCDATA，内容当解码后的文本
    if (RCDATA_TAGS.indexOf(name) >= 0) {
      const closeIndex: number = html.toLowerCase().indexOf('</' + name, i);
      if (closeIndex < 0) {
        appendTextNode(node, html.substring(i));
        break;
      }
      appendTextNode(node, html.substring(i, closeIndex));
      const gt: number = html.indexOf('>', closeIndex);
      i = gt < 0 ? length : gt + 1;
      continue;
    }

    if (name === 'body' || name === 'head') {
      // 重复出现的 body/head 标签：忽略，不嵌套
      stack.push(node);
      continue;
    }
    stack.push(node);
  }

  // 没有显式 <body> 时（HTML 片段），把根节点的内容收进一个 body
  if (body === null) {
    const createdBody: HtmlNode = new HtmlNode('body');
    const kept: HtmlNode[] = [];
    const rootChildren: HtmlNode[] = root.rawChildren();
    for (let c: number = 0; c < rootChildren.length; c++) {
      const child: HtmlNode = rootChildren[c];
      if (child.isElement() && child.tagName === 'head') {
        kept.push(child);
      } else {
        createdBody.appendChild(child);
      }
    }
    kept.push(createdBody);
    // 重建 root 的子节点顺序
    const rebuilt: HtmlNode[] = [];
    for (let c: number = 0; c < kept.length; c++) {
      rebuilt.push(kept[c]);
    }
    replaceChildren(root, rebuilt);
    body = createdBody;
  }

  root.bindDocument(doc);
  const result: ParseDocumentResult = { root: root, body: body };
  return result;
}

/** @internal 替换子节点列表（body 合成时使用） */
function replaceChildren(node: HtmlNode, children: HtmlNode[]): void {
  // 直接清空再逐个 append，避免 ArkTS 里对私有数组做整体赋值
  const current: HtmlNode[] = node.rawChildren();
  for (let i: number = current.length - 1; i >= 0; i--) {
    removeLastChild(node);
  }
  for (let i: number = 0; i < children.length; i++) {
    node.appendChild(children[i]);
  }
}

/** @internal 移除最后一个子节点 */
function removeLastChild(node: HtmlNode): void {
  node.rawChildren().pop();
}

/**
 * HTML 文档：持有解析树、baseUrl 与文档级查询入口。
 *
 * 注意：真实站点页面结构会变，解析器本身容错；这里不做 XSS/安全性过滤，
 * 因为只用于提取数据，不把 HTML 注入 UI。
 */
export class HtmlDocument {
  private base: string = '';
  private rootNode: HtmlNode = new HtmlNode('html');
  private bodyNode: HtmlNode = new HtmlNode('body');

  constructor(html: string, baseUrl: string) {
    this.base = baseUrl;
    const result: ParseDocumentResult = parseHtmlInto(html, this);
    this.rootNode = result.root;
    this.bodyNode = result.body;
  }

  /** @internal HtmlNode.absUrl 需要用到 */
  baseUrlValue(): string {
    return this.base;
  }

  body(): HtmlNode {
    return this.bodyNode;
  }

  select(selector: string): HtmlNode[] {
    return this.rootNode.select(selector);
  }

  selectFirst(selector: string): HtmlNode | null {
    return this.rootNode.selectFirst(selector);
  }

  getElementById(id: string): HtmlNode | null {
    return this.rootNode.getElementById(id);
  }

  getElementsByClass(cls: string): HtmlNode[] {
    return this.rootNode.getElementsByClass(cls);
  }
}

/** 解析 HTML 字符串（缺省容错，不会抛异常） */
export function parseHtml(html: string, baseUrl: string): HtmlDocument {
  return new HtmlDocument(html, baseUrl);
}
