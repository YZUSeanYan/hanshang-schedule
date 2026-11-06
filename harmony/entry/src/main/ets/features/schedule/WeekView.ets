/**
 * 周视图：7 列(周一~周日) × 12 小节网格,课程按色块显示,重叠课程自动分栏。
 * 移植自 Flutter 版 features/schedule/presentation/week_view.dart。
 * UI 精确还原 Android 版(左侧强调色条+圆角+半透明底色+文字混色)。
 * 修复:网格行垂直排列(包 Column)、底部可滚动到底、增加缓存高度。
 */
import { CourseEntry, Semester } from './ScheduleTypes';
import { SECTION_COUNT, startOf, endOf } from '../../constants/SectionTimes';
import { weekNumberOf, occursInWeek, DAY_MS } from '../../utils/WeekCalculator';
import { formatCourseLocation } from '../../utils/LocationFormatter';
import { jsonToWeeksList, SchedRow } from '../../model/SyncCodecs';
import { AppTheme } from '../../common/AppTheme';

/** 可见课程 */
interface VisibleCourse {
  entry: CourseEntry;
  slot: SchedRow;
}

/** 分栏结果 */
interface PlacedCourse {
  item: VisibleCourse;
  lane: number;
  laneCount: number;
}

const WEEKDAY_LABELS: string[] = ['一', '二', '三', '四', '五', '六', '日'];
const DAYS: number[] = [1, 2, 3, 4, 5, 6, 7];

@Component
export struct WeekView {
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @Prop semester: Semester = { id: 0, uuid: '', name: '', startDateMs: 0, totalWeeks: 20, isCurrent: false, updatedAtMs: 0 };
  @Prop week: number = 1;
  @Prop entries: CourseEntry[] = [];
  onCourseTap: (entry: CourseEntry) => void = () => {
  };

  private readonly TIME_COL_WIDTH: number = 56;
  private readonly SECTION_HEIGHT: number = 56;

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#333333'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private dividerColor(): string { return this.effectiveDark ? '#34383D' : '#E0E0E0'; }
  private gridColor(index: number): string {
    return this.effectiveDark ? (index % 2 === 0 ? '#171A1D' : '#111315') : (index % 2 === 0 ? '#FAFAFA' : '#FFFFFF');
  }

  private mondayMs(): number {
    return this.semester.startDateMs + (this.week - 1) * 7 * DAY_MS;
  }

  private dateOfDay(day: number): Date {
    return new Date(this.mondayMs() + (day - 1) * DAY_MS);
  }

  private isToday(day: number): boolean {
    const today = new Date();
    const currentWeek = weekNumberOf(this.semester.startDateMs, today.getTime());
    if (currentWeek !== this.week) return false;
    const date = this.dateOfDay(day);
    return date.getUTCFullYear() === today.getUTCFullYear() &&
      date.getUTCMonth() === today.getUTCMonth() &&
      date.getUTCDate() === today.getUTCDate();
  }

  private visibleCourses(day: number): VisibleCourse[] {
    const result: VisibleCourse[] = [];
    for (const entry of this.entries) {
      for (const slot of entry.slots) {
        if (slot.dayOfWeek !== day) continue;
        const weeks = jsonToWeeksList(slot.customWeeksJson);
        if (occursInWeek(slot.weeksType, weeks, this.week)) {
          result.push({ entry: entry, slot: slot });
        }
      }
    }
    return result;
  }

  private dayPlacements(day: number): PlacedCourse[] {
    return WeekView.placeOverlappingCourses(this.visibleCourses(day));
  }

