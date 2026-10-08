#ifndef SPIDERCOCOON_GOO_INCLUDED
#define SPIDERCOCOON_GOO_INCLUDED

// ---------------------------------------------------------------------------
// SpiderCocoon_Goo.cginc
// 繭（SpiderCocoon 本体・SpiderCocoonDepthDecal の glue/殻/視界ジャック）の
// 「粘液の帯」合成。吐いた糸・蜘蛛の巣と同じ塗り（SpiderGoo_Shading.cginc）を使う。
//
// 糸の並び（巻き数・角度・レイヤーの線対称オフセット・太さの乱雑性）は従来の
// SC_CompositeLayers と同じ。違うのは「描き方」:
//   - 1 本 1 本の糸を、平たい粘液の帯（断面の縁だけ丸い）として塗る
//   - 同じ層の隣り合う帯の間には、場所ごとにまだらな量の膜が張る
//   - 帯の中に細い筋（繊維）が数本走る
//   - 層は奥→手前へ重ね、上の帯の縁は下の帯の上に輪郭線として見え、
//     縁のすぐ外の下の帯には影が落ちる（アニメの“いとをはく”で巻かれた見え方）
//
// 座標（t 空間）: 糸の位相 t = uv.x*cx + uv.y*cy。糸の中心は t が整数、
// 隣の糸まで t で 1。距離場もこの t の単位で測る。
//
// 前提 include: SpiderCocoon_Noise → Common → Thread → Lighting → Compose
//               → SpiderGoo_Shading → 本ファイル
// ---------------------------------------------------------------------------

// 次の 6 つは巣・吐いた糸と同じ名前なので、宣言は SpiderCocoon_Common.cginc の 1 か所
// （同名を 2 回宣言するとエラーになるため）。繭での意味:
//   _GooThick    : 粘液の太さ倍率（_ThreadThickness に掛かる）
//   _GooBeads    : 糊の玉（帯の太さのふくらみ）0..1
//   _GooBeadFreq : 糊の玉の細かさ（糸に沿った座標 1 あたりの個数）
//   _GooWebFill  : 隣り合う帯の間を埋める膜の量（t 空間）
//   _GooWebScale : 膜のまだら模様の細かさ（UV 1 あたり。円周方向は整数に丸める）
//   _GooFiberMix : 帯の中の筋（繊維）の濃さ
float _GooFlat;          // 帯の平たさ 0..1（0=丸い管 / 1に近いほど縁だけ丸い平らな帯）
float _GooFiberLines;    // 帯 1 本あたりの筋の本数
float _GooOverlapShadow; // 上の帯が下の帯に落とす影の濃さ
// 巻きアニメ（円筒マッピングのデカール・視界ジャックのみ）。_WindEnable=0（既定）なら完成した繭。
// Udon（BossSpiderController）が MaterialPropertyBlock で進み具合 0..1 を毎フレーム渡す
float _WindEnable;
float _WindProgress;

// 層 li の角度シアー（1 周で何本ぶん帯が進むか）。層の並びは線対称: 0, +1, -1, +2, -2 ...
float SCG_LayerCx(int li, float cy, bool snapCx)
{
    uint  uli   = (uint)li;
    float lf    = (((uli & 1u) == 1u) ? 1.0 : -1.0) * (float)((uli + 1u) >> 1);
    float cxRaw = tan(radians(clamp(_FiberAngle + lf * _LayerAngleStep, -89.0, 89.0)));
    return snapCx ? round(cxRaw * cy) : cxRaw;
}

// 巻きアニメで帯 idx が「どこまで巻かれたか」の位置 0..1（層の中の巻き順）。
// 帯は螺旋なので、帯の中心の軸方向の位置 y がそのまま糸に沿った位置になる
// （角度が 1 周進むと y が |cx|/cy 進む）。y で切ると、糸の先端が円周をぐるぐる回りながら
// 軸に沿って進む。輪（cx=0）は 1 本ずつ円周を 1 周して巻く。奇数層は逆向きに戻る。
float SCG_WindPos(float idx, float px, float cx, float cy, float offY, bool back)
{
    float y = (idx - px * cx) / cy - offY;
    if (abs(cx) < 0.5) y += frac(px) / cy;
    y = saturate(y);
    return back ? 1.0 - y : y;
}

