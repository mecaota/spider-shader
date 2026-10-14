#ifndef SPIDERGOO_SHADING_INCLUDED
#define SPIDERGOO_SHADING_INCLUDED

// ---------------------------------------------------------------------------
// SpiderGoo_Shading.cginc
// 粘液の塗り（SpiderThreadTrail / SpiderWeb / SpiderCocoon / SpiderCocoonDepthDecal で共通）。
//
// 形（距離場 d = 輪郭までの符号付き距離。負=粘液の中）は各シェーダーが作り、
// ここでは「その形を、ぬめっとした丸い粘液として塗る」部分だけを受け持つ。
//   1. STG_GooProfile   : 輪郭からの深さ q から、丸い断面の法線を作る
//   2. STG_GooBaseColor : トゥーン陰影（明部/影部の 2 色）＋シーン光
//   3. STG_GooFinish    : リム・ハイライトの筋・輪郭線・透け・アンチエイリアス
// 2 と 3 の間で呼び出し側が色を加工できる（糸の「透ける繊維」など）。
//
// 前提 include: SpiderCocoon_Noise → Common → Thread → Lighting（.shader 側）
// ---------------------------------------------------------------------------

// 粘液感・色・陰影・光沢（_GooAmount / _GooColor … / _GooGloss*）は「質感」として
// 4 シェーダーで共通の uniform。宣言は SpiderSilk_Look.cginc の 1 か所だけ
// （Common 経由で読み込み済み。ここでも明示しておく。ガードで二重にはならない）。
#include "SpiderSilk_Look.cginc"

// 2D -> 2D hash [0,1)（テクスチャ不要・決定論的）
float2 STG_Hash22(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.xx + p3.yz) * p3.zy);
}

