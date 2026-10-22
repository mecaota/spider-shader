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

    float3 accRGB = 0.0;      // 事前乗算の蓄積色（内側→外側の over 合成）
    float  accA   = 0.0;

    // 層の数はマテリアル定数なので全ピクセル同じ回数（微分は上で確定済み）
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

    // Blend SrcAlpha で α が再度掛かるため割り戻す（繭の帯と同じ）。巻きアニメは最後に α だけ下げる
    return fixed4(accRGB / max(accA, 1e-4), accA * windFade);
}

fixed4 SC_ShadeSheetAtExUnclipped(float3 localPos, float3 worldPos, float3 N,
                                  float3 colX, float3 colY, float edge01)
{
    return SC_ShadeSheetAtExUnclippedStop(localPos, worldPos, N, colX, colY, edge01, false, 2.0);
}

#endif // SPIDERCOCOON_SHEET_INCLUDED
