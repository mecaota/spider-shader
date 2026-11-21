#ifndef SPIDERCOCOON_SHEET_INCLUDED
#define SPIDERCOCOON_SHEET_INCLUDED

// ---------------------------------------------------------------------------
// SpiderCocoon_Sheet.cginc
// 全身の繭（CocoonDecal の体表 glue / 全身の殻）を
// 「蜘蛛の巣ドレープ」（mecaota/SpiderWebDrape）風の見た目で塗る部分。
// _SurfaceStyle = 1（シェーダーキーワード SC_SURFACE_NET が ON）のときだけ使う
// （0 なら従来の繭の帯。そちらは一切変わらない）。
//
// ■ 蜘蛛の巣ドレープの見た目とは
//   蜘蛛糸（SpiderSilk）の粘液モードと同じ「数本の太い粘液の束＋その間に
//   張った穴だらけの膜」の帯を、横にすき間なく並べたもの。帯はすべて同じ向き
//   （平行）に走り、交差しない。2 枚目の膜だけ少し（_SheetLayerTwist 度）回して重ねる。
//
// ■ なぜ焼き込み画像ではなく、その場で計算（解析的に評価）するのか
//   蜘蛛の巣ドレープ本体は Editor で 1 枚の画像に焼いた模様を読む。その画像は
//   「1 m 四方の 1 枚ぶん」しかなく、体に巻くと繰り返しの継ぎ目が出る。
//   ここでは同じ距離場 STG_GooField（SpiderThread_Goo.cginc）をピクセルごとに
//   直接呼ぶので、継ぎ目の無い模様がどこまでも続く（代わりに少し重い）。
//
// ■ 単位はメートル
//   繭の箱のローカル座標（円筒: 半径 0.5、高さ -0.5..0.5）を、
//     円周方向 a = 角度 × (軸からの距離 × 箱の幅 m)   … 体の周りを回る長さ
//     軸方向   h = 高さ × 箱の高さ m
//   のメートル座標に直してから模様を評価する。蜘蛛の巣ドレープは「メッシュ UV 1 = 1 m」
//   なので、_SheetBandWidth などはネットの UV の値をそのまま入れれば同じ大きさになる。
//
// ■ 継ぎ目
//   角度は箱の -X 側（ふつうは背中）で -180°→+180° に飛ぶので、そこだけ模様が
//   切り替わる。AA（ぼかし幅）は継ぎ目で暴走しないよう、半周ずらした座標の微分と
//   小さい方を使う（繭の帯と同じ対策）。
//   1 周の長さ（2π × 軸からの距離）は帯のくり返しの整数倍ではないので、継ぎ目の左右で絵が合わない。
//   _SheetSeamBlend > 0 の時（外殻の 2 パスだけ。下の SCS_SeamlessPass）は、継ぎ目そのものが無い
//   「らせんの巻き方」で塗る（SCS_SheetLayersHelix）:
//     - 帯を「1 周でちょうど N 本ぶん上がるらせん」にする。N は層ごとの整数で、基準の太さ
//       SCS_HELIX_REF_RADIUS（軸からの距離）で元の向き _SheetRotation（+層の回転）に一番近い本数に丸める。
//     - 帯の番号の座標 v = 高さ / 帯の縦の間隔 − N × (角度 / 2π)。角度が 1 周飛ぶと v がちょうど N 飛ぶので、
//       同じ帯の続きになる。帯に沿う座標は「1 周の長さ × (角度 / 2π + 帯の番号 / N)」で、1 周飛んでも同じ値。
//     - 帯の縦の間隔（太さ）は元と同じ。傾きは丸めで少し変わり、軸に近い所（首・頭のてっぺん）ほど立つ。
//   _SheetSeamBlend = 0（網つきの全身の繭・既定）とほかのパスは、前と同じ計算・同じ値。
//   名前の _SheetSeamBlend は第1版（継ぎ目の左右を混ぜる角度）の名残で、今は 0 より大きいか（入/切）だけを見る
//   （ドライバーは前の約束どおり 25 を入れればよい）。
//
// 前提 include: SpiderCocoon_Noise → Common → Thread → Lighting → Compose
//               → SpiderGoo_Shading → SpiderCocoon_Goo（_WindEnable 等）→ 本ファイル
// 呼び出し: SpiderCocoon_Goo.cginc の SC_ShadeCocoonAtExUnclippedStop
//           （.shader 側で SC_COCOON_SHEET_STYLE を define し、キーワード SC_SURFACE_NET が ON のときだけ）
// ---------------------------------------------------------------------------

