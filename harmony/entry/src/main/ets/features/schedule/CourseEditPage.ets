/**
 * 课程编辑页：新增 / 编辑课程（同课程多时间段、单双周/自定义周次）。
 * 移植自 Flutter 版 features/schedule/presentation/course_edit_page.dart。
 */
import { CourseEntry, Semester, SlotDraft } from './ScheduleTypes';
import { ScheduleRepository } from './ScheduleRepository';
import { SECTION_COUNT } from '../../constants/SectionTimes';
import { MACARON, argbToCss, textOn } from '../../constants/CourseColors';
import { parseCustomWeeks } from '../../utils/WeekCalculator';
import { AppTheme } from '../../common/AppTheme';

/** 时间段表单状态 */
interface SlotForm {
  dayOfWeek: number;
  startSection: number;
  endSection: number;
  weeksType: number;
  customWeeks: string;
  location: string;
}

const WEEKDAY_LABELS: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
const WEEKS_TYPE_LABELS: string[] = ['每周', '单周', '双周', '自定义'];

@Component
export struct CourseEditPage {
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  /** 编辑已有课程时传入(含 semesterId) */
  @Prop existing: CourseEntry | null = null;
  @Prop semesterId: number = 0;
  onSaved: () => void = () => {
  };
  onCancel: () => void = () => {
  };

  @State name: string = '';
  @State teacher: string = '';
  @State note: string = '';
  @State color: number = -1; // -1 = 自动分配
  @State slots: SlotForm[] = [];
  @State saving: boolean = false;

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private inputColor(): string { return this.effectiveDark ? '#272B2F' : '#F9F9F9'; }
  private controlColor(): string { return this.effectiveDark ? '#292D31' : '#F0F0F0'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private secondaryText(): string { return this.effectiveDark ? '#B8BDC2' : '#666666'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private disabledText(): string { return this.effectiveDark ? '#656C73' : '#CCCCCC'; }

  aboutToAppear(): void {
    const existing = this.existing;
    if (existing !== null) {
      this.name = existing.course.name;
      this.teacher = existing.course.teacher;
      this.note = existing.course.note;
      this.color = existing.course.color;
      this.slots = existing.slots.map((s) => {
        const weeks = this.weeksFromSlot(s.customWeeksJson);
        return {
          dayOfWeek: s.dayOfWeek,
          startSection: s.startSection,
          endSection: s.endSection,
          weeksType: s.weeksType,
          customWeeks: weeks,
          location: s.location
        } as SlotForm;
      });
    } else {
      this.slots = [this.newSlot()];
      this.color = -1;
    }
  }

  private newSlot(): SlotForm {
    return { dayOfWeek: 1, startSection: 1, endSection: 2, weeksType: 0, customWeeks: '', location: '' } as SlotForm;
  }

  private weeksFromSlot(json: string): string {
    try {
      const parsed = JSON.parse(json) as number[];
      if (Array.isArray(parsed)) {
        return parsed.join(',');
      }
      return '';
    } catch (e) {
      return '';
    }
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Text('取消')
          .fontSize(15)
          .fontColor(this.secondaryText())
          .onClick(() => this.onCancel());
        Blank()
        Text(this.existing === null ? '添加课程' : '编辑课程')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText());
        Blank()
        Text('保存')
          .fontSize(15)
          .fontColor(this.saving ? this.disabledText() : '#087B58')
          .onClick(() => {
            if (!this.saving) this.save();
          });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 });