  build() {
    Column() {
      this.HeaderBuilder();
      Divider().height(1).color(this.dividerColor());
      Scroll() {
        Row() {
          this.TimeColumnBuilder();
          ForEach(DAYS, (day: number) => {
            this.DayColumnBuilder(day);
          }, (day: number) => `day-${this.week}-${day}`);
        }
        .alignItems(VerticalAlign.Top)
        .height(SECTION_COUNT * this.SECTION_HEIGHT);
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Fade)
      .padding({ bottom: 16 });
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(this.pageColor());
  }

  @Builder
  HeaderBuilder() {
    Row() {
      Column() { }
        .width(this.TIME_COL_WIDTH)
        .height(40);
      ForEach(DAYS, (day: number) => {
        Column() {
          Text(WEEKDAY_LABELS[day - 1])
            .fontSize(12)
            .fontColor(this.isToday(day) ? '#087B58' : this.mutedText())
            .fontWeight(FontWeight.Bold);
          Text(`${this.dateOfDay(day).getUTCDate()}`)
            .fontSize(13)
            .fontColor(this.isToday(day) ? Color.White : this.primaryText())
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .borderRadius(13)
            .backgroundColor(this.isToday(day) ? '#087B58' : Color.Transparent)
            .margin({ top: 2 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center);
      }, (day: number) => `hdr-${day}`);
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 });
  }

  @Builder
  TimeColumnBuilder() {
    Column() {
      ForEach(this.sectionList(), (section: number) => {
        Column() {
          Text(`${section}`)
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryText());
          Text(`${startOf(section)}-${endOf(section)}`)
            .fontSize(7)
            .fontColor(this.mutedText());
        }
        .width(this.TIME_COL_WIDTH)
        .height(this.SECTION_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);
      }, (section: number) => `sec-${section}`);
    }
    .width(this.TIME_COL_WIDTH);
  }

  private sectionList(): number[] {
    const list: number[] = [];
    for (let i = 1; i <= SECTION_COUNT; i++) list.push(i);
    return list;
  }

  @Builder
  DayColumnBuilder(day: number) {
    Column() {
      Stack() {
        // 背景网格:12 行垂直排列(包在 Column 里)
        Column() {
          ForEach(this.gridList(), (i: number) => {
            Column()
              .width('100%')
              .height(this.SECTION_HEIGHT)
              .backgroundColor(this.gridColor(i))
              .border({ width: { bottom: 0.5 }, color: this.dividerColor() });
          }, (i: number) => `grid-${day}-${i}`);
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start);
        // 课程色块(绝对定位)
        ForEach(this.dayPlacements(day), (placed: PlacedCourse) => {
          CourseBlock({ placed: placed, onCourseTap: this.onCourseTap });
        }, (placed: PlacedCourse) => `blk-${day}-${placed.item.slot.uuid}-${placed.lane}`);
      }
      .width('100%')
      .height(SECTION_COUNT * this.SECTION_HEIGHT);
    }
    .layoutWeight(1)
    .height(SECTION_COUNT * this.SECTION_HEIGHT);
  }

  private gridList(): number[] {
    const list: number[] = [];
    for (let i = 0; i < SECTION_COUNT; i++) list.push(i);
    return list;
  }

  static placeOverlappingCourses(source: VisibleCourse[]): PlacedCourse[] {
    const sorted = [...source].sort((a, b) => {
      const byStart = a.slot.startSection - b.slot.startSection;
      return byStart !== 0 ? byStart : a.slot.endSection - b.slot.endSection;
    });
    const result: PlacedCourse[] = [];
    let index = 0;
    while (index < sorted.length) {
      const group: VisibleCourse[] = [sorted[index]];
      let groupEnd = sorted[index].slot.endSection;
      let next = index + 1;
      while (next < sorted.length && sorted[next].slot.startSection <= groupEnd) {
        group.push(sorted[next]);
        if (sorted[next].slot.endSection > groupEnd) {
          groupEnd = sorted[next].slot.endSection;
        }
        next++;
      }
      const laneEnds: number[] = [];
      const lanes: number[] = [];
      for (const item of group) {
        let lane = -1;
        for (let i = 0; i < laneEnds.length; i++) {
          if (laneEnds[i] < item.slot.startSection) {
            lane = i;
            break;
          }
        }
        if (lane === -1) {
          lane = laneEnds.length;
          laneEnds.push(item.slot.endSection);
        } else {
          laneEnds[lane] = item.slot.endSection;
        }
        lanes.push(lane);
      }
      for (let i = 0; i < group.length; i++) {
        const pc: PlacedCourse = { item: group[i], lane: lanes[i], laneCount: laneEnds.length };
        result.push(pc);
      }
      index = next;
    }
    return result;
  }
}

/** 课程块组件 */
@Component
struct CourseBlock {
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @Prop placed: PlacedCourse = {
    item: {
      entry: {
        course: { id: 0, uuid: '', semesterId: 0, name: '', teacher: '', color: 0, note: '', updatedAtMs: 0 },
        slots: []
      },
      slot: { id: 0, uuid: '', courseId: 0, dayOfWeek: 0, startSection: 0, endSection: 0, weeksType: 0, customWeeksJson: '[]', location: '', updatedAtMs: 0 }
    },
    lane: 0,
    laneCount: 1
  };
  onCourseTap: (entry: CourseEntry) => void = () => {
  };

  private readonly SECTION_HEIGHT: number = 56;

