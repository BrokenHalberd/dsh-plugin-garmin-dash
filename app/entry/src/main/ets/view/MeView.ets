import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { ApiClient, ApiError } from '../service/ApiClient';
import { DeviceStore } from '../service/DeviceStore';
import { PairResult } from '../model/Types';
/** 底部选项栏 + 安全区高度：滚到底时用来避开遮挡 */
const BOTTOM_BAR_PAD: number = 104;

@Component
export struct MeView {
  /** 全局体重（kg），空 = 未设置 */
  @State bodyWeight: string = DeviceStore.getBodyWeight();
  /** 等级阈值表粘贴内容（每行：名称,5s,1min,5min,20min,60min） */
  @State levelText: string = '';
  @State levelMsg: string = '';
  onChanged: () => void = () => {};
  @State baseUrl: string = DeviceStore.getBaseUrl();
  @State pairCode: string = '';
  @State deviceId: string = DeviceStore.getDeviceId();
  @State busy: boolean = false;
  @State msg: string = '';
  @StorageLink('handFollow') handFollow: boolean = true;
  private toast(m: string): void {
    promptAction.showToast({ message: m, duration: 2500 });
  }
  /** 扫码配对：PC 端展示的二维码里是 https://<域名>/garmin-dash/pair?code=XXXXXXXX */
  private async scanAndPair(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.ALL],
      enableMultiMode: false,
      enableAlbum: true
    };
    this.msg = '请对准电脑上显示的配对二维码…';
    try {
      const result = await scanBarcode.startScanForResult(ctx, options);
      const text: string = result.originalValue;
      if (text === undefined || text === null || text.length === 0) {
        this.msg = '未识别到内容，请重试';
        return;
      }
      this.msg = '已识别，正在配对…';
      if (!this.applyScanText(text)) {
        this.msg = '二维码内容无法识别：' + text;
        return;
      }
      await this.doPair();
    } catch (e) {
      const err = e as BusinessError;
      this.msg = '扫码取消或失败：' + (err.message === undefined ? '' : err.message);
    }
  }
  /** 解析扫码文本：既支持完整配对链接，也支持只扫到 8 位配对码 */
  private applyScanText(text: string): boolean {
    const raw = text.trim();
    let code = '';
    let base = '';
    const idx = raw.indexOf('code=');
    if (idx >= 0) {
      let rest = raw.substring(idx + 5);
      const amp = rest.indexOf('&');
      if (amp >= 0) {
        rest = rest.substring(0, amp);
      }
      code = rest.trim().toUpperCase();
      const q = raw.indexOf('?');
      if (q > 0) {
        base = raw.substring(0, q);
      }
    } else if (raw.length === 8) {
      // 只扫到配对码：沿用已保存的地址
      code = raw.toUpperCase();
    }
    if (code.length === 0) {
      return false;
    }
    // 去掉链接里自带的接口路径，只留 scheme://host[:port]
    const p = base.indexOf('/garmin-dash');
    if (p > 0) {
      base = base.substring(0, p);
    }
    if (base.length > 0) {
      DeviceStore.setBaseUrl(base);
      this.baseUrl = DeviceStore.getBaseUrl();
    }
    this.pairCode = code;
    return true;
  }
  private saveUrl(): void {
    DeviceStore.setBaseUrl(this.baseUrl);
    this.baseUrl = DeviceStore.getBaseUrl();
    this.toast('地址已保存');
  }
  private async doPair(): Promise<void> {
    if (this.baseUrl.trim().length === 0) {
      this.msg = '请先扫码，或手动填服务器地址';
      return;
    }
    if (this.pairCode.trim().length === 0) {
      this.msg = '请先扫码，或手动填配对码';
      return;
    }
    this.busy = true;
    this.msg = '正在验证地址…';
    DeviceStore.setBaseUrl(this.baseUrl);
    this.baseUrl = DeviceStore.getBaseUrl();
    try {
      await ApiClient.health(this.baseUrl);
      this.msg = '地址可达，正在配对…';
      const r: PairResult = await ApiClient.pair(this.baseUrl, this.pairCode.trim().toUpperCase());
      DeviceStore.savePair(r.deviceKey, r.deviceId);
      this.deviceId = r.deviceId;
      this.msg = '配对成功！设备密钥已保存，之后无需再配对';
      this.toast('配对成功');
      this.onChanged();
    } catch (e) {
      const err = e as ApiError;
      this.msg = ApiClient.friendly(err);
      this.toast('配对失败');
    } finally {
      this.busy = false;
    }
  }
  private async testConn(): Promise<void> {
    this.msg = '正在测试连接…';
    try {
      await ApiClient.health(DeviceStore.getBaseUrl());
      this.msg = '✅ 服务器可达，接口正常';
      this.toast('服务器可达');
    } catch (e) {
      this.msg = '❌ ' + ApiClient.friendly(e);
    }
  }
  private clearPair(): void {
    DeviceStore.clearPair();
    this.deviceId = '';
    this.msg = '已清除本机配对';
    this.onChanged();
  }
  /** 解析粘贴的等级表：每行「名称,5s,1min,5min,20min,60min」 */
  private parseLevelTable(): void {
    const lines = this.levelText.split('\n');
    const names: string[] = [];
    const wkg: number[][] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const parts = line.split(',');
      if (parts.length < 6) {
        continue;
      }
      const row: number[] = [];
      let ok = true;
      for (let j = 1; j <= 5; j++) {
        const v = Number.parseFloat(parts[j]);
        if (!Number.isFinite(v)) {
          ok = false;
          break;
        }
        row.push(v);
      }
      if (!ok) {
        continue;
      }
      names.push(parts[0].trim());
      wkg.push(row);
    }
    if (names.length === 0) {
      this.levelMsg = '没解析到有效行：每行需 6 段，例如 Hero,25.18,11.50,7.60,6.71,6.60';
      return;
    }
    DeviceStore.setLevelTable(JSON.stringify({ names: names, wkg: wkg }));
    this.levelMsg = '已保存 ' + names.length + ' 个等级：' + names.join(' / ');
  }

  @Builder
  levelTableCard() {
    Column() {
      Row() {
        Text('等级阈值表').fontSize(14).fontWeight(FontWeight.Medium)
        Blank()
        Text(DeviceStore.getLevelTable().length > 10 ? '自定义 ✓' : '内置 Coggan')
          .fontSize(10).fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')

      TextArea({ text: this.levelText, placeholder: '每行：名称,5s,1min,5min,20min,60min\n例如：\nHero,25.18,11.50,7.60,6.71,6.60\nNoob,9.44,5.39,3.58,2.02,1.88' })
        .fontSize(12).height(120).width('100%').margin({ top: 8 })
        .backgroundColor($r('app.color.chip_background')).borderRadius(8)
        .onChange((v: string) => { this.levelText = v; })

      Row({ space: 10 }) {
        Button('保存等级表').fontSize(13).height(34).layoutWeight(1)
          .backgroundColor($r('app.color.accent')).fontColor($r('app.color.accent_on'))
          .onClick(() => { this.parseLevelTable(); })
        Button('恢复内置').fontSize(13).height(34).layoutWeight(1)
          .backgroundColor($r('app.color.chip_background')).fontColor($r('app.color.text_secondary'))
          .onClick(() => {
            DeviceStore.setLevelTable('');
            this.levelText = '';
            this.levelMsg = '已恢复内置 Coggan 表';
          })
      }
      .width('100%').margin({ top: 8 })

      Text(this.levelMsg.length > 0 ? this.levelMsg : '列顺序固定：5秒 / 1分钟 / 5分钟 / 20分钟 / 60分钟；判定取「≥ 该档下限」的最高档。')
        .fontSize(10).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 8 })
    }
    .padding(16).width('100%')
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
    .margin({ top: 10 })
  }

  @Builder
  weightCard() {
    Column() {
      Row() {
        Text('个人设置').fontSize(14).fontWeight(FontWeight.Medium)
        Blank()
        Text('用于 W/kg 与等级判定').fontSize(10).fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      Row() {
        Text('体重').fontSize(13).width(64)
        TextInput({ text: this.bodyWeight, placeholder: '例如 72.5' })
          .fontSize(14).type(InputType.Normal).layoutWeight(1).height(38)
          .backgroundColor($r('app.color.chip_background')).borderRadius(8)
          .onChange((v: string) => {
            this.bodyWeight = v;
            DeviceStore.setBodyWeight(v);
          })
        Text('kg').fontSize(11).fontColor($r('app.color.text_hint')).width(28).textAlign(TextAlign.End)
      }
      .width('100%').margin({ top: 10 })
      Text('改动立即保存并生效：功率形态的 W/kg、综合等级、车手类型都会按新体重重算。')
        .fontSize(10).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 8 })
    }
    .padding(16).width('100%')
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
    .margin({ top: 10 })
  }

  build() {
    Scroll() {
    Column() {
      Text('我的').fontSize(20).fontWeight(FontWeight.Bold)
        .width('100%').padding({ left: 4, top: 10, bottom: 10 })
      // —— 扫码配对（主入口）——
      Column() {
        Text('扫码配对').fontSize(15).fontWeight(FontWeight.Medium).width('100%')
        Text('电脑端运行「生成Garmin配对码」，然后用这里扫它显示的二维码')
          .fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%').margin({ top: 4, bottom: 10 })
        Button(this.busy ? '处理中…' : '📷 扫描配对二维码')
          .fontSize(15)
          .width('100%')
          .height(44)
          .enabled(!this.busy)
          .onClick(() => { this.scanAndPair(); })
      }
      .padding(14).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14)
      if (this.msg.length > 0) {
        Text(this.msg).fontSize(12).fontColor($r('app.color.text_secondary'))
          .width('100%').margin({ top: 10 })
      }
      // —— 配对状态 ——
      Column() {
        Row() {
          Text('配对状态').fontSize(13).fontColor($r('app.color.text_secondary'))
          Blank()
          Text(DeviceStore.isPaired() ? '已配对' : '未配对')
            .fontSize(13)
            .fontColor(DeviceStore.isPaired() ? $r('app.color.success') : $r('app.color.danger'))
        }
        .width('100%')
        if (this.deviceId.length > 0) {
          Text('设备 ID：' + this.deviceId).fontSize(12).fontColor($r('app.color.text_tertiary'))
            .margin({ top: 6 }).width('100%')
        }
        if (DeviceStore.getBaseUrl().length > 0) {
          Text('服务器：' + DeviceStore.getBaseUrl()).fontSize(11).fontColor($r('app.color.text_tertiary'))
            .margin({ top: 4 }).width('100%')
        }
        Button('测试连接').fontSize(13).width('100%').margin({ top: 10 })
          .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent'))
          .onClick(() => { this.testConn(); })
        Button('清除配对').fontSize(13).width('100%').margin({ top: 10 })
          .backgroundColor($r('app.color.chip_background')).fontColor($r('app.color.danger'))
          .onClick(() => { this.clearPair(); })
      }
      .padding(14).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14).margin({ top: 12 })
      Column() {
        Row() {
          Column() {
            Text('适人握持').fontSize(13).fontColor($r('app.color.text_secondary'))
            Text('按钮自动跟随左右手握持（防抖 1.5 秒，避免来回跳）')
              .fontSize(10).fontColor($r('app.color.text_hint')).margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.handFollow })
            .onChange((on: boolean) => {
              this.handFollow = on;
              this.toast(on ? '适人握持已开启' : '适人握持已关闭');
            })
        }
        .width('100%')
      }
      .padding(14).width('100%').backgroundColor($r('app.color.card_background_blur'))
      .border({ width: 1, color: $r('app.color.card_border_highlight') })
      .borderRadius(14).margin({ top: 12 })
      // —— 手动兜底 ——
      Column() {
        Text('手动配对（扫码不可用时）').fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%')
        TextInput({ text: this.baseUrl, placeholder: 'https://xxxxxxxx.dsh-market.com' })
          .fontSize(13)
          .onChange((v: string) => { this.baseUrl = v; })
          .margin({ top: 6 })
        TextInput({ text: this.pairCode, placeholder: '8 位配对码，例如 A1B2C3D4' })
          .fontSize(14)
          .maxLength(8)
          .onChange((v: string) => { this.pairCode = v.toUpperCase(); })
          .margin({ top: 8 })
        Row({ space: 8 }) {
          Button('保存地址').fontSize(13).layoutWeight(1)
            .backgroundColor($r('app.color.chip_background')).fontColor($r('app.color.text_primary'))
            .onClick(() => { this.saveUrl(); })
          Button('配对').fontSize(13).layoutWeight(1)
            .enabled(!this.busy)
            .onClick(() => { this.doPair(); })
        }
        .width('100%').margin({ top: 8 })
      }
      .padding(14).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14).margin({ top: 12 })
      Text('配对一次后长期有效：服务器域名固定，重启电脑也无需重新配对。')
        .fontSize(11).fontColor($r('app.color.text_hint')).width('100%').margin({ top: 12 })
      this.weightCard()
      this.levelTableCard()
    }
    .width('100%')

    .padding({ left: 12, right: 12 })
    .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }
}
