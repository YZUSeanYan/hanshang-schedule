/**
 * 日视图：按时间轴展示某一天的课程列表。
 * 移植自 Flutter 版 features/schedule/presentation/day_view.dart。
 * UI 精确还原 Android 版(左侧全高色条+时间列+竖分割线+课程信息)。
 */
import { CourseEntry, Semester } from './ScheduleTypes';
import { startOf, endOf } from '../../constants/SectionTimes';
import { argbToCss } from '../../constants/CourseColors';
import { weekNumberOf, occursInWeek } from '../../utils/WeekCalculator';
import { formatCourseLocation } from '../../utils/LocationFormatter';
import { jsonToWeeksList, SchedRow } from '../../model/SyncCodecs';
import { AppTheme } from '../../common/AppTheme';

/** 时间段简化视图 */
interface SchedSlot {
  uuid: string;
  dayOfWeek: number;
  startSection: number;
  endSection: number;
  weeksType: number;
  customWeeksJson: string;
  location: string;
}

@Component
export struct DayView {
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @Prop semester: Semester = { id: 0, uuid: '', name: '', startDateMs: 0, totalWeeks: 20, isCurrent: false, updatedAtMs: 0 };
  @Prop date: number = 0; // UTC ms
  @Prop entries: CourseEntry[] = [];
  onCourseTap: (entry: CourseEntry) => void = () => {
  };

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }

  private get weekday(): number {
    const d = new Date(this.date).getUTCDay();
    return d === 0 ? 7 : d;
  }

  private get week(): number {
    return weekNumberOf(this.semester.startDateMs, this.date);
  }

  private todayCourses(): CourseEntry[] {
    if (this.week < 1 || this.week > this.semester.totalWeeks) return [];
    const result: CourseEntry[] = [];
    for (const entry of this.entries) {
      for (const slot of entry.slots) {
        if (slot.dayOfWeek !== this.weekday) continue;
        const weeks = jsonToWeeksList(slot.customWeeksJson);
        if (occursInWeek(slot.weeksType, weeks, this.week)) {
          result.push(entry);
          break;
        }
      }
    }
    return result;
  }

  build() {
    Column() {
      if (this.week < 1) {
        this.EmptyBuilder('还没开学');
      } else if (this.week > this.semester.totalWeeks) {
        this.EmptyBuilder('学期已结束');
      } else if (this.todayCourses().length === 0) {
        this.EmptyBuilder('今天没课');
      } else {
        List({ space: 12 }) {
          ForEach(this.todayCourses(), (entry: CourseEntry) => {
            ListItem() {
              CourseCard({ entry: entry, weekday: this.weekday, week: this.week, onCourseTap: this.onCourseTap });
            };
          }, (entry: CourseEntry) => `daycard-${entry.course.uuid}`);
        }
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 12, bottom: 24 });
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor());
  }

  @Builder
  EmptyBuilder(text: string) {
    Column() {
      Text('☕')
        .fontSize(56);
      Text(text)
        .fontSize(17)
        .fontColor(this.mutedText())
        .margin({ top: 12 });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }
}

/** 课程卡片 - 精确还原 Android 样式 */
@Component
struct CourseCard {
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @Prop entry: CourseEntry = { course: { id: 0, uuid: '', semesterId: 0, name: '', teacher: '', color: 0, note: '', updatedAtMs: 0 }, slots: [] };
  @Prop weekday: number = 1;
  @Prop week: number = 1;
  onCourseTap: (entry: CourseEntry) => void = () => {
  };

  private surfaceColor(): string { return this.effectiveDark ? '#1C1F22' : '#FFFFFF'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#333333'; }
  private secondaryText(): string { return this.effectiveDark ? '#B8BDC2' : '#666666'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private dividerColor(): string { return this.effectiveDark ? '#34383D' : '#E0E0E0'; }

  private findSlot(): SchedSlot | null {
    for (const slot of this.entry.slots) {
      if (slot.dayOfWeek === this.weekday) {
        const weeks = jsonToWeeksList(slot.customWeeksJson);
        if (occursInWeek(slot.weeksType, weeks, this.week)) {
          return slot;
        }
      }
    }
    return null;
  }

  private startTime(): string {
    const slot = this.findSlot();
    return slot !== null ? startOf(slot.startSection) : '';
  }

  private endTime(): string {
    const slot = this.findSlot();
    return slot !== null ? endOf(slot.endSection) : '';
  }

  private sectionText(): string {
    const slot = this.findSlot();
    return slot !== null ? `第${slot.startSection}-${slot.endSection}节` : '';
  }

  private locationText(): string {
    const slot = this.findSlot();
    return slot !== null ? formatCourseLocation(slot.location) : '';
  }

  private colorCss(): string {
    return argbToCss(this.entry.course.color);
  }

  private subtitle(): string {
    const parts: string[] = [];
    parts.push(this.sectionText());
    if (this.locationText().length > 0) parts.push(this.locationText());
    if (this.entry.course.teacher.length > 0) parts.push(this.entry.course.teacher);
    return parts.join(' · ');
  }

  build() {
    Row() {
      // 左侧全高色条
      Column()
        .width(4)
        .height('100%')
        .backgroundColor(this.colorCss());
      // 时间列
      Column() {
        Text(this.startTime())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryText());
        Text(this.endTime())
          .fontSize(12)
          .fontColor(this.mutedText());
      }
      .padding({ left: 12, right: 12, top: 16, bottom: 16 })
      .alignItems(HorizontalAlign.Start);
      // 竖分割线
      Divider().vertical(true).height('100%').width(1).color(this.dividerColor());
      // 课程信息
      Column() {
        Text(this.entry.course.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryText())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        if (this.subtitle().length > 0) {
          Text(this.subtitle())
            .fontSize(12)
            .fontColor(this.secondaryText())
            .margin({ top: 4 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
        }
      }
      .layoutWeight(1)
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .height(80)
    .backgroundColor(this.surfaceColor())
    .borderRadius(12)
    .shadow({ radius: 2, color: this.effectiveDark ? '#40000000' : '#11000000', offsetY: 1 })
    .onClick(() => this.onCourseTap(this.entry));
  }
}
