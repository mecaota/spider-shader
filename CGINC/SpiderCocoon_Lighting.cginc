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

// 糸1本ぶんのトゥーン陰影（SpiderCocoon 本体と SpiderWeb で共通の質感）。
//   陰影は「面法線 × 光源」を主役にする（カメラ非依存。光の当たる面の裏側が
//   陰る）。各糸ごとの曲げ法線は detail として混ぜる。
//   N,T,B        : 面の基底（VFACE 反転済み）
//   cx, cy       : 糸を横断する向き（T*cx + B*cy がワールドの横断方向）
//   signedAcross : 糸横断の符号付き位置 -1..+1（中心0）
//   rimEdge      : 糸の縁ほど 1（ファイバー縁の影用）
//   L, ambient   : ライト方向と環境光（呼び出し側で一度だけ算出して渡す）
// ※ _LightColor0 を参照するため、.shader 側で Unity の Lighting.cginc を
//    先に include しておくこと（Common.cginc と同じ前提）。
float3 SC_ShadeFiberToon(float3 N, float3 T, float3 B, float cx, float cy,
                         float signedAcross, float rimEdge,
                         float3 L, float3 ambient)
{
    float3 fiberN  = SC_PerturbNormal(N, T, B, cx, cy, signedAcross, _FiberNormalStrength);
    float  ndlFace = dot(N, L);
    float  ndlFib  = dot(fiberN, L);
    float  ndl     = lerp(ndlFace, ndlFib, _FiberNormalStrength);
    float  toon    = SC_ToonRamp(ndl * 0.5 + 0.5, _ToonSteps, _ToonSmooth); // half-lambert で裏も真っ黒にしない

    // 発光的な下地: 明部は糸色そのまま、影部のみ影色まで暗くする。
    // ライト「強度」には依存しない（toon でライトの“向き”だけ使う）ので、
    // 照明が弱い／OFF でも正面が暗く沈まず、糸色がそのまま出る。
    float3 col = _ThreadColor.rgb * lerp(_ShadowColor.rgb, float3(1.0, 1.0, 1.0), toon);
    // シーン光・環境光を _LightInfluence ぶんだけ上乗せ（無くても下地が残る）
    col *= 1.0 + (_LightColor0.rgb * toon + ambient) * _LightInfluence;
    // 糸の縁を暗化
    col = lerp(col, col * _RimShadowColor.rgb, rimEdge * _RimShadowStrength);
    return col;
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
