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
//  ★ 視界ジャック（包まれ演出）: カメラが殻円筒の内側に入ると、カメラの周囲に
//     繭の内壁（紡錘形楕円体）を「実寸の深度付き」で描く。壁より手前にある
//     自分のアバターの体などは遮られず見える＝繭に包まれている見え方。
//     実装は SpiderCocoon 本体と共通（CGINC/SpiderCocoon_VisionJack.cginc）。
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
        _LayerPosStepX      ("レイヤー位置ステップ X 円周 (Pos Step X)", Float) = 0.02
        _LayerPosStepY      ("レイヤー位置ステップ Y 軸 (Pos Step Y)", Float) = 0.0
        _LayerThicknessFalloff ("奥レイヤーの減衰 (Thickness Falloff)", Range(0, 1)) = 0.0

        [Header(Projection Fit)]
        _RadiusFit          ("円筒半径 (box内接=0.5)", Range(0.05, 0.5))   = 0.5
        _HeightFit          ("円筒高さ (box一杯=0.5)", Range(0.05, 0.5))   = 0.5
        _ProjectRange       ("投影の許容距離 (Project Range m)", Range(0, 0.5)) = 0.1

        [Header(Glue Thickness)]
        _GlueThickness      ("糸の厚み m 輪郭の外への膨張 (Glue Thickness)", Range(0, 0.2)) = 0.06

        [Header(Ground And Ceiling)]
        _GroundTex          ("床/天井テクスチャ 蜘蛛の巣など (Ground Web)", 2D) = "black" {}
        _GroundColor        ("床/天井テクスチャの色 (Ground Tint)", Color) = (1, 1, 1, 1)
        _GroundDetectScale  ("床判定のサンプル間隔 m (Ground Detect Scale)", Range(0.01, 0.2)) = 0.05
        _GroundNormalY      ("水平とみなす法線Y (Horizontal Normal Y)", Range(0.5, 0.99)) = 0.8

        [Header(Vision Jack)]
        [Toggle] _VisionJackEnable ("視界ジャック有効 (Vision Jack)", Float) = 1
        [Toggle] _VisionJackInMirror ("ミラー内でも発火 (In Mirror)", Float) = 0
        _JackRadius         ("ジャック内壁の半径倍率 (Jack Radius Scale)", Range(0.2, 2)) = 0.7
        _JackStretch        ("ジャック内壁が閉じるまでの縦距離 (Jack Vertical Stretch)", Range(0.25, 4)) = 1.0

        [Header(Render State)]
        // ジャック壁の目印に使うステンシルビット。他のステンシル利用シェーダー
        // （アバター等）と衝突する場合にワールド側で付け替えられるようにする。
        // 本体とデカールの両マテリアルで同じ値に揃えること。
        [IntRange] _StencilRef ("ステンシル ビット (Stencil Bit)", Range(0, 255)) = 128
    }

    SubShader
    {
        // DisableBatching: 静的/動的バッチングされると unity_ObjectToWorld が単位行列
        // 相当になり、オブジェクト空間依存の glue 円筒判定・発火判定がすべて壊れるため必須。
        Tags { "Queue" = "Transparent" "RenderType" = "Transparent" "IgnoreProjector" = "True" "DisableBatching" = "True" }

        CGINCLUDE
        #include "UnityCG.cginc"
        #include "Lighting.cginc"

        #include "CGINC/SpiderCocoon_Noise.cginc"
        #include "CGINC/SpiderCocoon_Common.cginc"
        #include "CGINC/SpiderCocoon_Thread.cginc"
        #include "CGINC/SpiderCocoon_Lighting.cginc"
        #include "CGINC/SpiderCocoon_Compose.cginc"
        #include "CGINC/SpiderCocoon_VisionJack.cginc"

        UNITY_DECLARE_SCREENSPACE_TEXTURE(_CameraDepthTexture);

        // ※ _JackRadius / _JackStretch は共通化に伴い Common.cginc 側で宣言
        float _RadiusFit;
        float _HeightFit;
        float _ProjectRange;
        float _GlueThickness;

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

        // ---------------------------------------------------------------------
        // ★ VR ステレオの取り扱い（この2つの約束を全パスで統一する）:
        //   1) 画面 UV は常に「片目ローカル（0..1 がその目の視界全体）」で持ち回る。
        //      NDC 復元（uv*2-1）や隣接サンプルのオフセット計算はこの空間で行う。
        //      UNITY_MATRIX_P / _WorldSpaceCameraPos はステレオ時に目ごとの値へ
        //      差し替わるため、この空間なら左右それぞれで正しい逆射影になり、
        //      両目が「同一のワールド座標」を復元する＝左右の表示が一致する。
        //   2) _CameraDepthTexture を読む「瞬間」にだけ SC_DEPTH_UV() で変換する。
        //      Single-Pass(double-wide) では片目UV→横長テクスチャの半分領域へ、
        //      Instanced/mono では恒等変換（配列スライスは SC_SAMPLE_DEPTH_LOD が担当）。
        // ---------------------------------------------------------------------
        #define SC_DEPTH_UV(uv) UnityStereoTransformScreenSpaceTex(uv)

        // 片目ローカルUVでの 1px サイズ。
        // Single-Pass(double-wide) の _ScreenParams.x は「両目合計」の幅を返すため、
        // unity_StereoScaleOffset の scale（=0.5）で片目ぶんへ換算する。
        float2 SC_EyeTexelSize()
        {
            float2 ts = 1.0 / _ScreenParams.xy;
        #if defined(UNITY_SINGLE_PASS_STEREO)
            ts.x /= unity_StereoScaleOffset[unity_StereoEyeIndex].x;
        #endif
            return ts;
        }

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
            px = max(px, 2.0 * SC_EyeTexelSize());   // 最低2px（片目ローカル基準）
            px = min(px, 0.1);                       // 近距離で間隔が画面を覆うほど暴走しない上限

            // 片目ローカル 0..1 を出た隣接サンプルは「その側を選択候補から外す」。
            //  ・範囲外UVのままだと、深度はクランプ（double-wide はステレオ変換の
            //    saturate、mono/Instanced はサンプラー）される一方で NDC は画面外へ
            //    外挿され、表面上に存在しない偽の点が復元される
            //  ・しかもクランプで深度差≈0 になるため「深度差が小さい側を採用」の
            //    ロジックが偽の点を優先選択してしまう
            //  → dz を無限大扱いにし、必ず画面内の側の差分で法線を作る。
            //    両側とも範囲外なら後段の maxStep 判定が false（水平面でない）を返す。
            float2 uvMax = 1.0 - SC_EyeTexelSize();  // 1.0丁度は隣の目の先頭テクセルに触れる

            // X方向: 画面内かつ深度差が小さい側を採用。
            // 範囲判定は「オフセットした軸のみ」を見る（フラグメント自身の uv は
            // 必ず画面内。動かしていない軸まで検査すると、ピクセル中心が
            // 1-0.5px の最終行/列で両側とも除外され、その1px帯の床判定が
            // 常に false になってしまう）。
            float2 uvR = uv + float2(px.x, 0.0);
            float2 uvL = uv - float2(px.x, 0.0);
            bool   inR = (uvR.x <= uvMax.x);
            bool   inL = (uvL.x >= 0.0);
            float3 pR = SC_ViewPosAt(uvR, SC_SAMPLE_DEPTH_LOD(SC_DEPTH_UV(uvR)));
            float3 pL = SC_ViewPosAt(uvL, SC_SAMPLE_DEPTH_LOD(SC_DEPTH_UV(uvL)));
            float dzR = inR ? abs(-pR.z - z0) : 1e9;
            float dzL = inL ? abs(-pL.z - z0) : 1e9;
            float3 dX = (dzR <= dzL) ? (pR - p0) : (p0 - pL);

            // Y方向も同様
            float2 uvU = uv + float2(0.0, px.y);
            float2 uvD = uv - float2(0.0, px.y);
            bool   inU = (uvU.y <= uvMax.y);
            bool   inD = (uvD.y >= 0.0);
            float3 pU = SC_ViewPosAt(uvU, SC_SAMPLE_DEPTH_LOD(SC_DEPTH_UV(uvU)));
            float3 pD = SC_ViewPosAt(uvD, SC_SAMPLE_DEPTH_LOD(SC_DEPTH_UV(uvD)));
            float dzU = inU ? abs(-pU.z - z0) : 1e9;
            float dzD = inD ? abs(-pD.z - z0) : 1e9;
            float3 dY = (dzU <= dzD) ? (pU - p0) : (p0 - pD);

            // 両側とも大きな深度跳び＝輪郭画素 → 水平面ではない扱い
            float maxStep = 0.10 + 0.05 * z0 + _GroundDetectScale * 2.0; // 距離とサンプル間隔に応じた許容段差
            if (min(dzR, dzL) > maxStep) return false;
            if (min(dzU, dzD) > maxStep) return false;

            // view 空間の法線 → 世界空間へ（V の回転部の転置＝逆変換）
            float3 nV = cross(dX, dY);
            // 画面端のクランプ等で隣接点が中心と一致し法線が構成できない画素は、
            // 「水平面ではない」扱い（＝糸を描く従来既定）にフォールバックする。
            // ここで (0,1,0) に正規化してしまうと床と誤判定し、画面端に
            // 糸の消える帯が出る（VRでは左右で帯の位置が違い、チラつく）。
            if (dot(nV, nV) < 1e-14) return false;
            float3 nW = mul(nV, (float3x3)UNITY_MATRIX_V);
            nW = normalize(nW + float3(0.0, 1e-6, 0.0));
            return abs(nW.y) > _GroundNormalY;
        }

        // 視界ジャック（包まれ演出）の発火判定。vert/frag で同一のこの関数を使い、
        // 判定を一致させる。実体は共通実装（SpiderCocoon_VisionJack.cginc）で、
        // 中央カメラ位置により左右の目で必ず同じ結果になる。
        // ※ SC_CylRadialNormal / SC_ShadeCocoonAt も共通化に伴い
        //    SpiderCocoon_Compose.cginc へ移動した。
        bool SC_DecalJackActive()
        {
            return SC_VisionJackActiveEx(_RadiusFit, _HeightFit);
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
            // ★ 必ず「非ステレオ版」を使う（VRの左右ズレ・チラつき対策の核心）。
            // ComputeScreenPos は Single-Pass(double-wide) VR だと横長テクスチャの
            // 半分領域へ変換済みの UV を返す。その UV にフラグメント側の
            // SC_DEPTH_UV（UnityStereoTransformScreenSpaceTex）を重ねると変換が
            // 二重適用になり、深度の読み先が左右の目で別々にズレてしまう。
            // さらに NDC 復元（uv*2-1）も壊れ、床/天井判定が左右で食い違う。
            // 非ステレオ版なら常に「片目ローカル 0..1」となり、上記の約束と一致する。
            o.screenPos = ComputeNonStereoScreenPos(o.pos);
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

        // ================= Pass 0: 視界ジャック＝包まれ演出（共通実装） =================
        // ジャック中のみ描画。カメラを囲む繭の内壁（紡錘形楕円体）を「実寸の深度
        // 付き」で描く（実体は SpiderCocoon_VisionJack.cginc / 本体シェーダーと共通）。
        //   半径 = _RadiusFit × _JackRadius（実円筒より小さくできる）
        //   半高 = _HeightFit × _JackStretch（閉じるまでの縦距離）
        // ZTest LEqual ＋ 実深度の書き込みにより、壁より手前にあるもの
        // （自分のアバターの体・同じ繭の中の他プレイヤー）は遮られず見える。
        // 壁より奥の世界は糸に覆われ、隙間からだけ覗ける＝「包まれている」見え方。
        // ZWrite On なので、後から描かれる透明オブジェクトも壁と正しく前後判定される。
        // ステンシル bit128 を立て、後続の glue（Pass 1/2、ZTest Always で Z を
        // 無視する）が壁の糸を上塗りしないようにする。壁より手前で glue 対象の
        // 体表には Pass 1 が引き続き糸を描く（体も巻かれたまま包まれる）。
        Pass
        {
            // ForwardBase タグ: メインライト・環境光を確実にバインドする
            // （無いと直前の描画の残り値でライティングされ、描画順で見た目が揺れる）
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

            fixed4 fragJack(v2f_d i, out float outDepth : SV_Depth) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                outDepth = UNITY_NEAR_CLIP_VALUE;   // 仮値（discard 経路では書き込まれない）

                if (!SC_DecalJackActive()) discard;

                return SC_VisionJackWallShade(i.worldDir,
                                              _RadiusFit * _JackRadius,
                                              _HeightFit * _JackStretch,
                                              outDepth);
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
                Ref      [_StencilRef]
                ReadMask [_StencilRef]
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

                float2 duv = SC_DEPTH_UV(screenUV);
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

                // ★ 許容距離を足しても「このボックスの外」へは絶対に出さない。
                // box ローカルの半幅は 0.5。ここで上限を切ることで、
                //   ・シェーダーを設定したオブジェクトの中に入ったメッシュにのみ描く
                //   ・ボックス越しに見えた外のオブジェクトへは一切影響しない
                // を厳密に保証する（_RadiusFit を小さくした時の腕・肩対策マージンは維持）。
                float limR = min(_RadiusFit + marginR, 0.5);
                float limH = min(_HeightFit + marginH, 0.5);

                // 床・天井ゾーンは糸を glue しない（後段でテクスチャ表示へ）
                bool onGlue = !isFlat
                           && (abs(localPos.y) <= limH)
                           && (length(localPos.xz) <= limR);

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
                    // 片目の縦横比は射影行列から取る（m11/m00 = アスペクト比）。
                    // _ScreenParams は Single-Pass(double-wide) VR で両目合計の幅を
                    // 返すため、それで割ると左右の目でオフセット距離が狂う。
                    float  aspect = abs(UNITY_MATRIX_P._m11 / UNITY_MATRIX_P._m00);
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
                            // uvS は片目ローカル 0..1。画面外は「棄却」ではなく
                            // 端へクランプしてサンプルする（mono のサンプラーの
                            // エッジクランプと同じ連続的な劣化になり、棄却の有無と
                            // いう二値差が左右の目で食い違ってチラつくのを防ぐ。
                            // 上限 1-1px は double-wide で隣の目の先頭テクセルを
                            // 踏まないため）。
                            float2 uvS = screenUV + float2(cA / aspect, sA) * rr;
                            uvS = clamp(uvS, 0.0, 1.0 - SC_EyeTexelSize());

                            float rdN = SC_SAMPLE_DEPTH_LOD(SC_DEPTH_UV(uvS));
                            #if defined(UNITY_REVERSED_Z)
                                if (rdN <= 1e-7) continue;
                            #else
                                if (rdN >= 1.0 - 1e-7) continue;
                            #endif
                            float zN = LinearEyeDepth(rdN);
                            if (zN >= eyeZ - zStep) continue;               // 段差（輪郭）のみ対象

                            // 近傍表面が glue 対象（円筒内）かを確認。
                            // 近傍点は「そのピクセル(uvS)のレイ」上で厳密復元する。
                            // 中心ピクセルのレイ×近傍の深度で代用すると、点が横に
                            // 最大 _GlueThickness ぶんずれ、円筒境界での採否が狂う。
                            float3 vq = SC_ViewPosAt(uvS, rdN);
                            float3 pq = mul(UNITY_MATRIX_I_V, float4(vq, 1.0)).xyz;
                            float3 lq = mul(unity_WorldToObject, float4(pq, 1.0)).xyz;
                            if (abs(lq.y) > limH) continue;
                            if (length(lq.xz) > limR) continue;

                            zShell = min(zShell, zN - lift);
                        }
                    }

                    if (zShell < 1e5 && zShell < eyeZ)
                    {
                        float3 p  = _WorldSpaceCameraPos + rayPerZ * zShell;
                        float3 lp = mul(unity_WorldToObject, float4(p, 1.0)).xyz;
                        // シェルは厚みぶんだけ円筒からはみ出せる（ただし box の外は不可）
                        float exR = T / max(sxz, 1e-4);
                        float exH = T / max(sy, 1e-4);
                        if (abs(lp.y) <= min(limH + exH, 0.5) &&
                            length(lp.xz) <= min(limR + exR, 0.5))
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
                Ref      [_StencilRef]
                ReadMask [_StencilRef]
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
                // ミラー内ジャック時は重ねない。
                // 既知の制限: _VisionJackInMirror=1 でミラー内ジャックが発火して
                // いる間、鏡の中では壁の隙間から見える体表の glue が描かれない
                // （直視では Pass 1 が体表に糸を描き続けるが、このパスは全体を
                //   discard するため）。挙動を直視と完全一致させるには oblique
                //   深度復元での glue 描画をこの分岐に実装する必要がある。
                //   既定値（_VisionJackInMirror=0）では発生しない。
                if (SC_DecalJackActive()) discard;

                // ==== ミラーでも通常視点と同じ体表 glue ====
                // ミラーカメラは自前の深度を持つが、鏡面に沿った斜交（oblique）投影の
                // ため LinearEyeDepth は使えない。SC_EyeDepthOblique で視線深度を復元する。
                // ボックス前面（Cull Back + ZTest LEqual）が描画キャンバスなので、
                // 鏡内の柱・壁など手前の遮蔽物にはハードウェアZテストで正しく隠れる。
                float2 screenUV = i.screenPos.xy / max(i.screenPos.w, 1e-5);
                float2 duv = SC_DEPTH_UV(screenUV);
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
                // Pass 1 と同じく box の外へは出さない（対象外オブジェクト保護）
                float limR = min(_RadiusFit + marginR, 0.5);
                float limH = min(_HeightFit + marginH, 0.5);

                if (SC_IsHorizontalSurface(screenUV, rawDepth)) discard;   // 床・天井は描かない
                if (abs(gl.y) > limH) discard;
                if (length(gl.xz) > limR) discard;

                return SC_ShadeCocoonAt(gl, wp, SC_CylRadialNormal(gl));
            }
            ENDCG
        }
    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}
