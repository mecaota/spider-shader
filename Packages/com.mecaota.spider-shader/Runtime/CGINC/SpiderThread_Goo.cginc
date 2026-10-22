#ifndef SPIDERTHREAD_GOO_INCLUDED
#define SPIDERTHREAD_GOO_INCLUDED

// ---------------------------------------------------------------------------
// SpiderThread_Goo.cginc
// 蜘蛛糸の「粘液モード」（SpiderSilk 専用）。
//
// 繊維を何十本も並べる通常モードと違い、帯の中に数本の太い「粘液の束」を
// 距離場（SDF: 輪郭からの符号付き距離）で描く。アニメの“いとをはく”や
// “蜘蛛の巣ドレープ”のような
//   - ぬめっと丸い断面（トゥーン 2〜3 階調）
//   - 束に沿って走る白いハイライトの筋（濡れた光沢）
//   - 輪郭線
//   - 束どうしが近づくと水かき状に融合する
//   - 束の間に張った粘液の膜に穴が空き、穴と穴の間が糸になる
//   - 太さがくびれたり膨らんだりする（粘液の玉）
// を 1 パスで出す。
//
// 座標の前提（トレイルの UV）:
//   x = uv.x : 軌跡に沿った方向（Tile モードならメートル単位で連続増加）
//   y = uv.y : 帯の幅方向 0..1
//   距離場の単位は y（帯幅=1）。x 方向の距離が必要な所（膜の穴）だけ
//   縦横比 aspect = (1 x あたりのメートル)/(1 y あたりのメートル) で換算する。
//   ※ aspect は画面微分から三角形ごとに求めるので僅かにばらつく。x に掛けて
//     「座標」にすると継ぎ目が出るため、局所的な距離の換算にだけ使う。
//
// 塗り（丸い断面・ハイライト・輪郭線・透け）は SpiderWeb と共通の
// SpiderGoo_Shading.cginc。このファイルは帯の中の「形」を作る部分。
//
// 前提 include: SpiderCocoon_Noise → Common → Thread → Lighting
//               → SpiderGoo_Shading（.shader 側）
// ---------------------------------------------------------------------------

#define STG_MAX_STRANDS 4

float  _GooEnable;        // 0/1。粘液モード
// ---- 形 ----
float  _GooStrands;       // 束の本数 1..4
float  _GooWidth;         // 束の太さ（帯幅に対する直径の割合）
float  _GooSpread;        // 束の並ぶ幅（0=中央に集まって 1 本に融合 / 1=帯いっぱい）
float  _GooWobble;        // 束の蛇行の振れ幅（帯幅=1）
float  _GooWobbleFreq;    // 蛇行の細かさ（uv.x 1 あたりの波数）
// _GooBeads    : くびれ・玉の強さ 0..1（宣言は SpiderCocoon_Common.cginc。巣・繭と同名だが単位が違う）
// _GooBeadFreq : 玉の細かさ（uv.x 1 あたりの個数。宣言は同上）
float  _GooFlow;         // 玉が糸を伝って流れる速さ（uv.x/秒）
float  _GooMerge;         // 融合の粘り（束どうしを水かき状につなぐ半径・帯幅=1）
float  _GooTailThin;      // 頂点アルファが下がる尻尾ほど細く伸びる量 0..1
// ---- 穴の空いた膜 ----
float  _GooWeb;           // 束の間に膜が張る量 0..1（0=膜なし）
float  _GooWebCell;       // 穴の間隔（軌跡方向・uv.x 単位）
float  _GooWebRows;       // 帯の幅に並ぶ穴の列数
float  _GooWebHole;       // 穴の開き具合 0..1（大きいほど穴が広がり、膜が糸だけになる）
// ---- 糸だけの見た目（色・陰影・光沢は質感 = SpiderSilk_Look.cginc） ----
// _GooFiberMix : 粘液の中に透ける繊維の濃さ（宣言は SpiderCocoon_Common.cginc）

// 2 オクターブの value noise（-1..1）。粘液の蛇行を自然にするための揺らぎ。
float STG_Noise2(float x, float seed)
{
    float n = SC_ValueNoise1(x + seed) * 0.667
            + SC_ValueNoise1(x * 2.31 + seed * 1.7 + 11.3) * 0.333;
    return n * 2.0 - 1.0;
}

