/**
 * 近日课程卡片(2x4)。对应 Android 版「近日课程」小部件。
 * 数据键:upcomingJson(CardDay[],今天起 3 天)
 */
let upcomingCardStorage = new LocalStorage();

@Entry(upcomingCardStorage)
@Component
struct UpcomingCard {
  @LocalStorageProp('upcomingJson') upcomingJson: string = '[]';
  @State days: UpcomingDayItem[] = [];

  aboutToAppear(): void {
    try {
      this.days = JSON.parse(this.upcomingJson) as UpcomingDayItem[];
    } catch (e) {
      this.days = [];
    }
  }

  build() {
    Column() {
      Row() {
        Text('近日课程')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.widget_text_primary'));
        Blank();
        Text('今明后 3 天')
          .fontSize(9)
          .fontColor($r('app.color.widget_text_faint'));
      }
      .width('100%')
      .margin({ bottom: 6 });

      Row({ space: 8 }) {
        this.dayCol(this.days.length > 0 ? this.days[0] : null);
        this.dayCol(this.days.length > 1 ? this.days[1] : null);
        this.dayCol(this.days.length > 2 ? this.days[2] : null);
      }
      .layoutWeight(1)
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor($r('app.color.widget_background'))
    .onClick(() => {
      postCardAction(this, { 'action': 'router', 'abilityName': 'EntryAbility', 'params': {} });
    });
  }

  @Builder
  dayCol(day: UpcomingDayItem | null) {
    Column() {
      Text(day === null ? '' : `${day.dateLabel} ${day.weekdayLabel}`)
        .fontSize(9)
        .fontColor(day !== null && day.isToday ? '#158A63' : $r('app.color.widget_text_muted'))
        .fontWeight(day !== null && day.isToday ? FontWeight.Bold : FontWeight.Normal)
        .maxLines(1);

      Column({ space: 4 }) {
        if (day === null || day.courses.length === 0) {
          Text('无课')
            .fontSize(9)
            .fontColor($r('app.color.widget_text_faint'));
        } else {
          if (day.courses.length > 0) {
            this.courseRow(day.courses[0]);
          }
          if (day.courses.length > 1) {
            this.courseRow(day.courses[1]);
          }
          if (day.courses.length > 2) {
            this.courseRow(day.courses[2]);
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: 4 })
      .padding({ left: 6, right: 6, top: 4, bottom: 4 })
      .borderRadius(8)
      .backgroundColor($r('app.color.widget_surface'));
    }
    .layoutWeight(1)
    .height('100%');
  }

  @Builder
  courseRow(course: UpcomingCourseItem) {
    Column() {
      Text(course.name)
        .fontSize(9)
        .fontColor($r('app.color.widget_text_primary'))
        .maxLines(1);
      Text(course.time)
        .fontSize(7.5)
        .fontColor($r('app.color.widget_text_muted'))
        .maxLines(1);
    }
    .width('100%')
    .padding({ left: 3 })
    .borderRadius(4)
    .border({ width: { left: 2 }, color: course.colorHex });
  }
}

interface UpcomingCourseItem {
  name: string;
  time: string;
  location: string;
  colorHex: string;
}

interface UpcomingDayItem {
  dateLabel: string;
  weekdayLabel: string;
  isToday: boolean;
  courses: UpcomingCourseItem[];
}
