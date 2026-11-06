/**
 * 课表主页：周/日视图切换、周次滑动导航、课程详情、空状态。
 * 移植自 Flutter 版 features/schedule/presentation/schedule_page.dart。
 */
import { CourseEntry, Semester } from './ScheduleTypes';
import { WeekView } from './WeekView';
import { DayView } from './DayView';
import { CourseEditPage } from './CourseEditPage';
import { SemesterSettingsPage } from './SemesterSettingsPage';
import { ScheduleRepository } from './ScheduleRepository';
import { ShareRepository } from '../share/ShareRepository';
import { SyncEngine } from '../../sync/SyncEngine';
import { ScheduleDao } from '../../data/ScheduleDao';
import { weekNumberOf, clampWeek, DAY_MS, mondayOfMs } from '../../utils/WeekCalculator';
import { AppTheme } from '../../common/AppTheme';

// 简单页面路由
export type ScheduleRoute = 'main' | 'courseEdit' | 'semesterSettings';

@Component
export struct SchedulePage {
  @StorageProp(AppTheme.KEY_BRAND) brandColor: string = '#158A63';
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @StorageLink(AppTheme.KEY_SCHEDULE_REV) @Watch('onScheduleChanged') scheduleRev: number = 0;

  // ---- 导航 ----
  @State currentRoute: ScheduleRoute = 'main';
  @State editingCourse: CourseEntry | null = null;
  @State editingSemesterId: number = 0;

  // ---- 数据 ----
  @State semester: Semester | null = null;
  @State entries: CourseEntry[] = [];
  @State loading: boolean = true;

  // ---- 视图状态 ----
  @State isDayView: boolean = false;
  @State displayedWeek: number = 1;
  @State displayedDate: number = 0;
  @State currentWeek: number = 1;
  private weekSwiperController: SwiperController = new SwiperController();
  private pendingSwiperAlignment: boolean = false;

  // ---- 分享 ----
  @State showShareDialog: boolean = false;
  @State shareCode: string = '';
  @State shareExpires: string = '';
  @State sharing: boolean = false;

