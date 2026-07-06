// =============================================================================
// SpiderThreadTrail.shader — 蜘蛛が吐いた糸（トレイルパーティクル用）
//
//  - Trail Renderer / Particle System の Trails モジュールで使う前提の
//    リボン（帯）用シェーダー。帯の長さ方向に数本の糸が走る。
//  - 糸の質感（太さの乱雑性・うねり・トゥーン陰影・リムライト・レイヤー重ね）は
//    繭本体とまったく同じ共通実装（CGINC/*）を流用。マテリアルの値を揃えれば
//    見た目が一致する。
//  - 揺れアニメ: 糸のパターンを帯の幅方向へ sin 波でずらし、吐いた糸が
//    左右にたなびいているように見せる（ジオメトリは動かさないので
//    トレイルの軌跡そのものは崩れない）。
//
//  UV の前提（Unity のトレイルが生成する標準の UV）:
//    uv.x = 軌跡に沿った方向（Texture Mode: Stretch なら 0..1、Tile なら連続増加）
//    uv.y = 帯の幅方向 0..1
//  糸の位相 t = uv.x*cx + uv.y*cy なので、cy=_WindingCount が「幅方向に並ぶ
//  糸の本数」、cx=tan(_FiberAngle) が「軌跡に対する糸の傾き」になる。
//  頂点カラー（Color over Lifetime / Trail の Color）を最後に乗算するので、
//  尻尾に向かって糸がフェードアウトする表現はパーティクル側で設定できる。
// =============================================================================
Shader "mecaota/SpiderThreadTrail"
{
    Properties
    {
        // カテゴリ分け・共通/固有の区別は CustomEditor（SpiderCocoonShaderGUI）が担当。
        // [Header] は Editor スクリプトが無い環境（標準インスペクタ）向けの
        // フォールバック表示。カスタム GUI 側は Header 装飾をスキップして描く。
        // 共通プロパティは繭本体と同名（値を揃えると質感が一致）。既定値のみ
        // 細い帯向けにチューニングしてある（本数少なめ・レイヤー少なめ）。
        // ※ ShaderLab の属性引数は ASCII のみ（日本語を書くとパースエラー）。
        [Header(Thread Design)]
        _ThreadColor        ("糸の色 (Thread Color)", Color)              = (1, 1, 1, 1)
        _ThreadThickness    ("糸の太さ (Thickness)", Range(0.01, 1.0))     = 0.35
        _ThreadJitter       ("太さの乱雑性 (Thickness Jitter)", Range(0, 1))= 0.3
        _ThreadFuzz         ("幅の揺らぎ (Fuzz Amount)", Range(0, 1))       = 0.2
        _ThreadFuzzScale    ("揺らぎの細かさ (Fuzz Scale)", Float)          = 8.0

        [Header(Winding Layout)]
        _WindingCount       ("巻き数 / 幅方向の本数 (Winding Count)", Float) = 4
        _ThreadDensity      ("糸の密度倍率 (Density Mult)", Float)          = 1.0
        _FiberAngle         ("基準の糸の角度 (Base Fiber Angle deg)", Range(-89, 89)) = 0

        [Header(Toon Shading)]
        _ToonSteps          ("トゥーン段階数 (Toon Steps)", Range(1, 8))    = 3
        _ToonSmooth         ("段差の柔らかさ (Toon Smooth)", Range(0.001, 0.5)) = 0.05
        _ShadowColor        ("影色 (Shadow Tint)", Color)                  = (0.55, 0.55, 0.62, 1)
        _AmbientBoost       ("環境光の底上げ (Ambient Boost)", Range(0, 1)) = 0.35
        _LightInfluence     ("シーン光の反映度 (Light Influence)", Range(0, 1)) = 0.5

        [Header(Rim Light)]
        _RimColor           ("リムライト色 (Rim Color)", Color)            = (0.8, 0.9, 1.0, 1)
        _RimPower           ("リム幅 / 鋭さ (Rim Power)", Range(0.5, 16))   = 4.0
        _RimStrength        ("リム強さ (Rim Strength)", Range(0, 4))        = 0.4
        _RimFloor           ("リムの下限/全体発光 (Rim Floor)", Range(0, 1)) = 0.25

        [Header(Fiber Shading)]
        _FiberNormalStrength("糸断面の法線曲げ (Fiber Normal Strength)", Range(0, 1)) = 0.4
        _RimShadowColor     ("ファイバー縁の影色 (Fiber Edge Shadow)", Color) = (0.25, 0.22, 0.22, 1)
        _RimShadowStrength  ("ファイバー縁影の濃さ (Edge Shadow Strength)", Range(0, 1)) = 0.3

        [Header(Layer Stack)]
        _LayerCount         ("レイヤー枚数 (Layer Count)", Range(1, 8))     = 2
        _LayerAngleStep     ("レイヤー角度ステップ (Angle Step deg)", Range(-45, 45)) = 4
        _LayerPosStepX      ("レイヤー位置ステップ X 軌跡 (Pos Step X)", Float) = 0.0
        _LayerPosStepY      ("レイヤー位置ステップ Y 幅 (Pos Step Y)", Float) = 0.13
        _LayerThicknessFalloff ("奥レイヤーの減衰 (Thickness Falloff)", Range(0, 1)) = 0.0

        // ---- トレイル固有（揺れアニメ） ----
        [Header(Trail Sway)]
        _SwayAmount         ("揺れ幅 帯幅=1 (Sway Amount)", Range(0, 0.5))  = 0.15
        _SwaySpeed          ("揺れの速さ (Sway Speed)", Range(0, 10))        = 2.0
        _SwayWaves          ("揺れの波数 (Sway Waves)", Range(0, 20))        = 3.0
        _SwayAnchor         ("揺れ始めの距離 uv.x (Sway Anchor)", Range(0, 1)) = 0.2
        _TrailEdgeSoft      ("帯の端のフェード幅 (Edge Soft)", Range(0.001, 0.5)) = 0.15
    }

    SubShader
    {
        Tags
        {
            "Queue"           = "Transparent"
            "RenderType"      = "Transparent"
            "IgnoreProjector" = "True"
            "PreviewType"     = "Plane"
            "VRCFallback"     = "Hidden"
        }

        Pass
        {
            Name "FORWARD"
            // ForwardBase タグ: メインライト・環境光（_WorldSpaceLightPos0 /
            // _LightColor0 / SH）を確実にバインドするために必要（繭と同じ）。
            Tags { "LightMode" = "ForwardBase" }

            Cull   Off          // 帯はどちら側からも見える
            ZWrite Off
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
            #include "CGINC/SpiderCocoon_Compose.cginc"

            // トレイル固有 uniform（共通分は SpiderCocoon_Common.cginc で宣言済み）
            float _SwayAmount;
            float _SwaySpeed;
            float _SwayWaves;
            float _SwayAnchor;
            float _TrailEdgeSoft;

            // トレイルは頂点カラー（Color over Lifetime）を持つので専用の構造体を使う
            struct appdata_t
            {
                float4 vertex : POSITION;
                fixed4 color  : COLOR;
                float2 uv     : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f_t
            {
                float4 pos      : SV_POSITION;
                float2 uv       : TEXCOORD0;
                float3 worldPos : TEXCOORD1;
                fixed4 color    : COLOR0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f_t vert(appdata_t v)
            {
                v2f_t o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f_t, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                o.pos      = UnityObjectToClipPos(v.vertex);
                o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
                o.uv       = v.uv;
                o.color    = v.color;
                return o;
            }

            fixed4 frag(v2f_t i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // ==== 揺れアニメ ====
                // 糸パターンの座標を幅方向(uv.y)へ sin 波でずらす。パターンは
                // 周期的なので、ずらしても帯の中の糸の本数・間隔は変わらず、
                // 「糸が左右へたなびく」ようにだけ見える。周波数の違う波を
                // 2つ重ねて、単調な振り子に見えないようにしている。
                float ph   = i.uv.x * _SwayWaves * UNITY_TWO_PI;
                float sway = _SwayAmount *
                             (0.7 * sin(ph         + _Time.y * _SwaySpeed) +
                              0.3 * sin(ph * 2.33  - _Time.y * _SwaySpeed * 1.7 + 1.7));
                // 吐き出し口（uv.x=0）では揺れ 0 → _SwayAnchor までで徐々に振れる
                // （口元から糸が千切れて見えるのを防ぐ）。Tile モードで uv.x が
                // 大きくなっても saturate で 1 に張り付くだけなので破綻しない。
                sway *= saturate(i.uv.x / max(_SwayAnchor, 1e-4));

                float2 suv = float2(i.uv.x, i.uv.y + sway);

                // ==== 陰影用の基底（トレイルには法線・接線が無いので導出する） ====
                // N: トレイルはカメラ正対の帯なので「カメラへ向く法線」で近似。
                //    Cull Off でも常に視線側を向くため VFACE 分岐が不要になる。
                // T/B: ワールド座標と UV の画面微分から「uv.x / uv.y が増える
                //    ワールド方向」を解く（コタンジェントフレームの定石）。
                float3 V   = _WorldSpaceCameraPos - i.worldPos;
                float3 N   = normalize(V);

                float3 dpx = ddx(i.worldPos);
                float3 dpy = ddy(i.worldPos);
                float2 dux = ddx(i.uv);
                float2 duy = ddy(i.uv);
                float  det = dux.x * duy.y - duy.x * dux.y;
                float  sgn = (det >= 0.0) ? 1.0 : -1.0;
                float3 T   = (dpx * duy.y - dpy * dux.y) * sgn;  // ∂worldPos/∂uv.x 方向
                float3 B   = (dpy * dux.x - dpx * duy.x) * sgn;  // ∂worldPos/∂uv.y 方向
                T = (dot(T, T) > 1e-16) ? normalize(T) : float3(0.0, 1.0, 0.0);
                B = (dot(B, B) > 1e-16) ? normalize(B) : normalize(cross(N, T));

                // AA 幅は揺れ適用後の座標で取る（揺れの勾配ぶんも滑らかになる）
                float2 aaUV = float2(fwidth(suv.x), fwidth(suv.y));

                // レイヤー合成は繭本体と同一の共通実装。uv.x はシーム無しの連続
                // 座標（Stretch/Tile どちらでも巻き戻らない）なので snapCx /
                // foldFuzz は不要（メッシュ版と同じ扱い）。
                fixed4 col = SC_CompositeLayers(suv, N, T, B, i.worldPos, aaUV,
                                                false, false, false);

                // 帯の上下端をフェード: 揺れで端に寄った糸が帯の縁でスパッと
                // 切れて見えないよう、端に近い糸ほど薄くする。
                float edge = smoothstep(0.0, _TrailEdgeSoft,
                                        min(i.uv.y, 1.0 - i.uv.y));

                // 頂点カラー（Trail の Color / Color over Lifetime）を乗算 →
                // 尻尾へ向けて糸が消えていく等の演出はパーティクル側で制御できる
                col.rgb *= i.color.rgb;
                col.a   *= i.color.a * edge;
                return col;
            }
            ENDCG
        }
    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}
