/**
 * 登录 / 注册页（对应 Flutter 版 LoginPage）。
 * 未登录时启动分流到这里；登录/注册成功后进入主框架。
 * 含忘记密码两步流程（发验证码 → 凭码重置）。
 */
import { router } from '@kit.ArkUI';
import { AuthRepository } from '../repository/AuthRepository';
import { ApiError } from '../network/ApiClient';
import { AppTheme } from '../common/AppTheme';

@Entry
@Component
struct LoginPage {
  @StorageProp(AppTheme.KEY_BRAND) BRAND_GREEN: string = '#158A63';
  @StorageProp(AppTheme.KEY_EFFECTIVE_DARK) effectiveDark: boolean = false;
  @State isRegisterMode: boolean = false;
  @State submitting: boolean = false;
  @State account: string = '';
  @State username: string = '';
  @State email: string = '';
  @State password: string = '';
  @State showForgot: boolean = false;
  @State forgotCodeSent: boolean = false;
  @State forgotEmail: string = '';
  @State forgotCode: string = '';
  @State forgotNewPassword: string = '';
  @State forgotBusy: boolean = false;

  private pageColor(): string { return this.effectiveDark ? '#101214' : '#FFFFFF'; }
  private surfaceColor(): string { return this.effectiveDark ? '#1C1F22' : '#FFFFFF'; }
  private primaryText(): string { return this.effectiveDark ? '#F2F3F4' : '#1A1A1A'; }
  private subtleText(): string { return this.effectiveDark ? '#8F969D' : '#999999'; }
  private faintText(): string { return this.effectiveDark ? '#717880' : '#CCCCCC'; }
  private inputColor(): string { return this.effectiveDark ? '#272B2F' : '#F2F3F5'; }
  private controlColor(): string { return this.effectiveDark ? '#292D31' : '#EEEEEE'; }
  private dividerColor(): string { return this.effectiveDark ? '#34383D' : '#E5E7EA'; }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private async submit(): Promise<void> {
    // 表单校验（对应 Flutter Form validator）
    if (this.isRegisterMode) {
      if (this.username.trim().length < 2) {
        this.toast('用户名至少 2 个字符');
        return;
      }
      if (!this.email.includes('@')) {
        this.toast('请输入有效邮箱');
        return;
      }
      if (this.password.length < 8) {
        this.toast('密码至少 8 位');
        return;
      }
    } else {
      if (this.account.trim().length === 0) {
        this.toast('请输入用户名或邮箱');
        return;
      }
      if (this.password.length === 0) {
        this.toast('请输入密码');
        return;
      }
    }

    this.submitting = true;
    try {
      if (this.isRegisterMode) {
        await AuthRepository.register(this.username.trim(), this.email.trim(), this.password);
      } else {
        await AuthRepository.login(this.account.trim(), this.password);
      }
      router.replaceUrl({ url: 'pages/MainPage' });
    } catch (e) {
      if (e instanceof ApiError) {
        this.toast((e as ApiError).message);
      } else {
        this.toast('操作失败，请稍后重试');
      }
    } finally {
      this.submitting = false;
    }
  }

  private async forgotAction(): Promise<void> {
    if (this.forgotEmail.trim().length === 0 || !this.forgotEmail.includes('@')) {
      this.toast('请输入注册邮箱');
      return;
    }
    if (this.forgotCodeSent
      && (this.forgotCode.trim().length === 0 || this.forgotNewPassword.length < 8)) {
      this.toast('请填写 6 位验证码和至少 8 位新密码');
      return;
    }
    this.forgotBusy = true;
    try {
      if (!this.forgotCodeSent) {
        await AuthRepository.sendResetCode(this.forgotEmail.trim());
        this.forgotCodeSent = true;
        this.toast('验证码已发送，请查收邮箱（10 分钟内有效）');
      } else {
        await AuthRepository.resetPassword(this.forgotEmail.trim(),
          this.forgotCode.trim(), this.forgotNewPassword);
        this.showForgot = false;
        this.toast('密码已重置，请用新密码登录');
      }
    } catch (e) {
      if (e instanceof ApiError) {
        this.toast((e as ApiError).message);
      } else {
        this.toast('操作失败，请稍后重试');
      }
    } finally {
      this.forgotBusy = false;
    }
  }

