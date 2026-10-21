let storageLarge = new LocalStorage();

@Entry(storageLarge)
@Component
struct WidgetCardLarge {
  @LocalStorageProp('tsb') tsb: string = '';
  @LocalStorageProp('ctl') ctl: string = '';
  @LocalStorageProp('atl') atl: string = '';
  @LocalStorageProp('updated') updated: string = '';
  @LocalStorageProp('weekTss') weekTss: string = '';
  @LocalStorageProp('steps') steps: string = '';
  @LocalStorageProp('rhr') rhr: string = '';
  @LocalStorageProp('bb') bb: string = '';
  @LocalStorageProp('sleepDeep') sleepDeep: string = '';
  @LocalStorageProp('sleepLight') sleepLight: string = '';
  @LocalStorageProp('sleepRem') sleepRem: string = '';
  @LocalStorageProp('sleepAwake') sleepAwake: string = '';
  @LocalStorageProp('hrvNow') hrvNow: string = '';
  @LocalStorageProp('hrvLow') hrvLow: string = '';
  @LocalStorageProp('hrvB1') hrvB1: string = '';
  @LocalStorageProp('hrvB2') hrvB2: string = '';

  private num(v: string): number {
    if (v.length === 0) {
      return 0;
    }
    const n = Number(v);
    return Number.isNaN(n) ? 0 : n;
  }

  private tsbColor(): ResourceColor {
    if (this.tsb.length === 0) {
      return $r('app.color.text_tertiary');
    }
    const v = this.num(this.tsb);
    if (v > 5) {
      return '#3FBF7F';
    }
    if (v >= -10) {
      return '#37A9C6';
    }
    if (v >= -30) {
      return '#E0A33E';
    }
    return '#E4574F';
  }

  private formLabel(): string {
    if (this.tsb.length === 0) {
      return '等待数据';
    }
    const v = this.num(this.tsb);
    if (v > 15) {
      return '状态很好';
    }
    if (v > 5) {
      return '精力充沛';
    }
    if (v >= -10) {
      return '正常训练';
    }
    if (v >= -30) {
      return '疲劳积累';
    }
    return '过度疲劳';
  }

  private st(v: string): string {
    return v.length === 0 ? '—' : v;
  }

  private sleepTotal(): number {
    return this.num(this.sleepDeep) + this.num(this.sleepLight) + this.num(this.sleepRem) + this.num(this.sleepAwake);
  }

  private sleepText(): string {
    const t = this.sleepTotal();
    if (t <= 0) {
      return '睡眠 —';
    }
    const h = Math.floor(t / 60);
    const m = Math.round(t % 60);
    return '睡眠 ' + h + 'h' + (m < 10 ? '0' + m : '' + m);
  }

  private hrvPct(): number {
    const lo = this.num(this.hrvLow);
    const hi = this.num(this.hrvB2);
    const now = this.num(this.hrvNow);
    if (hi <= lo || this.hrvNow.length === 0) {
      return -1;
    }
    let p = ((now - lo) / (hi - lo)) * 100;
    if (p < 0) {
      p = 0;
    }
    if (p > 100) {
      p = 100;
    }
    return Math.round(p);
  }


  private wHrvLow(): number {
    const lo = this.num(this.hrvLow);
    return lo > 0 ? lo : 1;
  }

  private wHrvMid(): number {
    const lo = this.num(this.hrvLow);
    const b2 = this.num(this.hrvB2);
    return b2 > lo ? (b2 - lo) : 1;
  }

  private wHrvHigh(): number {
    return 20;
  }

  /** 白标位置：0~100（整条 = 0 ~ balancedUpper+20）✓ */
  private hrvMarkerPct(): number {
    if (this.hrvNow.length === 0) {
      return -1;
    }
    const b2 = this.num(this.hrvB2);
    const total = b2 + 20;
    if (total <= 0) {
      return -1;
    }
    let p = (this.num(this.hrvNow) / total) * 100;
    if (p < 2) {
      p = 2;
    }
    if (p > 98) {
      p = 98;
    }
    return Math.round(p);
  }

  @Builder
  leftRow(label: string, value: string, color: ResourceColor) {
    Row() {
      Text(label).fontSize(10).fontColor($r('app.color.text_tertiary')).width(56)
      Text(this.st(value)).fontSize(14).fontWeight(FontWeight.Medium).fontColor(color)
    }
    .width('100%').margin({ top: 2 })
  }

  @Builder
  rightItem(label: string, value: string) {
    Column() {
      Text(label).fontSize(9).fontColor($r('app.color.text_tertiary'))
      Text(this.st(value)).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
    }
    .alignItems(HorizontalAlign.Start).layoutWeight(1)
  }

