/**
 * WebView 教务导入页(M4 完整版):App 内 WebVPN 登录 → 嗅探课表接口 → 抓取解析 → 预览确认导入。
 * 移植自 Flutter 版 import_webview_page.dart(引导条/抓取按钮/预览/失败路径逐项对齐)。
 *
 * 安全红线:嗅探脚本只缓存"疑似课表"的 fetch/XHR 响应,不读取密码输入框。
 */
import { webview } from '@kit.ArkWeb';
import { AppTheme } from '../../common/AppTheme';
import { parseCapture, ParseResult, isParseSuccess } from './YzuParser';
import { ParsedCourse, ParsedSlot } from './TextImportParser';
import { SNIFFER_INJECT_JS, SNIFFER_COLLECT_JS } from './SnifferJs';
import { ScheduleDao } from '../../data/ScheduleDao';
import { ScheduleRepository } from '../schedule/ScheduleRepository';
import { SyncEngine } from '../../sync/SyncEngine';
import { SlotDraft } from '../schedule/ScheduleTypes';
import { router } from '@kit.ArkUI';

const WEBVPN_URL = 'https://webvpn.yzu.edu.cn';
const GUIDE_TEXT = '① 登录 WebVPN（统一身份认证）\n' +
  '② 进入 校内资源 → 教务系统（学生端）\n' +
  '③ 在「常用服务」点「班级课表」，选择对应班级后点「课表信息」\n' +
  '④ 课表完整显示后，点底部「抓取课表」';

type WebRoute = 'web' | 'preview' | 'failed';

@Entry
@Component
struct ImportWebViewPage {
  @StorageProp(AppTheme.KEY_BRAND) brandColor: string = '#158A63';
  @StorageProp(AppTheme.KEY_BRAND_TINT) brandTint: string = '#158A631F';
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;

  // WebView 状态
  @State pageTitle: string = '教务导入';
  @State loading: boolean = true;
  @State capturing: boolean = false;
  @State guideCollapsed: boolean = false;
  controller: webview.WebviewController = new webview.WebviewController();

  // 解析结果与路由
  @State route: WebRoute = 'web';
  @State parseResult: ParseResult = { courses: [], source: 'none', detail: '' };
  @State importBusy: boolean = false;
  @State importDone: string = '';
  private active: boolean = false;
  private asyncGeneration: number = 0;

  // 目标学期
  @State semesters: SemOption[] = [];
  @State targetSemIdx: number = 0;

  aboutToAppear(): void {
    this.active = true;
    this.asyncGeneration++;
    this.loadSemesters();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.asyncGeneration++;
  }

  onBackPress(): boolean {
    this.handleBack();
    return true;
  }

