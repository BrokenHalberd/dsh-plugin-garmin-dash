# 部署注意（DSH 升级后必看）

## 1. 插件被静默跳过 → 所有数据接口 503

DSH Desktop 升级（如升到 0.2.1-rc.2）后，`dsh-plugin-garmin-connect` 若 peer 版本不满足，
`dsh-app-boot` 会**跳过该插件**，日志只出现在 stderr 文件里：

```
$DSH_HOME/logs/<profile>-web.log.err
skipping profile bundle "dsh-plugin-garmin-connect"
Plugin dsh-plugin-garmin-connect@0.1.13 is incompatible with dsh 0.2.1-rc.2
Exact-version exemption: not active
```

后果：后端仍在运行、`/api/health` 返回 200、鉴权也正常，但所有数据接口返回
`503 {"error":"upstream_unavailable"}`，App 显示"上游暂时不可用"。

**修复**：在 profile 目录写 `compatibility.json`（键=精确包名@版本，值=精确 DSH 版本数组）：

```json
{
  "dsh-plugin-garmin-connect@0.1.13": ["0.2.1-rc.2"]
}
```

路径：`~/.dsh/profiles/<profile>/compatibility.json`，写完重启后端即可。

## 2. webserver 不允许监听 0.0.0.0

新版 host-webserver 拒绝通配地址：

```
host "0.0.0.0" is an unspecified (wildcard) address, which is not supported
```

改了 `cordis.patch.yml` 的 host 为具体 IP 后，回环（127.0.0.1）不再监听，
而 `bin/mint-pair-code.mjs` 要求回环可达 —— 两者冲突。
**正解**：host 绑 `127.0.0.1`，手机通过中转域名访问。

## 3. 配对码生成

不要自己拼接口，用插件自带：

```bash
node <profile>/node_modules/dsh-plugin-garmin-dash/bin/mint-pair-code.mjs
```

输出配对码、10 分钟有效期与完整配对链接。二维码可用 DSH 自带 qrcode 本地渲染：

```bash
node -e "require('<DSH>/resources/app/node_modules/qrcode').toFile('qr.png','<link>',{width:640,margin:2})"
```

配对接口请求体字段是 **pairCode**（不是 code）：
`POST /garmin-dash/api/pair {"pairCode":"XXXXXXXX"}` → `{"deviceKey":"...","deviceId":"..."}`

## 4. 聚合接口

`GET /garmin-dash/api/bundle?days=30&date=YYYY-MM-DD` 一次返回
trend / summary / hrv / hrvRange / bodyBattery / activities，内部 `Promise.all` 并行，
任一段失败只记入 `partial` 数组，整体仍 200。App 首屏、定时刷新、重试、切日期全部只发这一条请求。
