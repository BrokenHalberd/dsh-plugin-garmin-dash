import { MdBlock, MdSpan, parseMarkdown, parseInline } from './MarkdownParser';

/**
 * Markdown 消息渲染：标题 / 段落 / 列表 / 代码块 / 引用 / 表格 / 粗体 / 行内代码。
 * 颜色全部走资源色，自动适配深色模式。
 */
@Component
export struct MarkdownView {
  @Prop text: string = '';

  @Builder
  inlineSpans(spans: MdSpan[], size: number, color: ResourceColor) {
    Text() {
      ForEach(spans, (s: MdSpan) => {
        Span(s.text)
          .fontSize(size)
          .fontColor(s.code ? $r('app.color.accent') : color)
          .fontWeight(s.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontFamily(s.code ? 'monospace' : '')
      }, (s: MdSpan, i: number) => '' + i + s.text)
    }
    .width('100%')
    .wordBreak(WordBreak.BREAK_ALL)
    .constraintSize({ maxWidth: '100%' })
  }

  @Builder
  blockView(b: MdBlock) {
    if (b.kind === 'h1') {
      Text(b.text).fontSize(17).fontWeight(FontWeight.Bold).width('100%').wordBreak(WordBreak.BREAK_ALL).margin({ top: 6, bottom: 2 })
    } else if (b.kind === 'h2') {
      Text(b.text).fontSize(15).fontWeight(FontWeight.Bold).width('100%').wordBreak(WordBreak.BREAK_ALL).margin({ top: 6, bottom: 2 })
    } else if (b.kind === 'h3') {
      Text(b.text).fontSize(14).fontWeight(FontWeight.Medium).width('100%').margin({ top: 4, bottom: 1 })
    } else if (b.kind === 'li') {
      Row() {
        Text('•').fontSize(13).fontColor($r('app.color.text_tertiary')).width(12)
        this.inlineSpans(parseInline(b.text), 13, $r('app.color.text_primary'))
      }
      .width('100%').alignItems(VerticalAlign.Top).padding({ top: 1, bottom: 1 })
    } else if (b.kind === 'oli') {
      this.inlineSpans(parseInline(b.text), 13, $r('app.color.text_primary'))
    } else if (b.kind === 'quote') {
      Row() {
        Row().width(3).height('100%').backgroundColor($r('app.color.accent')).borderRadius(2)
        this.inlineSpans(parseInline(b.text), 12, $r('app.color.text_secondary'))
      }
      .width('100%').padding({ top: 3, bottom: 3 })
    } else if (b.kind === 'code') {
      Column() {
        Text(b.text).fontSize(11).fontFamily('monospace')
          .fontColor($r('app.color.text_primary'))
          .wordBreak(WordBreak.BREAK_ALL)
          .width('100%')
      }
      .width('100%').padding(8).margin({ top: 4, bottom: 4 })
      .backgroundColor($r('app.color.chip_background'))
      .borderRadius(8)
      .align(Alignment.TopStart)
    } else if (b.kind === 'table') {
      Column() {
        ForEach(b.rows, (row: string[], ri: number) => {
          Row() {
            ForEach(row, (cell: string) => {
              Text(cell)
                .fontSize(11)
                .fontWeight(ri === 0 ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(ri === 0 ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                .layoutWeight(1)
                .wordBreak(WordBreak.BREAK_ALL)
                .padding({ left: 6, right: 6, top: 5, bottom: 5 })
            }, (c: string, ci: number) => '' + ri + ci + c)
          }
          .width('100%')
          .backgroundColor(ri === 0 ? $r('app.color.chip_background') : Color.Transparent)
          .border({ width: { bottom: 0.5 }, color: $r('app.color.card_border_highlight') })
        }, (r: string[], ri: number) => '' + ri + r.join(','))
      }
      .width('100%').margin({ top: 4, bottom: 4 })
      .border({ width: 1, color: $r('app.color.card_border_highlight') })
      .borderRadius(8)
      .clip(true)
    } else if (b.kind === 'gap') {
      Row().height(5)
    } else {
      this.inlineSpans(parseInline(b.text), 13, $r('app.color.text_primary'))
    }
  }

  build() {
    Column() {
      ForEach(parseMarkdown(this.text), (b: MdBlock, i: number) => {
        this.blockView(b)
      }, (b: MdBlock, i: number) => '' + i + b.kind + b.text.length)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}