  build() {
    Row() {
      Column()
        .width(3)
        .height('100%')
        .backgroundColor(this.courseColorCss());
      Column() {
        Text(this.blockName())
          .fontSize(this.nameFontSize())
          .fontWeight(FontWeight.Bold)
          .fontColor(this.fgColor())
          .lineHeight(11)
          .maxLines(this.nameMaxLines())
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        if (this.showLocation() || this.showTeacher()) {
          Column().layoutWeight(1);
        }
        if (this.showLocation()) {
          Text(this.blockLocation())
            .fontSize(8)
            .fontColor(this.fgColorFaded())
            .lineHeight(9)
            .maxLines(this.locationMaxLines())
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
        }
        if (this.showTeacher()) {
          Text(this.placed.item.entry.course.teacher)
            .fontSize(8)
            .fontColor(this.fgColorFaded())
            .lineHeight(9)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: this.showLocation() ? 1 : 0 });
        }
      }
      .layoutWeight(1)
      .height('100%')
      .padding({ top: 4, right: 3, bottom: 4, left: this.isConflict() ? 2 : 4 })
      .alignItems(HorizontalAlign.Start);
    }
    .width(`${this.blockWidth()}%`)
    .height(this.blockHeight())
    .position({ x: `${this.blockLeft()}%`, y: this.blockTop() })
    .borderRadius(8)
    .border({ width: 0.5, color: this.courseBorderColor() })
    .backgroundColor(this.bgColor())
    .onClick(() => this.onCourseTap(this.placed.item.entry));
  }

  private blockName(): string {
    return this.placed.item.entry.course.name;
  }

  private blockLocation(): string {
    return formatCourseLocation(this.placed.item.slot.location);
  }

  private blockTop(): number {
    return (this.placed.item.slot.startSection - 1) * this.SECTION_HEIGHT + 2;
  }

  private blockHeight(): number {
    return (this.placed.item.slot.endSection - this.placed.item.slot.startSection + 1) * this.SECTION_HEIGHT - 4;
  }

  private blockWidth(): number {
    return 100 / this.placed.laneCount - 0.4;
  }

  private blockLeft(): number {
    return this.placed.lane * (100 / this.placed.laneCount) + 0.2;
  }

  private courseColorCss(): string {
    const c = this.placed.item.entry.course.color;
    const r = (c >>> 16) & 0xff;
    const g = (c >>> 8) & 0xff;
    const b = c & 0xff;
    return `rgb(${r},${g},${b})`;
  }

  private courseBorderColor(): string {
    const c = this.placed.item.entry.course.color;
    const r = (c >>> 16) & 0xff;
    const g = (c >>> 8) & 0xff;
    const b = c & 0xff;
    return `rgba(${r},${g},${b},${this.effectiveDark ? '0.72' : '0.30'})`;
  }

  private bgColor(): string {
    const c = this.placed.item.entry.course.color;
    const r = (c >>> 16) & 0xff;
    const g = (c >>> 8) & 0xff;
    const b = c & 0xff;
    return this.effectiveDark ? `rgba(${r},${g},${b},0.30)` : `rgba(${r},${g},${b},0.16)`;
  }

  private fgColor(): string {
    const c = this.placed.item.entry.course.color;
    if (this.effectiveDark) {
      const r = Math.round(((c >>> 16) & 0xff) + (255 - ((c >>> 16) & 0xff)) * 0.42);
      const g = Math.round(((c >>> 8) & 0xff) + (255 - ((c >>> 8) & 0xff)) * 0.42);
      const b = Math.round((c & 0xff) + (255 - (c & 0xff)) * 0.42);
      return `rgb(${r},${g},${b})`;
    }
    const r = Math.round(((c >>> 16) & 0xff) * 0.70);
    const g = Math.round(((c >>> 8) & 0xff) * 0.70);
    const b = Math.round((c & 0xff) * 0.70);
    return `rgb(${r},${g},${b})`;
  }

  private fgColorFaded(): string {
    const c = this.placed.item.entry.course.color;
    if (this.effectiveDark) {
      const r = Math.round(((c >>> 16) & 0xff) + (255 - ((c >>> 16) & 0xff)) * 0.24);
      const g = Math.round(((c >>> 8) & 0xff) + (255 - ((c >>> 8) & 0xff)) * 0.24);
      const b = Math.round((c & 0xff) + (255 - (c & 0xff)) * 0.24);
      return `rgb(${r},${g},${b})`;
    }
    const r = Math.round(((c >>> 16) & 0xff) * 0.50);
    const g = Math.round(((c >>> 8) & 0xff) * 0.50);
    const b = Math.round((c & 0xff) * 0.50);
    return `rgb(${r},${g},${b})`;
  }

  private nameFontSize(): number {
    return this.isConflict() ? 9.5 : 10;
  }

  private nameMaxLines(): number {
    if (this.isConflict() || this.sectionSpan() === 1) return 2;
    if (this.sectionSpan() === 2) return 3;
    return 4;
  }

  private showLocation(): boolean {
    return !this.isConflict() && this.blockLocation().length > 0;
  }

  private showTeacher(): boolean {
    if (this.isConflict() || this.placed.item.entry.course.teacher.length === 0) return false;
    return this.sectionSpan() > 1 || this.blockLocation().length === 0;
  }

  private locationMaxLines(): number {
    return this.sectionSpan() === 1 ? 1 : 2;
  }

  private sectionSpan(): number {
    return this.placed.item.slot.endSection - this.placed.item.slot.startSection + 1;
  }

  private isConflict(): boolean {
    return this.placed.laneCount > 1;
  }
}
