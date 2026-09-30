/* =========================================================================
   跃动小子 (com.baixiangzs.ydxz1)  JS 注入 payload  v1.0
   引擎: Egret 5.x + eui + EgretNative(iOS)  —— JS 引擎为 JavaScriptCore
   注入方式: native 侧取得 JSGlobalContextRef 后 JSEvaluateScript 本脚本
   约定:
     window.__ydxz_cfg    = { kill, killTower, god, godTower, fastBox, fastBoxAnim,
                              autoBox, ad, speed }   <- native 侧写入
     window.__ydxz_state() -> JSON string           <- native 侧轮询读取
   ========================================================================= */
(function () {
  'use strict';
  if (window.__ydxz_booted) { return; }
  window.__ydxz_booted = 1;

  var F = {                       // 默认：全关
    kill: 0, killTower: 0, god: 0, godTower: 0,
    fastBox: 0, fastBoxAnim: 0, autoBox: 0, ad: 0, speed: 0
  };
  window.__ydxz_cfg = F;

  var G = null, S = null;
  var patched = {};
  var logs = [];

  function log(m) {
    logs.push(m);
    if (logs.length > 60) logs.shift();
    try { console.log('[YDXZ] ' + m); } catch (e) {}
  }
  function isFn(o, k) { try { return o && typeof o[k] === 'function'; } catch (e) { return false; } }

  /* 阵营: 1=己方  -1=敌方  0=未知 */
  function side(o) {
    if (!o) return 0;
    try { if (o.isEnemy === true) return -1; if (o.isEnemy === false) return 1; } catch (e) {}
    try { if (isFn(o, 'GetCamp')) { var c = o.GetCamp(); if (c === 1) return 1; if (c === 2) return -1; } } catch (e) {}
    try {
      var d = o.data;
      if (d) { if (d.isEnemy === true) return -1; if (d.isEnemy === false) return 1;
               if (d.camp === 1) return 1; if (d.camp === 2) return -1; }
    } catch (e) {}
    try { if (o.camp === 1) return 1; if (o.camp === 2) return -1; } catch (e) {}
    return 0;
  }
  function kv(v) { var n = Number(v) || 0; return n > 1 ? n : 999999999; }

  /* ---------------- 通用补丁 ---------------- */
  function wrapChangeHp(C, tag) {
    var P = C && C.prototype; if (!P || P.__ydxzHp || typeof P.changeHp !== 'function') return false;
    var o = P.changeHp;
    P.changeHp = function (v) {
      var s = side(this);
      if (F.god && s === 1 && v > 0) return;
      if (F.kill && s === -1 && v > 0) { arguments[0] = kv(F.kill); }
      return o.apply(this, arguments);
    };
    P.__ydxzHp = 1; log('changeHp:' + tag); return true;
  }
  function wrapChangeCurHp(C, tag) {
    var P = C && C.prototype; if (!P || P.__ydxzCurHp || typeof P.ChangeCurHp !== 'function') return false;
    var o = P.ChangeCurHp;
    P.ChangeCurHp = function (v) {
      var s = side(this);
      if (F.god && s === 1 && v < 0) return;
      if (F.kill && s === -1 && v < 0) { arguments[0] = -kv(F.kill); }
      return o.apply(this, arguments);
    };
    P.__ydxzCurHp = 1; log('ChangeCurHp:' + tag); return true;
  }
  function wrapGetHurt(C, tag) {
    var P = C && C.prototype; if (!P || P.__ydxzHurt || typeof P.GetHurt !== 'function') return false;
    var o = P.GetHurt;
    P.GetHurt = function (a) {
      var s = side(this);
      if (F.god && s === 1) return;
      if (F.kill && s === -1) {
        if (typeof a === 'number') { if (a > 0) arguments[0] = kv(F.kill); }
        else if (a && typeof a === 'object' && a.damage >= 0) { a.damage = kv(F.kill); }
      }
      return o.apply(this, arguments);
    };
    P.__ydxzHurt = 1; log('GetHurt:' + tag); return true;
  }
  function wrapSetNowHp(C, tag) {
    var P = C && C.prototype; if (!P || P.__ydxzSetHp || typeof P.SetNowHp !== 'function') return false;
    var o = P.SetNowHp;
    P.SetNowHp = function (v) {
      if (F.god && typeof v === 'number' && v < (this.nowHp || 0) && side(this) === 1) v = this.nowHp;
      return o.apply(this, arguments);
    };
    P.__ydxzSetHp = 1; return true;
  }

  var NAMES = [
    'FightEntity', 'BossFightEntity', 'HeroFightEntity', 'PartnerFightEntity',
    'BossCampWarFightEntity', 'BossLairFightEntity', 'WorldBossFightEntity',
    'BagFightEntity', 'LoopDuelEntity', 'CardWarBattleBaseCard', 'CardWarBattleBaseCardData',
    'CardWarBattleShip', 'CardWarBattleSetCard',
    'DefenceTowerBaseEntity', 'DefenceTowerSoldierEntity', 'DefenceTowerChariotEntity',
    'DefenceTowerHeroEntity', 'DefenceTowerEffBaseEntity', 'DefenceTowerEffFullEntity',
    'SynthTowerBaseEntity', 'SynthTowerDefenderEntity', 'STSimulatorBaseEntity',
    'STSimulatorMonsterEntity', 'MinionBaseEntity', 'MinionMonsterEntity',
    'SurviveEntityBase', 'SurviveHumanoidEntityBase', 'SurviveMovableEntityBase',
    'MatchmanEntityBase', 'MatchmanTrialEntityBase', 'HeroBaseEntity', 'BaseEntity'
  ];

  function patchEntities() {
    var w = window, i, C;
    for (i = 0; i < NAMES.length; i++) {
      C = w[NAMES[i]];
      if (!C || typeof C !== 'function' || !C.prototype) continue;
      wrapChangeHp(C, NAMES[i]); wrapChangeCurHp(C, NAMES[i]);
      wrapGetHurt(C, NAMES[i]); wrapSetNowHp(C, NAMES[i]);
    }
    /* 泛化兜底：window 上所有带 changeHp / ChangeCurHp 的原型 */
    var n = 0;
    for (var k in w) {
      try {
        var X = w[k];
        if (!X || typeof X !== 'function' || !X.prototype) continue;
        if (typeof X.prototype.changeHp === 'function' && !X.prototype.__ydxzHp) { wrapChangeHp(X, 's:' + k); n++; }
        if (typeof X.prototype.ChangeCurHp === 'function' && !X.prototype.__ydxzCurHp) { wrapChangeCurHp(X, 's:' + k); n++; }
      } catch (e) {}
    }
    patched.scan = n;
  }

  /* ---------------- 开箱加速 ---------------- */
  function patchTween() {
    var T = null; try { T = window.egret && window.egret.Tween; } catch (e) {}
    if (!T || !T.prototype || T.prototype.__ydxzT) return;
    var P = T.prototype, ow = P.wait, ot = P.to, osp = P.setPosition;
    function fast(d) {
      var m = Number(F.fastBox) || 0;
      return (m > 1 && typeof d === 'number' && d > 0) ? Math.max(1, Math.round(d / m)) : d;
    }
    if (typeof ow === 'function') P.wait = function (d, p) { try { arguments[0] = fast(d); } catch (e) {} return ow.apply(this, arguments); };
    if (typeof ot === 'function') P.to = function (pr, d, ez) { try { arguments[1] = fast(d); } catch (e) {} return ot.apply(this, arguments); };
    if (typeof osp === 'function') P.setPosition = function (v, m) {
      var sp = Number(F.speed) || 0;
      if (sp > 1 && typeof v === 'number' && v > 0) {
        var pv = this._prevPosition || 0, d = v - pv;
        if (d > 0 && d < 5000) arguments[0] = pv + d * sp;
      }
      return osp.apply(this, arguments);
    };
    P.__ydxzT = 1; log('Tween patched');
  }

  function patchSpine() {
    if (patched.spine) return;
    var hits = 0;
    function doP(P, tag) {
      if (!P || P.__ydxzSpine || typeof P.setAnimation !== 'function') return;
      var oa = P.setAnimation, owp = P.waitPlayEnd;
      P.setAnimation = function () {
        var m = Number(F.fastBoxAnim) || 0;
        if (m > 1) { try { this.timeScale = m; } catch (e) {} }
        return oa.apply(this, arguments);
      };
      if (typeof owp === 'function') {
        P.waitPlayEnd = function () {
          var m = Number(F.fastBoxAnim) || 0;
          if (m > 1) {
            var q = { then: function (cb) { try { cb && cb(); } catch (e) {} return q; },
                      catch: function () { return q; } };
            return q;
          }
          return owp.apply(this, arguments);
        };
      }
      P.__ydxzSpine = 1; hits++;
    }
    try {
      var sp = window.spine;
      if (sp && typeof sp === 'object') {
        for (var k in sp) { try { var C = sp[k]; if (C && C.prototype) doP(C.prototype, k); } catch (e) {} }
      }
    } catch (e) {}
    patched.spine = hits; log('Spine patched hits=' + hits);
  }

  function autoBoxTick() {
    if (!F.autoBox || !G || !G.OpenBoxModel) return;
    try {
      var ob = G.OpenBoxModel;
      if (isFn(ob, 'isUnlockBoxAutoOpen') && !ob.isUnlockBoxAutoOpen()) return;
      var m = isFn(ob, 'getAutoModel') ? ob.getAutoModel() : null;
      if (m && !m.isOpen) { m.isOpen = true; log('autoBox ON'); }
    } catch (e) {}
  }

  /* ---------------- 免广告 ---------------- */
  function patchAd() {
    var pf = null; try { pf = window.platform; } catch (e) {}
    if (!pf || !isFn(pf, 'showRewardAd') || pf.__ydxzAd) return;
    var o = pf.showRewardAd;
    pf.showRewardAd = function (t) {
      if (F.ad) {
        log('showRewardAd(' + t + ') fake OK');
        try { var r = o.call(pf, t); if (r && isFn(r, 'then')) return r; } catch (e) {}
        var q = { result: 2, msg: 'ydxz' };
        var p = { then: function (cb) { try { cb(q); } catch (e) {} return p; },
                  catch: function () { return p; } };
        return p;
      }
      return o.apply(pf, arguments);
    };
    pf.__ydxzAd = 1; log('platform.showRewardAd patched');
  }

  /* ---------------- 解析 / 状态 ---------------- */
  function resolve() {
    try { G = window.GameGlobal || null; } catch (e) { G = null; }
    try { S = G ? G.Config : null; } catch (e) { S = null; }
  }
  function c(o, k) { try { return isFn(o, k) ? o[k]() : null; } catch (e) { return 'err'; } }
  function g(o, k) { try { return o[k]; } catch (e) { return null; } }

  window.__ydxz_state = function () {
    var o = { cfg: { kill: F.kill, god: F.god, killTower: F.killTower, godTower: F.godTower,
                     fastBox: F.fastBox, fastBoxAnim: F.fastBoxAnim, autoBox: F.autoBox,
                     ad: F.ad, speed: F.speed },
              patched: patched, global: !!G, cfgTable: !!S };
    try {
      o.models = G ? { openbox: !!G.OpenBoxModel, fight: !!G.CkFightingModel,
                       dtBattle: !!G.DefenceTowerBattleDataManager,
                       dtEntity: !!G.DefenceTowerEntityManager } : null;
      if (G && G.CkFightingModel) o.fight = { isFighting: g(G.CkFightingModel, 'isFighting'),
                                              GameSpeed: g(G.CkFightingModel, 'GameSpeed'),
                                              NowRound: g(G.CkFightingModel, 'NowRound') };
      if (G && G.OpenBoxModel) o.box = { count: c(G.OpenBoxModel, 'getBoxCount'),
                                         lv: c(G.OpenBoxModel, 'getBoxLevel'),
                                         unlockAuto: c(G.OpenBoxModel, 'isUnlockBoxAutoOpen') };
      if (G && G.DefenceTowerEntityManager && isFn(G.DefenceTowerEntityManager, 'GetAllEntity')) {
        var a = G.DefenceTowerEntityManager.GetAllEntity(); o.dtEnt = a ? a.length : 0;
      }
      if (S) { o.tables = {}; ['KnightsSettingConfig','KnightsChestConfig','KnightsItemConfig',
        'KnightsMonsterConfig','KnightsChestRankConfig','TowerDefenseBaseConfig'].forEach(function (n) {
          o.tables[n] = !!S[n]; });
        try { o.fightSpeedUp = S.KnightsSettingConfig && S.KnightsSettingConfig.fightSpeedUp; } catch (e) {}
      }
    } catch (e) { o.err = String(e); }
    o.log = logs.slice(-25);
    try { return JSON.stringify(o); } catch (e) { return '{"err":"json"}'; }
  };

  /* ---------------- 主循环 ---------------- */
  var round = 0;
  function loop() {
    round++;
    try {
      if (window.__ydxz_cfg && window.__ydxz_cfg !== F) {
        var nf = window.__ydxz_cfg;
        for (var k in F) if (nf.hasOwnProperty(k)) F[k] = nf[k];
      }
    } catch (e) {}
    autoBoxTick();
    if (round % 2 === 0) { resolve(); }
    setTimeout(loop, 700);
  }

  /* ---------------- boot ---------------- */
  resolve();
  patchTween();
  patchSpine();
  patchAd();
  patchEntities();
  log('boot global=' + !!G);

  var tries = 0;
  var iv = setInterval(function () {
    tries++;
    resolve();
    patchEntities();
    patchTween(); patchSpine(); patchAd();
    if (G && G.OpenBoxModel && G.CkFightingModel) { clearInterval(iv); log('resolved @' + tries); }
    if (tries > 60) clearInterval(iv);
  }, 1500);

  loop();
})();
