/**
 * 今日课程卡片(2x2)。对应 Android 版「今日课程」小部件。
 * 数据键:dateLabel/weekLabel/todayJson(CardCourse[])
 */
let todayCardStorage = new LocalStorage();

@Entry(todayCardStorage)
@Component
struct TodayCard {
  @LocalStorageProp('dateLabel') dateLabel: string = '';
  @LocalStorageProp('weekLabel') weekLabel: string = '';
  @LocalStorageProp('todayJson') todayJson: string = '[]';
  @State course0: TodayCardItem = { name: '', time: '', location: '', colorHex: '#C8E6A0' };
  @State course1: TodayCardItem = { name: '', time: '', location: '', colorHex: '#C8E6A0' };
  @State course2: TodayCardItem = { name: '', time: '', location: '', colorHex: '#C8E6A0' };
  @State count: number = 0;

  aboutToAppear(): void {
    this.parse();
  }

  private parse(): void {
    try {
      const list = JSON.parse(this.todayJson) as TodayCardItem[];
      this.count = list.length;
      if (list.length > 0) {
        this.course0 = list[0];
      }
      if (list.length > 1) {
        this.course1 = list[1];
      }
      if (list.length > 2) {
        this.course2 = list[2];
      }
    } catch (e) {
      this.count = 0;
    }
  }

  build() {
    Column() {
      // 头部
      Row() {
        Column() {
          Text(this.dateLabel)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.widget_text_primary'))
            .maxLines(1);
          Text(this.weekLabel)
            .fontSize(9)
            .fontColor($r('app.color.widget_text_muted'))
            .maxLines(1)
            .margin({ top: 1 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Text(`${this.count}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#158A63')
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(9)
          .backgroundColor('#158A631F');
      }
      .width('100%');

      // 课程列表(最多 3 条)
      Column({ space: 6 }) {
        if (this.count === 0) {
          Column() {
            Text('今天没有课程').fontSize(13).fontColor($r('app.color.widget_text_faint'));
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center);
        } else {
          this.rowOf(this.course0, this.count > 3);
          if (this.count > 1) {
            this.rowOf(this.course1, false);
          }
          if (this.count > 2) {
            this.rowOf(this.course2, false);
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center);
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
  rowOf(course: TodayCardItem, more: boolean) {
    Row({ space: 6 }) {
      Column()
        .width(3)
        .height(26)
        .borderRadius(1.5)
        .backgroundColor(course.colorHex);
      Column() {
        Text(course.name)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.widget_text_primary'))
          .maxLines(1);
        Text(`${course.time}${course.location.length > 0 ? ' · ' + course.location : ''}`)
          .fontSize(8.5)
          .fontColor($r('app.color.widget_text_muted'))
          .maxLines(1)
          .margin({ top: 1 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
      if (more) {
        Text('…').fontSize(11).fontColor($r('app.color.widget_text_faint'));
      }
    }
    .width('100%');
  }
}

interface TodayCardItem {
  name: string;
  time: string;
  location: string;
  colorHex: string;
}
