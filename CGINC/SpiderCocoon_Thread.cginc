#ifndef SPIDERCOCOON_THREAD_INCLUDED
#define SPIDERCOCOON_THREAD_INCLUDED

// ---------------------------------------------------------------------------
// SpiderCocoon_Thread.cginc
// 円柱に「巻きついた」平行な糸を 1 レイヤー分だけ手続き的に評価する。
//
// 座標の前提（円柱メッシュ）:
//   uv.x = 軸方向（高さ）。0/1 は別の縁なので “巻かない”（シーム無し）
//   uv.y = 円周方向。0 と 1 が同じ稜線で繋がる（ここがシーム）
//
// 糸の位相:  t = uv.x * cx + uv.y * cy
//   - cy : 円周方向に巻く本数 W（整数）。uv.y はシームをまたぐので
//          整数でないと 0/1 境界に縦の継ぎ目が出る。
//   - cx : 軸方向のシアー（= tan(角度)）。uv.x はシーム無しなので
//          任意の連続値でOK＝角度を自由に傾けてもシームレス。
//   基準（cx=0）では糸は uv.x に沿って走り、円周(uv.y)に W 本並ぶ。
//   糸の中心は t が整数の位置。隙間は t が半整数付近。
//
// 出力:
//   戻り値    : alpha（隙間=0, 糸中心=1）
//   outSigned : 糸を横断する符号付き位置 -1..+1（-1=片縁, 0=中心, +1=反対縁）
//               → 各糸の法線を左右に曲げるのに使う（光源依存の陰影の核）
//   outRim    : 糸の縁ほど 1（ファイバー縁の影用）
// ---------------------------------------------------------------------------

// 太さ系入力の過敏化ゲイン（小さいスライダー値でもコントラストを強く出す）
#define SC_JITTER_GAIN 2.5
#define SC_FUZZ_GAIN   2.5

float SC_EvalFiber(float2 uv, float cx, float cy, float2 posOffset,
                   float seed, float thickMul, float2 aaUV,
                   out float outSigned, out float outRim)
{
    float2 p = uv + posOffset;                 // レイヤー位置オフセット

    // 糸の位相。cy（uv.y 係数）が整数の限り uv.y の 0/1 境界は連続（シームレス）。
    float t   = p.x * cx + p.y * cy;
    float idx = round(t);                      // 最近接の糸インデックス
    float s   = t - idx;                       // 符号付き距離 -0.5..+0.5
    float dt  = abs(s);

    // 太さ（t 空間での半幅）。周期は常に 1 なので _ThreadThickness=糸間隔に対する割合。
    float hw = _ThreadThickness * 0.5 * thickMul;

    // 太さの乱雑性: 糸ごとの差（Jitter）＋ 糸長方向のうねり（Fuzz）。
    //   円周シーム（uv.y 0/1）をまたいでも連続するよう、糸インデックスを巻き数 W=cy で巡回。
    float period = max(abs(cy), 1.0);
    float idxMod = fmod(idx, period);
    float jit    = SC_Hash11Signed(idxMod + seed);
    float fuzzN  = SC_ValueNoise1(p.x * _ThreadFuzzScale + (idxMod + seed) * 7.0); // 0..1
    float widthMul = (1.0 + _ThreadJitter * SC_JITTER_GAIN * jit)
                   * (1.0 + _ThreadFuzz   * SC_FUZZ_GAIN   * (fuzzN * 2.0 - 1.0));
    hw = max(hw * widthMul, 1e-4);

    // アンチエイリアス幅。t の偏微分 = (cx, cy) なので画面微分を解析的に合成。
    // （動的ループ内で fwidth を呼ばないため、aaUV はループ前に算出して渡す）
    // UV シーム（uv.y が 1→0 に飛ぶ三角形）で fwidth が暴走し縦線が出るため、
    // hw を上限にクランプして継ぎ目のにじみを抑える。
    float aa = (abs(cx) * aaUV.x + abs(cy) * aaUV.y) + 1e-5;
    aa = min(aa, hw);

    float alpha = 1.0 - smoothstep(hw - aa, hw + aa, dt);

    outSigned = clamp(s / hw, -1.0, 1.0);
    outRim    = saturate(dt / hw);
    return alpha;
}

#endif // SPIDERCOCOON_THREAD_INCLUDED
