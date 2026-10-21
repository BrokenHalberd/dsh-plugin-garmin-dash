let storage = new LocalStorage();

@Entry(storage)
@Component
struct WidgetCard {
  @LocalStorageProp('tsb') tsb: string = '';
  @LocalStorageProp('ctl') ctl: string = '';
  @LocalStorageProp('atl') atl: string = '';
  @LocalStorageProp('ride') ride: string = '打开 App 同步';
  @LocalStorageProp('updated') updated: string = '';

  private tsbColor(): ResourceColor {
    const s = this.tsb;
    if (s.length === 0) {
      return $r('app.color.text_tertiary');
    }
    const v = Number(s);
    if (Number.isNaN(v)) {
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

  private tsbText(): string {
    return this.tsb.length === 0 ? '—' : this.tsb;
  }

  private ctlText(): string {
    return this.ctl.length === 0 ? '—' : this.ctl;
  }

  private atlText(): string {
    return this.atl.length === 0 ? '—' : this.atl;
  }

  @Builder
  wideLayout() {
    Column() {
      Row() {
        Text('今日表单').fontSize(12).fontColor($r('app.color.text_secondary'))
        Blank()
        Text('佳明').fontSize(10).fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')

      Row() {
        Text(this.tsbText()).fontSize(30).fontWeight(FontWeight.Bold).fontColor(this.tsbColor())
        Text(' TSB').fontSize(11).fontColor($r('app.color.text_tertiary')).margin({ left: 2, bottom: 5 })
      }
      .width('100%').alignItems(VerticalAlign.Bottom).margin({ top: 4 })

      Row() {
        Column() {
          Text('CTL 体能').fontSize(10).fontColor($r('app.color.text_tertiary'))
          Text(this.ctlText()).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)

        Column() {
          Text('ATL 疲劳').fontSize(10).fontColor($r('app.color.text_tertiary'))
          Text(this.atlText()).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
      }
      .width('100%').margin({ top: 8 })

      Text(this.ride.length === 0 ? '打开 App 同步' : this.ride)
        .fontSize(10).fontColor($r('app.color.text_tertiary')).width('100%')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 8 })

      if (this.updated.length > 0) {
        Text('更新 ' + this.updated).fontSize(9).fontColor($r('app.color.text_hint')).width('100%')
      }
    }
    .width('100%').height('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      this.wideLayout()
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor($r('app.color.background'))
    .borderRadius(16)
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: {
          page: 'Trend'
        }
      });
    })
  }
}