// 糸 1 本の半幅（t 空間）: 共通の太さ乱雑性 × 粘液の太り × 糊の玉
float SCG_HalfWidth(float idxMod, float seed, float fuzzCoord,
                    float thickMul, float thick, float bAmt)
{
    float hw   = _ThreadThickness * 0.5 * thickMul * SC_ThreadWidthMul(idxMod, seed, fuzzCoord);
    float bead = smoothstep(0.35, 0.9, SC_ValueNoise1(fuzzCoord * _GooBeadFreq
                                                      + idxMod * 7.13 + seed * 1.37));
    hw *= thick * lerp(1.0 - 0.2 * bAmt, 1.0 + 1.0 * bAmt, bead);
    return max(hw, 1e-4);
}

// 粘液の繭を 1 ピクセルぶん評価する。引数は SC_CompositeLayers と同じ:
//   uv        : 糸空間の座標。メッシュ版 x=軸(シーム無し) y=円周(ラップ)
//                          デカール版 x=円周(ラップ)  y=軸(シーム無し)
//   N, T, B   : 陰影用の基底。T*cx + B*cy が糸の横断方向になる向きで渡す
//   aaUV      : fwidth(uv)（ループ内で微分を取らないため呼び出し側で算出）
//   snapCx    : ラップする座標が uv.x のとき true（角度を閉じた螺旋へスナップ）
//   foldFuzz  : 糸に沿った座標をシームで折り返して連続化（デカールで true）
//   flatColor : ライティングせず明部の色で塗る
//   edge01    : 巻きの端からの深さ 0..1（1=内側, 0=巻きの境界）。境界に近いほど帯が
//               細り、帯ごとにばらばらの位置で途切れる（ほつれ）。端の無い形は 1 を渡す
// 戻り値: 合成済みの色（α割り戻し済み）。全層が隙間なら discard。
fixed4 SC_CompositeGooUnclipped(float2 uv, float3 N, float3 T, float3 B, float3 worldPos,
                       float2 aaUV, bool snapCx, bool foldFuzz, bool flatColor, float edge01)
{
    float3 L = STG_GooLightDir();
    float3 V = normalize(_WorldSpaceCameraPos - worldPos);

    // 粘液感（_GooAmount）: 太り・玉・膜をまとめて弱める（1 で各設定値そのまま）
    float amt   = saturate(_GooAmount);
    float thick = lerp(1.0, _GooThick, amt);
    float bAmt  = saturate(_GooBeads) * amt;

    float cy = max(round(_WindingCount * _ThreadDensity), 1.0);
    int   Lc = (int)round(_LayerCount);

    // 膜のまだら。円周（ラップする軸）は周期を整数にして継ぎ目なしにする
    float Fn    = max(round(_GooWebScale), 1.0);
    float fillN = STG_ValueNoise2Wrap(uv * Fn, snapCx ? float2(Fn, 0.0) : float2(0.0, Fn));
    float kFill = _GooWebFill * amt * lerp(0.05, 1.1, fillN * fillN);

    // ---- 巻きアニメ: 層を 1 枚ずつ順に巻く。各層の持ち時間はその層の巻き数（周回数）に
    //      比例させ、糸の先端が回る速さを層によらずそろえる。膜は進み具合とともに育つ ----
    float windP   = saturate(_WindProgress);
    bool  winding = snapCx && _WindEnable > 0.5 && windP < 0.9999;
    float windTurns = 0.0, turnsBefore = 0.0;
    if (winding)
    {
        [loop]
        for (int lj = 0; lj < SC_MAX_LAYERS; ++lj)
        {
            if (lj >= Lc) break;
            windTurns += cy / max(abs(SCG_LayerCx(lj, cy, snapCx)), 1.0);
        }
        kFill *= lerp(0.15, 1.0, windP);
    }

    float3 accRGB = 0.0;      // 事前乗算の蓄積色（奥→手前の over 合成）
    float  accA   = 0.0;

    // ループ回数は材質定数なので全ピクセルで同じ（ピクセルごとの continue は無い）
    [loop]
    for (int li = 0; li < SC_MAX_LAYERS; ++li)
    {
        if (li >= Lc) break;

        // ---- 層の並び（SC_CompositeLayers と同じ線対称オフセット） ----
        uint   uli      = (uint)li;
        float  grp      = (float)((uli + 1u) >> 1);            // 0,1,1,2,2,...
        float  side     = ((uli & 1u) == 1u) ? 1.0 : -1.0;     // 奇数=+ 偶数=-
        float  lf       = side * grp;
        float  angle    = _FiberAngle + lf * _LayerAngleStep;
        float  cxRaw    = tan(radians(clamp(angle, -89.0, 89.0)));
        float  cx       = snapCx ? round(cxRaw * cy) : cxRaw;
        float2 off      = float2(_LayerPosStepX, _LayerPosStepY) * lf;
        float  seed     = (float)li * 19.0 + 3.0;
        float  denom    = max((float)(Lc - 1), 1.0);
        float  thickMul = 1.0 - _LayerThicknessFalloff * ((float)li / denom);

        float fuzzX = uv.x + off.x;
        if (foldFuzz) fuzzX = abs(frac(fuzzX) - 0.5) * 2.0;
        float wrapPeriod = snapCx ? ((abs(cx) > 0.5) ? abs(cx) : 1048576.0) : cy;
        float period     = max(abs(wrapPeriod), 1.0);

        // ---- 最寄りの帯と、ピクセルを挟んだ反対側の隣の帯 ----
        float2 p    = uv + off;
        float  t    = p.x * cx + p.y * cy;
        float  idx  = round(t);
        float  s    = t - idx;                                   // -0.5..+0.5
        float  sg   = (s >= 0.0) ? 1.0 : -1.0;
        // フロア剰余で巡回（円周の継ぎ目の両側で同じ糸番号＝太さが連続）
        float  idM  = idx - period * floor(idx / period);
        float  idN  = idx + sg;
        float  idNM = idN - period * floor(idN / period);
        float  hw   = SCG_HalfWidth(idM,  seed, fuzzX, thickMul, thick, bAmt);
        float  hwN  = SCG_HalfWidth(idNM, seed, fuzzX, thickMul, thick, bAmt);
        // 巻きの端のほつれ: 定規で切ったような端にせず、境界に近づくほど帯を細らせ、
        // 帯ごとに違う位置（乱数）で途切れさせる。巻き終わりの糸が散る見え方になる
        float cutA = SC_Hash11(idM  * 1.73 + seed * 0.61 + 5.0) * 0.7;
        float cutB = SC_Hash11(idNM * 1.73 + seed * 0.61 + 5.0) * 0.7;
        hw  = max(hw  * smoothstep(cutA, cutA + 0.3, edge01), 1e-5);
        hwN = max(hwN * smoothstep(cutB, cutB + 0.3, edge01), 1e-5);

        // 巻きアニメ: まだ巻かれていない所の帯は描かず、糸の先端（約 1/3 周）は細らせる。
        // 膜は両側の帯が巻かれた所にだけ張る
        float kLayer = kFill;
        if (winding)
        {
            float turnsL = cy / max(abs(cx), 1.0);
            float w0 = turnsBefore / max(windTurns, 1e-4);
            turnsBefore += turnsL;
            float pl  = saturate((windP - w0) * windTurns / turnsL);    // この層の進み具合
            float tip = 0.35 / turnsL;                                  // 先端の細りの長さ（層内 0..1 単位）
            bool  back = (uli & 1u) == 1u;
            float rA = saturate((pl * (1.0 + tip) - SCG_WindPos(idx, p.x, cx, cy, off.y, back)) / tip);
            float rB = saturate((pl * (1.0 + tip) - SCG_WindPos(idN, p.x, cx, cy, off.y, back)) / tip);
            hw  = max(hw  * smoothstep(0.0, 1.0, rA), 1e-5);
            hwN = max(hwN * smoothstep(0.0, 1.0, rB), 1e-5);
            kLayer *= min(rA, rB);
        }

        // 2 本を smooth-min で融合: 融合半径 kFill が隙間より大きい所は膜で塞がり、
        // 小さい所は穴として残る（まだら模様で場所ごとに変わる）
        float d1 = abs(s) - hw;
        float d2 = (1.0 - abs(s)) - hwN;
        float hl;
        float d  = STG_SMin(d1, d2, kLayer, hl);                 // hl = 最寄りの帯側の重み
        float rl = lerp(hwN, hw, hl);

        // 輪郭の外向き = 帯を横断する向き（t の勾配）の ±
        float3 acr = T * cx + B * cy;
        float  al  = length(acr);
        acr = (al > 1e-5) ? acr / al : B;
        float3 oL  = acr * lerp(-sg, sg, hl);
        float  aaL = abs(cx) * aaUV.x + abs(cy) * aaUV.y + 1e-5;  // t の 1px 変化量

        // ---- 下の層への影: この帯の縁のすぐ外側（下の帯の上）を暗くする ----
        float shW    = max(rl * 0.6, aaL * 1.5);
        float shadow = (1.0 - smoothstep(0.0, shW, d)) * smoothstep(-aaL, aaL, d);
        accRGB = lerp(accRGB, accRGB * _GooShadowColor.rgb, shadow * _GooOverlapShadow);

        // ---- この帯を塗る（吐いた糸・蜘蛛の巣と共通の塗り） ----
        STG_GooSurface gs = STG_GooProfileW(d, rl, oL, N);
        // 平たい帯: 断面の法線は縁の近くだけ曲げる（中央は面の向きのまま）
        float qn = saturate((gs.q - _GooFlat) / max(1.0 - _GooFlat, 1e-3));
        gs.Nt = normalize(N * sqrt(saturate(1.0 - qn * qn)) + oL * qn);

        float aaQ    = min(aaL / max(rl, 1e-4), 1.0);
        float detail = saturate(1.6 - aaQ * 2.5);               // 数 px の細い帯では輪郭線・ツヤを弱める
        float3 col   = flatColor ? _GooColor.rgb : STG_GooBaseColor(gs, N, L);

        // 帯の中の筋（繊維）: 帯を横切る位置 0..1 を本数で刻み、帯に沿って少し揺らす
        float fa    = clamp(s / max(hw, 1e-4), -1.0, 1.0) * 0.5 + 0.5;
        fa += 0.12 * (SC_ValueNoise1(fuzzX * 9.0 + idM * 3.1 + seed) - 0.5);
        float nL    = max(round(_GooFiberLines), 1.0);
        float fg    = frac(fa * nL + SC_Hash11(idM + seed * 0.37) * 0.5);
        // 筋の中心（fg=0/1）からの距離 0..1。筋の太さは刻み幅の 14%
        float lineD = 1.0 - abs(fg - 0.5) * 2.0;
        float aaF   = aaL / max(hw, 1e-4) * nL + 1e-4;          // lineD の 1px 変化量
        float fiber = 1.0 - smoothstep(0.14 - aaF, 0.14 + aaF, lineD);
        fiber *= _GooFiberMix * hl * gs.core * detail;
        col = lerp(col, col * _GooShadowColor.rgb, fiber);

        float  gn = SC_ValueNoise1(fuzzX * _GooBeadFreq * 0.6 + idM * 1.7 + 3.3);
        // AA 幅は帯の半幅で上限を切る（UV の継ぎ目などで微分が暴走しても外へにじまない）
        fixed4 c  = STG_GooFinishAA(col, 0.0, gs, d, N, V, L, gn, detail,
                                    min(aaL * 0.6, rl), aaQ);

        // ---- 奥→手前へ over 合成（事前乗算） ----
        accRGB = c.rgb * c.a + accRGB * (1.0 - c.a);
        accA   = c.a         + accA   * (1.0 - c.a);
    }

    // Blend SrcAlpha で α が再度掛かるため割り戻す（縁が暗く沈むのを防ぐ）
    return fixed4(accRGB / max(accA, 1e-4), accA);
}