// ---- 蜘蛛の巣ドレープの帯の並べ方 ----
float _SheetBandWidth;     // 帯の幅 m（ネットの _SheetBandWidth。UV 1 = 1 m）
float _SheetRotation;      // 帯の向き 度（0 = 体の周りを水平に回る / 90 = 縦に走る）
float _SheetAlongScale;    // 帯に沿った方向の模様の細かさ（ネットの _SheetAlongScale）
float _SheetSeed;          // 模様の乱数シード
float _SheetLayers;        // 重ねる膜の枚数 1..3
float _SheetLayerTwist;    // 層ごとの回転 度
float _SheetLayerShift;    // 2 枚目以降の模様のずれ m
float _SheetLayerOpacity;  // 外側の層ごとの不透明度倍率
float _SheetSeamBlend;     // 0 より大きい = 継ぎ目の無いらせんの巻き方（上の「継ぎ目」。値の大きさは見ない）
// らせんの巻き方を入れるパスか。部位の繭は外殻のパス（GROUP_SHELL / GROUP_SHELL_DEPTH）だけで描くので、
// その 2 パスの画素シェーダーが最初に true にする。ほかのパスは false のままで、コンパイラがらせんの処理ごと消す
// （全パスに展開すると、シェーダーが大きくなるため）。
static bool SCS_SeamlessPass = false;
// らせんの本数を丸める基準の太さ（軸からの距離 m。胴くらい）。ここで元の傾きに一番近くなるよう本数を決める
#define SCS_HELIX_REF_RADIUS 0.15
// らせんの巻き方での膜の張り方（第4版）。格子に丸い穴を空ける膜（STG_GooField）はやめ、
// 束の輪郭を「膜の量」に応じた厚みだけ太らせて、束どうしの間を埋める膜にする。
//   帯はほぼ水平なので、格子の穴は帯の向きに一列（約 13 cm おき）に並ぶ。束の間が少し開いた所で
//   隣り合う 2 つだけが見え、同じ高さに並ぶ「目」になった（第14往復は丸い穴、第16往復は横長の切れ目）。
//   太らせる膜なら穴は束の間の細長いすき間にしかならず、帯のすき間と同じ形になる。
// SCS_HELIX_WEB_FILL: 膜が一番多い所での厚み（帯の幅 = 1）。束の間の狭いすき間はここで埋まる。
// SCS_HELIX_WEB_COVER0: 膜の量（cover）がこれ以下の所は膜なし（束だけ）。
#define SCS_HELIX_WEB_FILL   0.06
#define SCS_HELIX_WEB_COVER0 0.3
// 玉（くびれ）の強さ・細かさ。デカールには繭の意味の _GooBeads / _GooBeadFreq が
// 既にあるので、蜘蛛の巣ドレープ用は別名にする（下の #define で付け替える）。
float _SheetBeads;
float _SheetBeadFreq;

// 蜘蛛糸の距離場（STG_GooField）を、玉の 2 つだけ別名の uniform で読み込む。
// SpiderThread_Goo.cginc は _GooBeads / _GooBeadFreq を「使う」だけで宣言はしないので、
// 読み込む間だけ名前を付け替えれば、繭の _GooBeads（0.15 / 14）と衝突しない。
// 束・膜の設定（_GooStrands / _GooWidth / … / _GooWebHole）はこの include で宣言される。
#define _GooBeads    _SheetBeads
#define _GooBeadFreq _SheetBeadFreq
#include "SpiderThread_Goo.cginc"
#undef _GooBeads
#undef _GooBeadFreq

#define SCS_MAX_LAYERS 3

