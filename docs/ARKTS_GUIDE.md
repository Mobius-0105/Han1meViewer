# ArkTS / 纯 TS 编码规范（本项目强制）

本项目的所有业务代码都放在 `entry/src/main/ets/` 下。其中：

- `core/**`：**纯 TypeScript**，不 import 任何 `@kit.*` / `@ohos.*`，不依赖 UI，可在 Node 里直接跑单元测试；
- `logic/**`、`pages/**`、`components/**`：**ArkTS（.ets）**，可以使用系统 API 与 ArkUI，但语言子集受限制。

> 目标 SDK：`5.0.0(12)`（HarmonyOS NEXT API 12）。所有系统 API 必须使用 API 12 已存在的签名。

## 1. 语言限制（ArkTS 严格模式，违反会编译失败）

**禁止：**

- `any` / `unknown`（除 catch 参数可用 `Error` 或 `BusinessError`）；
- `enum`（用 `type X = 'a' | 'b'` 字符串字面量联合 + `const` 常量替代）；
- `namespace`、`declare`、装饰器（除 ArkUI 的 `@Entry/@Component/@State/...`）；
- 动态属性访问 `obj['key']`，**除非** obj 的类型是 `Record<string, T>`；
- 对象字面量的"结构类型"推断：必须写成 `const x: SomeInterface = { ... }` 并给全字段或显式可选；
- 对象展开 `{...a, b: 1}`、`Object.assign`、`delete obj.x`、`for...in`；
- `Function.prototype.bind/call/apply` 的任意使用；
- 隐式 `any` 的参数、返回值必须显式标注；
- `require()`、CommonJS；
- 交叉类型 `A & B`（ArkTS 不支持）；改用组合字段或继承；
- `as` 到无类型对象、`as any`、`instanceof` 判断内置泛型类型；
- 正则字面量里的 `s` / `d` 等新 flag（用 `RegExp` 构造或普通 flag）。

**允许：** `interface`、`class`（显式构造函数、显式字段类型）、`type` 别名、泛型、`Map`/`Set`/`Array`、`Promise`/`async/await`、`JSON.parse`（返回值需显式转成 `Record<string, Object>` 或已声明接口）、可选链 `?.`、空值合并 `??`、模板字符串、`Pick`/`Partial`（ArkTS 对工具类型支持有限，尽量不用）。

**class 字段必须初始化**（声明时或构造函数里）：

```ts
export class Foo {
  name: string = '';
  count: number = 0;
  constructor(name: string) {
    this.name = name;
  }
}
```

**字符串字面量联合**：

```ts
export type ThemeMode = 'system' | 'light' | 'dark';
```

## 2. 导入约定

- `.ts` 文件之间用**相对路径、不带扩展名**导入：`import { HomePage } from '../model/Models';`
- `.ets` 文件导入 `.ts` 同样不带扩展名。
- 系统 API 统一用 Kit 形式（API 12 支持）：

```ts
import { http } from '@kit.NetworkKit';
import { relationalStore, preferences } from '@kit.ArkData';
import { webview } from '@kit.ArkWeb';
import { media } from '@kit.MediaKit';
import { common, Want, AbilityConstant, UIAbility } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
```

`core/**` 里禁止出现以上任何系统 API。

## 3. 目录与模块契约（实现必须严格照此签名，其他 agent 依赖它）

### `core/parser/HtmlDom.ts`

```ts
export class HtmlNode {
  tagName: string;              // 小写，如 'div'
  constructor(tagName: string);
  attr(name: string): string;   // 不存在返回 ''
  hasAttr(name: string): boolean;
  id(): string;                 // attr('id')
  classes(): string[];
  hasClass(cls: string): boolean;
  text(): string;               // 后代全部文本，压缩空白（Jsoup Element.text() 语义）
  ownText(): string;            // 仅直接文本子节点，压缩空白（Jsoup ownText 语义）
  children(): HtmlNode[];       // 元素子节点
  childOrNull(index: number): HtmlNode | null;
  previousElementSibling(): HtmlNode | null;
  nextElementSibling(): HtmlNode | null;
  absUrl(attrName: string): string;  // 相对地址按文档 baseUrl 解析
  data(): string;               // script/style 的内容文本
  select(selector: string): HtmlNode[];
  selectFirst(selector: string): HtmlNode | null;
  getElementById(id: string): HtmlNode | null;
  getElementsByClass(cls: string): HtmlNode[];
  parent(): HtmlNode | null;
}

export class HtmlDocument {
  constructor(html: string, baseUrl: string);
  body(): HtmlNode;
  select(selector: string): HtmlNode[];
  selectFirst(selector: string): HtmlNode | null;
  getElementById(id: string): HtmlNode | null;
  getElementsByClass(cls: string): HtmlNode[];
}

export function parseHtml(html: string, baseUrl: string): HtmlDocument;
```

选择器需支持 `Parser.kt` 里用到的全部语法：`div`、`#id`、`.class`、`[attr]`、`[attr=value]`（可带引号）、
`[class^=...]`、`[class$=...]`、`[class*=...]`、`[class~=...]`、后代空格、子代 `>`、逗号分组、
`tag.class`、`tag[attr]`、`div > div > div`。属性值匹配均区分大小写（Jsoup 默认行为）。

### `core/parser/HanimeParser.ts`

```ts
export function extractCsrfFromLoginPage(html: string): string;
export function parseHomePage(html: string, baseUrl: string): HomePage;
export function parseSearchPage(html: string, baseUrl: string): SearchPage;
export function parseVideoPage(html: string, baseUrl: string, videoCode: string): HanimeVideo;
export function parseMyListPage(html: string, baseUrl: string): MyListPage;
export function parsePlaylistsPage(html: string, baseUrl: string): PlaylistsPage;
export function parseUserAccount(html: string, baseUrl: string): UserAccount;
```

