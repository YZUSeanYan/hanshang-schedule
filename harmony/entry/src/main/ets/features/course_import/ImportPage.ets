/**
 * 导入课表入口页(M4)——按 Flutter 版 import_page.dart 完整还原。
 * 布局：居中图标+标题 → VPN 手动导入卡 → 口令导入卡 → 小贴士卡。
 * （手动粘贴导入为鸿蒙版独有，入口收纳在口令卡下方文字链。）
 */
import { ShareRepository, } from '../share/ShareRepository';
import { SharePreview, SharePreviewCourse } from '../share/ShareTypes';
import { SyncEngine } from '../../sync/SyncEngine';
import { SlotDraft } from '../schedule/ScheduleTypes';
import { ScheduleRepository } from '../schedule/ScheduleRepository';
import { ScheduleDao } from '../../data/ScheduleDao';
import { mondayOfMs } from '../../utils/WeekCalculator';
import { parseBlockList, ParsedCourse } from './TextImportParser';
import { AppTheme } from '../../common/AppTheme';
import { router } from '@kit.ArkUI';

@Component
export struct ImportPage {
  @StorageProp(AppTheme.KEY_BRAND) brandColor: string = '#158A63';
  @StorageProp(AppTheme.KEY_BRAND_TINT) brandTint: string = '#158A631F';
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;

