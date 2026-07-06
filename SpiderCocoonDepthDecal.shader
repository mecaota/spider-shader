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
        // カテゴリ分け・共通/固有の区別は CustomEditor（SpiderCocoonShaderGUI）が担当。
        // [Header] は Editor スクリプトが無い環境（標準インスペクタ）向けの
        // フォールバック表示。カスタム GUI 側は Header 装飾をスキップして描くため
        // 二重表示にはならない。
        [Header(糸のデザイン)]
        _ThreadColor        ("糸の色 (Thread Color)", Color)              = (1, 1, 1, 1)
        _ThreadThickness    ("糸の太さ (Thickness)", Range(0.01, 1.0))     = 0.35
        _ThreadJitter       ("太さの乱雑性 (Thickness Jitter)", Range(0, 1))= 0.3
        _ThreadFuzz         ("幅の揺らぎ (Fuzz Amount)", Range(0, 1))       = 0.2
        _ThreadFuzzScale    ("揺らぎの細かさ (Fuzz Scale)", Float)          = 8.0

        [Header(巻きのレイアウト)]
        _WindingCount       ("巻き数 (Winding Count)", Float)               = 24
        _ThreadDensity      ("糸の密度倍率 (Density Mult)", Float)          = 1.0
        _FiberAngle         ("基準の糸の角度 (Base Fiber Angle deg)", Range(-89, 89)) = 0

        [Header(トゥーン陰影)]
        _ToonSteps          ("トゥーン段階数 (Toon Steps)", Range(1, 8))    = 3
        _ToonSmooth         ("段差の柔らかさ (Toon Smooth)", Range(0.001, 0.5)) = 0.05
        _ShadowColor        ("影色 (Shadow Tint)", Color)                  = (0.55, 0.55, 0.62, 1)
        _AmbientBoost       ("環境光の底上げ (Ambient Boost)", Range(0, 1)) = 0.35
        _LightInfluence     ("シーン光の反映度 (Light Influence)", Range(0, 1)) = 0.5

        [Header(リムライト)]
        _RimColor           ("リムライト色 (Rim Color)", Color)            = (0.8, 0.9, 1.0, 1)
        _RimPower           ("リム幅 / 鋭さ (Rim Power)", Range(0.5, 16))   = 4.0
        _RimStrength        ("リム強さ (Rim Strength)", Range(0, 4))        = 0.4
        _RimFloor           ("リムの下限/全体発光 (Rim Floor)", Range(0, 1)) = 0.25

        [Header(糸ごとの陰影)]
        _FiberNormalStrength("糸断面の法線曲げ (Fiber Normal Strength)", Range(0, 1)) = 0.4
        _RimShadowColor     ("ファイバー縁の影色 (Fiber Edge Shadow)", Color) = (0.25, 0.22, 0.22, 1)
        _RimShadowStrength  ("ファイバー縁影の濃さ (Edge Shadow Strength)", Range(0, 1)) = 0.3

        [Header(レイヤー)]
        _LayerCount         ("レイヤー枚数 (Layer Count)", Range(1, 8))     = 3
        _LayerAngleStep     ("レイヤー角度ステップ (Angle Step deg)", Range(-45, 45)) = 8
        _LayerPosStepX      ("レイヤー位置ステップ X 円周 (Pos Step X)", Float) = 0.02
        _LayerPosStepY      ("レイヤー位置ステップ Y 軸 (Pos Step Y)", Float) = 0.0
        _LayerThicknessFalloff ("奥レイヤーの減衰 (Thickness Falloff)", Range(0, 1)) = 0.0

        [Header(投影フィット)]
        _RadiusFit          ("円筒半径 (box内接=0.5)", Range(0.05, 0.5))   = 0.5
        _HeightFit          ("円筒高さ (box一杯=0.5)", Range(0.05, 0.5))   = 0.5
        _ProjectRange       ("投影の許容距離 (Project Range m)", Range(0, 0.5)) = 0.1

        [Header(糸の厚み)]
        _GlueThickness      ("糸の厚み m 輪郭の外への膨張 (Glue Thickness)", Range(0, 0.2)) = 0.06

        [Header(床と天井)]
        _GroundTex          ("床/天井テクスチャ 蜘蛛の巣など (Ground Web)", 2D) = "black" {}
        _GroundColor        ("床/天井テクスチャの色 (Ground Tint)", Color) = (1, 1, 1, 1)
        _GroundDetectScale  ("床判定のサンプル間隔 m (Ground Detect Scale)", Range(0.01, 0.2)) = 0.05
        _GroundNormalY      ("水平とみなす法線Y (Horizontal Normal Y)", Range(0.5, 0.99)) = 0.8

        [Header(視界ジャック)]
        [Toggle] _VisionJackEnable ("視界ジャック有効 (Vision Jack)", Float) = 1
        [Toggle] _VisionJackInMirror ("ミラー内でも発火 (In Mirror)", Float) = 0
        _JackRadius         ("ジャック内壁の半径倍率 (Jack Radius Scale)", Range(0.2, 2)) = 0.7
        _JackStretch        ("ジャック内壁が閉じるまでの縦距離 (Jack Vertical Stretch)", Range(0.25, 4)) = 1.0
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
        float _JackRadius;
        float _JackStretch;

        sampler2D _GroundTex;
        float4    _GroundTex_ST;
        fixed4    _GroundColor;
        float     _GroundDetectScale;
        float     _GroundNormalY;

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

        // 画面上の任意 UV の深度から view 空間座標を厳密復元（斜交投影対応。
        // SC_EyeDepthOblique と同じ代数で、xy 成分まで求める版）
        float3 SC_ViewPosAt(float2 uv, float rawDepth)
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
            float w = UNITY_MATRIX_P._m23 / denom;
            return float3(w * (ndc.x + UNITY_MATRIX_P._m02) / UNITY_MATRIX_P._m00,
                          w * (ndc.y + UNITY_MATRIX_P._m12) / UNITY_MATRIX_P._m11,
                          -w);
        }

        // 隣接画素の深度を「厳密復元」して表面の世界法線を求め、水平面かを判定する。
        // ・GPU の自動微分(ddx/ddy)は使わない（浅い角度で外積の向きが暴れて過去2回
        //   失敗した原因）。明示的に±2pxの4点をサンプルし、3点から法線を構成する。
        // ・シルエット境界の深度段差は「深度差が小さい側」を選んで回避（古典的な
        //   頑健法線復元）。両側とも段差なら輪郭画素とみなし水平面ではない扱い。
        // 高さゾーンに依存しないため、床の高さを厳密に合わせられない場合
        // （アバター搭載・段差・ジャンプ中など）でも床・天井を識別できる。
        bool SC_IsHorizontalSurface(float2 uv, float rawDepth0)
        {
            float3 p0 = SC_ViewPosAt(uv, rawDepth0);
            float  z0 = -p0.z;

            // サンプル間隔は「世界で約 _GroundDetectScale (m)」を基準にする。
            // 画素数固定だと近距離で対応する実寸が縮み、体表の微細な起伏
            // （肩・胸・服のしわ等の局所的な上向き面）まで床と誤判定して、
            // 近づくほど糸が消える。世界基準なら距離に依らず同じスケールで
            // 面の向きを評価できる。遠距離では最低2pxを確保。
            float2 px;
            px.x = 0.5 * abs(UNITY_MATRIX_P._m00) * _GroundDetectScale / max(z0, 0.05);
            px.y = 0.5 * abs(UNITY_MATRIX_P._m11) * _GroundDetectScale / max(z0, 0.05);
            px = max(px, 2.0 / _ScreenParams.xy);

            // X方向: 左右のうち深度差が小さい側を採用
            float2 uvR = uv + float2(px.x, 0.0);
            float2 uvL = uv - float2(px.x, 0.0);
            float3 pR = SC_ViewPosAt(uvR, SC_SAMPLE_DEPTH_LOD(UnityStereoTransformScreenSpaceTex(uvR)));
            float3 pL = SC_ViewPosAt(uvL, SC_SAMPLE_DEPTH_LOD(UnityStereoTransformScreenSpaceTex(uvL)));
            float dzR = abs(-pR.z - z0);
            float dzL = abs(-pL.z - z0);
            float3 dX = (dzR <= dzL) ? (pR - p0) : (p0 - pL);

            // Y方向も同様
            float2 uvU = uv + float2(0.0, px.y);
            float2 uvD = uv - float2(0.0, px.y);
            float3 pU = SC_ViewPosAt(uvU, SC_SAMPLE_DEPTH_LOD(UnityStereoTransformScreenSpaceTex(uvU)));
            float3 pD = SC_ViewPosAt(uvD, SC_SAMPLE_DEPTH_LOD(UnityStereoTransformScreenSpaceTex(uvD)));
            float dzU = abs(-pU.z - z0);
            float dzD = abs(-pD.z - z0);
            float3 dY = (dzU <= dzD) ? (pU - p0) : (p0 - pD);

            // 両側とも大きな深度跳び＝輪郭画素 → 水平面ではない扱い
            float maxStep = 0.10 + 0.05 * z0 + _GroundDetectScale * 2.0; // 距離とサンプル間隔に応じた許容段差
            if (min(dzR, dzL) > maxStep) return false;
            if (min(dzU, dzD) > maxStep) return false;

            // view 空間の法線 → 世界空間へ（V の回転部の転置＝逆変換）
            float3 nV = cross(dX, dY);
            float3 nW = mul(nV, (float3x3)UNITY_MATRIX_V);
            nW = normalize(nW + float3(0.0, 1e-6, 0.0));
            return abs(nW.y) > _GroundNormalY;
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
            // N はワールド固定の径方向のまま使う（視線による反転はしない）。
            // 反転すると法線が常にカメラを向き、陰影がカメラ追従になって
            // 正対時に白飛びする（ライト方向ベースの自然な陰影にならない）。
            // 裏向き法線でのリム暴走は SC_RimLight 側の abs で防いでいる。
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

                // 視界ジャック: カメラを囲む繭の「内壁」を、体表 glue と同じ描画処理で描く。
                // 交差先は無限円筒ではなく「上下が閉じた紡錘形（楕円体）」。
                // 上下に遠ざかるほど糸のリングの半径が縮み、極で 0 に収束して閉じる。
                //   半径 = _RadiusFit × _JackRadius（実円筒より小さくできる）
                //   半高 = _HeightFit × _JackStretch（閉じるまでの縦距離）
                // 内壁を小さくするとカメラが楕円体の外に出得るため、レイ原点を
                // 楕円体内へ連続的に引き込み、常に「内側から奥壁を見る」状態を保証する。
                // 糸のパラメータもライティングも通常の繭と完全に同一。隙間は共通
                // 実装内の discard で素通し（色・深度・ステンシルとも書かない）。
                float3 rdW = normalize(i.worldDir);
                float3 o = mul(unity_WorldToObject, float4(_WorldSpaceCameraPos, 1.0)).xyz;
                float3 d = mul((float3x3)unity_WorldToObject, rdW);

                float A = _RadiusFit * _JackRadius;                  // 内壁の半径
                float B = _HeightFit * _JackStretch;                 // 半高（閉じるまでの距離）

                // 楕円体を単位球へスケールしてレイ-球交差（奥側解）
                float3 os = float3(o.x / A, o.y / B, o.z / A);
                float3 ds = float3(d.x / A, d.y / B, d.z / A);

                // 原点の引き込み: 楕円体の外（または縁ぎりぎり）なら内側へ寄せる
                float osLen = length(os);
                if (osLen > 0.9) os *= 0.9 / osLen;

                float a2 = max(dot(ds, ds), 1e-9);
                float b2 = 2.0 * dot(os, ds);
                float c2 = dot(os, os) - 1.0;                        // 引き込み後は常に負
                float t  = (-b2 + sqrt(max(b2 * b2 - 4.0 * a2 * c2, 0.0))) / (2.0 * a2);

                float3 oc = float3(os.x * A, os.y * B, os.z * A);    // 引き込み後のローカル原点
                float3 lp = oc + d * t;
                float3 wp = mul(unity_ObjectToWorld, float4(lp, 1.0)).xyz;

                // 楕円体の内向き法線（勾配ベース。ローカル→ワールドへ方向変換）
                float3 nL = normalize(float3(lp.x / (A * A), lp.y / (B * B), lp.z / (A * A)));
                float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
                float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
                float3 colZ = float3(unity_ObjectToWorld._m02, unity_ObjectToWorld._m12, unity_ObjectToWorld._m22);
                float3 nW = normalize(colX * nL.x + colY * nL.y + colZ * nL.z);

                return SC_ShadeCocoonAt(lp, wp, -nW);
            }
            ENDCG
        }

        // ================= Pass 1: 通常カメラ（glue＋糸の厚み） =================
        Pass
        {
            // ForwardBase タグ: これが無いとメインライト（_WorldSpaceLightPos0 /
            // _LightColor0）と環境光(SH)がバインドされず、直前の描画の残り値で
            // ライティングされて描画順しだいで不自然になる。
            Tags { "LightMode" = "ForwardBase" }

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

                // 床・天井の判定: 面の向き（厳密復元した法線が水平面か）で行う。
                // 高さ不問なので、アバター搭載・段差・ジャンプ中でも床を識別できる。
                bool isFlat = SC_IsHorizontalSurface(screenUV, rawDepth);

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
            // ForwardBase タグ: Pass 1 と同じくメインライト・環境光のバインドに必要
            Tags { "LightMode" = "ForwardBase" }

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

                if (SC_IsHorizontalSurface(screenUV, rawDepth)) discard;   // 床・天井は描かない
                if (abs(gl.y) > _HeightFit + marginH) discard;
                if (length(gl.xz) > _RadiusFit + marginR) discard;

                return SC_ShadeCocoonAt(gl, wp, SC_CylRadialNormal(gl));
            }
            ENDCG
        }
    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}