  build() {
    Row() {
      // ══ 左栏：表单 ══
      Column() {
        Text('今日表单').fontSize(10).fontColor($r('app.color.text_secondary')).width('100%')
        Row() {
          Text(this.st(this.tsb)).fontSize(32).fontWeight(FontWeight.Bold).fontColor(this.tsbColor())
          Text(' TSB').fontSize(10).fontColor($r('app.color.text_tertiary')).margin({ left: 2, bottom: 4 })
        }
        .width('100%').alignItems(VerticalAlign.Bottom)
        Text(this.formLabel()).fontSize(10).fontColor(this.tsbColor()).width('100%')
        Divider().color($r('app.color.card_border_highlight')).margin({ top: 6, bottom: 2 })
        this.leftRow('CTL 体能', this.ctl, $r('app.color.text_primary'))
        this.leftRow('ATL 疲劳', this.atl, $r('app.color.text_primary'))
        this.leftRow('7天 TSS', this.weekTss, $r('app.color.text_secondary'))
        Blank()
        Text(this.updated.length > 0 ? ('更新 ' + this.updated) : '点击打开趋势')
          .fontSize(9).fontColor($r('app.color.text_hint')).width('100%')
      }
      .width('36%').height('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)

      Row().width(1).height('92%').backgroundColor($r('app.color.card_border_highlight'))

      // ══ 右栏：今日概览 + 睡眠条 + HRV条（全部在右栏内 ✓ 不超出）══
      Column() {
        Row() {
          this.rightItem('步数', this.steps)
          this.rightItem('静息心率', this.rhr)
          this.rightItem('电量', this.bb)
        }
        .width('100%')

        // 睡眠分段条
        Row() {
          Text(this.sleepText()).fontSize(9).fontColor($r('app.color.text_secondary'))
          Blank()
          Text('深' + this.st(this.sleepDeep) + ' 浅' + this.st(this.sleepLight) + ' REM' + this.st(this.sleepRem))
            .fontSize(8).fontColor($r('app.color.text_tertiary'))
        }
        .width('100%').margin({ top: 8 })

        Row() {
          if (this.sleepTotal() > 0) {
            Row().layoutWeight(this.num(this.sleepDeep) > 0 ? this.num(this.sleepDeep) : 0.001).height('100%').backgroundColor('#2F4F8F')
            Row().layoutWeight(this.num(this.sleepLight) > 0 ? this.num(this.sleepLight) : 0.001).height('100%').backgroundColor('#4A7BD0')
            Row().layoutWeight(this.num(this.sleepRem) > 0 ? this.num(this.sleepRem) : 0.001).height('100%').backgroundColor('#7FA8FF')
            Row().layoutWeight(this.num(this.sleepAwake) > 0 ? this.num(this.sleepAwake) : 0.001).height('100%').backgroundColor('#C7D2E5')
          } else {
            Row().layoutWeight(1).height('100%').backgroundColor('#E4E8EF')
          }
        }
        .width('100%').height(6).borderRadius(3).clip(true).margin({ top: 3 })

        Row() {
          Row().width(6).height(6).borderRadius(3).backgroundColor('#2F4F8F')
          Text('深').fontSize(8).fontColor($r('app.color.text_tertiary')).margin({ left: 2 })
          Row().width(6).height(6).borderRadius(3).backgroundColor('#4A7BD0').margin({ left: 6 })
          Text('浅').fontSize(8).fontColor($r('app.color.text_tertiary')).margin({ left: 2 })
          Row().width(6).height(6).borderRadius(3).backgroundColor('#7FA8FF').margin({ left: 6 })
          Text('REM').fontSize(8).fontColor($r('app.color.text_tertiary')).margin({ left: 2 })
          Row().width(6).height(6).borderRadius(3).backgroundColor('#C7D2E5').margin({ left: 6 })
          Text('醒').fontSize(8).fontColor($r('app.color.text_tertiary')).margin({ left: 2 })
        }
        .width('100%').margin({ top: 3 })

        // HRV 三区条 + 当前值白线
        Row() {
          Text('HRV ' + this.st(this.hrvNow) + ' ms').fontSize(9).fontColor($r('app.color.text_secondary'))
          Blank()
          Text('基线 ' + this.st(this.hrvLow) + '–' + this.st(this.hrvB2) + ' · 白线=昨夜')
            .fontSize(8).fontColor($r('app.color.text_tertiary'))
        }
        .width('100%').margin({ top: 8 })

        Stack({ alignContent: Alignment.Start }) {
          Row() {
            Row().layoutWeight(this.wHrvLow()).height('100%').backgroundColor('#E8A0A0')
            Row().layoutWeight(this.wHrvMid()).height('100%').backgroundColor('#A8D8B9')
            Row().layoutWeight(this.wHrvHigh()).height('100%').backgroundColor('#A8C8E8')
          }
          .width('100%').height('100%').borderRadius(3).clip(true)

          if (this.hrvPct() >= 0) {
            Column() {
              Row().width(3).height(10).backgroundColor('#FFFFFF').borderRadius(2)
            }
            .width('100%').height('100%').padding({ left: this.hrvPct() + '%' })
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%').height(6).margin({ top: 3 })

        Blank()
        Text('佳明仪表盘').fontSize(8).fontColor($r('app.color.text_hint')).width('100%')
      }
      .layoutWeight(1).height('100%').margin({ left: 12 })
      .alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start)
    }
    .width('100%').height('100%').padding(14)
    .backgroundColor($r('app.color.background'))
    .borderRadius(18)
    .alignItems(VerticalAlign.Top)
    .onClick(() => {
      postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { page: 'Trend' } });
    })
  }
}