      List({ space: 0 }) {
        // 课程名称
        ListItem() {
          Column() {
            Text('课程名称')
              .fontSize(13)
              .fontColor(this.mutedText())
              .alignSelf(ItemAlign.Start);
            TextInput({ text: this.name, placeholder: '如：大学物理Ⅳ' })
              .height(44)
              .fontSize(15)
              .fontColor(this.primaryText())
              .placeholderColor(this.mutedText())
              .backgroundColor(this.inputColor())
              .onChange((v: string) => { this.name = v; });
          }
          .padding({ top: 12, bottom: 12 })
          .alignItems(HorizontalAlign.Start);
        }

        // 教师
        ListItem() {
          Column() {
            Text('教师（选填）')
              .fontSize(13)
              .fontColor(this.mutedText())
              .alignSelf(ItemAlign.Start);
            TextInput({ text: this.teacher, placeholder: '选填' })
              .height(44)
              .fontSize(15)
              .fontColor(this.primaryText())
              .placeholderColor(this.mutedText())
              .backgroundColor(this.inputColor())
              .onChange((v: string) => { this.teacher = v; });
          }
          .padding({ top: 12, bottom: 12 })
          .alignItems(HorizontalAlign.Start);
        }

        // 颜色选择
        ListItem() {
          Column() {
            Text('课程颜色')
              .fontSize(13)
              .fontColor(this.mutedText())
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 8 });
            Row() {
              ForEach(MACARON, (c: number, idx: number) => {
                Column() {
                  Text(this.color === c ? '✓' : '')
                    .fontSize(12)
                    .fontColor(argbToCss(textOn(c)));
                }
                .width(32)
                .height(32)
                .borderRadius(16)
                .backgroundColor(argbToCss(c))
                .justifyContent(FlexAlign.Center)
                .margin({ right: 8, bottom: 8 })
                .border({
                  width: this.color === c ? 2 : 0,
                  color: this.color === c ? '#087B58' : Color.Transparent
                })
                .onClick(() => { this.color = c; });
              }, (c: number, idx: number) => `col-${idx}`);
            }
            .width('100%');
          }
          .padding({ top: 12, bottom: 12 })
          .alignItems(HorizontalAlign.Start);
        }

        // 上课时间段
        ForEach(this.slots, (slot: SlotForm, index: number) => {
          ListItem() {
            this.SlotCardBuilder(slot, index);
          };
        }, (slot: SlotForm, index: number) => `slot-${index}`);

        // 加一段按钮
        ListItem() {
          Text('+ 加一段')
            .fontSize(15)
            .fontColor('#087B58')
            .padding({ top: 12, bottom: 12 })
            .onClick(() => {
              this.slots.push(this.newSlot());
            });
        }

        // 备注
        ListItem() {
          Column() {
            Text('备注（选填）')
              .fontSize(13)
              .fontColor(this.mutedText())
              .alignSelf(ItemAlign.Start);
            TextInput({ text: this.note, placeholder: '选填' })
              .height(44)
              .fontSize(15)
              .fontColor(this.primaryText())
              .placeholderColor(this.mutedText())
              .backgroundColor(this.inputColor())
              .onChange((v: string) => { this.note = v; });
          }
          .padding({ top: 12, bottom: 12 })
          .alignItems(HorizontalAlign.Start);
        }
      }
      .layoutWeight(1);
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor());
  }

  @Builder
  SlotCardBuilder(slot: SlotForm, index: number) {
    Column() {
      // 星期 + 开始节 + 结束节
      Row() {
        Text(WEEKDAY_LABELS[slot.dayOfWeek - 1])
          .fontSize(14)
          .fontColor(this.primaryText())
          .layoutWeight(1)
          .height(40)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.controlColor())
          .borderRadius(8)
          .onClick(() => {
            slot.dayOfWeek = slot.dayOfWeek % 7 + 1;
          });
        Text(`${slot.startSection}`)
          .fontSize(14)
          .fontColor(this.primaryText())
          .layoutWeight(1)
          .height(40)
          .margin({ left: 8 })
          .textAlign(TextAlign.Center)
          .backgroundColor(this.controlColor())
          .borderRadius(8)
          .onClick(() => {
            slot.startSection = slot.startSection >= SECTION_COUNT ? 1 : slot.startSection + 1;
          });
        Text('至')
          .fontSize(13)
          .fontColor(this.mutedText())
          .margin({ left: 8 });
        Text(`${slot.endSection}`)
          .fontSize(14)
          .fontColor(this.primaryText())
          .layoutWeight(1)
          .height(40)
          .margin({ left: 8 })
          .textAlign(TextAlign.Center)
          .backgroundColor(this.controlColor())
          .borderRadius(8)
          .onClick(() => {
            slot.endSection = slot.endSection >= SECTION_COUNT ? 1 : slot.endSection + 1;
          });
        if (this.slots.length > 1) {
          Text('✕')
            .fontSize(16)
            .fontColor('#CC0000')
            .margin({ left: 8 })
            .onClick(() => {
              this.slots.splice(index, 1);
            });
        }
      }
      .width('100%')
      .margin({ top: 8 });

      // 周次类型
      Row() {
        ForEach([0, 1, 2, 3], (wt: number) => {
          Text(WEEKS_TYPE_LABELS[wt])
            .fontSize(12)
            .fontColor(slot.weeksType === wt ? Color.White : this.secondaryText())
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(slot.weeksType === wt ? '#087B58' : this.controlColor())
            .borderRadius(14)
            .margin({ right: 8 })
            .onClick(() => { slot.weeksType = wt; });
        }, (wt: number) => `wt-${wt}`);
      }
      .width('100%')
      .margin({ top: 8 });

      // 自定义周次 或 教室
      if (slot.weeksType === 3) {
        TextInput({ text: slot.customWeeks, placeholder: '自定义周次，如 1,3,5-8' })
          .height(40)
          .fontSize(14)
          .fontColor(this.primaryText())
          .placeholderColor(this.mutedText())
          .backgroundColor(this.inputColor())
          .borderRadius(8)
          .margin({ top: 8 })
          .onChange((v: string) => { slot.customWeeks = v; });
        TextInput({ text: slot.location, placeholder: '教室（选填）' })
          .height(40)
          .fontSize(14)
          .fontColor(this.primaryText())
          .placeholderColor(this.mutedText())
          .backgroundColor(this.inputColor())
          .borderRadius(8)
          .margin({ top: 8 })
          .onChange((v: string) => { slot.location = v; });
      } else {
        TextInput({ text: slot.location, placeholder: '教室（选填）' })
          .height(40)
          .fontSize(14)
          .fontColor(this.primaryText())
          .placeholderColor(this.mutedText())
          .backgroundColor(this.inputColor())
          .borderRadius(8)
          .margin({ top: 8 })
          .onChange((v: string) => { slot.location = v; });
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
    .alignItems(HorizontalAlign.Start);
  }

  // ---------- 保存 ----------
  private async save(): Promise<void> {
    if (this.name.trim().length === 0) {
      this.toast('请输入课程名称');
      return;
    }
    if (this.slots.length === 0) {
      this.toast('至少需要一个上课时间段');
      return;
    }
    for (const slot of this.slots) {
      if (slot.startSection > slot.endSection) {
        this.toast('存在开始节次大于结束节次的时间段');
        return;
      }
      if (slot.weeksType === 3 && parseCustomWeeks(slot.customWeeks).length === 0) {
        this.toast('自定义周次不能为空，如 1,3,5-8');
        return;
      }
    }
    this.saving = true;
    try {
      const drafts: SlotDraft[] = this.slots.map((s) => {
        return {
          dayOfWeek: s.dayOfWeek,
          startSection: s.startSection,
          endSection: s.endSection,
          weeksType: s.weeksType,
          customWeeks: parseCustomWeeks(s.customWeeks),
          location: s.location.trim()
        } as SlotDraft;
      });
      const existing = this.existing;
      if (existing === null) {
        await ScheduleRepository.createCourse(
          this.semesterId, this.name.trim(), this.teacher.trim(), this.color, this.note.trim(), drafts
        );
      } else {
        await ScheduleRepository.updateCourse(
          existing.course.id, this.name.trim(), this.teacher.trim(), this.color, this.note.trim(), drafts
        );
      }
      this.onSaved();
    } catch (e) {
      this.saving = false;
      this.toast('保存失败，请稍后重试');
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });
  }
}
