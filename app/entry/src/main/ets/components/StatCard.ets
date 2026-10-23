/**
 * 统计卡片组件（大卡 / 小卡两档）
 *
 * 用法：调用方只传数据，不传任何布局参数。
 *
 *   StatCard({ title: '步数', value: '2341', unit: '步' })                        // 小卡（48%，两两成行）
 *   StatCard({ title: '训练负荷', value: '52', cardSize: StatCardSize.Big })          // 大卡（100%，独占一行）
 *   StatCard({ title: 'Body Battery', value: '100', suffix: ' 最高', accent: true, sub: '当日最低 18' })          // 小卡（强调色）
 *
 * 布局规则（不可在调用处覆盖）：
 *   - 宽：恒 100%（占满所在网格单元；两列由父级 Grid 的 columnsTemplate 决定）
 *   - 高：不设 height，由父级 Grid 的 GridItemAlignment.STRETCH 拉伸到行高
 *   - 间距：不设 margin，行距/列距由父级 Grid 的 rowsGap/columnsGap 统一控制
 *   - 禁止任何 height / minHeight —— 高度由同行最高卡决定
 *
 * 为什么封装：此前布局散在 StatusView 里，每次增删卡片都要改 width/margin，
 * 改错过 8 次（写死高度、Grid 撑爆、漏改 bbCard、批量替换改到别的 builder…）。
 * 现在这些属性只存在这一处，调用方无参数可调，也就无从改错。
 */

/** 卡片尺寸档位：只有两种，不允许出现第三种宽度 */
export enum StatCardSize {
  /** 小卡片：48%，两个一行 */
  Small = 0,
  /** 大卡片：100%，独占一整行 */
  Big = 1
}

/** 全局唯一间距值（卡片行距 + 卡片区与相邻段落间距） */
export const CARD_GAP: number = 10

@Component
export struct StatCard {
  /** 卡片标题（左上角小字） */
  @Prop title: string = ''
  /** 主数值（大字） */
  @Prop value: string = '--'
  /** 单位（数值后的小字） */
  @Prop unit: string = ''
  /** 数值后缀（如 Body Battery 的「 最高」） */
  @Prop suffix: string = ''
  /** 副标题行（恒占一行，无内容也占位，保证同排卡片等高基线） */
  @Prop sub: string = ''
  /** 尺寸档位 */
  @Prop cardSize: StatCardSize = StatCardSize.Small
  /** 数值是否用强调色（Body Battery 用） */
  @Prop accent: boolean = false

  build() {
    Column() {
      Text(this.title)
        .fontSize(this.cardSize === StatCardSize.Big ? 13 : 12)
        .fontColor($r('app.color.text_tertiary'))

      Row() {
        Text(this.value)
          .fontSize(this.cardSize === StatCardSize.Big ? 30 : 26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.accent ? $r('app.color.accent') : $r('app.color.text_primary'))
        if (this.unit.length > 0) {
          Text(this.unit)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ left: 3, bottom: 4 })
        }
        if (this.suffix.length > 0) {
          Text(this.suffix)
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: 4 })
        }
      }
      .alignItems(VerticalAlign.Bottom)

      // 恒占一行：无内容也渲染一个空格，避免同排卡片基线错位
      Text(this.sub.length > 0 ? this.sub : ' ')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .padding(14)
    .width('100%')
    .backgroundColor($r('app.color.card_background_blur'))
    .border({ width: 1, color: $r('app.color.card_border_highlight') })
    .borderRadius(14)
  }
}