// 2D 回転（度）
float2 SCS_Rotate(float2 p, float deg)
{
    float s, c;
    sincos(radians(deg), s, c);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// 帯の層を重ねた色を、メートル座標 m（a = 体の周りを回る長さ, h = 軸方向の高さ）で求める。
// 戻り値 accRGB は事前乗算の蓄積色、accA は不透明度（巻きアニメの windFade は掛けない）。
// 画面微分（fwidth / ddx / ddy）もテクスチャも使わないので、分岐の中で呼んでもよい。
// AA 幅 aaM は呼び出し側が分岐の外で求めて渡す。中身は第12往復までの SC_ShadeSheetAtExUnclippedStop のループそのまま。
void SCS_SheetLayers(float2 m, float aaM, float3 N, float3 Tc, float3 axisDir, float3 L, float3 V, float wet,
                     float band, float alongMul, int layers, float edge01,
                     bool earlyStop, float stopAlpha, float windFade,
                     out float3 accRGB, out float accA)
{
    accRGB = 0.0;      // 事前乗算の蓄積色（内側→外側の over 合成）
    accA   = 0.0;

    // 層の数はマテリアル定数なので全ピクセル同じ回数（微分は呼び出し側で確定済み）
    [loop]
    for (int li = 0; li < SCS_MAX_LAYERS; ++li)
    {
        if (li >= layers) break;
        float lf = (float)li;

        // 層ごとに少し回し、2 枚目以降は乱数の向きへ少しずらす（ネットと同じ）
        float  rot = _SheetRotation + lf * _SheetLayerTwist;
        float2 q   = m;
        if (li > 0)
        {
            float dirR = SC_Hash11(_SheetSeed * 37.219 + lf * 53.17 + 11.3) * UNITY_TWO_PI;
            q += float2(cos(dirR), sin(dirR)) * _SheetLayerShift;
        }
        // 帯の座標: a = 帯に沿う向き, b = 帯を横切る向き（どちらも m）
        float2 ab = SCS_Rotate(q, -rot);

        // 帯を横切る向きに、幅 band ですき間なく積む（ネットの SGS_Evaluate と同じ）
        float bi = floor(ab.y / band);
        float y  = ab.y / band - bi;
        float x  = ab.x * alongMul + bi * 61.7 + _SheetSeed * 7.1 + lf * 23.9;
        float  d, r;
        float2 g;
        STG_GooField(float2(x, y), 1.0 / (alongMul * band), 0.0, d, g, r);
        float dM = d * band;                     // メートルへ戻す
        float rM = max(r * band, 1e-5);

        // ほつれ（巻きの端）: 繭の帯と同じく、帯ごとに違う位置で細って途切れる
        float cut  = SC_Hash11(bi * 1.73 + lf * 19.0 + 5.0) * 0.7;
        float fray = smoothstep(cut, cut + 0.3, edge01);
        dM += rM * (1.0 - fray);

        // 帯に沿う向き / 横切る向き（ワールド）
        float  s, c;
        sincos(radians(rot), s, c);
        float3 Ta = Tc * c + axisDir * s;
        float3 Tb = -Tc * s + axisDir * c;

        STG_GooSurface gs = STG_GooProfile(dM, rM, g, N, Ta, Tb);
        float3 col  = STG_GooBaseColor(gs, N, L);
        float  aaQ  = min(aaM / rM, 1.0);
        float  detail = saturate(1.6 - aaQ * 2.5);          // 数 px しかない束では輪郭線・ツヤを弱める
        float  gn   = SC_ValueNoise1(x * _SheetBeadFreq * 0.6 + 3.3);
        fixed4 cl   = STG_GooFinishAAWet(col, 0.0, gs, dM, N, V, L, gn, detail,
                                         min(aaM * 0.6, rM), aaQ, wet);
        cl.a *= fray;
        if (li > 0) cl.a *= pow(saturate(_SheetLayerOpacity), lf);

        accRGB = cl.rgb * cl.a + accRGB * (1.0 - cl.a);
        accA   = cl.a          + accA   * (1.0 - cl.a);

        // 深度パス: もう芯（stopAlpha 以上）と決まったので、残りの層は見ない
        if (earlyStop && accA * windFade >= stopAlpha) break;
    }
}

// らせんの巻き方用の粘液の距離場（STG_GooField の代わり。尻尾度 tailT = 0 のときと同じ束を描く）。
// 束の部分は STG_GooField と同じ式。違いは束の間の膜だけ:
//   STG_GooField は膜に格子の丸い穴を空けるが、ここでは束の輪郭を厚み m だけ太らせた形を膜にする
//   （m は膜の量 cover が SCS_HELIX_WEB_COVER0 を超えた所から直線で増える。上の SCS_HELIX_WEB_FILL の説明）。穴が格子に並ばないので、
//   同じ高さに小さな穴が 2 つ並ぶ「目」はできない。開く所は、束どうしが離れて m より広く空いた細長いすき間だけ。
// 出力の意味は STG_GooField と同じ（dist は帯の幅単位の符号付き距離、grad は外向き、radius は束の半径）。
void SCS_HelixGooField(float2 uv, out float dist, out float2 grad, out float radius)
{
    float x = uv.x;
    float y = uv.y;

    int   n       = (int)clamp(round(_GooStrands), 1.0, (float)STG_MAX_STRANDS);
    float nf      = (float)n;
    float amt     = saturate(_GooAmount);
    float beadAmt = saturate(_SheetBeads * amt);
    float baseR   = _GooWidth * 0.5;
    float k       = _GooMerge * amt * 0.5;
    float webAmt  = _GooWeb * amt;

    float cLo = 1.0, cHi = 0.0;
    dist   = 1e3;
    grad   = float2(0.0, 1.0);
    radius = baseR;

    // ---- 束（STG_GooField と同じ）----
    [unroll]
    for (int i = 0; i < STG_MAX_STRANDS; ++i)
    {
        if (i < n)   // n はマテリアル定数なので全ピクセルで同じ分岐
        {
            float fi   = (float)i;
            float seed = fi * 37.17 + 5.3;

            float slot = (n > 1) ? (fi / (nf - 1.0)) * 2.0 - 1.0 : 0.0;
            float c    = 0.5 + slot * _GooSpread * 0.5;
            c += _GooWobble * STG_Noise2(x * _GooWobbleFreq, seed);

            float jit  = 1.0 + 0.3 * SC_Hash11Signed(seed + 0.5);
            float bn   = SC_ValueNoise1((x - _Time.y * _GooFlow) * _SheetBeadFreq + seed * 3.1);
            bn = smoothstep(0.2, 0.85, bn);
            float r    = baseR * jit * lerp(1.0 - 0.7 * beadAmt, 1.0 + 0.55 * beadAmt, bn);
            r = max(r, 1e-4);

            c = clamp(c, r + 0.03, 1.0 - r - 0.03);
            cLo = min(cLo, c);
            cHi = max(cHi, c);

            float  di = abs(y - c) - r;
            float2 gi = float2(0.0, (y >= c) ? 1.0 : -1.0);
            float  h;
            dist   = STG_SMin(dist, di, k, h);
            grad   = lerp(gi, grad, h);
            radius = lerp(r, radius, h);
        }
    }

    // ---- 束の間の膜（束を厚み m だけ太らせた形。外側の束より外へは張らない）----
    if (n > 1 && webAmt > 0.001)
    {
        // 膜の量は STG_GooField と同じまだら。少ない所は膜が細り、束だけになる
        float cover = saturate((SC_ValueNoise1(x * _GooWobbleFreq * 0.9 + 51.7)
                                - (1.0 - webAmt)) * 3.0 + webAmt * 0.5);
        float m     = SCS_HELIX_WEB_FILL * saturate((cover - SCS_HELIX_WEB_COVER0) / (1.0 - SCS_HELIX_WEB_COVER0));
        float sheet = dist - m;                                   // 束を太らせた距離（帯の幅単位）
        float band  = max(cLo - y, y - cHi);                      // 束の間の範囲だけに張る
        float dm    = max(sheet, band);
        // 束との合わせは滑らかな最小（STG_SMin）にしない。滑らかな最小だと m = 0 でも束が (k−m)²/(4k) 太り、
        // 外側の束の内側に陰影の向きが逆になる筋も出るため。膜は束を太らせた形なので、
        // 外向き grad と半径 radius は束のものをそのまま使う（格子の穴の目安 _GooWebRows はもう使わない）
        dist = min(dist, dm);
    }

    float gl = length(grad);
    grad = (gl > 1e-4) ? grad / gl : float2(0.0, 1.0);
}

// 継ぎ目の無い「らせんの巻き方」で、帯の層を重ねた色を求める（_SheetSeamBlend > 0 の外殻のパスだけ）。
// u = 角度 / 2π（-0.5..0.5。継ぎ目で 1 飛ぶ）、h = 軸方向の高さ m、rhoM = 軸からの距離 m。
// 戻り値は SCS_SheetLayers と同じ（事前乗算の蓄積色と不透明度。windFade は掛けない）。
// 画面微分もテクスチャも使わない（AA 幅 aaM は呼び出し側が分岐の外で求めて渡す）。
// 1 周ずれた所（u ± 1）で同じ値になる理由:
//   v = h / dh − N u は N（整数）だけ変わる → 帯の番号 bi が N 変わり、帯の中の位置 y は同じ。
//   帯に沿う座標 x ∝ (u + bi / N) は (u + 1) + (bi − N) / N = u + bi / N で同じ。
//   ほつれ・ツヤの乱れは x の関数なので同じ。層のずれは u と h に足す定数なので同じ。
void SCS_SheetLayersHelix(float u, float h, float rhoM, float aaM, float3 N, float3 Tc, float3 axisDir,
                          float3 L, float3 V, float wet, float band, float alongMul, int layers, float edge01,
                          bool earlyStop, float stopAlpha, float windFade,
                          out float3 accRGB, out float accA)
{
    accRGB = 0.0;
    accA   = 0.0;

    float refC  = UNITY_TWO_PI * SCS_HELIX_REF_RADIUS;      // 基準の 1 周の長さ m
    float hereC = UNITY_TWO_PI * max(rhoM, 0.005);          // この点の 1 周の長さ m（軸の上で 0 にしない）
    // 面の上の勾配: 高さ h の勾配 = 体軸を面へ投影したもの（長さ 1 以下。頭のてっぺんの蓋の上では 0 に近い）、
    // 角度 u の勾配 = Tc / この点の 1 周の長さ（Tc は面に接し、体軸と直交する）
    float3 Th = axisDir - N * dot(N, axisDir);

    [loop]
    for (int li = 0; li < SCS_MAX_LAYERS; ++li)
    {
        if (li >= layers) break;
        float lf = (float)li;

        // 元の向き（度）と、帯の縦の間隔 dh（元の帯を高さの向きに測った幅。帯の太さはこれで元と同じ）
        // 帯の向きは 180° 周期なので -90..90 へ畳んでから ±80 に抑える（170° は -10° として扱う。畳まないと 80° の縦の帯に化ける）
        float rot = _SheetRotation + lf * _SheetLayerTwist;
        rot -= 180.0 * round(rot / 180.0);
        rot = clamp(rot, -80.0, 80.0);
        float sr, cr;
        sincos(radians(rot), sr, cr);
        float dh = band / max(cr, 0.17);
        // 1 周で上がる本数 N（基準の太さで元の傾きに一番近い整数。0 だと輪になって継ぎ目が残るので、向きの側へ 1 以上）
        float nExact = refC * sr / band;
        float nTurn  = round(nExact);
        nTurn = (abs(nTurn) < 1.0) ? ((nExact < 0.0) ? -1.0 : 1.0) : nTurn;

        // 2 枚目以降のずれ（元は m 単位の 2D のずれ）: 円周の向きは基準の 1 周で角度へ直し、高さはそのまま
        float uq = u, hq = h;
        if (li > 0)
        {
            float dirR = SC_Hash11(_SheetSeed * 37.219 + lf * 53.17 + 11.3) * UNITY_TWO_PI;
            uq += cos(dirR) * _SheetLayerShift / refC;
            hq += sin(dirR) * _SheetLayerShift;
        }

        // 帯の番号の座標と、帯に沿う座標（x の 1 周ぶんは基準の太さで決めた定数。上の説明）
        float v  = hq / dh - nTurn * uq;
        float bi = floor(v);
        float y  = v - bi;
        float turnLen = sqrt(refC * refC + nTurn * nTurn * dh * dh);    // 基準の太さでの、帯に沿った 1 周の長さ m
        float x  = (uq + bi / nTurn) * turnLen * alongMul + _SheetSeed * 7.1 + lf * 23.9;

        // 帯を横切る向き = v の面の上の勾配（Th / dh − N·Tc / この点の 1 周）。Th と Tc は直交し、N ≠ 0 なので長さは 0 にならない。
        // 帯を直角に横切った幅 m = 勾配の長さの逆数（円筒では dh·cos(傾き)、頭のてっぺんの蓋の上では扇形の広い幅になる）
        float3 gradV    = Th / dh - Tc * (nTurn / hereC);
        float  gradLen  = max(length(gradV), 1e-4);
        float3 Tb       = gradV / gradLen;
        float3 Ta       = cross(N, Tb);                    // 帯に沿う向き（面に接し、Tb と直交）
        float  bandHere = 1.0 / gradLen;

        float  d, r;
        float2 g;
        // 膜に格子の穴を空けない距離場（上の SCS_HelixGooField。縦横比は穴の丸さにしか使わないので要らない）
        SCS_HelixGooField(float2(x, y), d, g, r);
        float dM = d * bandHere;                 // メートルへ戻す
        float rM = max(r * bandHere, 1e-5);

        // ほつれ: 帯に沿って滑らかに変わる位置で細る（帯の番号の乱数だと、継ぎ目で番号が N 飛んで値が変わるため）
        float cut  = SC_ValueNoise1(x * 0.37 + lf * 19.0 + 5.0) * 0.7;
        float fray = smoothstep(cut, cut + 0.3, edge01);
        dM += rM * (1.0 - fray);

        STG_GooSurface gs = STG_GooProfile(dM, rM, g, N, Ta, Tb);
        float3 col  = STG_GooBaseColor(gs, N, L);
        float  aaQ  = min(aaM / rM, 1.0);
        float  detail = saturate(1.6 - aaQ * 2.5);          // 数 px しかない束では輪郭線・ツヤを弱める
        float  gn   = SC_ValueNoise1(x * _SheetBeadFreq * 0.6 + 3.3);
        fixed4 cl   = STG_GooFinishAAWet(col, 0.0, gs, dM, N, V, L, gn, detail,
                                         min(aaM * 0.6, rM), aaQ, wet);
        cl.a *= fray;
        if (li > 0) cl.a *= pow(saturate(_SheetLayerOpacity), lf);

        accRGB = cl.rgb * cl.a + accRGB * (1.0 - cl.a);
        accA   = cl.a          + accA   * (1.0 - cl.a);

        // 深度パス: もう芯（stopAlpha 以上）と決まったので、残りの層は見ない
        if (earlyStop && accA * windFade >= stopAlpha) break;
    }
}

// ローカル点 localPos（繭の上の点）を、蜘蛛の巣ドレープ風に塗る。戻り値は straight alpha。
// 引数は SC_ShadeCocoonAtExUnclipped と同じ。隙間でも discard はしない
// （呼び出し側の SC_ShadeCocoonAtEx / 殻のパスが α で捨てる）。
// earlyStop / stopAlpha は深度パス用（SpiderCocoon_Goo.cginc の SC_CompositeGooUnclippedStop と同じ意味）。
// 最後に巻きアニメの windFade を掛けるので、途中の判定にも windFade を掛けて比べる。
fixed4 SC_ShadeSheetAtExUnclippedStop(float3 localPos, float3 worldPos, float3 N,
                                      float3 colX, float3 colY, float edge01,
                                      bool earlyStop, float stopAlpha)
{
    float boxW = length(colX);                 // 箱の幅 m（ローカル 1 あたり）
    float boxH = length(colY);                 // 箱の高さ m

    // ---- メートル座標（a = 体の周りを回る長さ, h = 軸方向の高さ）----
    float rhoM = length(localPos.xz) * boxW;
    float ang  = atan2(localPos.z, localPos.x);
    float angB = atan2(-localPos.z, -localPos.x);   // 半周ずらした角度（継ぎ目対策の微分用）
    float2 m   = float2(ang * rhoM, localPos.y * boxH);

    // 1px あたりのメートル（AA 幅）。継ぎ目で角度が飛ぶので、角度の微分だけ半周ずらした角度との小さい方を使い、
    // 軸からの距離 ρ が変わる面（肩・腰など）の分 |角度|×fwidth(ρ) を足す（a = 角度×ρ の微分）
    float aaA  = rhoM * min(fwidth(ang), fwidth(angB)) + abs(ang) * fwidth(rhoM);
    float aaM  = max(max(aaA, fwidth(m.y)), 1e-5);

    // ---- 陰影用の基底 ----
    float3 axisDir = normalize(colY);                       // 体軸（h が増える向き）
    float3 nt  = cross(N, axisDir);                         // 角度が増える向き（a が増える向き）
    float3 Tc  = (length(nt) > 1e-5) ? normalize(nt) : normalize(colX);
    float3 L   = STG_GooLightDir();
    float3 V   = normalize(_WorldSpaceCameraPos - worldPos);
    float  wet = saturate(_GooAmount);                      // ネットの焼き込みと同じ（濡れ = 粘液感）

    float band     = max(_SheetBandWidth, 1e-3);
    float alongMul = max(_SheetAlongScale, 0.05);
    int   layers   = (int)clamp(round(_SheetLayers), 1.0, (float)SCS_MAX_LAYERS);

    // 巻きアニメ（_WindEnable）: 帯のリボンではなく、下から上へ高さで現れる簡易版
    float windFade = 1.0;
    if (_WindEnable > 0.5 && _WindProgress < 0.9999)
    {
        float hM    = (localPos.y + 0.5) * boxH;            // 足元からの高さ m
        float progM = saturate(_WindProgress) * boxH;
        windFade = 1.0 - smoothstep(progM - 0.03, progM, hM);   // 3 cm のぼかし
    }

    float3 accRGB;            // 事前乗算の蓄積色（内側→外側の over 合成）
    float  accA;
    // 継ぎ目の無いらせんの巻き方（_SheetSeamBlend > 0 の外殻のパスだけ。上の「継ぎ目」）。
    // 分岐の中は画面微分を使わない（aaM は上で求めた）ので、分岐で 1 px の線は出ない
    [branch] if (SCS_SeamlessPass && _SheetSeamBlend > 0.0)
    {
        SCS_SheetLayersHelix(ang / UNITY_TWO_PI, m.y, rhoM, aaM, N, Tc, axisDir, L, V, wet, band, alongMul,
                             layers, edge01, earlyStop, stopAlpha, windFade, accRGB, accA);
    }
    else
    {
        // 前と同じ巻き方（網つきの全身の繭・ほかのパス。前と同じ計算・同じ値）
        SCS_SheetLayers(m, aaM, N, Tc, axisDir, L, V, wet, band, alongMul, layers, edge01,
                        earlyStop, stopAlpha, windFade, accRGB, accA);
    }

    // Blend SrcAlpha で α が再度掛かるため割り戻す（繭の帯と同じ）。巻きアニメは最後に α だけ下げる
    return fixed4(accRGB / max(accA, 1e-4), accA * windFade);
}

fixed4 SC_ShadeSheetAtExUnclipped(float3 localPos, float3 worldPos, float3 N,
                                  float3 colX, float3 colY, float edge01)
{
    return SC_ShadeSheetAtExUnclippedStop(localPos, worldPos, N, colX, colY, edge01, false, 2.0);
}

#endif // SPIDERCOCOON_SHEET_INCLUDED
