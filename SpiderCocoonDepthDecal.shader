// =============================================================================
// SpiderCocoonDepthDecal.shader — 深度デカールでプレイヤー体表に繭 (VRChat / Built-in RP)
//
//  胴を囲むボックスメッシュに貼る「スクリーンスペース深度デカール」。
//  各画素で _CameraDepthTexture を読み、その先の表面（＝アバター）のワールド
//  座標を復元。その点を「このボックスのローカル空間」へ変換し、ボックスの
//  内接円筒（local XZ 半径・local Y 高さ）の中なら、本体 SpiderCocoon と
//  同じ手続き糸を描く。実アバター表面のシルエットにピクセル単位で沿う＝張り付き。
//  スクリプト駆動の uniform は不要（体軸はボックスの Transform から導出）。
//
//  ★ 糸の厚み（_GlueThickness）:
//     glue した糸をメッシュの輪郭から外へ厚み分だけ太らせる（画面空間の膨張）。
//     近傍の深度に「輪郭の段差（手前に glue 対象がある）」を見つけた画素は、
//     その深度で糸を盛る。左右の足の糸がそれぞれ外へ太るので、間隔が
//     厚みの2倍以内なら重なって繋がり、まとめて巻かれているように見える。
//     床のような連続面は「段差」ではないため誤って覆わない。0 で無効。
//
//  ★ ミラー（Pass 2）:
//     ミラーでも通常視点と同じ体表 glue を描く。ミラーカメラは自前の深度を
//     持つが、鏡面に沿った斜交（oblique）投影のため LinearEyeDepth は使えず、
//     専用の解析的復元（SC_EyeDepthOblique）で視線深度を求める。
//     ZTest LEqual なので鏡内の遮蔽物に正しく隠れる。
//
//  ★ 視界ジャック: カメラが殻円筒の内側に入ると、糸を画面全体に描く。
//     （近クリップ対策として、ジャック中はボックスを頂点で拡大する）
//
//  ★ 必須前提:
//     - ワールドに「影付きリアルタイム Directional Light」（_CameraDepthTexture 供給）。
//     - Quest は screen-space 非対応（PC 専用）。
// =============================================================================
Shader "mecaota/SpiderCocoonDepthDecal"
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
        _LayerPosStepX      ("レイヤー位置ステップ X 円周 (Pos Step X)", Float) = 0.02
        _LayerPosStepY      ("レイヤー位置ステップ Y 軸 (Pos Step Y)", Float) = 0.0
        _LayerThicknessFalloff ("奥レイヤーの減衰 (Thickness Falloff)", Range(0, 1)) = 0.0

        [Header(Fit  inside the box)]
        _RadiusFit          ("円筒半径 (box内接=0.5)", Range(0.05, 0.5))   = 0.5
        _HeightFit          ("円筒高さ (box一杯=0.5)", Range(0.05, 0.5))   = 0.5
        _ProjectRange       ("投影の許容距離 (Project Range m)", Range(0, 0.5)) = 0.1

        [Header(Glue Thickness)]
        _GlueThickness      ("糸の厚み m 輪郭の外への膨張 (Glue Thickness)", Range(0, 0.2)) = 0.06

        [Header(Ground and Ceiling Texture)]
        _GroundTex          ("床/天井テクスチャ 蜘蛛の巣など (Ground Web)", 2D) = "black" {}
        _GroundColor        ("床/天井テクスチャの色 (Ground Tint)", Color) = (1, 1, 1, 1)
        _GroundLevel        ("床とみなす高さ ローカルY (Ground Level)", Range(-0.5, 0.5)) = -0.45
        _CeilingLevel       ("天井とみなす高さ ローカルY (Ceiling Level)", Range(-0.5, 0.5)) = 0.5

        [Header(Vision Jack)]
        [Toggle] _VisionJackEnable ("視界ジャック有効 (Vision Jack)", Float) = 1
        [Toggle] _VisionJackInMirror ("ミラー内でも発火 (In Mirror)", Float) = 0
    }

    SubShader
    {
        Tags { "Queue" = "Transparent" "RenderType" = "Transparent" "IgnoreProjector" = "True" }

        CGINCLUDE
        #include "UnityCG.cginc"
        #include "Lighting.cginc"

        #include "CGINC/SpiderCocoon_Noise.cginc"
        #include "CGINC/SpiderCocoon_Common.cginc"
        #include "CGINC/SpiderCocoon_Thread.cginc"
        #include "CGINC/SpiderCocoon_Lighting.cginc"
        #include "CGINC/SpiderCocoon_Compose.cginc"

        UNITY_DECLARE_SCREENSPACE_TEXTURE(_CameraDepthTexture);

        float _RadiusFit;
        float _HeightFit;
        float _ProjectRange;
        float _GlueThickness;

        sampler2D _GroundTex;
        float4    _GroundTex_ST;
        fixed4    _GroundColor;
        float     _GroundLevel;
        float     _CeilingLevel;

        // 深度の LOD0 サンプル（動的ループ内でも安全な明示 LOD 版）
        #if defined(UNITY_STEREO_INSTANCING_ENABLED) || defined(UNITY_STEREO_MULTIVIEW_ENABLED)
            #define SC_SAMPLE_DEPTH_LOD(uv) (UNITY_SAMPLE_TEX2DARRAY_LOD(_CameraDepthTexture, float3((uv).x, (uv).y, (float)unity_StereoEyeIndex), 0).r)
        #else
            #define SC_SAMPLE_DEPTH_LOD(uv) (tex2Dlod(_CameraDepthTexture, float4((uv).x, (uv).y, 0, 0)).r)
        #endif

        // 斜交（oblique）投影対応の視線深度復元。
        // ミラーカメラは鏡面に沿った「斜めの近クリップ面」を使うため、通常の
        // LinearEyeDepth（_ZBufferParams）では深度を正しく復元できない。
        // 射影行列の疎な構造を利用し、生深度とNDC座標から視線前方距離を解析的に逆算する。
        //   clip = P・view,  view.z = -w,  clip.w = w
        //   view.x = w(ndc.x + P02)/P00,  view.y = w(ndc.y + P12)/P11
        //   z行: ndcZ・w = P20・x + P21・y + P22・z + P23  →  w = P23 / (ndcZ - K)
        float SC_EyeDepthOblique(float2 uv, float rawDepth)
        {
            float2 ndc = float2(uv.x * 2.0 - 1.0, (uv.y * 2.0 - 1.0) * _ProjectionParams.x);
            #if defined(UNITY_REVERSED_Z)
                float ndcZ = rawDepth;
            #else
                float ndcZ = rawDepth * 2.0 - 1.0;
            #endif
            float K = UNITY_MATRIX_P._m20 * (ndc.x + UNITY_MATRIX_P._m02) / UNITY_MATRIX_P._m00
                    + UNITY_MATRIX_P._m21 * (ndc.y + UNITY_MATRIX_P._m12) / UNITY_MATRIX_P._m11
                    - UNITY_MATRIX_P._m22;
            float denom = ndcZ - K;
            denom = (abs(denom) < 1e-8) ? 1e-8 : denom;
            return UNITY_MATRIX_P._m23 / denom;
        }

        // 視界ジャックの発火判定（vert/frag で同一のこの関数を使い、判定を一致させる）
        bool SC_DecalJackActive()
        {
            if (_VisionJackEnable < 0.5) return false;
            if (SC_IsInMirror() && _VisionJackInMirror < 0.5) return false;
            float3 camLocal = mul(unity_WorldToObject, float4(_WorldSpaceCameraPos, 1.0)).xyz;
            return (length(camLocal.xz) < _RadiusFit) && (abs(camLocal.y) < _HeightFit);
        }

        // ローカル点の「円筒の径方向」法線（陰影用）
        float3 SC_CylRadialNormal(float3 lp)
        {
            float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
            float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
            float3 colZ = float3(unity_ObjectToWorld._m02, unity_ObjectToWorld._m12, unity_ObjectToWorld._m22);
            float3 radialW = colX * lp.x + colZ * lp.z;
            return (length(lp.xz) > 1e-5) ? normalize(radialW) : normalize(colY);
        }

        // ローカル点 localPos（＝繭の上の点）を、本体 SpiderCocoon と同じ
        // 手続き糸＋トゥーン＋リムで着色して返す。糸の隙間なら discard。
        fixed4 SC_ShadeCocoonAt(float3 localPos, float3 worldPos, float3 N)
        {
            float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
            float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);

            float ang = atan2(localPos.z, localPos.x);
            // 横リング: uv.x=円周(糸が走る方向), uv.y=軸(巻き数 cy が並ぶ方向)
            float2 uv = float2(ang / (UNITY_PI * 2.0) + 0.5, localPos.y + 0.5);

            float3 axisDir = normalize(colY);   // 体軸
            float3 V = normalize(_WorldSpaceCameraPos - worldPos);
            // 法線が視線と逆向きなら反転（リム全面発光・明暗反転を防ぐ）
            if (dot(N, V) < 0.0) N = -N;
            float3 nt = cross(axisDir, N);
            float3 T = (length(nt) > 1e-5) ? normalize(nt) : normalize(colX); // uv.x=円周方向
            float3 B = axisDir;                                               // uv.y=軸方向

            float2 aaUV = float2(fwidth(uv.x), fwidth(uv.y));

            // レイヤー合成は共通実装（SpiderCocoon_Compose.cginc）へ。
            // デカール版: uv.x=円周（ラップ）のため角度は整数スナップ（snapCx=true）、
            // Fuzz 折返しあり、通常ライティング。
            return SC_CompositeLayers(uv, N, T, B, worldPos, aaUV, true, true, false);
        }

        struct appdata_d
        {
            float4 vertex : POSITION;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        struct v2f_d
        {
            float4 pos      : SV_POSITION;
            float4 screenPos: TEXCOORD0;
            float3 worldDir : TEXCOORD1; // カメラ→頂点のワールドレイ
            UNITY_VERTEX_INPUT_INSTANCE_ID
            UNITY_VERTEX_OUTPUT_STEREO
        };

        v2f_d vert(appdata_d v)
        {
            v2f_d o;
            UNITY_SETUP_INSTANCE_ID(v);
            UNITY_INITIALIZE_OUTPUT(v2f_d, o);
            UNITY_TRANSFER_INSTANCE_ID(v, o);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

            float4 vtx = v.vertex;
            // ジャック中はボックスを大きく膨らませる。壁が近クリップ面より
            // 手前に来てフラグメントが消え、画面に穴が開くのを防ぐため。
            if (SC_DecalJackActive()) vtx.xyz *= 100.0;

            float3 worldVtx = mul(unity_ObjectToWorld, vtx).xyz;
            o.pos       = UnityObjectToClipPos(vtx);
            o.screenPos = ComputeScreenPos(o.pos);
            o.worldDir  = worldVtx - _WorldSpaceCameraPos;
            return o;
        }

        // Pass 0（ジャック専用）用の頂点シェーダー。
        // 非ジャック時は頂点を縮退させ、フラグメントを一切発生させない。
        // （Pass 0 は深度・ステンシルを書くパスなので、フラグメント側の discard に
        //   頼らず頂点段階で完全に無効化し、通常時の描画へ影響ゼロを保証する。
        //   これにより視界ジャック以外はレンダーキューを完全に遵守する。）
        v2f_d vertJack(appdata_d v)
        {
            v2f_d o = vert(v);
            if (!SC_DecalJackActive()) o.pos = float4(0.0, 0.0, 0.0, 0.0);
            return o;
        }
        ENDCG

        // ================= Pass 0: 視界ジャック専用（常に最優先で全画面に糸） =================
        // ジャック中のみ描画。深度＝近クリップ面を書き込み、後から描かれる通常の
        // オブジェクトを Z テストで遮断する。さらにステンシル bit128 を立て、
        // 同じシェーダーの別インスタンス（ZTest Always で Z を無視する）が後から
        // 描かれてもジャックを塗り潰せないようにする（Pass 1/2 は bit128 を避ける）。
        Pass
        {
            ZWrite On
            ZTest  Always
            Cull   Front
            Blend  SrcAlpha OneMinusSrcAlpha
            Stencil
            {
                Ref       128
                ReadMask  128
                WriteMask 128
                Comp      Always
                Pass      Replace
            }

            CGPROGRAM
            #pragma vertex   vertJack
            #pragma fragment fragJack
            #pragma target   3.5
            #pragma multi_compile_instancing

            fixed4 fragJack(v2f_d i, out float outDepth : SV_Depth) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                outDepth = UNITY_NEAR_CLIP_VALUE;   // 後続オブジェクトを Z テストで遮断

                if (!SC_DecalJackActive()) discard;

                // 画面空間の糸。描画内容は素の糸パターン（本体ジャックと同系の見た目）。
                float2 screenUV = i.screenPos.xy / max(i.screenPos.w, 1e-5);
                float2 juv = screenUV;
                juv.x *= _ScreenParams.x / _ScreenParams.y;   // アスペクト補正（糸太さを等方に）
                float2 aaJ = float2(fwidth(juv.x), fwidth(juv.y));

                // レイヤー合成は共通実装へ。フラット彩色（flatColor=true）なので
                // ライティングは行われず、基底 N/T/B と位置はダミーでよい。
                // 隙間は共通実装内の discard で素通し（色・深度・ステンシルとも書かない）。
                float3 dummyPos = _WorldSpaceCameraPos + i.worldDir;
                return SC_CompositeLayers(juv, float3(0.0, 1.0, 0.0), float3(1.0, 0.0, 0.0),
                                          float3(0.0, 0.0, 1.0), dummyPos, aaJ,
                                          false, false, true);
            }
            ENDCG
        }

        // ================= Pass 1: 通常カメラ（glue＋糸の厚み） =================
        Pass
        {
            ZWrite Off
            ZTest  Always
            Cull   Front
            Blend  SrcAlpha OneMinusSrcAlpha
            // ジャック（bit128）が描かれた画素には描かない（＝ジャック優先。
            // 同じシェーダーの別インスタンスが後から描かれても上書きできない）
            Stencil
            {
                Ref      128
                ReadMask 128
                Comp     NotEqual
            }

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment fragMain
            #pragma target   3.5
            #pragma multi_compile_instancing

            fixed4 fragMain(v2f_d i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);                       // unity_ObjectToWorld を per-instance に
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                bool inMirror = SC_IsInMirror();
                float2 screenUV = i.screenPos.xy / max(i.screenPos.w, 1e-5);

                // ==== 通常: 深度→体表 glue。輪郭は糸の厚みぶん外へ膨張 ====
                // （視界ジャックは Pass 0 が担当）
                // ミラーは Pass 2（ミラー専用の glue）が担当するため、ここでは描かない。
                if (inMirror) discard;

                float3 camFwd = -UNITY_MATRIX_V[2].xyz;

                float2 duv = UnityStereoTransformScreenSpaceTex(screenUV);
                float rawDepth = UNITY_SAMPLE_SCREENSPACE_TEXTURE(_CameraDepthTexture, duv).r;
                bool hasDepth;
                #if defined(UNITY_REVERSED_Z)
                    hasDepth = (rawDepth > 1e-7);
                #else
                    hasDepth = (rawDepth < 1.0 - 1e-7);
                #endif
                if (!hasDepth) discard;            // 投影先の表面が無い（空）なら描かない

                float  eyeZ    = LinearEyeDepth(rawDepth);
                float  viewZ   = dot(i.worldDir, camFwd);
                float3 rayPerZ = i.worldDir / max(viewZ, 1e-5);
                float3 worldPos = _WorldSpaceCameraPos + rayPerZ * eyeZ;
                float3 localPos = mul(unity_WorldToObject, float4(worldPos, 1.0)).xyz;

                // 床・天井の判定は「ローカル高さのゾーン」で行う（位置ベース）。
                // 画面微分から表面の向きを推定する方式は、距離・角度に依存して
                // 不安定だったため廃止。床・天井は水平面＝ボックス内で一定の高さに
                // あるので、高さゾーンなら視点に一切依存せず決定的に判定できる。
                //   localPos.y < _GroundLevel  → 床（既定 -0.45 = ボックス最下部 5%）
                //   localPos.y > _CeilingLevel → 天井（既定 0.5 = 実質無効）
                bool isFlat = (localPos.y < _GroundLevel) || (localPos.y > _CeilingLevel);

                // 許容距離 _ProjectRange（ワールドm）: 円筒より近い距離にあるメッシュ
                // 表面には「そこにもメッシュがあるかのように」投影する（腕・肩対策）。
                float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
                float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
                float3 colZ = float3(unity_ObjectToWorld._m02, unity_ObjectToWorld._m12, unity_ObjectToWorld._m22);
                float sxz     = 0.5 * (length(colX) + length(colZ));
                float sy      = length(colY);
                float marginR = _ProjectRange / max(sxz, 1e-4);
                float marginH = _ProjectRange / max(sy, 1e-4);

                // 床・天井ゾーンは糸を glue しない（後段でテクスチャ表示へ）
                bool onGlue = !isFlat
                           && (abs(localPos.y) <= _HeightFit + marginH)
                           && (length(localPos.xz) <= _RadiusFit + marginR);

                float T = _GlueThickness;
                bool shellHit = false;

                if (T < 0.0005)
                {
                    // 厚み無し: 従来どおり体表そのものへ glue
                    shellHit = onGlue;
                }
                else
                {
                    // ==== 糸の厚み: glue する面を基準メッシュから厚みぶん外側へ ====
                    // 体表を「厚み T のシェル（膨張面）」に持ち上げ、その面へ glue する。
                    //  - この画素の表面そのもの      → T 手前へ持ち上げ（前面が浮く）
                    //  - 近傍の段差（輪郭のすぐ外）  → 横距離 d に応じ sqrt(T²-d²) 手前へ
                    //    （輪郭が丸く外へ張り出す。足の間隔が 2T 以内なら左右が融合）
                    // 前面と輪郭が1つの連続したシェルになるため、分離したコピー
                    // （分身）のようには見えない。
                    float zShell = 1e6;

                    if (onGlue) zShell = eyeZ - T;      // 前面の持ち上げ

                    float3 boxW = float3(unity_ObjectToWorld._m03, unity_ObjectToWorld._m13, unity_ObjectToWorld._m23);
                    float  zBox   = max(dot(boxW - _WorldSpaceCameraPos, camFwd), 0.05);
                    float  aspect = _ScreenParams.x / _ScreenParams.y;
                    float  zStep  = max(T * 0.3, 0.02);   // 段差（輪郭）とみなす深度差

                    [loop]
                    for (int ri = 1; ri <= 3; ++ri)
                    {
                        float d    = T * (float)ri / 3.0;                   // 横方向の距離（世界）
                        float lift = sqrt(max(T * T - d * d, 0.0));         // その距離での持ち上げ量
                        float rr   = 0.5 * UNITY_MATRIX_P._m11 * d / zBox;  // 画面 UV での半径

                        [loop]
                        for (int di = 0; di < 8; ++di)
                        {
                            float sA, cA;
                            sincos((float)di * (UNITY_PI * 0.25), sA, cA);
                            float2 uvS = screenUV + float2(cA / aspect, sA) * rr;
                            if (uvS.x < 0.0 || uvS.x > 1.0 || uvS.y < 0.0 || uvS.y > 1.0) continue;

                            float rdN = SC_SAMPLE_DEPTH_LOD(UnityStereoTransformScreenSpaceTex(uvS));
                            #if defined(UNITY_REVERSED_Z)
                                if (rdN <= 1e-7) continue;
                            #else
                                if (rdN >= 1.0 - 1e-7) continue;
                            #endif
                            float zN = LinearEyeDepth(rdN);
                            if (zN >= eyeZ - zStep) continue;               // 段差（輪郭）のみ対象

                            // 近傍表面が glue 対象（円筒内）かを確認
                            float3 pq = _WorldSpaceCameraPos + rayPerZ * zN;
                            float3 lq = mul(unity_WorldToObject, float4(pq, 1.0)).xyz;
                            if (abs(lq.y) > _HeightFit + marginH) continue;
                            if (length(lq.xz) > _RadiusFit + marginR) continue;

                            zShell = min(zShell, zN - lift);
                        }
                    }

                    if (zShell < 1e5 && zShell < eyeZ)
                    {
                        float3 p  = _WorldSpaceCameraPos + rayPerZ * zShell;
                        float3 lp = mul(unity_WorldToObject, float4(p, 1.0)).xyz;
                        // シェルは厚みぶんだけ円筒からはみ出せる
                        float exR = T / max(sxz, 1e-4);
                        float exH = T / max(sy, 1e-4);
                        if (abs(lp.y) <= _HeightFit + marginH + exH &&
                            length(lp.xz) <= _RadiusFit + marginR + exR)
                        {
                            localPos = lp;
                            worldPos = p;
                            shellHit = true;
                        }
                    }
                }

                if (!shellHit)
                {
                    // ==== 床・天井: 指定テクスチャ（蜘蛛の巣など）を貼る ====
                    // 未設定（既定 "black"＝α0）なら透明のまま＝何も表示されない。
                    if (isFlat && all(abs(localPos) <= 0.5))
                    {
                        float2 wuv = (localPos.xz + 0.5) * _GroundTex_ST.xy + _GroundTex_ST.zw;
                        fixed4 web = tex2D(_GroundTex, wuv) * _GroundColor;
                        if (web.a <= 0.001) discard;
                        return web;
                    }
                    discard;
                }

                return SC_ShadeCocoonAt(localPos, worldPos, SC_CylRadialNormal(localPos));
            }
            ENDCG
        }

        // ================= Pass 2: ミラー専用（体表 glue・ハードウェアZで正しく遮蔽） =================
        Pass
        {
            ZWrite Off
            ZTest  LEqual
            Cull   Back
            Blend  SrcAlpha OneMinusSrcAlpha
            // ジャック（bit128）が描かれた画素には描かない（ジャック優先）
            Stencil
            {
                Ref      128
                ReadMask 128
                Comp     NotEqual
            }

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment fragMirror
            #pragma target   3.5
            #pragma multi_compile_instancing

            fixed4 fragMirror(v2f_d i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // このパスはミラー内でのみ描く
                if (!SC_IsInMirror()) discard;
                if (SC_DecalJackActive()) discard;   // ミラー内ジャック時は重ねない

                // ==== ミラーでも通常視点と同じ体表 glue ====
                // ミラーカメラは自前の深度を持つが、鏡面に沿った斜交（oblique）投影の
                // ため LinearEyeDepth は使えない。SC_EyeDepthOblique で視線深度を復元する。
                // ボックス前面（Cull Back + ZTest LEqual）が描画キャンバスなので、
                // 鏡内の柱・壁など手前の遮蔽物にはハードウェアZテストで正しく隠れる。
                float2 screenUV = i.screenPos.xy / max(i.screenPos.w, 1e-5);
                float2 duv = UnityStereoTransformScreenSpaceTex(screenUV);
                float rawDepth = UNITY_SAMPLE_SCREENSPACE_TEXTURE(_CameraDepthTexture, duv).r;
                bool hasDepth;
                #if defined(UNITY_REVERSED_Z)
                    hasDepth = (rawDepth > 1e-7);
                #else
                    hasDepth = (rawDepth < 1.0 - 1e-7);
                #endif
                if (!hasDepth) discard;          // 投影先の表面が無ければ描かない

                float3 camFwd  = -UNITY_MATRIX_V[2].xyz;
                float  eyeZ    = SC_EyeDepthOblique(screenUV, rawDepth);
                float  viewZ   = dot(i.worldDir, camFwd);
                float3 rayPerZ = i.worldDir / max(viewZ, 1e-5);
                float3 wp = _WorldSpaceCameraPos + rayPerZ * eyeZ;
                float3 gl = mul(unity_WorldToObject, float4(wp, 1.0)).xyz;

                // 円筒＋許容距離の中の表面のみ glue（床・天井ゾーンは除外）
                float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
                float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
                float3 colZ = float3(unity_ObjectToWorld._m02, unity_ObjectToWorld._m12, unity_ObjectToWorld._m22);
                float sxz     = 0.5 * (length(colX) + length(colZ));
                float sy      = length(colY);
                float marginR = _ProjectRange / max(sxz, 1e-4);
                float marginH = _ProjectRange / max(sy, 1e-4);

                bool isFlat = (gl.y < _GroundLevel) || (gl.y > _CeilingLevel);
                if (isFlat) discard;
                if (abs(gl.y) > _HeightFit + marginH) discard;
                if (length(gl.xz) > _RadiusFit + marginR) discard;

                return SC_ShadeCocoonAt(gl, wp, SC_CylRadialNormal(gl));
            }
            ENDCG
        }
    }

    Fallback Off
}
