/**
 * 一周课程卡片(2x4)。对应 Android 版「一周课程」小部件。
 * 数据键:weekLabel/weekJson(7 个数字)/weekTotal
 */
let weekCardStorage = new LocalStorage();

@Entry(weekCardStorage)
@Component
struct WeekCard {
  @LocalStorageProp('weekLabel') weekLabel: string = '';
  @LocalStorageProp('weekJson') weekJson: string = '[]';
  @LocalStorageProp('weekTotal') weekTotal: number = 0;
  @State counts: number[] = [0, 0, 0, 0, 0, 0, 0];
  @State todayIdx: number = 0;

  aboutToAppear(): void {
    try {
      const list = JSON.parse(this.weekJson) as number[];
      if (list.length === 7) {
        this.counts = list;
      }
    } catch (e) {
    }
    const d = new Date().getUTCDay();
    this.todayIdx = d === 0 ? 6 : d - 1;
  }

  build() {
    Column() {
      // 头部
      Row() {
        Text(this.weekLabel)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.widget_text_primary'))
          .maxLines(1)
          .layoutWeight(1);
        Text(`本周 ${this.weekTotal} 节`)
          .fontSize(10)
          .fontColor('#158A63');
      }
      .width('100%');

      // 7 天列
      Row({ space: 6 }) {
        this.dayCol('一', this.counts[0], 0);
        this.dayCol('二', this.counts[1], 1);
        this.dayCol('三', this.counts[2], 2);
        this.dayCol('四', this.counts[3], 3);
        this.dayCol('五', this.counts[4], 4);
        this.dayCol('六', this.counts[5], 5);
        this.dayCol('日', this.counts[6], 6);
      }
      .layoutWeight(1)
      .width('100%')
      .margin({ top: 10 });
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
  dayCol(label: string, count: number, idx: number) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(10)
        .fontColor(idx === this.todayIdx ? Color.White : $r('app.color.widget_text_muted'))
        .width(18)
        .height(18)
        .textAlign(TextAlign.Center)
        .borderRadius(9)
        .backgroundColor(idx === this.todayIdx ? '#158A63' : Color.Transparent);
      Column() {
        Text(`${count}`)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(count > 0 ? $r('app.color.widget_text_primary') : $r('app.color.widget_text_faint'));
        Text('节')
          .fontSize(7)
          .fontColor($r('app.color.widget_text_faint'))
          .margin({ top: 1 });
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .borderRadius(8)
      .backgroundColor(count > 0 ? $r('app.color.widget_surface') : Color.Transparent);
    }
    .layoutWeight(1)
    .height('100%');
  }
}
