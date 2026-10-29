import { router } from '@kit.ArkUI';
import { ApiClient , BundleResult } from '../service/ApiClient';
import { DeviceStore } from '../service/DeviceStore';
import { Activity } from '../model/Types';
import { Fmt } from '../util/Format';

/** 一个自然周的分组（仅日期排序时使用） */
interface WeekGroup {
  weekStart: string;
  label: string;
  range: string;
  tss: number;
  km: number;
  items: Activity[];
}

/** 强度分档（按 IF，缺失则用 TSS/小时折算） */
interface IntensityBand {
  name: string;
  color: string;
}

const PAGE_SIZE = 20;

/**
 * 运动记录页 —— 向 Intervals.icu 的活动列表看齐。
 *
 * 全部由现有 `/activities` 数据现算（不新增上游取数）：
 *   · 顶部「近 7 天」汇总条：TSS / 时长 / 距离 / 次数
 *   · 日期视图按自然周分组，每周头显示该周 TSS 与里程
 *   · 每行左侧色条 = 强度分档（恢复 / 耐力 / 节奏 / 阈值 / VO2max）
 *   · 排序可切换：日期 · TSS · 距离（后两者为排名列表，与分组互斥）
 */
/** 底部选项栏 + 安全区高度：滚到底时用来避开遮挡 */
const BOTTOM_BAR_PAD: number = 104;

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
  @State sortBy: string = 'date';   // date | tss | distance

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
    const key = 'activities:0';
    const cached = DeviceStore.cacheGet(key);
    let showed = false;
    // 先用首页 bundle 缓存秒开（不阻塞首屏 ✓），网络请求继续在后台更新
    if (this.items.length === 0) {
      try {
        const cachedAll = DeviceStore.cacheGet('bundle:all');
        if (cachedAll.length > 10) {
          const b = JSON.parse(cachedAll) as BundleResult;
          if (b.activities !== undefined && b.activities !== null && b.activities.length > 0) {
            this.items = b.activities;
            this.hasMore = b.activities.length >= PAGE_SIZE;
            this.staleNote = '缓存 · ' + Fmt.ago(DeviceStore.cacheAge('bundle:all')) + ' · 正在刷新…';
            this.loading = false;
            showed = true;
          }
        }
      } catch (e0) {
      }
    }
    if (cached.length > 0) {
      this.items = JSON.parse(cached) as Activity[];
      this.staleNote = '缓存 · ' + Fmt.ago(DeviceStore.cacheAge(key)) + ' · 正在刷新…';
      showed = true;
    }
    if (!fromPull && !showed) {
      this.loading = true;
    }
    this.err = '';
    ApiClient.getActivitiesDays(90)
      .then((list: Activity[]) => {
        this.items = list;
        this.hasMore = list.length >= PAGE_SIZE;
        this.staleNote = '';
        this.loading = false;
        this.refreshing = false;
        DeviceStore.cachePut(key, JSON.stringify(list));
      })
      .catch((e: Object) => {
        this.loading = false;
        this.refreshing = false;
        if (!showed) {
          this.err = ApiClient.friendly(e);
        }
      });
  }

  private loadMore(): void {
    if (this.loadingMore || !this.hasMore || !DeviceStore.isPaired()) {
      return;
    }
    this.loadingMore = true;
    ApiClient.getActivities(PAGE_SIZE, this.items.length)
      .then((list: Activity[]) => {
        this.items = this.items.concat(list);
        this.hasMore = list.length >= PAGE_SIZE;
        this.loadingMore = false;
      })
      .catch((e: Object) => {
        this.loadingMore = false;
        this.err = ApiClient.friendly(e);
      });
  }

  // ── 派生：强度分档 ──

  /** 强度比：优先 IF，缺失时用 NP/均功率或 TSS/小时折算 */
  private intensityOf(a: Activity): number | null {
    if (a.intensityFactor !== null && a.intensityFactor > 0) {
      return a.intensityFactor;
    }
    const np = a.normPower;
    const ap = a.avgPower;
    if (np !== null && ap !== null && ap > 0) {
      return Math.round((np / ap) * 100) / 100;
    }
    if (a.trainingStressScore !== null && a.durationSeconds !== null && a.durationSeconds > 600) {
      const hours = a.durationSeconds / 3600;
      const tssPerHour = a.trainingStressScore / hours;
      return Math.round(Math.sqrt(tssPerHour / 100) * 100) / 100;
    }
    return null;
  }

  private band(a: Activity): IntensityBand {
    const f = this.intensityOf(a);
    if (f === null) {
      return { name: '无功率', color: '#8A93A5' };
    }
    if (f < 0.6) {
      return { name: '恢复', color: '#2E9BB5' };
    }
    if (f < 0.75) {
      return { name: '耐力', color: '#2FA36B' };
    }
    if (f < 0.85) {
      return { name: '节奏', color: '#E0A33E' };
    }
    if (f < 0.95) {
      return { name: '阈值', color: '#D9534F' };
    }
    return { name: 'VO2max', color: '#8E5BD9' };
  }

  // ── 派生：汇总与分组 ──

  /** 近 7 天汇总（基于已加载数据；默认一页 20 条通常覆盖一周以上） */
  private recentSummary(): string {
    const cutoff = Fmt.shiftDays(Fmt.today(), -6);
    let tss = 0;
    let sec = 0;
    let m = 0;
    let n = 0;
    for (let i = 0; i < this.items.length; i++) {
      const a = this.items[i];
      const d = a.startTime.length >= 10 ? a.startTime.substring(0, 10) : a.startTime;
      if (d < cutoff) {
        continue;
      }
      n++;
      if (a.trainingStressScore !== null) {
        tss += a.trainingStressScore;
      }
      if (a.durationSeconds !== null) {
        sec += a.durationSeconds;
      }
      if (a.distanceMeters !== null) {
        m += a.distanceMeters;
      }
    }
    if (n === 0) {
      return '近 7 天：暂无活动';
    }
    return '近 7 天 ' + n + ' 次 · TSS ' + Math.round(tss) + ' · ' + Fmt.durationShort(sec) + ' · ' + Fmt.km(m);
  }

  private weekLabelOf(weekStart: string): string {
    const thisWeek = Fmt.weekStart(Fmt.today());
    if (weekStart === thisWeek) {
      return '本周';
    }
    if (weekStart === Fmt.shiftDays(thisWeek, -7)) {
      return '上周';
    }
    return Fmt.monthDay(weekStart) + ' 那周';
  }

  /** 日期视图：按自然周分组（新周在前） */
  private groups(): WeekGroup[] {
    const out: WeekGroup[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const a = this.items[i];
      const d = a.startTime.length >= 10 ? a.startTime.substring(0, 10) : Fmt.today();
      const ws = Fmt.weekStart(d);
      let g: WeekGroup | null = null;
      for (let k = 0; k < out.length; k++) {
        if (out[k].weekStart === ws) {
          g = out[k];
          break;
        }
      }
      if (g === null) {
        const created: WeekGroup = {
          weekStart: ws,
          label: this.weekLabelOf(ws),
          range: Fmt.monthDay(ws) + '–' + Fmt.monthDay(Fmt.shiftDays(ws, 6)),
          tss: 0,
          km: 0,
          items: []
        };
        out.push(created);
        g = created;
      }
      g.items.push(a);
      if (a.trainingStressScore !== null) {
        g.tss += a.trainingStressScore;
      }
      if (a.distanceMeters !== null) {
        g.km += a.distanceMeters / 1000;
      }
    }
    return out;
  }

  /** TSS / 距离视图：扁平排名列表 */
  private ranked(): Activity[] {
    const list: Activity[] = this.items.slice(0);
    const key = this.sortBy;
    list.sort((a: Activity, b: Activity) => {
      const av = key === 'tss' ? (a.trainingStressScore ?? -1) : (a.distanceMeters ?? -1);
      const bv = key === 'tss' ? (b.trainingStressScore ?? -1) : (b.distanceMeters ?? -1);
      return bv - av;
    });
    return list.slice(0, 30);
  }

  // ── @Builder（一律无参或传对象）──

  @Builder
  sortChip(label: string, value: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.sortBy === value ? $r('app.color.accent_on') : $r('app.color.text_secondary'))
      .backgroundColor(this.sortBy === value ? $r('app.color.accent') : $r('app.color.chip_background'))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .onClick(() => { this.sortBy = value; })
  }

  @Builder
  activityRow(a: Activity) {
    Row() {
      // 强度色条
      Column()
        .width(4)
        .height(44)
        .borderRadius(2)
        .backgroundColor(this.band(a).color)

      Column() {
        Row() {
          Text(Fmt.sportName(a.type)).fontSize(13).fontWeight(FontWeight.Medium)
          Text(' · ' + Fmt.shortTime(a.startTime)).fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Blank()
          Text(this.band(a).name).fontSize(10).fontColor(this.band(a).color)
        }
        .width('100%')
        Row() {
          Text(Fmt.km(a.distanceMeters) + ' · ' + Fmt.durationShort(a.durationSeconds))
            .fontSize(11).fontColor($r('app.color.text_secondary'))
          Blank()
          Text('TSS ' + Fmt.int(a.trainingStressScore) + ' · IF ' + Fmt.num1(this.intensityOf(a), ''))
            .fontSize(11).fontColor($r('app.color.accent'))
        }
        .width('100%').margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(12)
    .onClick(() => {
      router.pushUrl({ url: 'pages/ActivityDetailPage', params: { id: a.id } });
    })
  }

  @Builder
  groupHeader(g: WeekGroup) {
    Row() {
      Column() {
        Text(g.label).fontSize(13).fontWeight(FontWeight.Bold)
        Text(g.range).fontSize(9).fontColor($r('app.color.text_hint'))
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Text('TSS ' + Math.round(g.tss) + ' · ' + g.km.toFixed(1) + ' km · ' + g.items.length + ' 次')
        .fontSize(11).fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding({ top: 10, bottom: 6 })
  }

  build() {
    Refresh({ refreshing: $$this.refreshing }) {
      Column() {
        // 汇总条 + 排序
        Column() {
          Row() {
            Text('运动记录').fontSize(15).fontWeight(FontWeight.Bold)
            Blank()
            Text('共 ' + this.items.length + ' 条').fontSize(11).fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          Text(this.recentSummary()).fontSize(11).fontColor($r('app.color.text_secondary'))
            .width('100%').margin({ top: 4 })
          Row({ space: 8 }) {
            this.sortChip('日期', 'date')
            this.sortChip('TSS', 'tss')
            this.sortChip('距离', 'distance')
          }
          .width('100%').margin({ top: 8 })
        }
        .width('100%').padding({ bottom: 8 })

        if (this.staleNote.length > 0) {
          Text(this.staleNote).fontSize(11).fontColor($r('app.color.banner_text'))
            .width('100%').padding(8)
            .backgroundColor($r('app.color.banner_background')).borderRadius(8).margin({ bottom: 8 })
        }
        if (this.err.length > 0) {
          Column() {
            Text(this.err).fontSize(13).fontColor($r('app.color.danger'))
            Button('重试').fontSize(13).margin({ top: 8 }).onClick(() => { this.loadFirst(false); })
          }
          .padding(16).width('100%').backgroundColor($r('app.color.card_background_blur'))
          .border({ width: 1, color: $r('app.color.card_border_highlight') }).borderRadius(14)
        }
        if (this.loading && this.items.length === 0) {
          Row() {
            LoadingProgress().width(22).height(22)
            Text('读取中…').fontSize(13).fontColor($r('app.color.text_tertiary')).margin({ left: 8 })
          }
          .padding(16)
        }

        List({ space: 8 }) {
          if (this.sortBy === 'date') {
            ForEach(this.groups(), (g: WeekGroup) => {
              ListItem() {
                this.groupHeader(g)
              }
              ForEach(g.items, (a: Activity) => {
                ListItem() {
                  this.activityRow(a)
                }
              }, (a: Activity) => String(a.id))
            }, (g: WeekGroup) => g.weekStart)
          } else {
            ForEach(this.ranked(), (a: Activity) => {
              ListItem() {
                this.activityRow(a)
              }
            }, (a: Activity) => String(a.id))
          }
          if (this.hasMore && this.sortBy === 'date') {
            ListItem() {
              Row() {
                Text(this.loadingMore ? '加载中…' : '加载更多')
                  .fontSize(13).fontColor($r('app.color.accent'))
              }
              .width('100%').height(44).justifyContent(FlexAlign.Center)
              .onClick(() => { this.loadMore(); })
            }
          }
          ListItem() {
            Row().height(96)
          }
        }
        .layoutWeight(1)
        .onReachEnd(() => {
          // 滚动到底自动加载下一页（复用已有的 loadMore，失败不清空列表）
          this.loadMore();
        })
        .width('100%')
        .contentEndOffset(108)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .onRefreshing(() => {
      this.refreshing = true;
      this.loadFirst(true);
    })
    .width('100%')
    .height('100%')
  }
}