  // ---- 课程详情 ----
  @State showCourseDetail: boolean = false;
  @State selectedEntry: CourseEntry | null = null;

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private surfaceColor(): string { return this.effectiveDark ? '#1C1F22' : '#FFFFFF'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private secondaryText(): string { return this.effectiveDark ? '#B8BDC2' : '#666666'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private iconColor(): string { return this.effectiveDark ? '#E5E7E9' : '#333333'; }

  aboutToAppear(): void {
    this.loadData();
  }

  onPageShow(): void {
    this.loadData();
  }

  private onScheduleChanged(): void {
    this.loadData();
  }

  async loadData(): Promise<void> {
    this.loading = true;
    const previousSemesterId = this.semester?.id ?? 0;
    const previousWeek = this.displayedWeek;
    const sem = await ScheduleDao.findCurrentSemester();
    this.semester = sem;
    if (sem !== null) {
      this.entries = await ScheduleRepository.loadCourseEntries(sem.id);
      const raw = weekNumberOf(sem.startDateMs, Date.now());
      const clamped = clampWeek(raw, sem.totalWeeks);
      this.currentWeek = clamped ?? 1;
      const sameSemester = previousSemesterId === sem.id;
      this.displayedWeek = sameSemester
        ? Math.max(1, Math.min(previousWeek, sem.totalWeeks))
        : this.currentWeek;
      this.displayedDate = mondayOfMs(Date.now());
      this.pendingSwiperAlignment = !sameSemester;
    } else {
      this.entries = [];
      this.pendingSwiperAlignment = false;
    }
    this.loading = false;
  }

  build() {
    Column() {
      if (this.currentRoute === 'courseEdit') {
        Column() { CourseEditPage({
          existing: this.editingCourse,
          semesterId: this.semester?.id ?? 0,
          onSaved: () => {
            this.navigateTo('main');
            this.editingCourse = null;
            AppTheme.notifyScheduleChanged();
            this.loadData();
          },
          onCancel: () => {
            this.editingCourse = null;
            this.navigateTo('main');
          }
        });
      }
      .width('100%')
      .height('100%')
      .transition(TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ x: 24 }))
        .animation({ duration: 240, curve: Curve.FastOutSlowIn }));
      } else if (this.currentRoute === 'semesterSettings') {
        Column() { SemesterSettingsPage({
          onSaved: () => {
            this.navigateTo('main');
            this.loadData();
          },
          onCancel: () => {
            this.navigateTo('main');
          }
        });
      }
      .width('100%')
      .height('100%')
      .transition(TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ x: 24 }))
        .animation({ duration: 240, curve: Curve.FastOutSlowIn }));
      } else {
        this.MainContentBuilder();
      }
    }
    .width('100%')
    .height('100%');
  }

  private navigateTo(route: ScheduleRoute): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      this.currentRoute = route;
    });
  }

  @Builder
  MainContentBuilder() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 底层:课表主内容
      Column() {
        if (this.loading) {
          Column() {
            LoadingProgress().width(40).height(40).color(this.brandColor);
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center);
        } else if (this.semester === null) {
          this.NoSemesterBuilder();
        } else if (this.entries.length === 0) {
          this.NoCourseBuilder();
        } else {
          this.ScheduleHeaderBuilder();
          Stack({ alignContent: Alignment.TopStart }) {
            if (this.isDayView) {
              DayView({
                semester: this.semester!,
                date: this.displayedDate,
                entries: this.entries,
                onCourseTap: (entry: CourseEntry) => this.onCourseTap(entry)
              })
                .transition(TransitionEffect.OPACITY
                  .combine(TransitionEffect.translate({ x: 20 }))
                  .animation({ duration: 220, curve: Curve.FastOutSlowIn }));
            } else {
              Swiper(this.weekSwiperController) {
                ForEach(this.weekList(), (week: number) => {
                  WeekView({
                    semester: this.semester!,
                    week: week,
                    entries: this.entries,
                    onCourseTap: (entry: CourseEntry) => this.onCourseTap(entry)
                  });
                }, (week: number) => `week-page-${this.semester!.id}-${week}`);
              }
              .index(this.displayedWeek - 1)
              .loop(false)
              .indicator(false)
              .duration(260)
              .cachedCount(1)
              .onChange((index: number) => {
                this.displayedWeek = index + 1;
              })
              .onAppear(() => { this.alignWeekSwiperIfNeeded(); })
              .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }));
            }
          }
          .width('100%')
          .layoutWeight(1);
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageColor());

      // 顶层:课程详情弹层
      if (this.showCourseDetail && this.selectedEntry !== null) {
        this.CourseDetailBuilder();
      }
      // 顶层:分享弹层
      if (this.showShareDialog) {
        this.ShareDialogBuilder();
      }
    }
    .width('100%')
    .height('100%');
  }

  // ---------- 分享弹层 ----------
  @Builder
  ShareDialogBuilder() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => { this.closeShareDialog(); })
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }));
      Column() {
        Text('分享给同学')
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.primaryText()).margin({ top: 16 });
        if (this.shareCode.length > 0) {
          Text('同学登录邗上课表后输入这个口令,即可领取一份可独立编辑的课表')
            .fontSize(12).fontColor(this.mutedText()).margin({ top: 8 });
          Text(this.shareCode)
            .fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.primaryText()).letterSpacing(4).margin({ top: 16 });
          Text(`有效期至 ${this.shareExpires}`)
            .fontSize(12).fontColor(this.mutedText()).margin({ top: 8 });
        } else if (this.sharing) {
          LoadingProgress().width(32).height(32).color(this.brandColor).margin({ top: 24 });
          Text('正在生成口令...').fontSize(14).fontColor(this.mutedText()).margin({ top: 12 });
        }
        Row() {
          Text('关闭').fontSize(15).fontColor(this.secondaryText()).layoutWeight(1).height(44).textAlign(TextAlign.Center)
            .onClick(() => { this.closeShareDialog(); });
          if (this.shareCode.length > 0) {
            Text('复制口令').fontSize(15).fontColor(Color.White).layoutWeight(1).height(44).textAlign(TextAlign.Center)
              .backgroundColor(this.brandColor).borderRadius(22)
              .onClick(() => {
                this.getUIContext().getPromptAction().showToast({ message: '口令已复制', duration: 2000 });
              });
          }
        }.width('100%').margin({ top: 16 });
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 24 })
      .backgroundColor(this.surfaceColor())
      .borderRadius({ topLeft: 16, topRight: 16 })
      .transition(TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: 48 }))
        .animation({ duration: 260, curve: Curve.FastOutSlowIn }));
    }
    .width('100%')
    .height('100%');
  }

  private closeShareDialog(): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.showShareDialog = false;
    });
  }

  private async shareSemester(): Promise<void> {
    if (this.semester === null || this.semester.uuid.length === 0) {
      this.toast('课表正在准备同步标识,请稍后再试');
      return;
    }
    const entries = this.entries;
    if (entries.length === 0) {
      this.toast('当前课表还没有课程,先添加课程再分享');
      return;
    }
    this.shareCode = '';
    this.sharing = true;
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.showShareDialog = true;
    });
    try {
      await SyncEngine.sync();
      const info = await ShareRepository.create(this.semester.uuid);
      this.shareCode = info.code;
      this.shareExpires = info.expiresAt.substring(0, 16);
    } catch (e) {
      this.toast('生成口令失败,请稍后重试');
      this.closeShareDialog();
    } finally {
      this.sharing = false;
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });
  }

  // ---------- 表头 ----------
  @Builder
  ScheduleHeaderBuilder() {
    Column() {
      Row() {
        // 标题区(Android: AppBar title + subtitle)
        Column() {
          Text(this.isDayView
            ? `${new Date(this.displayedDate).getUTCMonth() + 1}月${new Date(this.displayedDate).getUTCDate()}日 ${this.weekdayLabel(this.displayedDate)}`
            : `第 ${this.displayedWeek} 周`)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryText());
          Text(this.isDayView ? this.daySubtitle() : this.weekRangeText())
            .fontSize(11)
            .fontColor(this.mutedText())
            .margin({ top: 2 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
        // 操作按钮区:统一使用 Harmony 系统单色符号
        Row() {
          Column() {
            SymbolGlyph(this.isDayView
              ? $r('sys.symbol.rectangle_grid_1x2')
              : $r('sys.symbol.list_bullet'))
              .fontSize(20)
              .fontColor([this.iconColor()]);
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .stateStyles({ pressed: { .opacity(0.55) }, normal: { .opacity(1) } })
          .onClick(() => { this.switchScheduleView(); });
          if (!this.isDayView && this.currentWeek !== this.displayedWeek) {
            Text('回本周')
              .fontSize(12)
              .fontColor(this.brandColor)
              .height(32)
              .padding({ left: 4, right: 4 })
              .onClick(() => { this.goToWeek(this.currentWeek); });
          }
          Column() {
            if (this.sharing) {
              LoadingProgress().width(18).height(18).color(this.brandColor);
            } else {
              SymbolGlyph($r('sys.symbol.share'))
                .fontSize(20)
                .fontColor([this.iconColor()]);
            }
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .stateStyles({ pressed: { .opacity(0.55) }, normal: { .opacity(1) } })
          .onClick(() => this.shareSemester());
          Column() {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(21)
              .fontColor([this.iconColor()]);
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .stateStyles({ pressed: { .opacity(0.55) }, normal: { .opacity(1) } })
          .onClick(() => {
            this.editingCourse = null;
            this.navigateTo('courseEdit');
          });
          Column() {
            SymbolGlyph($r('sys.symbol.gearshape'))
              .fontSize(20)
              .fontColor([this.iconColor()]);
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .stateStyles({ pressed: { .opacity(0.55) }, normal: { .opacity(1) } })
          .onClick(() => { this.navigateTo('semesterSettings'); });
        };
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 });
      if (!this.isDayView) {
        Scroll() {
          Row() {
            ForEach(this.weekList(), (w: number) => {
              Text(`${w}`)
                .fontSize(12)
                .fontColor(w === this.displayedWeek ? Color.White : this.secondaryText())
                .width(32)
                .height(32)
                .textAlign(TextAlign.Center)
                .borderRadius(16)
                .backgroundColor(w === this.displayedWeek ? this.brandColor : Color.Transparent)
                .margin({ right: 6 })
                .onClick(() => { this.goToWeek(w); });
            }, (w: number) => `wk-${w}`);
          }
          .padding({ left: 16, right: 16, bottom: 8 });
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off);
      }
    }
    .backgroundColor(this.surfaceColor())
    .shadow({ radius: 2, color: this.effectiveDark ? '#40000000' : '#08000000', offsetY: 1 });
  }

  // ---------- 空状态 ----------
  @Builder
  NoSemesterBuilder() {
    Column() {
      Text('📅').fontSize(56);
      Text('先设置一下学期吧').fontSize(17).fontColor(this.primaryText()).margin({ top: 16 });
      Text('设置开学日期后,就能自动计算今天是第几周').fontSize(13).fontColor(this.mutedText()).margin({ top: 8 });
      Text('设置学期').fontSize(15).fontColor(Color.White)
        .padding({ left: 24, right: 24, top: 10, bottom: 10 })
        .backgroundColor(this.brandColor).borderRadius(20).margin({ top: 24 })
        .onClick(() => { this.navigateTo('semesterSettings'); });
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
  }

  @Builder
  NoCourseBuilder() {
    Column() {
      Text('📝').fontSize(56);
      Text('还没有课程').fontSize(17).fontColor(this.primaryText()).margin({ top: 16 });
      Text('从教务系统一键导入,或先手动添加一门课').fontSize(13).fontColor(this.mutedText()).margin({ top: 8 });
      Text('手动添加课程').fontSize(15).fontColor(Color.White)
        .padding({ left: 24, right: 24, top: 10, bottom: 10 })
        .backgroundColor(this.brandColor).borderRadius(20).margin({ top: 24 })
        .onClick(() => {
          this.editingCourse = null;
          this.navigateTo('courseEdit');
        });
      // 学期切换入口:多学期时让用户能切换到正确的学期
      if (this.semester !== null) {
        Text(`当前学期:${this.semester.name} · 切换/管理 ›`)
          .fontSize(12)
          .fontColor(this.brandColor)
          .margin({ top: 16 })
          .onClick(() => { this.navigateTo('semesterSettings'); });
      }
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center);
  }

  // ---------- 课程详情 ----------
  onCourseTap(entry: CourseEntry): void {
    this.selectedEntry = entry;
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
      this.showCourseDetail = true;
    });
  }

  @Builder
  CourseDetailBuilder() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 半透明背景
      Column()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => { this.closeCourseDetail(); })
        .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }));
      // 底部卡片
      Column() {
        Text(this.selectedEntry!.course.name)
          .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.primaryText()).margin({ top: 16 });
        Text(this.selectedEntry!.course.teacher)
          .fontSize(14).fontColor(this.secondaryText()).margin({ top: 4 });
        ForEach(this.selectedEntry!.slots, (slot: SchedSlot, idx: number) => {
          Row() {
            Text(`第${slot.startSection}-${slot.endSection}节`).fontSize(14).fontColor(this.primaryText()).margin({ top: 8 });
            Text(this.fmtSlotLocation(slot)).fontSize(13).fontColor(this.mutedText()).margin({ top: 8, left: 12 });
          }.width('100%');
        }, (slot: SchedSlot, idx: number) => `detail-slot-${idx}`);
        Row() {
          Text('编辑').fontSize(15).fontColor(this.brandColor).layoutWeight(1).height(44).textAlign(TextAlign.Center)
            .onClick(() => {
              this.editingCourse = this.selectedEntry;
              this.closeCourseDetail();
              this.navigateTo('courseEdit');
            });
          Text('删除').fontSize(15).fontColor('#CC0000').layoutWeight(1).height(44).textAlign(TextAlign.Center)
            .onClick(() => { this.confirmDelete(); });
        }.width('100%').margin({ top: 16 });
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 24 })
      .backgroundColor(this.surfaceColor())
      .borderRadius({ topLeft: 16, topRight: 16 })
      .transition(TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: 48 }))
        .animation({ duration: 260, curve: Curve.FastOutSlowIn }));
    }
    .width('100%')
    .height('100%');
  }

  private closeCourseDetail(): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.showCourseDetail = false;
    });
  }

  private fmtSlotLocation(slot: SchedSlot): string {
    return slot.location.length > 0 ? slot.location : '';
  }

  private async confirmDelete(): Promise<void> {
    if (this.selectedEntry === null) return;
    await ScheduleRepository.deleteCourse(this.selectedEntry.course.id);
    this.closeCourseDetail();
    this.selectedEntry = null;
    this.loadData();
  }

  // ---------- 工具 ----------
  private switchScheduleView(): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
      this.isDayView = !this.isDayView;
    });
  }

  private goToWeek(week: number): void {
    if (this.semester === null) return;
    const target = Math.max(1, Math.min(week, this.semester.totalWeeks));
    if (target === this.displayedWeek) return;
    this.weekSwiperController.changeIndex(target - 1, true);
  }

  private alignWeekSwiperIfNeeded(): void {
    if (!this.pendingSwiperAlignment || this.currentRoute !== 'main' || this.isDayView || this.semester === null) {
      return;
    }
    this.pendingSwiperAlignment = false;
    this.weekSwiperController.changeIndex(this.displayedWeek - 1, false);
  }

  private weekList(): number[] {
    const list: number[] = [];
    if (this.semester === null) return list;
    for (let i = 1; i <= this.semester.totalWeeks; i++) list.push(i);
    return list;
  }

  private weekdayLabel(dateMs: number): string {
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const d = new Date(dateMs).getUTCDay();
    return labels[d === 0 ? 6 : d - 1];
  }

  private daySubtitle(): string {
    if (this.semester === null) return '';
    if (this.currentWeek < 1) return `开学前 · ${this.semester.name}`;
    if (this.currentWeek > this.semester.totalWeeks) return `学期已结束 · ${this.semester.name}`;
    return `第 ${this.currentWeek} 周 · ${this.semester.name}`;
  }

  private weekRangeText(): string {
    if (this.semester === null) return '';
    const monday = this.semester.startDateMs + (this.displayedWeek - 1) * 7 * DAY_MS;
    const sunday = monday + 6 * DAY_MS;
    const mDate = new Date(monday);
    const sDate = new Date(sunday);
    return `${mDate.getUTCMonth() + 1}月${mDate.getUTCDate()}日 - ${sDate.getUTCMonth() + 1}月${sDate.getUTCDate()}日 · ${this.semester.name}`;
  }
}

/** 时间段简化视图(内部) */
interface SchedSlot {
  uuid: string;
  dayOfWeek: number;
  startSection: number;
  endSection: number;
  weeksType: number;
  customWeeksJson: string;
  location: string;
}