// 2D value noise 0..1（格子点の乱数を滑らかに補間。継ぎ目の無いまだら模様）
float STG_ValueNoise2(float2 p)
{
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = STG_Hash22(i).x;
    float b = STG_Hash22(i + float2(1.0, 0.0)).x;
    float c = STG_Hash22(i + float2(0.0, 1.0)).x;
    float d = STG_Hash22(i + float2(1.0, 1.0)).x;
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// 片方の軸だけ周期的な 2D value noise 0..1。period.x / period.y が 0 より大きい
// 軸は、その値（整数）で格子を巡回させる＝円周の継ぎ目でも模様が連続する。
float STG_ValueNoise2Wrap(float2 p, float2 period)
{
    float2 i  = floor(p);
    float2 f  = p - i;
    float2 u  = f * f * (3.0 - 2.0 * f);
    float2 i1 = i + 1.0;
    if (period.x > 0.5) { i.x -= period.x * floor(i.x / period.x); i1.x -= period.x * floor(i1.x / period.x); }
    if (period.y > 0.5) { i.y -= period.y * floor(i.y / period.y); i1.y -= period.y * floor(i1.y / period.y); }
    float a = STG_Hash22(i).x;
    float b = STG_Hash22(float2(i1.x, i.y)).x;
    float c = STG_Hash22(float2(i.x, i1.y)).x;
    float d = STG_Hash22(i1).x;
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// 多項式 smooth-min（Inigo Quilez）。a,b の小さい方を取りつつ、k 以内では
// 丸く膨らませてつなぐ＝粘液が水かき状に融合した形になる。
// 出力 h は「a 側の重み」。勾配・半径などの付随量も同じ h で補間する。
// ※ lerp(b, a, h) の形で書くと、片方が「糸が無い」ことを表す巨大な値（1e6 等）の
//   とき b + (a-b) の桁落ちで小さい方の値が潰れる。min(a,b) から引く形なら
//   数学的に同じ値で桁落ちしない。
float STG_SMin(float a, float b, float k, out float h)
{
    k = max(k, 1e-5);
    h = saturate(0.5 + 0.5 * (b - a) / k);
    float m = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - m * m * k * 0.25;
}

// ライト方向。ライトが無いシーンでは _WorldSpaceLightPos0 が 0 になる
// （normalize で NaN）ので、真上から照らしたことにする。
float3 STG_GooLightDir()
{
    return (dot(_WorldSpaceLightPos0.xyz, _WorldSpaceLightPos0.xyz) > 1e-6)
         ? normalize(_WorldSpaceLightPos0.xyz) : float3(0.0, 1.0, 0.0);
}

struct STG_GooSurface
{
    float  q;      // 断面を横切る位置（0=束の中心, 1=輪郭）
    float  core;   // 断面の厚み（中心 1, 輪郭 0）
    float3 outW;   // 輪郭の外向き（ワールド）
    float3 Nt;     // 丸い断面の法線（ワールド）
};

// 丸い断面を作る。
//   d    : 距離場（負=粘液の中）   r : その場所の束の半径（d と同じ単位）
//   g    : 輪郭の外向き（x=T 方向, y=B 方向。正規化済み）
//   N    : 面の法線（視線側を向いたもの）  T, B : 面の接線（ワールド）
// 丸い棒の断面なら、法線は (横向き q, 正面 sqrt(1-q^2)) → 輪郭ほど横を向いて陰る。
STG_GooSurface STG_GooProfile(float d, float r, float2 g, float3 N, float3 T, float3 B)
{
    STG_GooSurface s;
    s.q    = saturate(1.0 + d / max(r, 1e-4));
    s.core = sqrt(saturate(1.0 - s.q * s.q));
    s.outW = normalize(T * g.x + B * g.y);
    s.Nt   = normalize(N * s.core + s.outW * s.q);
    return s;
}

// 輪郭の外向きをワールドのベクトルで直接渡す版（繭のように糸の向きが層ごとに違う場合）
STG_GooSurface STG_GooProfileW(float d, float r, float3 outW, float3 N)
{
    STG_GooSurface s;
    s.q    = saturate(1.0 + d / max(r, 1e-4));
    s.core = sqrt(saturate(1.0 - s.q * s.q));
    s.outW = outW;
    s.Nt   = normalize(N * s.core + s.outW * s.q);
    return s;
}

// トゥーン陰影（階調は共通の _ToonSteps / _ToonSmooth。1 段ならアニメ風の 2 色）
float3 STG_GooBaseColor(STG_GooSurface s, float3 N, float3 L)
{
    float  toon = SC_ToonRamp(dot(s.Nt, L) * 0.5 + 0.5 - _GooShade, _ToonSteps, _ToonSmooth);
    float3 col  = lerp(_GooShadowColor.rgb, _GooColor.rgb, toon);
    // シーン光: 0=完全発光（色そのまま）/ 1=ライトと環境光に完全に従う。
    // 「1.0 を基準に明暗を掛ける」形なので、明るいワールドでも色味が白飛びしにくい。
    float3 ambient = ShadeSH9(float4(N, 1.0)) + _AmbientBoost;
    float3 lit     = clamp(_LightColor0.rgb * toon + ambient, 0.25, 1.35);
    return col * lerp(float3(1.0, 1.0, 1.0), lit, _LightInfluence);
}

// 仕上げ（リム・ハイライト・輪郭線・透け・AA）。AA 幅を呼び出し側が渡す版。
// 戻り値は straight alpha。
//   col        : STG_GooBaseColor の結果（呼び出し側で加工済みでもよい）
//   extraAlpha : 追加で不透明にしたい量（糸の「透ける繊維」など。無ければ 0）
//   d          : 距離場（AA 用）
//   glossNoise : ハイライトの途切れ用ノイズ 0..1（糸に沿って変化する値）
//   detail     : 輪郭線・ハイライトの効き 0..1（数 px しかない細糸で 1 未満にする）
//   aaD        : d の 1px ぶんの変化量（AA 幅）
//   aaQ        : q の 1px ぶんの変化量
// ループの中で距離場を作るシェーダー（繭）は fwidth を使えないため、
// 解析的に求めた AA 幅をこちらへ渡す。
//   wet        : 濡れ具合 0..1（ツヤと透けの効き）。巣の縦糸（乾いた糸）と横糸（粘液）の
//                ように、1 つの距離場の中で場所ごとに濡れ具合が違うときに渡す
fixed4 STG_GooFinishAAWet(float3 col, float extraAlpha, STG_GooSurface s, float d,
                          float3 N, float3 V, float3 L, float glossNoise, float detail,
                          float aaD, float aaQ, float wet)
{
    wet = saturate(wet);

    // ---- リム（濡れた縁のツヤ。共通リム設定を断面法線で評価）----
    col += SC_RimLight(s.Nt, V);

    // ---- ハイライトの筋 ----
    // 丸い断面で反射が最も強い位置 = ハーフベクトル H を断面に投影した位置。
    // 物理的な位置に _GooGlossOffset で光源側への寄せを足し、アニメ風の
    // くっきりした帯（smoothstep の段）として描く。
    float3 H     = normalize(L + V);
    float  hN    = dot(H, N);
    float  hA    = dot(H, s.outW);
    float  peak  = hA / max(length(float2(hN, hA)), 1e-4);          // 外向き側の位置 -1..1
    float  lsd   = dot(L, s.outW);
    // 物理的な位置そのままだと、光が横から当たると筋が縁の輪郭線に潜って
    // 見えなくなる。断面の内側 55% までに縮めて、常に面の上に筋を残す。
    float  gw    = _GooGlossWidth;
    peak = clamp(peak + _GooGlossOffset * lsd, -1.0, 1.0) * 0.55;
    float  aaq   = aaQ + 1e-4;
    float  gloss = 1.0 - smoothstep(gw - aaq, gw + aaq, abs(s.q - peak));
    gloss *= smoothstep(_GooGlossBreak - 0.1, _GooGlossBreak + 0.1, glossNoise * 1.1);
    gloss *= _GooGloss * _GooGlossColor.a * detail * wet;
    col = lerp(col, _GooGlossColor.rgb, saturate(gloss));

    // ---- 輪郭線 ----
    float ol = smoothstep(1.0 - _GooOutline - aaq, 1.0 - _GooOutline + aaq, s.q)
             * step(1e-4, _GooOutline) * detail;
    col = lerp(col, _GooOutlineColor.rgb, ol * _GooOutlineColor.a);

    // ---- 不透明度 ----
    // 中心（厚いのに屈折で透けて見える所）ほど透け、縁（斜めに見る所）ほど
    // 濃くなる＝ゼリー/粘液らしい見え方。ハイライトと輪郭は不透明寄りに。
    float a = _GooOpacity * (1.0 - _GooClarity * wet * s.core);
    a = max(a, saturate(gloss) * _GooOpacity);
    a = lerp(a, max(a, _GooOutlineColor.a * _GooOpacity), ol);
    a = max(a, extraAlpha * _GooOpacity);

    // 輪郭のアンチエイリアス（1px 程度ぼかす）
    float aa = aaD + 1e-5;
    a *= 1.0 - smoothstep(-aa, aa, d);

    return fixed4(col, a);
}

// STG_GooFinishAAWet が返す不透明度の上限（2026-10-14 軽量化。深度だけのパスや近接表示の早い棄却用）。
//   a = _GooOpacity × (1 − _GooClarity × 濡れ × 厚み)  … 濡れ・厚みは 0..1 なので |1 − _GooClarity| と 1 の大きい方以下
//   ツヤ（× _GooOpacity）・輪郭線（× _GooOutlineColor.a）・追加の不透明度（extraAlpha × _GooOpacity）で上がる分も含め、
//   最後の輪郭のぼかし（0..1 倍）で下がるだけなので、|_GooOpacity| × 下の max を超えない。
//   extraMax: 呼び出し側が渡す extraAlpha の上限（使わないなら 0）
float STG_GooAlphaCeiling(float extraMax)
{
    return abs(_GooOpacity) * max(max(1.0, abs(1.0 - _GooClarity)),
                                  max(abs(_GooOutlineColor.a), abs(extraMax)));
}

// 濡れ具合は粘液感（_GooAmount）そのまま: ツヤ（ハイライト）と透けは「濡れている度合い」
// なので、粘液感を下げると一緒に弱まる
fixed4 STG_GooFinishAA(float3 col, float extraAlpha, STG_GooSurface s, float d,
                       float3 N, float3 V, float3 L, float glossNoise, float detail,
                       float aaD, float aaQ)
{
    return STG_GooFinishAAWet(col, extraAlpha, s, d, N, V, L, glossNoise, detail,
                              aaD, aaQ, _GooAmount);
}

// 仕上げ（fwidth で AA 幅を求める版。濡れ具合を渡す版）
fixed4 STG_GooFinishWet(float3 col, float extraAlpha, STG_GooSurface s, float d,
                        float3 N, float3 V, float3 L, float glossNoise, float detail,
                        float aaMax, float wet)
{
    return STG_GooFinishAAWet(col, extraAlpha, s, d, N, V, L, glossNoise, detail,
                              min(fwidth(d) * 0.6, aaMax), fwidth(s.q), wet);
}

// 仕上げ（fwidth で AA 幅を求める版。ループの外で距離場を作るシェーダー用）
//   aaMax : AA 幅の上限（d と同じ単位）。距離場が不連続になり得る形（巣の縦糸の
//           選択が切り替わる所など）では糸の半径を渡し、fwidth の暴走で糸の外側
//           まで半透明ににじむのを防ぐ。不要なら十分大きい値を渡す
fixed4 STG_GooFinish(float3 col, float extraAlpha, STG_GooSurface s, float d,
                     float3 N, float3 V, float3 L, float glossNoise, float detail,
                     float aaMax)
{
    return STG_GooFinishAA(col, extraAlpha, s, d, N, V, L, glossNoise, detail,
                           min(fwidth(d) * 0.6, aaMax), fwidth(s.q));
}

#endif // SPIDERGOO_SHADING_INCLUDED
