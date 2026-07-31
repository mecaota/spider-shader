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
//  - 揺れアニメ（_SwayAnimEnable）: UVドメインを歪ませて糸を揺らす。
//    円周シームでも連続・軸の両端は固定可（SpiderWeb と共通の SC_SwayOffset）
//  - カメラが繭の内側に入ると視界ジャック（包まれ演出）: カメラの周囲に
//    繭の内壁（紡錘形楕円体）を実寸の深度付きで描く。壁より手前にある
//    自分のアバターの体などは遮られず見える＝繭に包まれている見え方。
//    実装はデカール版と共通（CGINC/SpiderCocoon_VisionJack.cginc）
// =============================================================================
Shader "mecaota/SpiderCocoon"
{
    Properties
    {
        // カテゴリ分け・共通/固有の区別は CustomEditor（SpiderCocoonShaderGUI）が担当。
        // [Header] は Editor スクリプトが無い環境（標準インスペクタ）向けの
        // フォールバック表示。カスタム GUI 側は Header 装飾をスキップして描くため
        // 二重表示にはならない。
        // ※ ShaderLab の属性引数は ASCII のみ（日本語を書くとパースエラー）。
        [Header(Thread Design)]
        _ThreadColor        ("糸の色 (Thread Color)", Color)              = (1, 1, 1, 1)
        _ThreadThickness    ("糸の太さ (Thickness)", Range(0.01, 1.0))     = 0.35
        _ThreadJitter       ("太さの乱雑性 (Thickness Jitter)", Range(0, 1))= 0.3
        _ThreadFuzz         ("幅の揺らぎ (Fuzz Amount)", Range(0, 1))       = 0.2
        _ThreadFuzzScale    ("揺らぎの細かさ (Fuzz Scale)", Float)          = 8.0

        [Header(Winding Layout)]
        _WindingCount       ("巻き数 (Winding Count)", Float)               = 24
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
        _LayerCount         ("レイヤー枚数 (Layer Count)", Range(1, 8))     = 3
        _LayerAngleStep     ("レイヤー角度ステップ (Angle Step deg)", Range(-45, 45)) = 8
        _LayerPosStepX      ("レイヤー位置ステップ X 軸 (Pos Step X)", Float) = 0.0
        _LayerPosStepY      ("レイヤー位置ステップ Y 円周 (Pos Step Y)", Float) = 0.02
        _LayerThicknessFalloff ("奥レイヤーの減衰 (Thickness Falloff)", Range(0, 1)) = 0.0

        [Header(Sway Animation)]
        [ToggleUI] _SwayAnimEnable ("揺れアニメ有効 (Sway Enable)", Float) = 0
        _SwayAnimAmount ("揺れ幅 (Sway Amount)", Range(0, 0.05)) = 0.012
        _SwayAnimSpeed  ("揺れの速さ (Sway Speed)", Range(0, 10)) = 1.5
        _SwayAnimWaves  ("波の細かさ (Sway Waves)", Range(0, 10)) = 2.0
        _SwayAnimAnchor ("端の固定幅 0で固定なし (Edge Anchor)", Range(0, 0.5)) = 0.15

        [Header(Billboard)]
        [Toggle] _Billboard ("ビルボード / 継ぎ目を裏へ (Billboard)", Float) = 0
        _BillboardSeamOffset ("継ぎ目の位置オフセット (Seam Offset deg)", Range(0, 360)) = 0

        [Header(Backface And Vision Jack)]
        [Toggle] _HideBackFibers ("裏面の糸を隠す (Hide Back Fibers)", Float) = 1
        // ※ 発火域（半径・高さ）は必ずメッシュの bounds の内側に収めること。
        //   bounds の外で発火させると、メッシュに背を向けた瞬間にフラスタム
        //   カリングでレンダラーごと消え、壁が全画面単位で出たり消えたりする
        //   （頂点シェーダーの×100拡大は CPU のカリング判定に反映されない）。
        //   既定値は標準 Cylinder（半径0.5・半高1.0）の内側に設定してある。
        [Toggle] _VisionJackEnable ("視界ジャック有効 (Vision Jack)", Float) = 0
        _VisionJackRadius ("内側判定の半径 (Inside Radius)", Float) = 0.45
        _VisionJackHeight ("内側判定の高さ (Inside Height)", Float) = 0.9
        [Toggle] _VisionJackInMirror ("ミラー内でも発火 (In Mirror)", Float) = 0
        _JackRadius         ("ジャック内壁の半径倍率 (Jack Radius Scale)", Range(0.2, 2)) = 0.7
        _JackStretch        ("ジャック内壁が閉じるまでの縦距離 (Jack Vertical Stretch)", Range(0.25, 4)) = 1.0

        [Header(Render State)]
        [Enum(Off,0,On,1)] _ZWrite ("ZWrite", Float) = 0
        // ジャック壁の目印に使うステンシルビット。他のステンシル利用シェーダー
        // （アバター等）と衝突する場合にワールド側で付け替えられるようにする。
        // 本体とデカールの両マテリアルで同じ値に揃えること。
        [IntRange] _StencilRef ("ステンシル ビット (Stencil Bit)", Range(0, 255)) = 128
    }

    SubShader
    {
        Tags
        {
            "Queue"            = "Transparent"
            "RenderType"       = "Transparent"
            "IgnoreProjector"  = "True"
            "VRCFallback"      = "Hidden"
            // 静的/動的バッチングされると unity_ObjectToWorld が単位行列相当になり、
            // オブジェクト空間依存の発火判定・投影がすべて壊れる（例: ワールド原点
            // 付近を通っただけで無関係の繭がジャック誤発火）。必ず無効化する。
            "DisableBatching"  = "True"
        }

        // ================= Pass 0: 視界ジャック＝包まれ演出（デカール版と共通実装） =================
        // カメラ（VRでは両目の中点）が繭の内側に入ったときだけ、カメラを囲む
        // 繭の内壁（紡錘形楕円体）を「実寸の深度付き」で描く。
        //   半径 = _VisionJackRadius × _JackRadius
        //   半高 = _VisionJackHeight × _JackStretch
        // ZTest LEqual ＋ 実深度の書き込みにより、壁より手前にあるもの
        // （自分のアバターの体など）は遮られず見える＝「包まれている」見え方。
        // 非発火時は頂点を縮退させ、フラグメントを一切発生させない（通常描画へ影響ゼロ）。
        // ステンシル [_StencilRef]（既定128）はデカール版と共通の目印
        // （デカールの glue が上塗りしない。両マテリアルで同値に揃えること）。
        Pass
        {
            Name "VISIONJACK"
            // ForwardBase タグ: メインライト・環境光を確実にバインドする
            Tags { "LightMode" = "ForwardBase" }

            ZWrite On
            ZTest  LEqual
            Cull   Front
            Blend  SrcAlpha OneMinusSrcAlpha
            Stencil
            {
                Ref       [_StencilRef]
                ReadMask  [_StencilRef]
                WriteMask [_StencilRef]
                Comp      Always
                Pass      Replace
            }

            CGPROGRAM
            #pragma vertex   vertJack
            #pragma fragment fragJack
            #pragma target   3.5
            #pragma multi_compile_instancing

            #include "UnityCG.cginc"
            #include "Lighting.cginc"

            #include "CGINC/SpiderCocoon_Noise.cginc"
            #include "CGINC/SpiderCocoon_Common.cginc"
            #include "CGINC/SpiderCocoon_Thread.cginc"
            #include "CGINC/SpiderCocoon_Lighting.cginc"
            #include "CGINC/SpiderCocoon_Compose.cginc"
            #include "CGINC/SpiderCocoon_VisionJack.cginc"

            struct v2f_jack
            {
                float4 pos      : SV_POSITION;
                float3 worldDir : TEXCOORD0; // カメラ→頂点のワールドレイ
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f_jack vertJack(appdata v)
            {
                v2f_jack o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f_jack, o);
                UNITY_TRANSFER_INSTANCE_ID(v, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                bool active = SC_VisionJackActive();

                // 発火中はメッシュを大きく膨らませる（壁が近クリップ面に切られて
                // 画面に穴が開くのを防ぐ）。非発火時は縮退させ完全に無効化する。
                float4 vtx = v.vertex;
                if (active) vtx.xyz *= 100.0;

                float3 worldVtx = mul(unity_ObjectToWorld, vtx).xyz;
                o.pos      = active ? UnityObjectToClipPos(vtx) : float4(0.0, 0.0, 0.0, 0.0);
                o.worldDir = worldVtx - _WorldSpaceCameraPos;
                return o;
            }

            fixed4 fragJack(v2f_jack i, out float outDepth : SV_Depth) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                outDepth = UNITY_NEAR_CLIP_VALUE;   // 仮値（discard 経路では書き込まれない）

                if (!SC_VisionJackActive()) discard;

                return SC_VisionJackWallShade(i.worldDir,
                                              _VisionJackRadius * _JackRadius,
                                              _VisionJackHeight * _JackStretch,
                                              outDepth);
            }
            ENDCG
        }

        // ================= Pass 1: 通常の繭メッシュ描画 =================
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
            #include "CGINC/SpiderCocoon_Compose.cginc"
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

                // 視界ジャック（包まれ演出）は専用の Pass 0 が実寸の壁として描く。
                // （旧実装の「頂点を全画面へ展開」はここから廃止した）
                o.pos = UnityObjectToClipPos(float4(vpos, 1.0));
                return o;
            }

            fixed4 frag(v2f i, fixed facing : VFACE) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // 裏面（カメラに背を向けた面＝奥の内壁）は通常 discard する。
                // これで手前の糸の隙間から「奥の暗い糸」が透けて見えなくなる。
                // （視界ジャック中にカメラから見える繭の内側はすべて裏面なので、
                //   既定ではメッシュは消え、Pass 0 の内壁だけが描かれる）
                if (_HideBackFibers > 0.5 && facing < 0.0) discard;

                // ---- 基底ベクトル（VFACE で裏面の法線を反転） ----
                float3 N = normalize(i.worldNormal) * sign(facing);
                float3 T = normalize(i.worldTangent.xyz);
                float3 B = normalize(cross(N, T)) * i.worldTangent.w * unity_WorldTransformParams.w;

                // ---- 揺れアニメ: UVドメインを歪ませて糸を揺らす ----
                // uv.y（円周）方向の波数は SC_SwayOffset 内で整数に丸められる
                // ため、円周の継ぎ目でも揺れは連続（シームに裂け目は出ない）。
                // 端の固定幅は uv.x（軸）の両端に効かせ、繭の口元を留める。
                float2 uvS = i.uv;
                if (_SwayAnimEnable > 0.5)
                {
                    float endD = min(i.uv.x, 1.0 - i.uv.x);
                    // 固定帯が振幅より狭いと帯内で歪みが折り返るため下限を設ける
                    float anc = max(_SwayAnimAnchor, 3.0 * SC_SwayAmp());
                    float aw  = (_SwayAnimAnchor > 1e-4)
                              ? smoothstep(0.0, anc, endD) : 1.0;
                    uvS -= SC_SwayOffset(i.uv, true) * aw;
                }

                // 動的ループ内で fwidth を呼ばないよう、AA 幅はここで一度だけ算出
                //（揺れ変形後の座標で取ることで、変形分も含めた正しい AA になる）
                float2 aaUV = float2(fwidth(uvS.x), fwidth(uvS.y));

                // レイヤー合成は共通実装（SpiderCocoon_Compose.cginc）へ。
                // メッシュ版: uv.x=軸（シーム無し）のため角度は連続値のまま
                // （snapCx=false）、Fuzz 折返し不要、通常ライティング。
                return SC_CompositeLayers(uvS, N, T, B, i.worldPos, aaUV,
                                          false, false, false);
            }
            ENDCG
        }
    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}