// Keep the existing discard behaviour for single-surface callers. Group caps
// combine multiple projections before deciding whether the final pixel is empty.
fixed4 SC_CompositeGoo(float2 uv, float3 N, float3 T, float3 B, float3 worldPos,
                       float2 aaUV, bool snapCx, bool foldFuzz, bool flatColor, float edge01)
{
    fixed4 c = SC_CompositeGooUnclipped(uv, N, T, B, worldPos, aaUV,
                                     snapCx, foldFuzz, flatColor, edge01);
    if (c.a <= 0.001) discard;
    return c;
}

// ---------------------------------------------------------------------------
// 円筒マッピングの共通シェーディングヘルパー
// 「メッシュUVを持たない任意のローカル点」を、本体 SpiderCocoon と同じ
// 粘液の帯で着色する。デカールの glue（深度復元した体表点）と
// 視界ジャックの内壁（レイ交差点）の両方から使う共用部品。
// ---------------------------------------------------------------------------

// ローカル点の「円筒の径方向」ワールド法線（陰影用）。colX/Y/Z は円筒の
// ローカル軸（object→world 行列の列）。巻き座標を別の繭と共有するときに使う版
float3 SC_CylRadialNormalEx(float3 lp, float3 colX, float3 colY, float3 colZ)
{
    float3 radialW = colX * lp.x + colZ * lp.z;
    return (length(lp.xz) > 1e-5) ? normalize(radialW) : normalize(colY);
}

