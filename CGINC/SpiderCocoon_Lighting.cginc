#ifndef SPIDERCOCOON_LIGHTING_INCLUDED
#define SPIDERCOCOON_LIGHTING_INCLUDED

// ---------------------------------------------------------------------------
// SpiderCocoon_Lighting.cginc
// 各糸ごとの法線摂動・トゥーンランプ・シルエットリムライト。
// ---------------------------------------------------------------------------

// 各糸の断面（丸い円柱）に沿って法線を曲げる。
//   N        : 面法線（VFACE 反転済み）
//   T, B     : タンジェント / バイタンジェント（world）
//   cx, cy   : 糸位相の勾配 (cx, cy)。糸を横断する向き＝この勾配方向。
//   signed   : 糸横断の符号付き位置 -1..+1（中心0）
//   strength : 曲げ量 0..1（縁で最大 ±90°×strength 倒す）
// 戻り値: 糸ごとに曲がった法線。中心は N のまま、縁ほど横へ倒れる→縁が陰る。
float3 SC_PerturbNormal(float3 N, float3 T, float3 B,
                        float cx, float cy, float signedAcross, float strength)
{
    // 糸を横断する向き（位相 t の勾配 (cx,cy) を world へ）
    float3 acrossDir = T * cx + B * cy;
    float  al = length(acrossDir);
    acrossDir = (al > 1e-5) ? acrossDir / al : B;

    // N を acrossDir の方へ角度 bend だけ回す（回転の基本形）
    float  bend = signedAcross * (SC_HALF_PI * strength);
    return normalize(N * cos(bend) + acrossDir * sin(bend));
}

// トゥーンランプ: 0..1 の明るさを steps 段に量子化し、境界を softness でぼかす。
float SC_ToonRamp(float x, float steps, float softness)
{
    float scaled = saturate(x) * steps;
    float lo     = floor(scaled);
    float fr     = scaled - lo;
    float e      = smoothstep(0.5 - softness, 0.5 + softness, fr);
    return (lo + e) / steps;
}

// リムライト（フレネル）＋下限の発光。
//   fres は輪郭ほど 1、正面中央で 0。_RimFloor を足すと中央にも発光が乗るので、
//   「縁は光るのに正面だけ発光が切れる」現象を防げる（＝面全体が薄く発光）。
//   dot に abs を掛けるのは、視線と逆向きの法線（デカール glue の径方向法線が
//   裏側を向くケース）で fres が 1 に張り付いて全面発光するのを防ぐため。
//   メッシュ版の N は VFACE で常に視線側を向くため abs は挙動を変えない。
float3 SC_RimLight(float3 N, float3 V)
{
    float fres   = pow(1.0 - saturate(abs(dot(N, V))), _RimPower);
    float amount = max(fres, _RimFloor);   // 正面中央でも _RimFloor ぶん発光
    return _RimColor.rgb * amount * _RimStrength;
}

#endif // SPIDERCOCOON_LIGHTING_INCLUDED
