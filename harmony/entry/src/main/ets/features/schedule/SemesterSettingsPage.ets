/**
 * 学期设置页：开学第一周的周一 + 总周数，自动计算"今天是第几周"。
 * 移植自 Flutter 版 features/schedule/presentation/semester_settings_page.dart。
 */
import { Semester } from './ScheduleTypes';
import { ScheduleRepository } from './ScheduleRepository';
import { ScheduleDao } from '../../data/ScheduleDao';
import { weekNumberOf, clampWeek, mondayOfMs } from '../../utils/WeekCalculator';
import { AppTheme } from '../../common/AppTheme';

@Component
export struct SemesterSettingsPage {
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  onSaved: () => void = () => {
  };
  onCancel: () => void = () => {
  };

  @State name: string = '';
  @State startMs: number = 0;
  @State totalWeeks: number = 20;
  @State editingUuid: string = ''; // 空=新建
  @State allSemesters: Semester[] = [];
  @State currentWeek: number = 0;
  @State switchingSemesterId: number = 0;

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private surfaceColor(): string { return this.effectiveDark ? '#1C1F22' : '#FAFAFA'; }
  private inputColor(): string { return this.effectiveDark ? '#272B2F' : '#F9F9F9'; }
  private controlColor(): string { return this.effectiveDark ? '#292D31' : '#E0E0E0'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private secondaryText(): string { return this.effectiveDark ? '#B8BDC2' : '#666666'; }
  private mutedText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private disabledText(): string { return this.effectiveDark ? '#656C73' : '#CCCCCC'; }
  private accentSurface(): string { return this.effectiveDark ? '#18352C' : '#E8F5F0'; }

  aboutToAppear(): void {
    this.loadCurrentSemester();
    this.loadAllSemesters();
  }

  private async loadCurrentSemester(): Promise<void> {
    const sem = await ScheduleDao.findCurrentSemester();
    if (sem !== null) {
      this.editingUuid = sem.uuid;
      this.name = sem.name;
      this.startMs = sem.startDateMs;
      this.totalWeeks = sem.totalWeeks;
      const raw = weekNumberOf(sem.startDateMs, Date.now());
      const clamped = clampWeek(raw, sem.totalWeeks);
      this.currentWeek = clamped ?? 0;
    } else {
      this.name = this.suggestName();
      this.startMs = mondayOfMs(Date.now());
      this.totalWeeks = 20;
    }
  }

  private async loadAllSemesters(): Promise<void> {
    this.allSemesters = await ScheduleDao.listSemesters();
  }

  private suggestName(): string {
    const now = new Date();
    const term = (now.getMonth() + 1 >= 2 && now.getMonth() + 1 <= 7) ? '春' : '秋';
    return `${now.getFullYear()}${term}`;
  }

  private fmtDate(ms: number): string {
    const d = new Date(ms);
    const mm = d.getUTCMonth() + 1 < 10 ? `0${d.getUTCMonth() + 1}` : `${d.getUTCMonth() + 1}`;
    const dd = d.getUTCDate() < 10 ? `0${d.getUTCDate()}` : `${d.getUTCDate()}`;
    return `${d.getUTCFullYear()}-${mm}-${dd}`;
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
        Text('学期设置')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText());
        Blank()
        Text('保存')
          .fontSize(15)
          .fontColor('#087B58')
          .onClick(() => this.save());
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 });

      List({ space: 12 }) {
        // 当前周提示
        ListItem() {
          Column() {
            Text(this.currentWeek > 0 ? `今天是第 ${this.currentWeek} 周` : '当前不在学期内')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryText());
            Text(`开学周一：${this.fmtDate(this.startMs)}`)
              .fontSize(12)
              .fontColor(this.mutedText())
              .margin({ top: 4 });
          }
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .backgroundColor(this.accentSurface())
          .borderRadius(12);
        }

        // 学期名称
        ListItem() {
          Column() {
            Text('学期名称')
              .fontSize(13)
              .fontColor(this.mutedText())
              .alignSelf(ItemAlign.Start);
            TextInput({ text: this.name, placeholder: '如 2026秋' })
              .height(44)
              .fontSize(15)
              .fontColor(this.primaryText())
              .placeholderColor(this.mutedText())
              .backgroundColor(this.inputColor())
              .onChange((v: string) => { this.name = v; });
          }
          .alignItems(HorizontalAlign.Start);
        }

        // 开学日期
        ListItem() {
          Column() {
            Text('开学第一周周一')
              .fontSize(13)
              .fontColor(this.mutedText())
              .alignSelf(ItemAlign.Start);
            Text(this.fmtDate(this.startMs))
              .fontSize(15)
              .fontColor(this.primaryText())
              .height(44)
              .width('100%')
              .padding({ left: 12 })
              .backgroundColor(this.inputColor())
              .borderRadius(8)
              .alignSelf(ItemAlign.Start)
              .onClick(() => this.pickStartDate());
          }
          .alignItems(HorizontalAlign.Start);
        }

        // 总周数
        ListItem() {
          Column() {
            Text(`总周数：${this.totalWeeks} 周`)
              .fontSize(13)
              .fontColor(this.secondaryText())
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 8 });
            Slider({ value: this.totalWeeks, min: 16, max: 25, step: 1 })
              .width('100%')
              .trackColor(this.controlColor())
              .selectedColor('#087B58')
              .onChange((v: number) => { this.totalWeeks = Math.round(v); });
          }
          .alignItems(HorizontalAlign.Start);
        }

        // 创建/保存按钮
        ListItem() {
          Text(this.editingUuid.length === 0 ? '创建学期' : '保存修改')
            .fontSize(16)
            .fontColor(Color.White)
            .width('100%')
            .height(46)
            .textAlign(TextAlign.Center)
            .backgroundColor('#087B58')
            .borderRadius(23)
            .onClick(() => this.save());
        }
      }
      .layoutWeight(1);

      // 全部学期列表
      if (this.allSemesters.length > 0) {
        Column() {
          Text('全部学期')
            .fontSize(14)
            .fontColor(this.mutedText())
            .padding({ left: 16, top: 8, bottom: 8 });
          ForEach(this.allSemesters, (s: Semester) => {
            Row() {
              Text(s.isCurrent ? '◉' : '○')
                .fontSize(14)
                .fontColor(s.isCurrent ? '#087B58' : this.disabledText());
              Column() {
                Text(s.name)
                  .fontSize(15)
                  .fontColor(this.primaryText());
                Text(`${this.fmtDate(s.startDateMs)} 开学 · 共 ${s.totalWeeks} 周`)
                  .fontSize(11)
                  .fontColor(this.mutedText())
                  .margin({ top: 2 });
              }
              .layoutWeight(1)
              .height(44)
              .margin({ left: 12 })
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Start)
              .onClick(() => this.loadSemester(s));
              if (!s.isCurrent) {
                if (this.switchingSemesterId === s.id) {
                  Column() {
                    LoadingProgress()
                      .width(18)
                      .height(18)
                      .color('#087B58');
                  }
                  .width(76)
                  .height(40)
                  .justifyContent(FlexAlign.Center);
                } else {
                  Text('设为当前')
                    .fontSize(13)
                    .fontColor(this.switchingSemesterId === 0 ? '#087B58' : this.mutedText())
                    .width(76)
                    .height(40)
                    .textAlign(TextAlign.Center)
                    .stateStyles({ pressed: { .opacity(0.55) }, normal: { .opacity(1) } })
                    .onClick(() => this.setAsCurrent(s));
                }
              }
              Text('删除')
                .fontSize(13)
                .fontColor('#CC0000')
                .width(52)
                .height(40)
                .textAlign(TextAlign.Center)
                .stateStyles({ pressed: { .opacity(0.55) }, normal: { .opacity(1) } })
                .onClick(() => this.deleteSemester(s));
            }
            .width('100%')
            .padding({ left: 16, right: 8, top: 8, bottom: 8 });
          }, (s: Semester) => `sem-${s.id}`);
        }
        .width('100%')
        .backgroundColor(this.surfaceColor());
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor());
  }

  /** 打开系统日期选择器选择开学第一周的周一(自动校准到最近周一) */
  private pickStartDate(): void {
    const ctx = this.getUIContext();
    const initial = new Date(this.startMs);
    ctx.showDatePickerDialog({
      start: new Date('2024-01-01'),
      end: new Date('2028-12-31'),
      selected: initial,
      lunar: false,
      lunarSwitch: false,
      onDateAccept: (value: Date) => {
        // 校准到该周的周一(周日视为下一周周一)
        const day = value.getDay();
        const diff = day === 0 ? 1 : 1 - day;
        const monday = new Date(value.getFullYear(), value.getMonth(), value.getDate() + diff);
        this.startMs = monday.getTime();
      }
    });
  }

  private loadSemester(s: Semester): void {
    this.editingUuid = s.uuid;
    this.name = s.name;
    this.startMs = s.startDateMs;
    this.totalWeeks = s.totalWeeks;
    const raw = weekNumberOf(s.startDateMs, Date.now());
    const clamped = clampWeek(raw, s.totalWeeks);
    this.currentWeek = clamped ?? 0;
  }

  private async setAsCurrent(s: Semester): Promise<void> {
    if (this.switchingSemesterId !== 0 || s.isCurrent) {
      return;
    }
    this.switchingSemesterId = s.id;
    try {
      await ScheduleRepository.setCurrentSemester(s.id);
      AppTheme.notifyScheduleChanged();
      await this.loadCurrentSemester();
      await this.loadAllSemesters();
    } catch (e) {
      this.toast('切换学期失败，请稍后重试');
    } finally {
      this.switchingSemesterId = 0;
    }
  }

  private async deleteSemester(s: Semester): Promise<void> {
    await ScheduleRepository.deleteSemester(s.uuid);
    if (this.editingUuid === s.uuid) {
      this.editingUuid = '';
      this.name = this.suggestName();
      this.startMs = mondayOfMs(Date.now());
      this.totalWeeks = 20;
    }
    await this.loadAllSemesters();
  }

  private async save(): Promise<void> {
    if (this.name.trim().length === 0) {
      this.toast('请输入学期名称');
      return;
    }
    try {
      if (this.editingUuid.length === 0) {
        await ScheduleRepository.createSemester(this.name.trim(), this.startMs, this.totalWeeks);
      } else {
        const s = this.allSemesters.find((x) => x.uuid === this.editingUuid);
        if (s !== undefined) {
          const updated: Semester = {
            id: s.id, uuid: s.uuid, name: this.name.trim(),
            startDateMs: this.startMs, totalWeeks: this.totalWeeks,
            isCurrent: s.isCurrent, updatedAtMs: Date.now()
          };
          await ScheduleRepository.updateSemester(updated);
        }
      }
      this.onSaved();
    } catch (e) {
      this.toast('保存失败，请稍后重试');
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });
  }
}
