import { ApiClient } from '../service/ApiClient';
import { DeviceStore } from '../service/DeviceStore';
import { Trend, TrendPoint, WeeklyTotal } from '../model/Types';
import { Fmt } from '../util/Format';
import { Theme } from '../util/Theme';
import { common } from '@kit.AbilityKit';
@Component
export struct TrendView {
  @Prop @Watch('onTick') tick: number = 0;
  @State trend: Trend | null = null;
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State err: string = '';
  /** 系统深浅色：Canvas 取色用 */
  @State dark: boolean = false;
  @State staleNote: string = '';
  @State days: number = 90;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  aboutToAppear(): void {
    this.dark = Theme.isDark(getContext(this) as common.UIAbilityContext);
    this.load(false);
  }
  onTick(): void {
    this.load(false);
  }
  private load(fromPull: boolean): void {
    if (!DeviceStore.isPaired()) {
      this.err = '尚未配对：请到「我的」里完成配对';
      return;
    }
    if (!fromPull) {
      this.loading = true;
    }
    this.err = '';
    const key = 'trend:' + this.days;
    ApiClient.getTrend(this.days)
      .then((t: Trend) => {
        this.trend = t;
        this.loading = false;
        this.refreshing = false;
        this.staleNote = '';
        DeviceStore.cachePut(key, JSON.stringify(t));
        this.draw();
      })
      .catch((e: Object) => {
        this.loading = false;
        this.refreshing = false;
        const cached = DeviceStore.cacheGet(key);
        if (cached.length > 0) {
          this.trend = JSON.parse(cached) as Trend;
          this.staleNote = '离线数据 · ' + Fmt.ago(DeviceStore.cacheAge(key)) + '（' + ApiClient.friendly(e) + '）';
          this.draw();
        } else {
          this.err = ApiClient.friendly(e);
        }
      });
  }
  /** PMC 折线：CTL(体能) / ATL(疲劳) / TSB(状态)，含网格与刻度 */
  private draw(): void {
    const t = this.trend;
    if (t === null || t.points.length === 0) {
      return;
    }
    const pts: TrendPoint[] = t.points;
    const w = this.ctx.width;
    const h = this.ctx.height;
    const padL = 30;
    const padR = 6;
    const padT = 8;
    const padB = 18;
    const plotW = w - padL - padR;
    const plotH = h - padT - padB;
    this.ctx.clearRect(0, 0, w, h);
    let max = 1;
    let min = 0;
    for (let i = 0; i < pts.length; i++) {
      const p = pts[i];
      const vals: (number | null)[] = [p.ctl, p.atl, p.tsb];
      for (let k = 0; k < vals.length; k++) {
        const v = vals[k];
        if (v === null) {
          continue;
        }
        if (v > max) {
          max = v;
        }
        if (v < min) {
          min = v;
        }
      }
    }
    max = max * 1.12;
    min = min * 1.12;
    const span = max - min <= 0 ? 1 : max - min;
    const yOf = (v: number): number => padT + plotH - ((v - min) / span) * plotH;
    const xOf = (i: number): number => padL + (pts.length > 1 ? (plotW * i) / (pts.length - 1) : plotW);
    // 网格 + y 轴刻度
    this.ctx.strokeStyle = Theme.grid(this.dark);
    this.ctx.lineWidth = 1;
    this.ctx.font = '9px sans-serif';
    this.ctx.fillStyle = Theme.axis(this.dark);
    for (let g = 0; g <= 4; g++) {
      const v = min + (span * g) / 4;
      const y = yOf(v);
      this.ctx.beginPath();
      this.ctx.moveTo(padL, y);
      this.ctx.lineTo(w - padR, y);
      this.ctx.stroke();
      this.ctx.fillText('' + Math.round(v), 2, y + 3);
    }
    // 零线（TSB 正负分界）
    if (min < 0 && max > 0) {
      this.ctx.strokeStyle = Theme.zeroLine(this.dark);
      this.ctx.beginPath();
      this.ctx.moveTo(padL, yOf(0));
      this.ctx.lineTo(w - padR, yOf(0));
      this.ctx.stroke();
    }
    // CTL 线下淡填充
    this.ctx.beginPath();
    let started = false;
    for (let i = 0; i < pts.length; i++) {
      const v = pts[i].ctl;
      if (v === null) {
        continue;
      }
      const x = xOf(i);
      const y = yOf(v);
      if (!started) {
        this.ctx.moveTo(x, y);
        started = true;
      } else {
        this.ctx.lineTo(x, y);
      }
    }
    if (started) {
      this.ctx.lineTo(xOf(pts.length - 1), yOf(min));
      this.ctx.lineTo(xOf(0), yOf(min));
      this.ctx.closePath();
      this.ctx.fillStyle = Theme.fill(this.dark);
      this.ctx.fill();
    }
    const line = (pick: (p: TrendPoint) => number | null, color: string, width: number) => {
      this.ctx.strokeStyle = color;
      this.ctx.lineWidth = width;
      this.ctx.beginPath();
      let on = false;
      for (let i = 0; i < pts.length; i++) {
        const v = pick(pts[i]);
        if (v === null) {
          continue;
        }
        const x = xOf(i);
        const y = yOf(v);
        if (!on) {
          this.ctx.moveTo(x, y);
          on = true;
        } else {
          this.ctx.lineTo(x, y);
        }
      }
      this.ctx.stroke();
    };
    line((p: TrendPoint) => p.ctl, Theme.ctl(this.dark), 2.4);
    line((p: TrendPoint) => p.atl, Theme.atl(this.dark), 2);
    line((p: TrendPoint) => p.tsb, Theme.tsb(this.dark), 1.6);
    // x 轴首尾日期
    this.ctx.fillStyle = Theme.axis(this.dark);
    this.ctx.fillText(pts[0].date.substring(5), padL, h - 5);
    this.ctx.fillText(pts[pts.length - 1].date.substring(5), w - padR - 28, h - 5);
  }
  /** 每周汇总：最近一周排最前（后端按升序返回，这里倒序展示） */
  private weeklyDesc(): WeeklyTotal[] {
    const t = this.trend;
    if (t === null) {
      return [];
    }
    const out: WeeklyTotal[] = [];
    for (let i = t.weekly.length - 1; i >= 0; i--) {
      out.push(t.weekly[i]);
    }
    out.sort((a: WeeklyTotal, b: WeeklyTotal) => (a.weekStart < b.weekStart ? 1 : -1));
    return out;
  }
  /** 本周 / 上周 / 8.17 */
  private weekLabel(weekStart: string): string {
    const thisWeek = Fmt.weekStart(Fmt.today());
    if (weekStart === thisWeek) {
      return '本周';
    }
    if (weekStart === Fmt.shiftDays(thisWeek, -7)) {
      return '上周';
    }
    return Fmt.monthDay(weekStart);
  }
  /** 8.17–8.23 */
  private weekRange(weekStart: string): string {
    return Fmt.monthDay(weekStart) + '–' + Fmt.monthDay(Fmt.shiftDays(weekStart, 6));
  }
  private lastOf(kind: string): string {
    const t = this.trend;
    if (t === null || t.points.length === 0) {
      return '--';
    }
    const p = t.points[t.points.length - 1];
    if (kind === 'ctl') {
      return Fmt.int(p.ctl);
    }
    if (kind === 'atl') {
      return Fmt.int(p.atl);
    }
    return Fmt.int(p.tsb);
  }
  @Builder
  statCard(label: string, value: string, color: ResourceColor, sub: string) {
    Column() {
      Text(value).fontSize(20).fontWeight(FontWeight.Bold).fontColor(color)
      Text(label).fontSize(11).fontColor(Theme.tsb(this.dark)).margin({ top: 2 })
      if (sub.length > 0) {
        Text(sub).fontSize(9).fontColor($r('app.color.text_hint')).margin({ top: 1 })
      }
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(12)
  }
  private weekMaxTss(): number {
    const t = this.trend;
    if (t === null || t.weekly.length === 0) {
      return 1;
    }
    let m = 1;
    for (let i = 0; i < t.weekly.length; i++) {
      if (t.weekly[i].tss > m) {
        m = t.weekly[i].tss;
      }
    }
    return m;
  }
  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column() {
          Row() {
            Text('训练负荷').fontSize(20).fontWeight(FontWeight.Bold)
            Blank()
            Text('近 ' + this.days + ' 天').fontSize(12).fontColor(Theme.tsb(this.dark))
          }
          .width('100%').padding({ left: 4, right: 4, top: 10, bottom: 10 })
          if (this.staleNote.length > 0) {
            Text(this.staleNote).fontSize(11).fontColor($r('app.color.banner_text'))
              .width('100%').padding(8).backgroundColor($r('app.color.banner_background')).borderRadius(8).margin({ bottom: 8 })
          }
          if (this.err.length > 0) {
            Column() {
              Text(this.err).fontSize(13).fontColor($r('app.color.danger'))
              Button('重试').fontSize(13).margin({ top: 8 }).onClick(() => { this.load(false); })
            }
            .padding(16).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14)
          }
          if (this.loading && this.trend === null) {
            Row() {
              LoadingProgress().width(22).height(22)
              Text('读取中…').fontSize(13).fontColor(Theme.tsb(this.dark)).margin({ left: 8 })
            }.padding(16)
          }
          if (this.trend !== null && this.trend.points.length > 0) {
            Row({ space: 8 }) {
              this.statCard('CTL 体能', this.lastOf('ctl'), Theme.ctl(this.dark), '42 天负荷')
              this.statCard('ATL 疲劳', this.lastOf('atl'), Theme.atl(this.dark), '7 天负荷')
              this.statCard('TSB 状态', this.lastOf('tsb'), $r('app.color.text_secondary'), '体能−疲劳')
            }
            .width('100%')
            Column() {
              Canvas(this.ctx)
                .width('100%')
                .height(190)
                .onReady(() => { this.draw(); })
              Row({ space: 14 }) {
                Text('● CTL').fontSize(11).fontColor(Theme.ctl(this.dark))
                Text('● ATL').fontSize(11).fontColor(Theme.atl(this.dark))
                Text('● TSB').fontSize(11).fontColor(Theme.tsb(this.dark))
                Blank()
                Text('TSB 为正=状态好').fontSize(10).fontColor($r('app.color.text_hint'))
              }
              .width('100%').padding({ top: 6 })
            }
            .padding(10).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14).margin({ top: 8 })
            Text('每周汇总').fontSize(14).fontWeight(FontWeight.Medium)
              .width('100%').margin({ top: 14, bottom: 6 })
            Column({ space: 8 }) {
              ForEach(this.weeklyDesc(), (wk: WeeklyTotal) => {
                Column() {
                  Row() {
                    Column() {
                      Text(this.weekLabel(wk.weekStart)).fontSize(12).fontWeight(FontWeight.Medium)
                      Text(this.weekRange(wk.weekStart)).fontSize(9).fontColor($r('app.color.text_hint'))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .width(84)
                    Text(Fmt.km(wk.distanceMeters)).fontSize(13).fontWeight(FontWeight.Medium).layoutWeight(1)
                    Text(Fmt.durationShort(wk.durationSeconds)).fontSize(11).fontColor($r('app.color.text_secondary')).width(52)
                    Text('TSS ' + Math.round(wk.tss)).fontSize(11).fontColor($r('app.color.accent')).width(62)
                      .textAlign(TextAlign.End)
                  }
                  .width('100%')
                  Stack({ alignContent: Alignment.Start }) {
                    Row().width('100%').height(6).backgroundColor($r('app.color.chip_background')).borderRadius(3)
                    Row().width(Math.max(2, (wk.tss / this.weekMaxTss()) * 100) + '%')
                      .height(6).backgroundColor(Theme.ctl(this.dark)).borderRadius(3)
                  }
                  .width('100%').margin({ top: 6 })
                }
                .padding(12).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(12)
              }, (wk: WeeklyTotal) => wk.weekStart)
            }
            .width('100%')
            Text('下拉刷新 · CTL/ATL 为 TSS 的 42/7 天指数移动平均')
              .fontSize(10).fontColor(Theme.axis(this.dark)).width('100%').margin({ top: 10, bottom: 96 })
          }
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.Start)
        .padding({ left: 12, right: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
    }
    .onRefreshing(() => {
      this.load(true);
    })
    .width('100%')
    .height('100%')
  }
}
