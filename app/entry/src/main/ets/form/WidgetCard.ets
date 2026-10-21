/**
 * 服务卡片：今日表单 + 最近一次骑行
 * 数据由 EntryFormAbility.onAddForm 通过 formBindingData 注入。
 */
let storage = new LocalStorage();

@Entry(storage)
@Component
struct WidgetCard {
  @LocalStorageProp('tsb') tsb: string = '—';
  @LocalStorageProp('ctl') ctl: string = '—';
  @LocalStorageProp('atl') atl: string = '—';
  @LocalStorageProp('ride') ride: string = '打开 App 同步数据';
  @LocalStorageProp('updated') updated: string = '';

  private tsbColor(): string {
    const s = this.tsb;
    if (s === '—') {
      return '#8A93A5';
    }
    const v = Number(s);
    if (Number.isNaN(v)) {
      return '#8A93A5';
    }
    if (v > 5) {
      return '#2FA36B';
    }
    if (v >= -10) {
      return '#2E9BB5';
    }
    if (v >= -30) {
      return '#E0A33E';
    }
    return '#D9534F';
  }

  build() {
    Column() {
      Row() {
        Text('今日表单').fontSize(11).fontColor('#8A93A5')
        Blank()
        Text('佳明').fontSize(9).fontColor('#8A93A5')
      }
      .width('100%')
      Row() {
        Text(this.tsb).fontSize(26).fontWeight(FontWeight.Bold).fontColor(this.tsbColor())
        Text(' TSB').fontSize(10).fontColor('#8A93A5').margin({ left: 2, bottom: 4 })
      }
      .width('100%').alignItems(VerticalAlign.Bottom)
      Row() {
        Column() {
          Text('CTL 体能').fontSize(9).fontColor('#8A93A5')
          Text(this.ctl).fontSize(14).fontWeight(FontWeight.Medium)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column() {
          Text('ATL 疲劳').fontSize(9).fontColor('#8A93A5')
          Text(this.atl).fontSize(14).fontWeight(FontWeight.Medium)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }
      .width('100%').margin({ top: 6 })
      Text(this.ride).fontSize(9).fontColor('#8A93A5').width('100%').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 6 })
      if (this.updated.length > 0) {
        Text('更新 ' + this.updated).fontSize(8).fontColor('#B0B6C0').width('100%')
      }
    }
    .width('100%').height('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    .justifyContent(FlexAlign.Start)
  }
}