  build() {
    Stack() {
      Column() {
        Scroll() {
          Column({ space: 16 }) {
            Image($r('app.media.app_icon'))
              .width(84)
              .height(84)
              .borderRadius(20)
              .margin({ top: 56 });
            Text('邗上课表')
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.BRAND_GREEN)
              .margin({ bottom: 4 })
            Text('扬州大学课程表 · 无广告')
              .fontSize(14)
              .fontColor(this.subtleText())
            Text('与扬州大学官方无隶属或授权关系')
              .fontSize(10)
              .fontColor(this.faintText())
              .margin({ top: 2 })

            if (this.isRegisterMode) {
              TextInput({ text: this.username, placeholder: '用户名' })
                .height(48).borderRadius(10).backgroundColor(this.inputColor())
                .fontColor(this.primaryText()).placeholderColor(this.subtleText())
                .onChange((v: string) => { this.username = v; })
              TextInput({ text: this.email, placeholder: '邮箱' })
                .height(48).borderRadius(10).backgroundColor(this.inputColor())
                .fontColor(this.primaryText()).placeholderColor(this.subtleText())
                .onChange((v: string) => { this.email = v; })
            } else {
              TextInput({ text: this.account, placeholder: '用户名或邮箱' })
                .height(48).borderRadius(10).backgroundColor(this.inputColor())
                .fontColor(this.primaryText()).placeholderColor(this.subtleText())
                .onChange((v: string) => { this.account = v; })
            }

            TextInput({ text: this.password, placeholder: this.isRegisterMode ? '密码（至少 8 位）' : '密码' })
              .type(InputType.Password)
              .showPasswordIcon(true)
              .height(48).borderRadius(10).backgroundColor(this.inputColor())
              .fontColor(this.primaryText()).placeholderColor(this.subtleText())
              .onChange((v: string) => { this.password = v; })

            Button() {
              Row({ space: 8 }) {
                if (this.submitting) {
                  LoadingProgress().width(20).height(20).color(Color.White)
                } else {
                  Text(this.isRegisterMode ? '注册并登录' : '登录')
                    .fontColor(Color.White).fontSize(16)
                }
              }
            }
            .width('100%')
            .height(46)
            .backgroundColor(this.BRAND_GREEN)
            .borderRadius(23)
            .enabled(!this.submitting)
            .margin({ top: 8 })
            .onClick(() => { this.submit(); })

            Row() {
              Text(this.isRegisterMode ? '已有账号？去登录' : '没有账号？去注册')
                .fontColor(this.BRAND_GREEN).fontSize(14)
                .onClick(() => {
                  this.isRegisterMode = !this.isRegisterMode;
                })
              Blank()
              if (!this.isRegisterMode) {
                Text('忘记密码')
                  .fontColor(this.subtleText()).fontSize(14)
                  .onClick(() => {
                    this.showForgot = true;
                    this.forgotCodeSent = false;
                    this.forgotCode = '';
                    this.forgotNewPassword = '';
                  })
              }
            }
            .width('100%')
            .margin({ top: 4, bottom: 32 })
          }
          .padding({ left: 32, right: 32 })
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .align(Alignment.Start)
        .width('100%')
        .height('100%')
      }

      if (this.showForgot) {
        this.forgotOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageColor())
  }

  @Builder
  forgotOverlay() {
    Column() {
      Column({ space: 16 }) {
        Text('重置密码')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
        TextInput({ text: this.forgotEmail, placeholder: '注册邮箱' })
          .height(46).borderRadius(10).backgroundColor(this.inputColor())
          .fontColor(this.primaryText()).placeholderColor(this.subtleText())
          .onChange((v: string) => { this.forgotEmail = v; })
        if (this.forgotCodeSent) {
          TextInput({ text: this.forgotCode, placeholder: '邮箱验证码（6 位）' })
            .height(46).borderRadius(10).backgroundColor(this.inputColor())
            .fontColor(this.primaryText()).placeholderColor(this.subtleText())
            .onChange((v: string) => { this.forgotCode = v; })
          TextInput({ text: this.forgotNewPassword, placeholder: '新密码（至少 8 位）' })
            .type(InputType.Password)
            .height(46).borderRadius(10).backgroundColor(this.inputColor())
            .fontColor(this.primaryText()).placeholderColor(this.subtleText())
            .onChange((v: string) => { this.forgotNewPassword = v; })
        }
        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1).height(42)
            .backgroundColor(this.controlColor()).fontColor(this.primaryText())
            .border({ width: 1, color: this.dividerColor() })
            .onClick(() => { this.showForgot = false; })
          Button(this.forgotCodeSent ? '确认重置' : '发送验证码')
            .layoutWeight(1).height(42)
            .backgroundColor(this.BRAND_GREEN)
            .enabled(!this.forgotBusy)
            .onClick(() => { this.forgotAction(); })
        }
        .width('100%')
      }
      .padding(24)
      .borderRadius(16)
      .backgroundColor(this.surfaceColor())
      .width('100%')
      .onClick(() => {
      })
    }
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24 })
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.45)')
    .onClick(() => { this.showForgot = false; })
  }
}
