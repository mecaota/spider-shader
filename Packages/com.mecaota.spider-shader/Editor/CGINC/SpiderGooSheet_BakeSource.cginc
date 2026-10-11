// =============================================================================
// ねばねばネット（粘液シート）の形だけを評価する Editor 専用コード。
// 吐いた糸（SpiderThreadTrail）の粘液モードの距離場 STG_GooField（束＋穴の空いた膜）を、
// 帯としてすき間なく並べる。格子にも網にもせず、吐いた糸の見た目をそのまま使う。
// 出力の形式は SGS_Pattern（距離・半径 / 向き・補助・光沢ノイズ）。
//
// 座標：
//   q        : メッシュ UV の中心を原点にした座標（UV 単位）
//   a / b    : 帯に沿った方向 / 横切る方向の座標（UV 単位、_SheetRotation の向き）
//   帯の中   : x = a × _SheetAlongScale（吐いた糸の uv.x と同じ「メートル」に揃える）
//              y = 帯の幅を 0..1 にした座標（吐いた糸の uv.y と同じ）
//   STG_GooField の距離は帯の幅が 1 なので、帯の幅（UV）を掛けて UV 単位へ戻す。
// 変更時は SpiderGooSheetBaker.GeneratorVersion も更新する。
// =============================================================================
#ifndef SPIDER_GOO_SHEET_BAKE_SOURCE_INCLUDED
#define SPIDER_GOO_SHEET_BAKE_SOURCE_INCLUDED
#include "UnityCG.cginc"
#include "Lighting.cginc"
#include "../../Runtime/CGINC/SpiderCocoon_Noise.cginc"
#include "../../Runtime/CGINC/SpiderCocoon_Common.cginc"
#include "../../Runtime/CGINC/SpiderCocoon_Thread.cginc"
#include "../../Runtime/CGINC/SpiderCocoon_Lighting.cginc"
#include "../../Runtime/CGINC/SpiderGoo_Shading.cginc"
#include "../../Runtime/CGINC/SpiderThread_Goo.cginc"

float _SheetBandWidth, _SheetRotation, _SheetAlongScale;
float _Seed;

struct SGS_Pattern
{
    float d;             // 負なら粘液の内側（メッシュ UV 単位）
    float radius;        // 断面の半径（同上）
    float2 direction;    // 塗り用の外向き（UV 平面内）
    float spokeness;     // 焼き込み画像の互換用（常に 1。濡れ具合は粘液感そのまま）
    float glossNoise;    // ハイライトの途切れ用
};

SGS_Pattern SGS_Evaluate(float2 uv)
{
    float2 q = uv - 0.5;
    float s, c;
    sincos(radians(_SheetRotation), s, c);
    float2 dirA = float2(c, s);               // 帯に沿った向き
    float2 dirB = float2(-s, c);              // 帯を横切る向き
    float a = dot(q, dirA);
    float b = dot(q, dirB);
    float band = max(_SheetBandWidth, 1e-4);
    float alongMul = max(_SheetAlongScale, 0.05);
    // 帯を横切る向きに、幅 band ですき間なく積む。帯ごとに模様の位相をずらす
    //（吐いた糸のトレイルごとの乱数と同じ考え方）。
    float i = floor(b / band);
    float y = b / band - i;
    float x = a * alongMul + i * 61.7 + _Seed * 7.1;
    float d, r;
    float2 g;
    // 帯の中の縦横比：x 1 あたりの長さ (1/alongMul UV) ÷ y 1 あたりの長さ (band UV)
    STG_GooField(float2(x, y), 1.0 / (alongMul * band), 0.0, d, g, r);

    SGS_Pattern p;
    p.d = d * band;
    p.radius = max(r * band, 1e-5);
    // 帯の座標（x=沿う, y=横切る）の向きを UV 平面へ戻す
    float2 gg = g.x * dirA + g.y * dirB;
    p.direction = (dot(gg, gg) > 1e-8) ? normalize(gg) : dirB;
    p.spokeness = 1.0;
    p.glossNoise = SC_ValueNoise1(x * _GooBeadFreq * 0.6 + 3.3);
    return p;
}
#endif