  private async loadSemesters(): Promise<void> {
    const generation = this.asyncGeneration;
    const rows = await ScheduleDao.listSemesters();
    if (!this.isCurrent(generation)) {
      return;
    }
    const options: SemOption[] = [];
    for (const r of rows) {
      options.push({ id: r.id, label: `${r.name}（${r.totalWeeks} 周）`, isCurrent: r.isCurrent });
    }
    this.semesters = options;
    for (let i = 0; i < options.length; i++) {
      if (options[i].isCurrent) {
        this.targetSemIdx = i;
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.WebPane();
      if (this.route === 'preview') {
        Column() {
          this.PreviewPane();
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.pageColor())
        .transition(TransitionEffect.translate({ x: '100%' })
          .animation({ duration: 220, curve: Curve.FastOutSlowIn }));
      } else if (this.route === 'failed') {
        Column() {
          this.FailedPane();
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.pageColor())
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.98, y: 0.98 }))
          .animation({ duration: 180, curve: Curve.EaseOut }));
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor());
  }

  pageTransition() {
    PageTransitionEnter({ duration: 220, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right);
    PageTransitionExit({ duration: 180, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right);
  }

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private surfaceColor(): string { return this.effectiveDark ? '#1C1F22' : '#F7F8FA'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private secondaryText(): string { return this.effectiveDark ? '#B8BDC2' : '#666666'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private faintText(): string { return this.effectiveDark ? '#717880' : '#BBBBBB'; }
  private dividerColor(): string { return this.effectiveDark ? '#34383D' : '#F0F0F0'; }

  // ==================== WebView 主界面 ====================

  @Builder
  WebPane() {
    Column() {
      // 顶栏:返回 + 标题 + 刷新
      Row() {
        Text('＜')
          .fontSize(20)
          .fontColor(this.primaryText())
          .padding(6)
          .onClick(() => this.handleBack());
        Text(this.pageTitle)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 4 })
          .layoutWeight(1);
        Text('⟳')
          .fontSize(19)
          .fontColor(this.primaryText())
          .padding(8)
          .onClick(() => {
            try {
              this.controller.refresh();
            } catch (e) {
            }
          });
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 10 });

      // 引导条(可折叠)
      Column() {
        if (!this.guideCollapsed) {
          Row() {
            Text(GUIDE_TEXT)
              .fontSize(11)
              .fontColor(this.secondaryText())
              .lineHeight(17)
              .layoutWeight(1);
            Text('收起 ▴')
              .fontSize(11)
              .fontColor(this.brandColor)
              .padding(4)
              .onClick(() => { this.guideCollapsed = true; });
          }
          .alignItems(VerticalAlign.Top)
          .padding({ left: 12, right: 8, top: 8, bottom: 8 });
        } else {
          Row() {
            Text('操作指引')
              .fontSize(11)
              .fontColor(this.secondaryText())
              .layoutWeight(1);
            Text('展开 ▾')
              .fontSize(11)
              .fontColor(this.brandColor)
              .padding(4)
              .onClick(() => { this.guideCollapsed = false; });
          }
          .padding({ left: 12, right: 8, top: 6, bottom: 6 });
        }
      }
      .width('100%')
      .backgroundColor(this.brandTint);

      // WebView 主体
      Web({ src: WEBVPN_URL, controller: this.controller })
        .layoutWeight(1)
        .width('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onlineImageAccess(true)
        .onPageBegin(() => {
          if (this.active) {
            this.loading = true;
          }
        })
        .onPageEnd(() => {
          if (!this.active) {
            return;
          }
          this.loading = false;
          try {
            this.pageTitle = this.controller.getTitle() || '教务导入';
          } catch (e) {
            this.pageTitle = '教务导入';
          }
          this.injectSniffer();
        })
        .onControllerAttached(() => {
          if (this.active) {
            this.injectSniffer();
          }
        });

      // 底部抓取按钮(对齐 Flutter bottomNavigationBar)
      Column() {
        Row({ space: 8 }) {
          if (this.capturing) {
            LoadingProgress().width(18).height(18).color(Color.White);
          }
          Text(this.capturing ? '抓取中…' : '抓取课表')
            .fontSize(16)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium);
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height(48)
        .borderRadius(24)
        .backgroundColor(this.capturing ? '#AAAAAA' : this.brandColor)
        .onClick(() => { this.capture(); });
      }
      .width('100%')
      .padding(12);
    }
    .width('100%')
    .height('100%');
  }

  /** 注入嗅探脚本(每次页面加载完补一次,防 SPA 路由切换后 hook 丢失) */
  private injectSniffer(): void {
    try {
      this.controller.runJavaScript(SNIFFER_INJECT_JS).catch(() => {
      });
    } catch (e) {
      // 忽略注入失败
    }
  }

  private isCurrent(generation: number): boolean {
    return this.active && generation === this.asyncGeneration;
  }

  private handleBack(): void {
    if (this.importBusy) {
      return;
    }
    if (this.route !== 'web') {
      this.route = 'web';
      return;
    }
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return;
      }
    } catch (e) {
    }
    router.back();
  }

  /** 抓取:补注入 → collect → 解析 → 预览/失败 */
  private capture(): void {
    if (this.capturing) {
      return;
    }
    const generation = this.asyncGeneration;
    this.capturing = true;
    this.controller.runJavaScript(SNIFFER_INJECT_JS)
      .then(() => this.controller.runJavaScript(SNIFFER_COLLECT_JS))
      .then((result: string) => {
        if (!this.isCurrent(generation)) {
          return;
        }
        this.capturing = false;
        const raw = unwrapJsString(result);
        if (raw.length === 0) {
          this.parseResult = { courses: [], source: 'none', detail: '页面数据读取失败，请确认课表页面已加载完成后再抓取' };
          this.route = 'failed';
          return;
        }
        const parsed = parseCapture(raw);
        this.parseResult = parsed;
        this.route = isParseSuccess(parsed) ? 'preview' : 'failed';
      })
      .catch((e: Object) => {
        if (!this.isCurrent(generation)) {
          return;
        }
        this.capturing = false;
        this.parseResult = { courses: [], source: 'none', detail: `抓取异常：${e}` };
        this.route = 'failed';
      });
  }

  // ==================== 预览页 ====================

  @Builder
  PreviewPane() {
    Column() {
      // 顶栏
      Row() {
        Text('＜')
          .fontSize(20)
          .fontColor(this.primaryText())
          .padding(6)
          .onClick(() => { this.route = 'web'; });
        Text(`解析出 ${this.parseResult.courses.length} 门课程`)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .margin({ left: 4 })
          .layoutWeight(1);
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 6 });

      Text(this.parseResult.detail)
        .fontSize(11)
        .fontColor(this.mutedText())
        .padding({ left: 16, right: 16 });

      // 目标学期选择
      Row() {
        Text('导入到学期').fontSize(14).fontColor(this.secondaryText());
        Blank();
        Select(this.semesterOptions())
          .selected(this.targetSemIdx)
          .value(this.selectedSemesterLabel())
          .fontColor(this.primaryText())
          .font({ size: 13 })
          .onSelect((index: number) => { this.targetSemIdx = index; });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 6 });

      Divider().color(this.dividerColor());

      // 课程清单
      Scroll() {
        Column() {
          ForEach(this.parseResult.courses, (course: ParsedCourse, idx: number) => {
            Column() {
              Row({ space: 8 }) {
                Text(`${idx + 1}`)
                  .fontSize(11)
                  .fontColor(Color.White)
                  .width(20)
                  .height(20)
                  .textAlign(TextAlign.Center)
                  .borderRadius(10)
                  .backgroundColor(this.brandColor);
                Column() {
                  Text(course.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.primaryText())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis });
                  if (course.teacher.length > 0) {
                    Text(course.teacher)
                      .fontSize(11)
                      .fontColor(this.mutedText())
                      .margin({ top: 1 });
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);
                Text(`${course.slots.length} 个时间段`)
                  .fontSize(11)
                  .fontColor(this.faintText());
              }
              .width('100%');

              ForEach(course.slots, (slot: ParsedSlot, sIdx: number) => {
                Text(`周${'一二三四五六日'.charAt(slot.dayOfWeek - 1)} 第${slot.startSection}-${slot.endSection}节 · ${slot.weeksText.length > 0 ? slot.weeksText : '每周'}${slot.location.length > 0 ? ' · ' + slot.location : ''}`)
                  .fontSize(11)
                  .fontColor(this.secondaryText())
                  .padding({ left: 28, top: 3 });
              }, (slot: ParsedSlot, sIdx: number) => `slot-${idx}-${sIdx}`);
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ top: 10, bottom: 10, left: 16, right: 16 });

            if (idx < this.parseResult.courses.length - 1) {
              Divider().color(this.dividerColor());
            }
          }, (course: ParsedCourse, idx: number) => `course-${idx}-${course.name}`);
        }
        .width('100%')
        .constraintSize({ minHeight: 160 });
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off);

      // 确认导入
      Column() {
        if (this.importDone.length > 0) {
          Text(this.importDone)
            .fontSize(13)
            .fontColor(this.brandColor)
            .margin({ bottom: 8 });
        }
        Row({ space: 8 }) {
          if (this.importBusy) {
            LoadingProgress().width(18).height(18).color(Color.White);
          }
          Text(this.importBusy ? '导入中…' : `导入 ${this.parseResult.courses.length} 门课程`)
            .fontSize(16)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium);
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height(48)
        .borderRadius(24)
        .backgroundColor(this.importBusy ? '#AAAAAA' : this.brandColor)
        .enabled(!this.importBusy)
        .onClick(() => { this.confirmImport(); });
      }
      .width('100%')
      .padding(12);
    }
    .width('100%')
    .height('100%');
  }

  private semesterOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const s of this.semesters) {
      options.push({ value: s.label } as SelectOption);
    }
    return options;
  }

  private selectedSemesterLabel(): string {
    if (this.targetSemIdx >= 0 && this.targetSemIdx < this.semesters.length) {
      return this.semesters[this.targetSemIdx].label;
    }
    return '请先创建学期';
  }

  private async confirmImport(): Promise<void> {
    if (this.importBusy) {
      return;
    }
    if (this.targetSemIdx >= this.semesters.length) {
      this.toast('请先在课表页创建学期');
      return;
    }
    const semesterId = this.semesters[this.targetSemIdx].id;
    const generation = this.asyncGeneration;
    this.importBusy = true;
    try {
      let count = 0;
      for (const course of this.parseResult.courses) {
        const drafts: SlotDraft[] = course.slots.map((s) => {
          return {
            dayOfWeek: s.dayOfWeek,
            startSection: s.startSection,
            endSection: s.endSection,
            weeksType: s.weeksType,
            customWeeks: s.customWeeks,
            location: s.location
          } as SlotDraft;
        });
        await ScheduleRepository.createCourse(semesterId, course.name, course.teacher, -1, '', drafts);
        count++;
      }
      if (!this.isCurrent(generation)) {
        return;
      }
      AppTheme.notifyScheduleChanged();
      // 后台同步,不阻塞结果提示
      SyncEngine.sync().catch(() => {
      });
      this.importDone = `已导入 ${count} 门课程`;
      this.toast(`已导入 ${count} 门课程，可在课表页查看`);
      this.importBusy = false;
      router.back();
    } catch (e) {
      if (this.isCurrent(generation)) {
        this.importBusy = false;
        this.toast('导入失败，请稍后重试');
      }
    }
  }

  // ==================== 失败页 ====================

  @Builder
  FailedPane() {
    Column({ space: 12 }) {
      Text('😕')
        .fontSize(44)
        .margin({ top: 64 });
      Text('没有识别出课程')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryText());
      Text(this.parseResult.detail)
        .fontSize(12)
        .fontColor(this.mutedText())
        .lineHeight(18)
        .padding({ left: 24, right: 24 })
        .textAlign(TextAlign.Center);

      Text('返回网页重试')
        .fontSize(15)
        .fontColor(Color.White)
        .width('60%')
        .height(44)
        .textAlign(TextAlign.Center)
        .borderRadius(22)
        .backgroundColor(this.brandColor)
        .margin({ top: 16 })
        .onClick(() => { this.route = 'web'; });
      Text('返回导入页')
        .fontSize(13)
        .fontColor(this.mutedText())
        .padding(12)
        .onClick(() => router.back());
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center);
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });
  }
}

/** 学期下拉选项 */
interface SemOption {
  id: number;
  label: string;
  isCurrent: boolean;
}

/** runJavaScript 回调返回值可能是 JSON 编码的字符串(带引号),解包 */
function unwrapJsString(result: string): string {
  if (typeof result !== 'string' || result.length === 0) {
    return '';
  }
  if (result.charAt(0) === '"' && result.charAt(result.length - 1) === '"') {
    try {
      const decoded = JSON.parse(result) as string;
      return typeof decoded === 'string' ? decoded : '';
    } catch (e) {
      return '';
    }
  }
  return result;
}