// 粘液の距離場を評価する。
//   uv      : 揺れ適用後の UV
//   aspect  : (uv.x 1 あたりのメートル)/(uv.y 1 あたりのメートル)
//   tailT   : 尻尾度 0..1（頂点アルファ由来。1 に近いほど引き伸ばされて細い）
// 出力:
//   dist    : 符号付き距離（負=粘液の中）。単位は帯幅
//   grad    : 輪郭の外向き方向（x=軌跡方向, y=幅方向）。断面の法線に使う
//   radius  : その場所の束の半径（輪郭からの深さを 0..1 に正規化するため）
void STG_GooField(float2 uv, float aspect, float tailT,
                  out float dist, out float2 grad, out float radius)
{
    float x = uv.x;
    float y = uv.y;

    int   n       = (int)clamp(round(_GooStrands), 1.0, (float)STG_MAX_STRANDS);
    float nf      = (float)n;
    // 粘液感（_GooAmount）: 玉・融合・膜を一緒に弱める（1 で各設定値そのまま）
    float amt     = saturate(_GooAmount);
    float thin    = lerp(1.0, 1.0 - 0.8 * _GooTailThin, tailT);            // 伸びて細る
    float beadAmt = saturate(_GooBeads * amt + 0.5 * _GooTailThin * tailT); // 細るほど玉が目立つ
    float baseR   = _GooWidth * 0.5;
    float k       = _GooMerge * amt * 0.5 * lerp(1.0, 0.6, tailT);
    float webAmt  = _GooWeb * amt;

    float  centers[STG_MAX_STRANDS];
    dist   = 1e3;
    grad   = float2(0.0, 1.0);
    radius = baseR;

    // ---- 束（軌跡に沿って走る太い粘液）----
    [unroll]
    for (int i = 0; i < STG_MAX_STRANDS; ++i)
    {
        centers[i] = 0.5;
        if (i < n)   // n はマテリアル定数なので全ピクセルで同じ分岐（微分が壊れない）
        {
            float fi   = (float)i;
            float seed = fi * 37.17 + 5.3;

            // 基準位置: 帯の中央を中心に _GooSpread の幅へ等間隔に並べる
            float slot = (n > 1) ? (fi / (nf - 1.0)) * 2.0 - 1.0 : 0.0;
            float c    = 0.5 + slot * _GooSpread * 0.5;
            // 蛇行: 束ごとに位相の違うノイズで左右へうねる
            c += _GooWobble * STG_Noise2(x * _GooWobbleFreq, seed);

            // 太さ: 束ごとの個体差 × くびれ/玉 × 尻尾の細り
            float jit  = 1.0 + 0.3 * SC_Hash11Signed(seed + 0.5);
            float bn   = SC_ValueNoise1((x - _Time.y * _GooFlow) * _GooBeadFreq + seed * 3.1);
            bn = smoothstep(0.2, 0.85, bn);                       // 玉とくびれの差をはっきり
            float r    = baseR * jit * thin * lerp(1.0 - 0.7 * beadAmt, 1.0 + 0.55 * beadAmt, bn);
            r = max(r, 1e-4);

            // 帯の端で束が切れないように、中心を帯の内側に収める
            c = clamp(c, r + 0.03, 1.0 - r - 0.03);

            centers[i] = c;

            float  di = abs(y - c) - r;
            float2 gi = float2(0.0, (y >= c) ? 1.0 : -1.0);
            float  h;
            dist   = STG_SMin(dist, di, k, h);
            grad   = lerp(gi, grad, h);
            radius = lerp(r, radius, h);
        }
    }

    // ---- 束の間に張った、穴の空いた粘液の膜 ----
    // 「膜 = 全面が粘液、そこへ丸い穴をランダムに空ける」と考える。穴は格子の
    // 各セルに 1 個ずつ（位置と大きさはハッシュでばらす）。穴どうしの間に
    // 残った部分が、太さの不揃いな糸と、3 つの穴に囲まれた粘着だまりになる。
    // 穴の SDF = (穴の中心までの距離) - (穴の半径)。膜の SDF はその符号反転。
    if (n > 1 && webAmt > 0.001)
    {
        float cLo = centers[0], cHi = centers[0];
        [unroll]
        for (int j = 1; j < STG_MAX_STRANDS; ++j)
        {
            if (j < n) { cLo = min(cLo, centers[j]); cHi = max(cHi, centers[j]); }
        }

        // 膜の量は軌跡に沿ってまだらに変える。少ない所は穴が広がって膜が
        // 千切れ、糸だけ→何も無し、と自然に消えていく。
        float cover = saturate((SC_ValueNoise1(x * _GooWobbleFreq * 0.9 + 51.7)
                                - (1.0 - webAmt)) * 3.0 + webAmt * 0.5);
        float holeR = lerp(1.25, lerp(0.22, 0.52, _GooWebHole), cover)   // セル単位
                    * lerp(1.0, 1.25, tailT);                           // 尻尾ほど穴が広がる

        float  cellU = max(_GooWebCell, 1e-3);                 // 軌跡方向のセル（uv.x 単位）
        float  cellV = 1.0 / max(_GooWebRows, 1.0);            // 幅方向のセル（帯幅単位）
        // セル座標の x を「見た目の距離」に揃える係数（穴を真円にする）
        float  sx = clamp(cellU * aspect / cellV, 0.33, 3.0);
        float2 p  = float2(x / cellU, y / cellV);
        float2 ip = floor(p);
        float2 fp = p - ip;

        float  hd  = 1e3;                 // 穴の和集合の SDF（セル単位・負=穴の中）
        float2 hg  = float2(0.0, 1.0);    // 膜の外向き（最寄りの穴の中心へ向かう）
        [unroll]
        for (int cyI = -1; cyI <= 1; ++cyI)
        {
            [unroll]
            for (int cxI = -1; cxI <= 1; ++cxI)
            {
                float2 g   = float2((float)cxI, (float)cyI);
                float2 rnd = STG_Hash22(ip + g + 17.0);
                float2 o   = 0.15 + 0.7 * rnd;                        // セル内の穴の位置
                float  rr  = holeR * lerp(0.65, 1.2, STG_Hash22(ip + g + 91.0).x);
                float2 df  = (g + o - fp) * float2(sx, 1.0);            // 穴の中心へのベクトル
                float  dl  = length(df);
                float  h;
                hd = STG_SMin(hd, dl - rr, 0.12, h);                   // 隣の穴と滑らかに合流
                hg = lerp(df / max(dl, 1e-4), hg, h);
            }
        }

        float sheet = -hd * cellV;                                    // 帯幅単位の膜 SDF
        float band  = max(cLo - y, y - cHi);                          // 束の間の範囲だけに張る
        float dm    = max(sheet, band);
        float2 gm   = (sheet > band) ? hg : float2(0.0, (y > 0.5 * (cLo + cHi)) ? 1.0 : -1.0);

        float h;
        dist   = STG_SMin(dist, dm, k, h);
        grad   = lerp(gm, grad, h);
        radius = lerp(cellV * 0.3, radius, h);
    }

    float gl = length(grad);
    grad = (gl > 1e-4) ? grad / gl : float2(0.0, 1.0);
}

