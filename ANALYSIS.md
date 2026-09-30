# 跃动小子 逆向分析报告

IPA: `跃动小子_1.0_decrypted.ipa` 163501017 B
Bundle: `com.baixiangzs.ydxz1`
主二进制: `yuedongxiaozi` 17150160 B  arm64  MD5 见 `dylib` 同目录

---

## 1. 引擎判定（实证）

| 证据 | 结论 |
|---|---|
| 包内 `game/https/js/{egret,egret.web,eui,tween,assetsmanager}.min_*.js` | **Egret 5.x + eui** |
| `game/game.html` 带 `class="egret-player" data-entry-class="Main"` | Egret HTML5 入口 |
| `Frameworks` 无 Unity/Cocos | 非 Unity、非 Cocos |
| ObjC 类 `EgretNativeIOS / EgretNativePlayer_ios / EgretEAGLView / EgretRenderTicker / EgretRTRootView` | **EgretNative iOS 运行时** |
| 未定义符号含 `_JSGlobalContextCreateInGroup / _JSEvaluateScript / _JSStringCreateWithUTF8CString / _JSObjectMakeFunctionWithCallback` 等 **54 个 JavaScriptCore C API** | **JS 引擎 = JavaScriptCore（非 V8）** |
| `llvm-objdump --macho --load-commands` 中 **无 `LC_DYLD_CHAINED_FIXUPS (0x80000022)`**，只有 `DYLD_INFO_ONLY` | **传统 bind 表 → fishhook 重绑定可用** |

### 资源加载路径（二进制内字符串，实证）
```
game/https/js          -> https://js/
game/https/resource    -> https://resource/
root / files
```
JS 与资源均从 App 包内目录读取。

### native ↔ JS 桥（实证字符串）
```
__callNative__     __nativeCallback__   cmd
readFile  saveFile  writeFileString  writeFileBin  appendFileString
statFile  unlink  mkdir  rmdir  readDir  unzipFile  copyFile  renameFile
showRewardAd  setUserDefault  copyToClipboard  getIAPParam  IAPPay  sendGameEvent
getNativeRes  getSingleNativeRes  closeSplash  egretGameStarted
```
JS 侧封装在 `start.min_*.js`：
```js
A.callNativeCmd = function(n, i) {
  var r = {id: ++o.nativeCallId, cmd: n, params: i};
  o.nativeCallbackMap[r.id] = t;
  egret.ExternalInterface.call("__callNative__", JSON.stringify(r));
}
```
`egret.ExternalInterface` = `egret_native` 命名空间（EgretNative 原生模块）。

---

## 2. 游戏逻辑定位（`main.min_b273739a.js` 5,483,365 B）

JS 被压缩（局部变量名 a/b/c…），但 **类名 `__reflect()` 与 `h.Xxx=` 导出名完整保留**。

导出总入口在文件末尾：
```js
...}.call(window, window, window.egret, window.eui);
```
即所有 `h.Xxx = v` 都挂在 **`window.Xxx`** 上。

### 关键类与真实导出名（实证）

| 压缩名 | 导出名 | 用途 |
|---|---|---|
| `qLt` | `CkFightLogic` | 伤害/命中/暴击/连击/眩晕判定 |
| `dK` | `FightEntity` | 战斗表现实体（HP/护盾/伤害数字） |
| `mK` | `DefenceTowerBaseEntity` | 塔防实体基类（GetHurt / SetNowHp / GetCamp） |
| `v$` | `LoopDuelEntity` | 循环对决实体（ChangeCurHp / GetHurt） |
| `YLt` | `CkFightingModel` | 战斗总控（GameSpeed / NowRound / sendFight） |
| `c` | `OpenBoxModel` | 开箱数据模型（自动开箱 / 月卡 / 开箱 Rpc 10000） |
| `Hpe` | `OpenBoxAutoSettingModel` | 自动开箱设置（`isOpen` / `isQuickOpen`） |
| `EMt` | `BoxLayer` | 开箱界面（doOpenBox / doAuto） |
| `knt` | `BoxLayerOpenState` | 开箱动画状态（`playShakeAni` / `isQuickOpen`） |
| `Lnt` | `BoxLayerOpenedState` | 开箱结束状态（自动分解 / 自动出售） |
| `HI`/`dDt` | `GameGlobalImpl` | 全局模型容器（单例） |

`GameGlobal` 单例初始化（实证）：
```js
ae.initModule()   // GameGlobal.initModule()
```
内部把 `OpenBoxModel / CkFightingModel / DefenceTowerEntityManager / ...` 全部挂到该实例上。

