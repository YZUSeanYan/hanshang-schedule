/**
 * 下一节课卡片(2x2)。对应 Android 版「下一节课」小部件。
 * 数据键:dateLabel/nextJson(CardCourse)/nextIsTomorrow
 */
let nextCardStorage = new LocalStorage();

@Entry(nextCardStorage)
@Component
struct NextClassCard {
  @LocalStorageProp('dateLabel') dateLabel: string = '';
  @LocalStorageProp('nextJson') nextJson: string = '';
  @LocalStorageProp('nextIsTomorrow') nextIsTomorrow: number = 0;
  @State course: NextCardItem = { name: '', time: '', location: '', colorHex: '#C8E6A0' };
  @State has: boolean = false;

  aboutToAppear(): void {
    if (this.nextJson.length > 2) {
      try {
        this.course = JSON.parse(this.nextJson) as NextCardItem;
        this.has = true;
      } catch (e) {
        this.has = false;
      }
    }
  }

  build() {
    Column() {
      Row() {
        Text(this.nextIsTomorrow === 1 ? '明天第一节课' : '下一节课')
          .fontSize(11)
          .fontColor($r('app.color.widget_text_muted'));
        Blank();
        Text(this.dateLabel)
          .fontSize(9)
          .fontColor($r('app.color.widget_text_faint'))
          .maxLines(1);
      }
      .width('100%');

      if (this.has) {
        Column() {
          Column() {
            Text('✓')
              .fontSize(13)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Bold);
          }
          .width(28)
          .height(28)
          .borderRadius(14)
          .backgroundColor(this.course.colorHex)
          .justifyContent(FlexAlign.Center)
          .margin({ bottom: 8 });
          Text(this.course.name)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.widget_text_primary'))
            .maxLines(2)
            .textAlign(TextAlign.Center);
          Text(this.course.time)
            .fontSize(12)
            .fontColor('#158A63')
            .margin({ top: 4 });
          if (this.course.location.length > 0) {
            Text(this.course.location)
              .fontSize(10)
              .fontColor($r('app.color.widget_text_muted'))
              .maxLines(1)
              .margin({ top: 2 });
          }
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center);
      } else {
        Column() {
          Text('🎉').fontSize(22).margin({ bottom: 4 });
          Text('近两天没有课程了')
            .fontSize(12)
            .fontColor($r('app.color.widget_text_faint'));
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center);
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor($r('app.color.widget_background'))
    .onClick(() => {
      postCardAction(this, { 'action': 'router', 'abilityName': 'EntryAbility', 'params': {} });
    });
  }
}

interface NextCardItem {
  name: string;
  time: string;
  location: string;
  colorHex: string;
}