// 粘液モードのシェーディング。戻り値は straight alpha（割り戻し不要）。
//   uv       : 揺れ適用後の UV
//   seed     : トレイルごとの乱数 0..1（無ければ 0）
//   N, T, B  : カメラ正対の法線 / 軌跡方向 / 幅方向（ワールド）
//   aspect   : STG_GooField と同じ縦横比
//   vcolA    : 頂点アルファ（尻尾度の算出に使う）
fixed4 STG_ShadeGoo(float2 uv, float seed, float3 N, float3 T, float3 B, float3 worldPos,
                    float aspect, float vcolA)
{
    float tailT = saturate(1.0 - vcolA);
    // トレイルごとの乱数で模様の位相をずらす（連射した糸が同じ模様の縞に見えないように）。
    // uv.x は以降ノイズの入力にしか使わないので、定数を足してもよい。
    uv.x += seed * 61.7;

    float  d, r;
    float2 g;
    STG_GooField(uv, aspect, tailT, d, g, r);

    // ---- 丸い断面 → トゥーン陰影（SpiderGoo_Shading.cginc）----
    STG_GooSurface s = STG_GooProfile(d, r, g, N, T, B);
    float3 V   = normalize(_WorldSpaceCameraPos - worldPos);
    float3 L   = STG_GooLightDir();
    float3 col = STG_GooBaseColor(s, N, L);

    // ---- 粘液の中に透ける繊維（束に沿って走る細い筋）----
    // 束の断面位置 0..1 を y 座標にして繊維パターンを評価するので、
    // 繊維は束の蛇行・くびれに沿って曲がる。
    float  sAcr  = 0.5 + 0.5 * s.q * g.y;
    float2 fuv   = float2(uv.x, sAcr);
    float2 aaF   = float2(fwidth(fuv.x), fwidth(fuv.y));
    float  cxF   = tan(radians(clamp(_FiberAngle, -89.0, 89.0)));
    float  cyF   = max(round(_WindingCount * _ThreadDensity), 1.0);
    float  fSgn, fRim;
    float  fiber = SC_EvalFiberEx(fuv, cxF, cyF, float2(0.0, 0.0), 7.0, 1.0, aaF,
                                  uv.x, 1048576.0, fSgn, fRim);
    fiber *= _GooFiberMix * s.core;                       // 輪郭付近では繊維を消す
    col = lerp(col, col * _GooShadowColor.rgb, fiber);    // 影色寄りの筋として沈める

    // ハイライトを所々で途切れさせるノイズ。玉と同じ速さで流し、uv.y も混ぜて
    // 束ごとに途切れる位置をずらす（全部の束で同じ所が切れると不自然）。
    float gbn = SC_ValueNoise1((uv.x - _Time.y * _GooFlow) * _GooBeadFreq * 1.7
                               + uv.y * 5.3 + 3.3);

    return STG_GooFinish(col, fiber, s, d, N, V, L, gbn, 1.0, 1e6);
}

#endif // SPIDERTHREAD_GOO_INCLUDED