---

## 3. 战斗架构（关键结论）

### 3.1 主战斗 = **服务端权威**
```js
CkFightingModel.sendFight = function(type, enemyid, ...) {
  var t = {type: type, enemyid: enemyid, index: e, gm: !!i};
  this.Rpc(10600, t, function (n) {   // n.steps 由服务器下发
     ...
     d.openFightingLayer(n, p);
  });
}
```
`openFightingLayer` 把服务端返回的 `myInfo / enemyInfo / steps` 交给战斗层 **纯回放**：
`FightEntity.changeHp()` 只是把 steps 里已算好的伤害画成飘字/血条。

⇒ **对 Rpc 10600 的战斗（冒险/爬塔/竞技场/PVP/Boss），客户端改伤害不会改变服务器结算结果。**

### 3.2 客户端权威的战斗（秒杀/无敌可真正生效）
以下玩法由客户端模拟步进、只把结果上报（`Rpc 11002 / 11006` 只传 `{type, duration}`）：
- **防御塔塔防**（`DefenceTowerEntityManager` / `DefenceTowerBattleUtils.CalculateDamage`）
  - 本地伤害公式：`getPureHurt = (atk - def) * (0.9 + 0.15*rand)`
  - 实体受伤入口：`DefenceTowerBaseEntity.GetHurt(info)`，`camp==1` 己方 / `camp==2` 敌方
- **合成塔 SynthTower / 小兵对战 Minion / 幸存者 Survive / 循环对决 LoopDuel**

⇒ 本插件的秒杀/无敌主要针对这一类。

---

## 4. 快速开箱（可行）

开箱请求（实证）：
```js
t = {count: Math.min(this._openMulCount, OpenBoxModel.getItemCountById(104e5))};
OpenBoxModel.Rpc(10000, t, function (n) { ... });       // 请求开箱
```
动画层：
- `BoxLayerOpenState.playShakeAni` → `spine.setAnimation(0,"a_"+n,!1).waitPlayEnd()`
- 每个动画步骤都是 `x.Tween.get(...).wait(ms/GameSpeed)`
- 快速开箱标志 `isQuickOpen` 把 2→11 级抖动动画直接跳到 `a_n`

**加速手段（本插件实现）**：
1. 包装 `egret.Tween.prototype.wait / to`，把时长按倍率缩小（不影响判定逻辑）
2. 包装 Spine 动画句柄的 `waitPlayEnd`，倍率 >1 时立即 resolve（跳过播放等待）
3. 自动开箱：`OpenBoxAutoSettingModel.isOpen = true`（需等级/月卡解锁条件成立）

⚠️ 开箱结果由 **服务端 Rpc 10000 下发**，掉率不可改。

---

## 5. 免广告（JS 侧）

广告入口（实证，`OpenBoxModel.showRewardAd`）：
```js
showRewardAd = function (n, cb) {
  if (OpenBoxModel.getMonthCardSuperDay() > 0) { cb(true); return; }
  if (!AppInfo.supportAd || Date.now() - this.lastShowAdTime < 500) { cb(false); return; }
  this.lastShowAdTime = Date.now();
  platform.showRewardAd(n).then(function (t) {
    var e = 1 == t.result ? 2 : (0 == t.result ? 1 : 0);   // result==1 才算看完
    a.Rpc(102, {type: n, result: e, msg: t.msg, agentId: AppInfo.AgentID});
    cb(t.result);
  });
}
```
本插件包装 `platform.showRewardAd` 直接 resolve `{result: 1}`（JS 侧自动按 result==1 走上报链）。

---

## 6. 注入链（本 dylib 实现）

```
1) fishhook 重绑定 JSGlobalContextCreateInGroup / JSEvaluateScript
     → 捕获游戏 JS 的 JSGlobalContextRef
2) JSEvaluateScript 注入 ydxz_inject.js（CI 内嵌为 C 字符串）
3) 面板开关 → 每秒写入 JS 的 window.__ydxz_cfg
4) 每秒读取 window.__ydxz_state() 回显面板状态
```

⚠️ 侧载环境无 CydiaSubstrate —— 本 dylib **不链接 substrate**，只用 fishhook + objc runtime。

---

## 7. 文件

```
YDXZTweak.m                     dylib 主源
ydxz_inject.js                  注入 payload（JS 全局作用域）
avatar.b64                      悬浮球头像
fishhook.c / fishhook.h         Facebook fishhook（支持传统 bind 表）
control / .github/workflows/build.yml
```
