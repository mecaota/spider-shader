#ifndef SPIDERCOCOON_COMPOSE_INCLUDED
#define SPIDERCOCOON_COMPOSE_INCLUDED

// ---------------------------------------------------------------------------
// SpiderCocoon_Compose.cginc
// 「レイヤー線対称ループ → ライティング → over 合成 → α割り戻し」の共通実装。
// 本体 SpiderCocoon（メッシュ）・SpiderCocoonDepthDecal（glue/殻/ジャック）の
// 3実装で重複していた合成ループを、この1関数に集約する。
//
// 前提 include（.shader 側でこの順に読み込むこと）:
//   SpiderCocoon_Noise.cginc → Common → Thread → Lighting → 本ファイル
//
// 引数:
//   uv        : 糸空間の座標。t = uv.x*cx + uv.y*cy（cy=巻き数・整数）。
//               メッシュ版: x=軸(シーム無し) y=円周(ラップ)
//               デカール版: x=円周(ラップ)  y=軸(シーム無し)
//   N, T, B   : 陰影用の基底。T*cx + B*cy が糸の横断方向になる向きで渡す
//   worldPos  : 描画点のワールド座標（V・リムライト用）
//   aaUV      : fwidth(uv)（動的ループ内で微分を取らないため呼び出し側で算出）
//   snapCx    : 角度シアー cx を「1周で整数本進む閉じた螺旋」へスナップ。
//               ラップする座標が uv.x の場合（デカール）に true 必須
//   foldFuzz  : Fuzz 座標をシームで折り返して連続化（デカールで true）
//   flatColor : ライティングを行わずフラットな糸色＋縁影のみで描く
//               （視界ジャック用。リムライトの加算も行わない）
//
// 戻り値: 合成済みの色（α割り戻し済み）。全レイヤーが隙間なら discard。
// ---------------------------------------------------------------------------

fixed4 SC_CompositeLayers(float2 uv, float3 N, float3 T, float3 B, float3 worldPos,
                          float2 aaUV, bool snapCx, bool foldFuzz, bool flatColor)
{
    float3 L = normalize(_WorldSpaceLightPos0.xyz);
    float3 V = normalize(_WorldSpaceCameraPos - worldPos);

    // 全レイヤー共通の環境光
    float3 ambient = ShadeSH9(float4(N, 1.0)) + _AmbientBoost;

    // 円周方向の巻き数はシーム維持のため整数に丸める（cy 係数）
    float cy = max(round(_WindingCount * _ThreadDensity), 1.0);
    int   Lc = (int)round(_LayerCount);

    // ---- 背面 → 前面へ over 合成 ----
    float3 accumRGB = 0.0;
    float  accumA   = 0.0;

    [loop]
    for (int li = 0; li < SC_MAX_LAYERS; ++li)
    {
        if (li >= Lc) break;                 // 実レイヤー数で打ち切り

        // 偶数/奇数で線対称にオフセット。li=0 は常に 0。
        //   li : 0  1   2   3   4 ...
        //   lf : 0 +1  -1  +2  -2 ...（左右ミラーでクロスする巻き）
        // 整数の除算(/2)・剰余(%2)は GPU で遅くコンパイラ警告も出るため、
        // 非負が保証される uint のビット演算（>>1 = ÷2、&1 = 奇偶）で求める。
        uint   uli      = (uint)li;
        float  grp      = (float)((uli + 1u) >> 1);           // 0,1,1,2,2,...
        float  side     = ((uli & 1u) == 1u) ? 1.0 : -1.0;    // 奇数=+ 偶数=-
        float  lf       = side * grp;
        float  angle    = _FiberAngle + lf * _LayerAngleStep;
        float  cxRaw    = tan(radians(clamp(angle, -89.0, 89.0)));
        // snapCx: ラップする座標(uv.x)に掛かる場合は「1周でちょうど cx 本ぶん
        // 進む閉じた螺旋」にする（シームレス条件）。シーム無し座標なら連続値のまま。
        float  cx       = snapCx ? round(cxRaw * cy) : cxRaw;
        float2 off      = float2(_LayerPosStepX, _LayerPosStepY) * lf;
        float  seed     = (float)li * 19.0 + 3.0;
        float  denom    = max((float)(Lc - 1), 1.0);
        float  thickMul = 1.0 - _LayerThicknessFalloff * ((float)li / denom);

        // Fuzz（糸長方向のうねり）の座標。ラップする座標系では
        // シームで折り返して連続化する（0↔1 対称・連続）。
        float fuzzX = uv.x + off.x;
        if (foldFuzz) fuzzX = abs(frac(fuzzX) - 0.5) * 2.0;

        float sgn, rimEdge;
        float a = SC_EvalFiberEx(uv, cx, cy, off, seed, thickMul, aaUV, fuzzX, sgn, rimEdge);
        a *= _ThreadColor.a;
        if (a <= 0.001) continue;            // 隙間はスキップ

        float3 col;
        if (flatColor)
        {
            // 糸色＋ファイバー縁の影のみ（視界ジャック用のフラットな描画）
            col = _ThreadColor.rgb;
            col = lerp(col, col * _RimShadowColor.rgb, rimEdge * _RimShadowStrength);
        }
        else
        {
            // 陰影は「面法線 × 光源」を主役にする（カメラ非依存。光の当たる
            // 面の裏側が陰る）。各糸ごとの曲げ法線は detail として混ぜる。
            float3 fiberN  = SC_PerturbNormal(N, T, B, cx, cy, sgn, _FiberNormalStrength);
            float  ndlFace = dot(N, L);
            float  ndlFib  = dot(fiberN, L);
            float  ndl     = lerp(ndlFace, ndlFib, _FiberNormalStrength);
            float  toon    = SC_ToonRamp(ndl * 0.5 + 0.5, _ToonSteps, _ToonSmooth); // half-lambert で裏も真っ黒にしない

            // 発光的な下地: 明部は糸色そのまま、影部のみ影色まで暗くする。
            // ライト「強度」には依存しない（toon でライトの“向き”だけ使う）ので、
            // 照明が弱い／OFF でも正面が暗く沈まず、糸色がそのまま出る。
            col = _ThreadColor.rgb * lerp(_ShadowColor.rgb, float3(1.0, 1.0, 1.0), toon);
            // シーン光・環境光を _LightInfluence ぶんだけ上乗せ（無くても下地が残る）
            col *= 1.0 + (_LightColor0.rgb * toon + ambient) * _LightInfluence;
            // 糸の縁を暗化
            col = lerp(col, col * _RimShadowColor.rgb, rimEdge * _RimShadowStrength);
        }

        // over 合成（src = このレイヤー）
        accumRGB = col * a + accumRGB * (1.0 - a);
        accumA   = a       + accumA   * (1.0 - a);
    }

    if (accumA <= 0.001) discard;            // 完全な隙間はピクセル破棄

    // シルエットのリムライトは合成後に面全体へ加算（糸がある所だけ）
    if (!flatColor) accumRGB += SC_RimLight(N, V) * accumA;

    // over 合成の蓄積は事前乗算済み。Blend SrcAlpha で α が再度掛かるため
    // ここで割り戻す（半透明の縁が暗く沈むのを防ぐ）。
    return fixed4(accumRGB / max(accumA, 1e-4), accumA);
}

#endif // SPIDERCOCOON_COMPOSE_INCLUDED
