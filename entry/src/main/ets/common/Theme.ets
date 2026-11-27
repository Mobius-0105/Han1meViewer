/**
 * 主题与尺寸常量（PuraPily 风格重做版）。
 *
 * 设计基线（参考 PuraPily 的视觉规范，本工程独立实现）：
 *  - 页面背景：一张渐变光感壁纸（自绘 wallpaper_day / wallpaper_night）+ 一层薄 scrim；
 *  - 主色：系统蓝 #007DFF；强调色：B 站粉 #FB7299（点赞/收藏）；
 *  - 浅色主题页面底 #F1F2F4、卡片 #FFFFFF；深色页面底 #101114、卡片 #17181A；
 *  - 卡片 70% 不透明度 + 背景模糊 + 1vp 25% 描边，保证壁纸透出但文字可读；
 *  - 圆角：视频卡片 8、列表卡 12、大面板/轮播 30、胶囊 999；
 *  - 文字：主 #18191C/#F2F4F8，次 #50545A/#C9CDD3，三级 #606773/#A2A7AE。
 *
 * 颜色会随 AppStorage['themeMode']（'system' | 'light' | 'dark'）变化。
 */

export interface AppColors {
  // 基础
  primary: string;
  primaryContainer: string;
  onPrimary: string;
  /** 强调色（点赞/收藏/角标） */
  secondary: string;
  background: string;
  surface: string;
  surfaceVariant: string;
  cardBg: string;
  textPrimary: string;
  textSecondary: string;
  textHint: string;
  divider: string;
  error: string;
  overlay: string;
  playerBg: string;

  // 壁纸与遮罩
  pageTop: string;
  pageBottom: string;
  /** 壁纸上的薄遮罩（保证深浅色下文字对比度） */
  pageScrim: string;
  blobA: string;
  blobB: string;
  blobC: string;

  // 卡片/玻璃材质
  glassTint: string;
  glassStrongTint: string;
  glassBorder: string;
  glassShadow: string;
  barTint: string;
  chipTint: string;
  onGlass: string;
  /** 封面图上方的渐变遮罩 */
  heroScrim: string;
}

export function lightColors(): AppColors {
  const colors: AppColors = {
    primary: '#007DFF',
    primaryContainer: '#E6F0FF',
    onPrimary: '#FFFFFF',
    secondary: '#FB7299',
    background: '#F1F2F4',
    surface: '#FFFFFF',
    surfaceVariant: '#E8EAEE',
    cardBg: '#FFFFFF',
    textPrimary: '#18191C',
    textSecondary: '#50545A',
    textHint: '#606773',
    divider: '#1A000000',
    error: '#E84026',
    overlay: '#66000000',
    playerBg: '#000000',

    pageTop: '#1A3CA8',
    pageBottom: '#2C2A6B',
    pageScrim: '#4DF1F2F4',
    blobA: '#00FFFFFF',
    blobB: '#00FFFFFF',
    blobC: '#00FFFFFF',

    glassTint: '#FFFFFF',
    glassStrongTint: '#FFFFFF',
    glassBorder: '#1F000000',
    glassShadow: '#14000000',
    barTint: '#F2FFFFFF',
    chipTint: '#F2FFFFFF',
    onGlass: '#18191C',
    heroScrim: '#B3000000'
  };
  return colors;
}

export function darkColors(): AppColors {
  const colors: AppColors = {
    primary: '#3E9BFF',
    primaryContainer: '#12305C',
    onPrimary: '#FFFFFF',
    secondary: '#FB7299',
    background: '#101114',
    surface: '#17181A',
    surfaceVariant: '#1F2126',
    cardBg: '#17181A',
    textPrimary: '#F2F4F8',
    textSecondary: '#C9CDD3',
    textHint: '#A2A7AE',
    divider: '#1AFFFFFF',
    error: '#FF6B60',
    overlay: '#99000000',
    playerBg: '#000000',

    pageTop: '#06090F',
    pageBottom: '#1E1A3A',
    pageScrim: '#40101114',
    blobA: '#00FFFFFF',
    blobB: '#00FFFFFF',
    blobC: '#00FFFFFF',

    glassTint: '#17181A',
    glassStrongTint: '#1F2126',
    glassBorder: '#40FFFFFF',
    glassShadow: '#40000000',
    barTint: '#F217181A',
    chipTint: '#26282D',
    onGlass: '#F2F4F8',
    heroScrim: '#CC000000'
  };
  return colors;
}

export class Theme {
  static isDark(): boolean {
    const mode: string | undefined = AppStorage.get<string>('themeMode');
    if (mode === 'dark') {
      return true;
    }
    if (mode === 'light') {
      return false;
    }
    const systemDark: boolean | undefined = AppStorage.get<boolean>('systemDark');
    return systemDark === true;
  }

  /** 用户选择的主题强调色（默认 #007DFF，设置页可切换） */
  static accent(): string {
    const stored: string | undefined = AppStorage.get<string>('themeColor');
    return stored !== undefined && stored.length > 0 ? stored : '#007DFF';
  }

  /** 由强调色派生浅色容器底（浅色主题混合白、深色主题压暗） */
  static accentContainer(): string {
    const accent: string = Theme.accent();
    const dark: boolean = Theme.isDark();
    const r: number = parseInt(accent.substring(1, 3), 16);
    const g: number = parseInt(accent.substring(3, 5), 16);
    const b: number = parseInt(accent.substring(5, 7), 16);
    const mix: number = dark ? 0.18 : 0.12;
    const base: number = dark ? 24 : 255;
    const channel = (value: number): number => Math.round(value * mix + base * (1 - mix));
    const toHex = (value: number): string => {
      const text: string = value.toString(16);
      return text.length < 2 ? '0' + text : text;
    };
    return '#' + toHex(channel(r)) + toHex(channel(g)) + toHex(channel(b));
  }

  static colors(): AppColors {
    const colors: AppColors = Theme.isDark() ? darkColors() : lightColors();
    colors.primary = Theme.accent();
    colors.primaryContainer = Theme.accentContainer();
    return colors;
  }
}

export class Dimens {
  /** 页面左右边距（PuraPily: cardMargin 12） */
  static readonly pagePadding: number = 12;
  static readonly gap: number = 12;
  /** 视频卡片圆角 */
  static readonly cardRadius: number = 8;
  /** 列表卡/设置分组圆角 */
  static readonly listRadius: number = 12;
  static readonly smallRadius: number = 6;
  /** 轮播/大面板/弹层圆角 */
  static readonly panelRadius: number = 30;
  static readonly titleSize: number = 17;
  static readonly subtitleSize: number = 15;
  static readonly bodySize: number = 14;
  static readonly captionSize: number = 12;
  /** 悬浮顶栏标题行高度：52 → 60（二级页返回钮下方留出更多呼吸、主界面四页顶栏同步加高） */
  static readonly topBarHeight: number = 60;
  static readonly tabBarHeight: number = 56;
  /** Tab 页内容底部需要留出的空间（悬浮底栏 + 间距） */
  static readonly bottomInset: number = 96;
}