float3 SC_CylRadialNormal(float3 lp)
{
    float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
    float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
    float3 colZ = float3(unity_ObjectToWorld._m02, unity_ObjectToWorld._m12, unity_ObjectToWorld._m22);
    return SC_CylRadialNormalEx(lp, colX, colY, colZ);
}

// ローカル点 localPos（＝繭の上の点）を粘液の帯で着色して返す。
// colX/colY は巻き座標の軸（object→world 行列の列）、edge01 は巻きの端からの深さ
// （SC_CompositeGoo 参照）。糸の隙間なら discard（SC_CompositeGoo 内）。
fixed4 SC_ShadeCocoonAtExUnclipped(float3 localPos, float3 worldPos, float3 N,
                          float3 colX, float3 colY, float edge01)
{
    float ang = atan2(localPos.z, localPos.x);
    // 横リング: uv.x=円周(糸が走る方向), uv.y=軸(巻き数 cy が並ぶ方向)
    float2 uv = float2(ang / (UNITY_PI * 2.0) + 0.5, localPos.y + 0.5);

    float3 axisDir = normalize(colY);   // 体軸
    // N はワールド固定の径方向のまま使う（視線による反転はしない）。
    // 反転すると法線が常にカメラを向き、陰影がカメラ追従になって
    // 正対時に白飛びする（ライト方向ベースの自然な陰影にならない）。
    // 裏向き法線でのリム暴走は SC_RimLight 側の abs で防いでいる。
    float3 nt = cross(axisDir, N);
    float3 T = (length(nt) > 1e-5) ? normalize(nt) : normalize(colX); // uv.x=円周方向
    float3 B = axisDir;                                               // uv.y=軸方向

    float2 aaUV = float2(fwidth(uv.x), fwidth(uv.y));
    // atan2 の ±180° の継ぎ目では uv.x が 1→0 に飛び、fwidth が暴走して
    // AA が全幅ににじむ。半周ずらした座標の微分と小さい方を採る（継ぎ目対策）
    aaUV.x = min(aaUV.x, fwidth(frac(uv.x + 0.5)));

    // 円筒マッピング版: uv.x=円周（ラップ）のため角度は整数スナップ（snapCx=true）、
    // 糸に沿った座標は折返しあり、通常ライティング。
    return SC_CompositeGooUnclipped(uv, N, T, B, worldPos, aaUV, true, true, false, edge01);
}

fixed4 SC_ShadeCocoonAtEx(float3 localPos, float3 worldPos, float3 N,
                          float3 colX, float3 colY, float edge01)
{
    fixed4 c = SC_ShadeCocoonAtExUnclipped(localPos, worldPos, N, colX, colY, edge01);
    if (c.a <= 0.001) discard;
    return c;
}

// 自分自身（unity_ObjectToWorld）の巻き座標・ほつれ無しで着色する従来版
fixed4 SC_ShadeCocoonAt(float3 localPos, float3 worldPos, float3 N)
{
    float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
    float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
    return SC_ShadeCocoonAtEx(localPos, worldPos, N, colX, colY, 1.0);
}

#endif // SPIDERCOCOON_GOO_INCLUDED
