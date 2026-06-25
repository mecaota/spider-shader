// =============================================================================
// SpiderCocoon.shader  —  蜘蛛の糸で巻かれた繭 シェーダー (VRChat / Built-in RP 専用)
//
//  - 円柱メッシュに「筒状に巻きついた」平行な糸を手続き生成（テクスチャ不要）
//  - 巻き数 W は円周方向(uv.y)に整数本でシームレス。角度は軸方向(uv.x)の
//    シアーなので任意の連続角度に傾けてもシームレス
//  - 糸の隙間は透過。裏面の糸は既定で隠し、隙間から奥の暗い糸が透けない
//  - 各糸ごとに法線を曲げて光源依存の陰影（トゥーンランプ）
//  - シルエットのリムライト（色・幅・強さ調整可）
//  - レイヤーを _LayerCount 枚だけ重ね描画。最背面=オフセット0、
//    追加レイヤーは偶数/奇数で線対称に角度・位置をオフセット
//  - 裏側（繭の内側）をカメラが覗くと視界ジャック（全画面化）
// =============================================================================
Shader "mecaota/SpiderCocoon"
{
    Properties
    {
        [Header(Thread Design)]
        _ThreadColor        ("糸の色 (Thread Color)", Color)              = (1, 1, 1, 1)
        _ThreadThickness    ("糸の太さ (Thickness)", Range(0.01, 1.0))     = 0.35
        _ThreadJitter       ("太さの乱雑性 (Thickness Jitter)", Range(0, 1))= 0.3
        _ThreadFuzz         ("幅の揺らぎ (Fuzz Amount)", Range(0, 1))       = 0.2
        _ThreadFuzzScale    ("揺らぎの細かさ (Fuzz Scale)", Float)          = 8.0

        [Header(Thread Layout)]
        _WindingCount       ("巻き数 (Winding Count)", Float)               = 24
        _ThreadDensity      ("糸の密度倍率 (Density Mult)", Float)          = 1.0
        _FiberAngle         ("基準の糸の角度 (Base Fiber Angle deg)", Range(-89, 89)) = 0

        [Header(Toon Shading)]
        _ToonSteps          ("トゥーン段階数 (Toon Steps)", Range(1, 8))    = 3
        _ToonSmooth         ("段差の柔らかさ (Toon Smooth)", Range(0.001, 0.5)) = 0.05
        _ShadowColor        ("影色 (Shadow Tint)", Color)                  = (0.55, 0.55, 0.62, 1)
        _AmbientBoost       ("環境光の底上げ (Ambient Boost)", Range(0, 1)) = 0.35
        _LightInfluence     ("シーン光の反映度 (Light Influence)", Range(0, 1)) = 0.5

        [Header(Silhouette Rim Light)]
        _RimColor           ("リムライト色 (Rim Color)", Color)            = (0.8, 0.9, 1.0, 1)
        _RimPower           ("リム幅 / 鋭さ (Rim Power)", Range(0.5, 16))   = 4.0
        _RimStrength        ("リム強さ (Rim Strength)", Range(0, 4))        = 0.4
        _RimFloor           ("リムの下限/全体発光 (Rim Floor)", Range(0, 1)) = 0.25

        [Header(Per Fiber Shading)]
        _FiberNormalStrength("糸断面の法線曲げ (Fiber Normal Strength)", Range(0, 1)) = 0.4
        _RimShadowColor     ("ファイバー縁の影色 (Fiber Edge Shadow)", Color) = (0.25, 0.22, 0.22, 1)
        _RimShadowStrength  ("ファイバー縁影の濃さ (Edge Shadow Strength)", Range(0, 1)) = 0.3

        [Header(Layers)]
        _LayerCount         ("レイヤー枚数 (Layer Count)", Range(1, 8))     = 3
        _LayerAngleStep     ("レイヤー角度ステップ (Angle Step deg)", Range(-45, 45)) = 8
        _LayerPosStepX      ("レイヤー位置ステップ X 軸 (Pos Step X)", Float) = 0.0
        _LayerPosStepY      ("レイヤー位置ステップ Y 円周 (Pos Step Y)", Float) = 0.02
        _LayerThicknessFalloff ("奥レイヤーの減衰 (Thickness Falloff)", Range(0, 1)) = 0.0

        [Header(Billboard)]
        [Toggle] _Billboard ("ビルボード / 継ぎ目を裏へ (Billboard)", Float) = 0
        _BillboardSeamOffset ("継ぎ目の位置オフセット (Seam Offset deg)", Range(0, 360)) = 0

        [Header(Back Faces and Vision Jack)]
        [Toggle] _HideBackFibers ("裏面の糸を隠す (Hide Back Fibers)", Float) = 1
        [Toggle] _VisionJackEnable ("視界ジャック有効 (Vision Jack)", Float) = 0
        _VisionJackRadius ("内側判定の半径 (Inside Radius)", Float) = 0.55
        _VisionJackHeight ("内側判定の高さ (Inside Height)", Float) = 1.1
        [Toggle] _VisionJackInMirror ("ミラー内でも発火 (In Mirror)", Float) = 0

        [Header(Render State)]
        [Enum(Off,0,On,1)] _ZWrite ("ZWrite", Float) = 0
    }

    SubShader
    {
        Tags
        {
            "Queue"            = "Transparent"
            "RenderType"       = "Transparent"
            "IgnoreProjector"  = "True"
            "VRCFallback"      = "Hidden"
        }

        Pass
        {
            Name "FORWARD"
            Tags { "LightMode" = "ForwardBase" }

            Cull   Off
            ZWrite [_ZWrite]
            Blend  SrcAlpha OneMinusSrcAlpha

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment frag
            #pragma target   3.5
            #pragma multi_compile_instancing
            #pragma multi_compile_fwdbase

            #include "UnityCG.cginc"
            #include "Lighting.cginc"

            #include "CGINC/SpiderCocoon_Noise.cginc"
            #include "CGINC/SpiderCocoon_Common.cginc"
            #include "CGINC/SpiderCocoon_Thread.cginc"
            #include "CGINC/SpiderCocoon_Lighting.cginc"
            #include "CGINC/SpiderCocoon_VisionJack.cginc"

            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                float3 vpos = v.vertex.xyz;
                float3 vnrm = v.normal;
                float3 vtan = v.tangent.xyz;

                // ビルボード: 円柱はローカルY軸まわりに回転対称なので、頂点を
                // その軸まわりに回してもシルエットは不変。UV だけが回るので、
                // UV の継ぎ目（uv.y=0/1）を常にカメラの裏側へ送れる。
                if (_Billboard > 0.5)
                {
                    float3 camOS  = mul(unity_WorldToObject, float4(_WorldSpaceCameraPos, 1.0)).xyz;
                    float  camAng = atan2(camOS.x, camOS.z);          // ローカルでのカメラ方位
                    float  a      = camAng + radians(_BillboardSeamOffset);
                    float  s = sin(a), c = cos(a);
                    vpos = float3(c * vpos.x + s * vpos.z, vpos.y, -s * vpos.x + c * vpos.z);
                    vnrm = float3(c * vnrm.x + s * vnrm.z, vnrm.y, -s * vnrm.x + c * vnrm.z);
                    vtan = float3(c * vtan.x + s * vtan.z, vtan.y, -s * vtan.x + c * vtan.z);
                }

                float3 worldPos    = mul(unity_ObjectToWorld, float4(vpos, 1.0)).xyz;
                float3 worldNormal = UnityObjectToWorldNormal(vnrm);

                o.uv           = v.uv;
                o.worldPos     = worldPos;
                o.worldNormal  = worldNormal;
                o.worldTangent = float4(UnityObjectToWorldDir(vtan), v.tangent.w);

                // 視界ジャック: カメラが繭の内側に入ったら、頂点を全画面へ展開。
                bool jack = SC_VisionJackActive();
                o.visionJack = jack ? 1.0 : 0.0;
                o.pos = jack ? SC_VisionJackClipPos(v.uv)
                             : UnityObjectToClipPos(float4(vpos, 1.0));
                return o;
            }

            fixed4 frag(v2f i, fixed facing : VFACE) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                bool jack = i.visionJack > 0.5;

                // 裏面（カメラに背を向けた面＝奥の内壁）は通常 discard する。
                // これで手前の糸の隙間から「奥の暗い糸」が透けて見えなくなる。
                // ただし視界ジャック発火中は、その裏面を全画面カバーに使うので描く。
                if (!jack && _HideBackFibers > 0.5 && facing < 0.0) discard;

                // ---- 基底ベクトル（VFACE で裏面の法線を反転） ----
                float3 L = normalize(_WorldSpaceLightPos0.xyz);
                float3 V = normalize(_WorldSpaceCameraPos - i.worldPos);
                float3 N = normalize(i.worldNormal) * sign(facing);
                float3 T = normalize(i.worldTangent.xyz);
                float3 B = normalize(cross(N, T)) * i.worldTangent.w * unity_WorldTransformParams.w;

                // 動的ループ内で fwidth を呼ばないよう、AA 幅はここで一度だけ算出
                float2 aaUV = float2(fwidth(i.uv.x), fwidth(i.uv.y));

                // 全レイヤー共通の環境光
                float3 ambient = ShadeSH9(float4(N, 1.0)) + _AmbientBoost;

                // 円周方向の巻き数 W はシーム維持のため整数に丸める（cy 係数）
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
                    int    grp      = (li + 1) / 2;                       // 0,1,1,2,2,...
                    float  side     = (li % 2 == 1) ? 1.0 : -1.0;         // 奇数=+ 偶数=-
                    float  lf       = side * (float)grp;
                    float  angle    = _FiberAngle + lf * _LayerAngleStep;
                    float  cx       = tan(radians(clamp(angle, -89.0, 89.0))); // 軸方向シアー(連続)
                    float2 off      = float2(_LayerPosStepX, _LayerPosStepY) * lf;
                    float  seed     = (float)li * 19.0 + 3.0;
                    float  denom    = max((float)(Lc - 1), 1.0);
                    float  thickMul = 1.0 - _LayerThicknessFalloff * ((float)li / denom);

                    float sgn, rimEdge;
                    float a = SC_EvalFiber(i.uv, cx, cy, off, seed, thickMul, aaUV, sgn, rimEdge);
                    a *= _ThreadColor.a;
                    if (a <= 0.001) continue;            // 隙間はスキップ

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
                    float3 col = _ThreadColor.rgb * lerp(_ShadowColor.rgb, float3(1.0, 1.0, 1.0), toon);
                    // シーン光・環境光を _LightInfluence ぶんだけ上乗せ（無くても下地が残る）
                    col *= 1.0 + (_LightColor0.rgb * toon + ambient) * _LightInfluence;
                    // 糸の縁を暗化
                    col = lerp(col, col * _RimShadowColor.rgb, rimEdge * _RimShadowStrength);

                    // over 合成（src = このレイヤー）
                    accumRGB = col * a + accumRGB * (1.0 - a);
                    accumA   = a       + accumA   * (1.0 - a);
                }

                if (accumA <= 0.001) discard;            // 完全な隙間はピクセル破棄

                // シルエットのリムライトは合成後に面全体へ加算（糸がある所だけ）
                accumRGB += SC_RimLight(N, V) * accumA;

                return fixed4(accumRGB, accumA);
            }
            ENDCG
        }
    }

    Fallback Off
}
