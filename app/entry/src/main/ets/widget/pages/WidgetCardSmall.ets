let storageSmall = new LocalStorage();

@Entry(storageSmall)
@Component
struct WidgetCardSmall {
  @LocalStorageProp('spin') spin: string = '\u27F3';

  @LocalStorageProp('tsb') tsb: string = '';
  @LocalStorageProp('ctl') ctl: string = '';
  @LocalStorageProp('atl') atl: string = '';

  private tsbColor(): ResourceColor {
    const s = this.tsb;
    if (s.length === 0) {
      return $r('app.color.text_tertiary');
    }
    const v = Number(s);
    if (!Number.isFinite(v)) {
      return $r('app.color.text_tertiary');
    }
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

  build() {
    Row() {
      Column() {
        Text('TSB').fontSize(9).fontColor($r('app.color.text_tertiary'))
        Text(this.tsb.length === 0 ? '—' : this.tsb)
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.tsbColor())
      }
      .alignItems(HorizontalAlign.Center).layoutWeight(1)
      .onClick(() => {
        postCardAction(this, {
          action: 'router',
          bundleName: 'com.atlas.garmindash',
          moduleName: 'entry',
          abilityName: 'EntryAbility',
          params: { page: 'Trend' }
        });
      })

      Column() {
        Text('CTL').fontSize(9).fontColor($r('app.color.text_tertiary'))
        Text(this.ctl.length === 0 ? '—' : this.ctl)
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      }
      .alignItems(HorizontalAlign.Center).layoutWeight(1)

      Column() {
        Text('ATL').fontSize(9).fontColor($r('app.color.text_tertiary'))
        Text(this.atl.length === 0 ? '—' : this.atl)
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      }
      .alignItems(HorizontalAlign.Center).layoutWeight(1)

      Text(this.spin)
        .fontSize(12).fontColor($r('app.color.accent')).padding({ left: 2, right: 2 })
        .onClick(() => {
          postCardAction(this, {
            action: 'message',
            params: {
              method: 'refresh'
            }
          });
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: 10 })
    .backgroundColor($r('app.color.background'))
    .borderRadius(16)
    .justifyContent(FlexAlign.Center)
  }
}