### `core/parser/CommentParser.ts`

```ts
export function parseComments(json: string): VideoComments;       // 首屏：{ comments: html, ... }
export function parseCommentsPage(json: string): VideoComments;   // { items_html, has_more, next_offset }
export function parseReplies(json: string): VideoComments;        // { replies: html }
export function parsePostComment(json: string): PostCommentResult;
export function parsePostReply(json: string): PostCommentResult;
```

### `core/parser/SearchOptionParser.ts`

```ts
export function parseOptionList(json: string, lang: string): SearchOptionItem[];
export function parseOptionMap(json: string, lang: string): Record<string, SearchOptionItem[]>;
```

`lang` 取值为站点 JSON 里的语言键：`zh-rCN` / `zh-rTW` / `en` / `ja`。

## 4. 平台层（.ets）契约

### `logic/net/Errors.ets`

```ts
export class AppError extends Error { code: number = -1; constructor(message: string); }
export class NetworkError extends AppError {}
export class CloudflareChallengeError extends AppError {}   // 403 + cf-mitigated: challenge
export class IpBlockedError extends AppError {}             // 403 + "you have been blocked"
export class NotFoundError extends AppError {}              // 403/404/500 影片不存在
export class LoginExpiredError extends AppError {}
export class ParseError extends AppError {}
export function describeError(err: Error): string;
```

### `logic/net/CookieStore.ets`

```ts
export class CookieStore {
  static getInstance(): CookieStore;
  async init(ctx: common.UIAbilityContext): Promise<void>;
  /** 返回该 URL 应携带的 Cookie 请求头值，无则 '' */
  getCookieHeader(url: string): string;
  /** 解析 Set-Cookie / cookies 字段并持久化 */
  saveFromResponse(url: string, setCookieValues: string[]): void;
  /** 手动设置（登录/粘贴 cookie 用），字符串形如 "a=1; b=2" */
  setCookieString(raw: string): void;
  getCookieString(): string;
  clear(): void;
}
```

### `logic/net/HttpClient.ets`

```ts
export interface HttpHeaders { [key: string]: string }   // 用 Record<string, string>
export interface HttpResult {
  code: number;
  body: string;
  headers: Record<string, string>;  // 键统一小写
}
export class HttpClient {
  static getInstance(): HttpClient;
  async get(url: string, headers: Record<string, string>): Promise<HttpResult>;
  async postForm(url: string, form: Record<string, string>, headers: Record<string, string>): Promise<HttpResult>;
  async postJson(url: string, jsonBody: string, headers: Record<string, string>): Promise<HttpResult>;
}
```

- 自动带上 Cookie（`CookieStore`）、`User-Agent`、`Accept-Language`；
- 请求失败抛 `NetworkError`；HTTP 非 2xx 不抛异常，交给 `logic/net/ResponseGuard.ets` 统一判定；
- 超时 15s，`expectDataType: http.HttpDataType.STRING`，`usingCache: true`。

### `logic/net/HanimeApi.ets`

```ts
export class HanimeApi {
  static getInstance(): HanimeApi;
  /** 设置 baseUrl / UA / 备用 CDN，内部重建 */
  configure(baseUrl: string, userAgent: string, backupCdn: boolean): void;

  getHome(): Promise<HomePage>;
  search(req: SearchRequest): Promise<SearchPage>;
  getVideo(videoCode: string): Promise<HanimeVideo>;
  getComments(videoCode: string, offset: number): Promise<VideoComments>;
  getReplies(commentId: string): Promise<VideoComments>;
  postComment(text: string, currentUserId: string, targetId: string, token: string): Promise<PostCommentResult>;
  postReply(commentId: string, text: string, token: string): Promise<PostCommentResult>;
  likeComment(token: string, type: string, foreignId: string, isPositive: boolean, likesCount: number, likesSum: number, likeStatus: boolean, unlikeStatus: boolean): Promise<void>;
  favVideo(videoCode: string, cancel: boolean, userId: string, token: string): Promise<void>;
  rateVideo(videoCode: string, positive: boolean, likeStatus: boolean, unlikeStatus: boolean, likesCount: number, unlikesCount: number, userId: string, token: string): Promise<void>;
  getMyList(userId: string, type: string, page: number): Promise<MyListPage>;
  getPlaylists(userId: string, page: number): Promise<PlaylistsPage>;
  getPlaylistItems(listCode: string, page: number): Promise<MyListPage>;
  getOnlineHistory(userId: string, sort: string, page: number): Promise<MyListPage>;
  getUserAccount(userId: string): Promise<UserAccount>;
  getLoginPageToken(): Promise<string>;
}
```

所有方法内部自行调用对应 parser；HTTP 非成功状态统一经 `ResponseGuard.ets` 抛出 `Errors.ets` 里的错误。

### `logic/db/AppDb.ets` / `logic/settings/AppSettings.ets`

见 `docs/ARCHITECTURE.md` 与任务描述（owner: db-agent）。

## 5. 测试（只用 Node，不需要 HarmonyOS SDK）

- `core/**` 用 `tsx` 跑：`npm test`（`tsx --test tests/*.test.ts`）；
- 类型检查：`npm run typecheck`（`tsc -p tsconfig.test.json --noEmit`）；
- 纯逻辑不要 import `@ohos.*`，否则 Node 测试无法运行。

## 6. 命名与注释

- 文件名：类/解析器用 `PascalCase.ts`，工具用 `PascalCase.ts`（与 Android 侧对应）；
- 代码注释用中文，重点写"为什么"以及站点结构变化的坑；
- 不要写 `TODO` 占位实现；无法实现的功能明确在 `docs/FEATURE_MATRIX.md` 标注为"未实现"。