  @State showManualPaste: boolean = false;
  @State shareCode: string = '';
  @State pasteText: string = '';
  @State parsedCourses: ParsedCourse[] = [];
  @State claiming: boolean = false;
  @State semesterId: number = 0;
  @State preview: SharePreview | null = null;
  @State showPreview: boolean = false;
  @State claimConflict: boolean = false;
  @State showCreateSemester: boolean = false;
  @State newSemName: string = '';
  @State creatingSem: boolean = false;

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private surfaceColor(): string { return this.effectiveDark ? '#1C1F22' : '#F7F8FA'; }
  private inputColor(): string { return this.effectiveDark ? '#272B2F' : '#FFFFFF'; }
  private controlColor(): string { return this.effectiveDark ? '#292D31' : '#F0F0F0'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private secondaryText(): string { return this.effectiveDark ? '#B8BDC2' : '#666666'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private disabledText(): string { return this.effectiveDark ? '#656C73' : '#BDBDBD'; }
  private dividerColor(): string { return this.effectiveDark ? '#34383D' : '#E5E7EA'; }

  aboutToAppear(): void {
    this.loadSemester();
  }

  private async loadSemester(): Promise<void> {
    const sem = await ScheduleDao.findCurrentSemester();
    if (sem !== null) {
      this.semesterId = sem.id;
    }
  }

  build() {
    Column() {
      if (this.showManualPaste) {
        Column() {
          this.ManualPastePage();
        }.width('100%').height('100%')
        .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.FastOutSlowIn }));
      } else {
        this.MainImportPage();
      }
      if (this.showPreview && this.preview !== null) {
        this.PreviewOverlay();
      }
      if (this.showCreateSemester) {
        this.CreateSemesterOverlay();
      }
      if (this.showOverwriteConfirm) {
        this.OverwriteConfirmOverlay();
      }
    }
    .width('100%')
    .height('100%');
  }

  // ---------- 主导入页(对齐 Android) ----------
  @Builder
  MainImportPage() {
    Scroll() {
      Column() {
        // 顶部图标+标题(Android: Icon 72 + titleLarge + bodyMedium)
        Text('🏫')
          .fontSize(64)
          .margin({ top: 16 });
        Text('从教务系统导入课表')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .margin({ top: 12 });
        Text('推荐在 App 内打开 WebVPN 手动完成登录与导入；也可以输入同学分享的口令导入。')
          .fontSize(13)
          .fontColor(this.secondaryText())
          .textAlign(TextAlign.Center)
          .lineHeight(19)
          .margin({ top: 10, bottom: 20 });

        // ---- 卡片1: VPN 手动导入(Android: Card + FilledButton) ----
        Column() {
          Text('VPN 手动导入（推荐）')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryText());
          Text('登录过程完全显示在 App 内，遇到验证码或二次验证也能由你本人继续操作。')
            .fontSize(12)
            .fontColor(this.mutedText())
            .margin({ top: 6 });
          Button('打开 WebVPN 手动导入')
            .fontSize(15)
            .fontColor(Color.White)
            .width('100%')
            .height(44)
            .backgroundColor(this.brandColor)
            .borderRadius(22)
            .margin({ top: 14 })
            .onClick(() => {
              router.pushUrl({ url: 'features/course_import/ImportWebViewPage' });
            });
        }
        .padding(16)
        .borderRadius(12)
        .backgroundColor(this.surfaceColor())
        .width('100%')
        .alignItems(HorizontalAlign.Start);

        // ---- 卡片2: 口令导入(Android: Card + TextField + TonalButton) ----
        Column() {
          Row() {
            Text('👥')
              .fontSize(18)
              .fontColor(this.brandColor);
            Text('口令导入（同学分享）')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryText())
              .margin({ left: 8 });
          };
          Text('输入同学分享的 6 位口令，预览确认后创建一份独立课表副本。')
            .fontSize(12)
            .fontColor(this.mutedText())
            .margin({ top: 6 });
          TextInput({ text: this.shareCode, placeholder: '例如 K7M2QP' })
            .height(48)
            .fontSize(16)
            .maxLength(6)
            .fontColor(this.primaryText())
            .placeholderColor(this.mutedText())
            .backgroundColor(this.inputColor())
            .borderRadius(8)
            .margin({ top: 12 })
            .onChange((v: string) => { this.shareCode = v.toUpperCase(); });
          Text('查看课表预览')
            .fontSize(15)
            .fontColor(this.shareCode.trim().length === 6 ? this.brandColor : this.disabledText())
            .width('100%')
            .height(44)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.shareCode.trim().length === 6 ? this.brandTint : this.controlColor())
            .borderRadius(22)
            .margin({ top: 12 })
            .onClick(() => {
              if (this.shareCode.trim().length === 6 && !this.claiming) {
                this.previewShareCode();
              }
            });
        }
        .padding(16)
        .borderRadius(12)
        .backgroundColor(this.surfaceColor())
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 16 });

        // ---- 手动粘贴入口(文字链,鸿蒙版保留的备用通道) ----
        Text('没有口令？试试手动粘贴导入 ›')
          .fontSize(12)
          .fontColor(this.mutedText())
          .margin({ top: 12 })
          .onClick(() => { this.showManualPaste = true; });

        // ---- 卡片3: 小贴士(Android: Card) ----
        Column() {
          Text('小贴士')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryText());
          Text('· 校园网环境可直连教务系统，无需 WebVPN；\n· 请在「常用服务 → 班级课表」中选择自己对应的班级；\n· 导入结果可以在课表页继续手动调整。')
            .fontSize(12)
            .fontColor(this.mutedText())
            .lineHeight(19)
            .margin({ top: 6, bottom: 16 });
        }
        .padding(16)
        .borderRadius(12)
        .backgroundColor(this.surfaceColor())
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 16 });
      }
      .padding({ left: 16, right: 16 })
      .width('100%');
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
    .edgeEffect(EdgeEffect.Spring);
  }

  // ---------- 手动粘贴页 ----------
  @Builder
  ManualPastePage() {
    Column() {
      Row() {
        Text('＜')
          .fontSize(20)
          .fontColor(this.primaryText())
          .onClick(() => { this.showManualPaste = false; });
        Text('手动粘贴导入')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .margin({ left: 12 });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 });

      Scroll() {
        Column() {
          Text('从教务系统复制课表文本')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryText());
          Text('打开教务系统 → 本学期课表 → 全部课程清单 → 全选拷贝 → 粘贴到下方')
            .fontSize(12)
            .fontColor(this.mutedText())
            .margin({ top: 4 });
          TextArea({ text: this.pasteText, placeholder: '粘贴课表文本到这里...' })
            .height(200)
            .fontSize(13)
            .fontColor(this.primaryText())
            .placeholderColor(this.mutedText())
            .backgroundColor(this.surfaceColor())
            .borderRadius(8)
            .margin({ top: 12 })
            .onChange((v: string) => { this.pasteText = v; });
          Row() {
            Text('解析预览')
              .fontSize(14)
              .fontColor(Color.White)
              .layoutWeight(1)
              .height(42)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.pasteText.length > 10 ? this.brandColor : '#CCCCCC')
              .borderRadius(21)
              .onClick(() => {
                if (this.pasteText.length > 10) {
                  this.parsedCourses = parseBlockList(this.pasteText);
                }
              });
            Text('清空')
              .fontSize(14)
              .fontColor(this.secondaryText())
              .layoutWeight(1)
              .height(42)
              .margin({ left: 12 })
              .textAlign(TextAlign.Center)
              .backgroundColor(this.controlColor())
              .borderRadius(21)
              .onClick(() => {
                this.pasteText = '';
                this.parsedCourses = [];
              });
          }
          .width('100%')
          .margin({ top: 12 });

          if (this.parsedCourses.length > 0) {
            Text(`解析到 ${this.parsedCourses.length} 门课程`)
              .fontSize(14)
              .fontColor(this.brandColor)
              .margin({ top: 12 });
            ForEach(this.parsedCourses.slice(0, 10), (course: ParsedCourse, idx: number) => {
              Column() {
                Text(course.name).fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor(this.primaryText());
                Text(`${course.teacher} · ${course.slots.length} 个时间段`)
                  .fontSize(12).fontColor(this.mutedText()).margin({ top: 2 });
              }
              .padding(12)
              .backgroundColor(this.surfaceColor())
              .borderRadius(8)
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .margin({ top: 4 });
            }, (course: ParsedCourse, idx: number) => `parsed-${idx}`);
            Text('确认导入')
              .fontSize(15)
              .fontColor(Color.White)
              .width('100%')
              .height(46)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.brandColor)
              .borderRadius(23)
              .margin({ top: 12, bottom: 24 })
              .onClick(() => this.importParsedCourses());
          }
        }
        .padding(16)
        .width('100%');
      }
      .layoutWeight(1);
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor());
  }

  // ---------- 口令预览弹层(对齐 Android AlertDialog) ----------
  @Builder
  PreviewOverlay() {
    Column() {
      Column()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => { this.showPreview = false; });
      Column() {
        Text(this.previewNameText())
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.primaryText()).margin({ top: 16 });
        Text(`${this.previewCountText()} 门课程 · 有效期至 ${this.expiresText()}`)
          .fontSize(12).fontColor(this.mutedText()).margin({ top: 4 });

        // 课程清单(最多 8 条)
        Column() {
          ForEach(this.previewCourses(), (course: SharePreviewCourse, idx: number) => {
            Row({ space: 10 }) {
              Text('📖').fontSize(16);
              Column() {
                Text(course.name)
                  .fontSize(14)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(this.courseSubtitle(course))
                  .fontSize(11).fontColor(this.mutedText()).margin({ top: 1 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1);
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 });
          }, (course: SharePreviewCourse, idx: number) => `pv-${idx}-${course.name}`);
        }
        .margin({ top: 8 })
        .constraintSize({ maxHeight: 240 });

        Text('导入后创建一份独立副本，可自由编辑，不会影响分享者的课表。')
          .fontSize(11).fontColor(this.mutedText()).margin({ top: 8 });

        Row() {
          Text('取消').fontSize(15).fontColor(this.secondaryText()).layoutWeight(1).height(46).textAlign(TextAlign.Center)
            .onClick(() => { this.showPreview = false; });
          Divider().vertical(true).color(this.dividerColor()).height(46);
          Text(this.claiming ? '导入中…' : '导入我的课表')
            .fontSize(15).fontColor(this.brandColor).layoutWeight(1).height(46).textAlign(TextAlign.Center)
            .onClick(() => this.claimShareCode(false));
        }
        .width('100%')
        .margin({ top: 12 })
        .borderRadius(8)
        .backgroundColor(this.surfaceColor());
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 20 })
      .backgroundColor(this.pageColor())
      .borderRadius({ topLeft: 16, topRight: 16 });
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 }).justifyContent(FlexAlign.End);
  }

  // ---------- 创建学期弹层(导入页「请先创建学期」一键引导) ----------
  @Builder
  CreateSemesterOverlay() {
    Column() {
      Column()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => { this.showCreateSemester = false; });
      Column() {
        Text('先创建一个学期')
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.primaryText()).margin({ top: 20 });
        Text('导入课程前需要告诉 App 这是哪个学期的课表。默认使用当前建议的学期名与 20 周,创建后可随时在课表页调整。')
          .fontSize(13).fontColor(this.secondaryText())
          .margin({ top: 12, left: 16, right: 16 })
          .lineHeight(20);
        TextInput({ text: this.newSemName, placeholder: '例如 2026秋' })
          .height(46)
          .fontSize(15)
          .fontColor(this.primaryText())
          .placeholderColor(this.mutedText())
          .backgroundColor(this.surfaceColor())
          .borderRadius(10)
          .margin({ top: 12, left: 16, right: 16 })
          .onChange((v: string) => { this.newSemName = v; });
        Row() {
          Text('取消').fontSize(15).fontColor(this.secondaryText()).layoutWeight(1).height(46).textAlign(TextAlign.Center)
            .onClick(() => { this.showCreateSemester = false; });
          Divider().vertical(true).color(this.dividerColor()).height(46);
          Text(this.creatingSem ? '创建中…' : '一键创建')
            .fontSize(15).fontColor(this.brandColor).layoutWeight(1).height(46).textAlign(TextAlign.Center)
            .onClick(() => { this.createSemesterNow(); });
        }
        .width('100%')
        .margin({ top: 12 })
        .borderRadius(8)
        .backgroundColor(this.surfaceColor());
      }
      .width('78%')
      .padding({ bottom: 20 })
      .borderRadius(16)
      .backgroundColor(this.pageColor());
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center);
  }

  /** 建议学期名:今年秋 / 明年春(按 2-8 月属春,9-1 月属秋) */
  private suggestSemesterName(): string {
    const d = new Date();
    const year = d.getFullYear();
    const month = d.getMonth() + 1;
    if (month >= 2 && month <= 7) {
      return `${year}春`;
    }
    if (month >= 8) {
      return `${year}秋`;
    }
    return `${year - 1}秋`;
  }

  private async createSemesterNow(): Promise<void> {
    if (this.creatingSem) {
      return;
    }
    const name = this.newSemName.trim().length > 0 ? this.newSemName.trim() : this.suggestSemesterName();
    this.creatingSem = true;
    try {
      // 默认本学期:从最近一个周一开学起 20 周
      const monday = mondayOfMs(Date.now());
      // createSemester 内部已自动设为当前学期
      const id = await ScheduleRepository.createSemester(name, monday, 20);
      this.semesterId = id;
      this.showCreateSemester = false;
      this.toast(`已创建学期「${name}」,现在可以继续导入`);
      AppTheme.notifyScheduleChanged();
    } catch (e) {
      this.toast('创建失败,请稍后再试');
    } finally {
      this.creatingSem = false;
    }
  }

  // ---------- 业务 ----------
  private previewNameText(): string {
    const p = this.preview;
    if (p === null) {
      return '课表预览';
    }
    return p.semesterName.length > 0 ? `${p.semesterName} · 课表预览` : '课表预览';
  }

  private previewCountText(): string {
    const p = this.preview;
    return p === null ? '0' : `${p.courseCount}`;
  }

  private expiresText(): string {
    const p = this.preview;
    if (p === null) {
      return '';
    }
    return p.expiresAt.replace('T', ' ').substring(0, 16);
  }

  private previewCourses(): SharePreviewCourse[] {
    const p = this.preview;
    if (p === null) {
      return [];
    }
    return p.courses.slice(0, 8);
  }

  private courseSubtitle(course: SharePreviewCourse): string {
    const teacher = course.teacher.length > 0 ? course.teacher + ' · ' : '';
    return `${teacher}${course.slotCount} 个时间段`;
  }

  private async previewShareCode(): Promise<void> {
    this.claiming = true;
    try {
      const preview = await ShareRepository.preview(this.shareCode.trim());
      this.preview = preview;
      this.showPreview = true;
    } catch (e) {
      this.toast('预览失败，请确认口令是否正确');
    } finally {
      this.claiming = false;
    }
  }

  private async claimShareCode(replaceExisting: boolean): Promise<void> {
    if (this.claiming) {
      return;
    }
    this.claiming = true;
    try {
      const count = await ShareRepository.claim(this.shareCode.trim(), replaceExisting);
      await SyncEngine.sync();
      AppTheme.notifyScheduleChanged();
      this.showPreview = false;
      this.shareCode = '';
      this.toast(`已导入 ${count} 门课程，可在课表页查看`);
    } catch (e) {
      const msg = `${e}`;
      if (msg.includes('409') && !replaceExisting) {
        // 同名同开学日学期冲突:提示覆盖
        this.showPreview = false;
        this.confirmOverwrite();
      } else {
        this.toast('导入失败，请稍后重试');
      }
    } finally {
      this.claiming = false;
    }
  }

  @State showOverwriteConfirm: boolean = false;

  @Builder
  OverwriteConfirmOverlay() {
    Column() {
      Column()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => { this.showOverwriteConfirm = false; });
      Column() {
        Text('已有同一学期的课表')
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.primaryText()).margin({ top: 20 });
        Text('你已有相同名称和开学日期的课表，是否用分享的课表覆盖它？')
          .fontSize(14).fontColor(this.secondaryText())
          .margin({ top: 12, left: 16, right: 16 })
          .lineHeight(21);
        Row() {
          Text('取消').fontSize(15).fontColor(this.secondaryText()).layoutWeight(1).height(46).textAlign(TextAlign.Center)
            .onClick(() => { this.showOverwriteConfirm = false; });
          Divider().vertical(true).color(this.dividerColor()).height(46);
          Text('覆盖').fontSize(15).fontColor(this.brandColor).layoutWeight(1).height(46).textAlign(TextAlign.Center)
            .onClick(() => {
              this.showOverwriteConfirm = false;
              this.claimShareCode(true);
            });
        }
        .width('100%')
        .margin({ top: 16 })
        .borderRadius(8)
        .backgroundColor(this.surfaceColor());
      }
      .width('78%')
      .borderRadius(16)
      .backgroundColor(this.pageColor());
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center);
  }

  private confirmOverwrite(): void {
    this.showOverwriteConfirm = true;
  }

  private async importParsedCourses(): Promise<void> {
    if (this.semesterId === 0) {
      this.newSemName = this.suggestSemesterName();
      this.showCreateSemester = true;
      return;
    }
    try {
      for (const course of this.parsedCourses) {
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
        await ScheduleRepository.createCourse(this.semesterId, course.name, course.teacher, -1, '', drafts);
      }
      await SyncEngine.sync();
      AppTheme.notifyScheduleChanged();
      this.toast(`已导入 ${this.parsedCourses.length} 门课程`);
      this.parsedCourses = [];
      this.pasteText = '';
      this.showManualPaste = false;
    } catch (e) {
      this.toast('导入失败，请稍后重试');
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });
  }
}
