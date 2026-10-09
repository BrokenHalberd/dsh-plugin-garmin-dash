import { router } from '@kit.ArkUI';
import { ApiClient } from '../service/ApiClient';
import { DeviceStore } from '../service/DeviceStore';
import { Activity } from '../model/Types';
import { Fmt } from '../util/Format';
const PAGE: number = 20;
@Component
export struct ActivitiesView {
  @Prop @Watch('onTick') tick: number = 0;
  @State items: Activity[] = [];
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State hasMore: boolean = true;
  @State err: string = '';
  @State staleNote: string = '';
  @State filter: string = 'all';
  aboutToAppear(): void {
    this.loadFirst(false);
  }
  onTick(): void {
    this.loadFirst(false);
  }
  private loadFirst(fromPull: boolean): void {
    if (!DeviceStore.isPaired()) {
      this.err = '尚未配对：请到「我的」里完成配对';
      return;
    }
    if (!fromPull) {
      this.loading = true;
    }
    this.err = '';
    const key = 'activities:' + PAGE + ':0';
    ApiClient.getActivities(PAGE, 0)
      .then((list: Activity[]) => {
        this.items = list;
        this.hasMore = list.length >= PAGE;
        this.loading = false;
        this.refreshing = false;
        this.staleNote = '';
        DeviceStore.cachePut(key, JSON.stringify(list));
      })
      .catch((e: Object) => {
        this.loading = false;
        this.refreshing = false;
        const cached = DeviceStore.cacheGet(key);
        if (cached.length > 0) {
          this.items = JSON.parse(cached) as Activity[];
          this.staleNote = '离线数据 · ' + Fmt.ago(DeviceStore.cacheAge(key)) + '（' + ApiClient.friendly(e) + '）';
        } else {
          this.err = ApiClient.friendly(e);
        }
      });
  }
  private loadMore(): void {
    if (this.loadingMore || !this.hasMore) {
      return;
    }
    this.loadingMore = true;
    ApiClient.getActivities(PAGE, this.items.length)
      .then((list: Activity[]) => {
        const merged: Activity[] = this.items;
        for (let i = 0; i < list.length; i++) {
          merged.push(list[i]);
        }
        this.items = merged;
        this.hasMore = list.length >= PAGE;
        this.loadingMore = false;
      })
      .catch((e: Object) => {
        this.loadingMore = false;
        this.err = ApiClient.friendly(e);
      });
  }
  private shown(): Activity[] {
    if (this.filter === 'all') {
      return this.items;
    }
    const out: Activity[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].type === this.filter) {
        out.push(this.items[i]);
      }
    }
    return out;
  }
  @Builder
  metric(label: string, value: string) {
    Column() {
      Text(value).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      Text(label).fontSize(10).fontColor($r('app.color.text_tertiary')).margin({ top: 1 })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }
  @Builder
  chip(label: string, value: string) {
    Text(label).fontSize(12)
      .fontColor(this.filter === value ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(this.filter === value ? $r('app.color.accent') : $r('app.color.chip_background'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .borderRadius(14)
      .onClick(() => { this.filter = value; })
  }
  @Builder
  card(a: Activity) {
    Column() {
      Row() {
        Text(Fmt.sportName(a.type)).fontSize(13).fontWeight(FontWeight.Medium)
        Text(' · ' + Fmt.shortTime(a.startTime)).fontSize(12).fontColor($r('app.color.text_tertiary'))
        Blank()
        Text('TSS ' + Fmt.int(a.trainingStressScore)).fontSize(12).fontColor($r('app.color.accent'))
      }
      .width('100%')
      Text(Fmt.km(a.distanceMeters) + ' · ' + Fmt.durationShort(a.durationSeconds))
        .fontSize(18).fontWeight(FontWeight.Bold).margin({ top: 6 }).width('100%')
      Row() {
        this.metric('均功率', Fmt.num(a.avgPower, ' W'))
        this.metric('NP', Fmt.num(a.normPower, ' W'))
        this.metric('IF', a.intensityFactor === null ? '--' : a.intensityFactor.toFixed(2))
        this.metric('均心率', Fmt.num(a.averageHeartRate, ''))
        this.metric('爬升', Fmt.num(a.elevationGainMeters, ' m'))
      }
      .width('100%').margin({ top: 8 })
    }
    .padding(14).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14)
    .onClick(() => {
      router.pushUrl({ url: 'pages/ActivityDetailPage', params: { id: a.id } });
    })
  }
  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      Column() {
        Row() {
          Text('运动记录').fontSize(20).fontWeight(FontWeight.Bold)
          Blank()
          Text('已加载 ' + this.items.length + ' 次').fontSize(12).fontColor($r('app.color.text_tertiary'))
        }
        .width('100%').padding({ left: 4, right: 4, top: 10, bottom: 8 })
        Row({ space: 8 }) {
          this.chip('全部', 'all')
          this.chip('骑行', 'cycling')
          this.chip('跑步', 'running')
          Blank()
        }
        .width('100%').padding({ bottom: 8 })
        if (this.staleNote.length > 0) {
          Text(this.staleNote).fontSize(11).fontColor($r('app.color.banner_text'))
            .width('100%').padding(8).backgroundColor($r('app.color.banner_background')).borderRadius(8).margin({ bottom: 8 })
        }
        if (this.err.length > 0) {
          Column() {
            Text(this.err).fontSize(13).fontColor($r('app.color.danger'))
            Button('重试').fontSize(13).margin({ top: 8 }).onClick(() => { this.loadFirst(false); })
          }
          .padding(16).width('100%').backgroundColor($r('app.color.card_background_blur')).border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14)
        }
        if (this.loading && this.items.length === 0) {
          Row() {
            LoadingProgress().width(22).height(22)
            Text('读取中…').fontSize(13).fontColor($r('app.color.text_tertiary')).margin({ left: 8 })
          }.padding(16)
        }
        List({ space: 10 }) {
          ForEach(this.shown(), (a: Activity) => {
            ListItem() {
              this.card(a)
            }
          }, (a: Activity) => '' + a.id)
          if (this.hasMore && this.filter === 'all') {
            ListItem() {
              Row() {
                if (this.loadingMore) {
                  LoadingProgress().width(18).height(18)
                  Text('加载中…').fontSize(12).fontColor($r('app.color.text_tertiary')).margin({ left: 6 })
                } else {
                  Text('加载更多').fontSize(13).fontColor($r('app.color.accent'))
                }
              }
              .width('100%').height(44).justifyContent(FlexAlign.Center)
              .onClick(() => { this.loadMore(); })
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12, bottom: 86 })
      .alignItems(HorizontalAlign.Start)
    }
    .onRefreshing(() => {
      this.loadFirst(true);
    })
    .width('100%')
    .height('100%')
  }
}
