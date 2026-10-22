// =============================================================================
// SpiderWebDrape.shader — 蜘蛛の巣ドレープシェーダー（蜘蛛糸の粘液シート）（PC / Unity 2022.3 / Built-in RP）
// 初心者向け: 蜘蛛糸（SpiderSilk）の粘液モードの帯（束＋穴の空いた膜）を、
// すき間なく並べた模様を Editor で画像（距離・補助・被覆率の 3 配列）へ焼きます。
// 実行中は各層がその画像を少し回転・ずらして読み、体に覆いかぶさる粘液の膜（Drape）として
// 最大 8 層に重ねます（深度は一番内側の層だけ書く 9 パス）。帯の中の形の設定は蜘蛛糸と同じ名前・意味で、糸に沿った方向の単位も
// 同じメートルです（_SheetAlongScale = メッシュ UV 1 あたりのメートル。WebPlane は 1 m 四方で、
// 投げ網 CaptureNetDrape では約 1.95 倍＝約 2 m。既定の 3 は蜘蛛糸より玉・穴が少し細かい）。
// 形の入力を変えたら Inspector の「焼き直す」を押します。色・光沢・層数・層ごとの太さは不要です。
// 2026-10-08 採用（他の蜘蛛の巣ドレープ系シェーダーは撤去）。
// =============================================================================
Shader "mecaota/SpiderWebDrape"
{
    Properties
    {
        // ※ 質感（Look）21 個（_Goo の色・陰影・光沢・粘液感 / トゥーン / リム）は 5 シェーダー
        //   （蜘蛛糸・蜘蛛の巣・繭・繭デカール・蜘蛛の巣ドレープ）で
        //   名前・型・範囲・既定値を完全一致させる（一覧: Editor/SpiderSilkLook.cs、宣言: CGINC/SpiderSilk_Look.cginc）。
        //   巣・繭・繭デカール・蜘蛛の巣ドレープではこの値を「継承元の蜘蛛糸マテリアル」から受け継ぐ。
        // カテゴリ分けは CustomEditor（SpiderCocoonShaderGUI）が担当。
        // [Header] は標準インスペクタ向けのフォールバック表示。
        // ※ ShaderLab の属性引数は ASCII のみ（日本語を書くとパースエラー）。
        [Header(Baked Pattern)]
        [IntRange] _BakedVariants ("焼込: 模様の枚数 (Variants)", Range(1, 3)) = 3
        [Enum(Size512,512,Size1024,1024,Size2048,2048)] _BakeResolution ("焼込: 解像度 (Resolution)", Float) = 1024
        [Enum(Uncompressed,0,BC5_BC7,1)] _BakeCompression ("焼込: 無圧縮 / 圧縮 (Compression)", Float) = 1
        _BakePadding ("焼込: 読取範囲の余白 UV (Padding)", Range(0.02, 0.3)) = 0.08
        [HideInInspector] _BakedShape ("Baked Shape", 2DArray) = "" {}
        [HideInInspector] _BakedDetail ("Baked Detail", 2DArray) = "" {}
        [HideInInspector] _BakedCoverage ("Baked Coverage", 2DArray) = "" {}
        [HideInInspector] _BakedTexelSize ("Baked Texel Size", Vector) = (0.0009765625, 0.0009765625, 1024, 1024)
        [HideInInspector] _BakedDistanceRange ("Baked Distance Range", Vector) = (1, 1, 1, 0)
        [HideInInspector] _BakedRadiusRange ("Baked Radius Range", Vector) = (1, 1, 1, 0)
        [HideInInspector] _BakedUVSpan ("Baked UV Span", Float) = 1
        [HideInInspector] _BakedSliceCount ("Baked Slice Count", Float) = 0
        [HideInInspector] _BakedWetParams ("Baked Wet Parameters", Vector) = (1, 1, 1, 0)


        [Header(Layers)]
        [IntRange] _WebLayers ("重ねる膜の枚数 (Layers)", Range(1, 8)) = 2
        _WebLayerDepth ("浮遊部の全層の厚さ m (Stack Depth)", Range(0.007, 0.12)) = 0.06
        _WebLayerContactDepth ("接着部の全層の厚さ m (Contact Depth)", Range(0.007, 0.07)) = 0.008
        _WebLayerAdhere ("接着する割合の目安 (Adhere)", Range(0, 1)) = 0.35
        _WebLayerAdhereScale ("接着の斑の細かさ UV毎 (Adhere Scale)", Float) = 4
        _WebLayerTwist ("層ごとの回転 角度 (Layer Twist)", Range(0, 180)) = 8
        _WebLayerShift ("模様のずれ上限 半径比 (Pattern Shift)", Range(0, 0.5)) = 0.08
        _WebLayerOpacity ("層ごとの不透明度倍率 (Layer Opacity)", Range(0.3, 1)) = 0.95
        _WebLayerWidthOuter ("一番外の層の太さ倍率 (Outer Width)", Range(0.3, 3)) = 1
        _WebLayerWidthJitter ("層ごとの太さのばらつき (Width Jitter)", Range(0, 1)) = 0

        [Header(Goo Sheet)]
        _WebRadius ("膜の外形の半径 UV (Sheet Radius)", Range(0.05, 1.5)) = 0.5
        _SheetBandWidth ("粘液の帯の幅 UV (Band Width)", Range(0.02, 0.5)) = 0.12
        _SheetRotation ("帯の向き 角度 (Band Rotation)", Range(0, 180)) = 17
        _SheetAlongScale ("帯に沿った長さ m/UV (Along Scale)", Range(0.1, 10)) = 3

        // ---- 帯の中の形（蜘蛛糸 SpiderSilk の粘液モードと同じ名前・範囲・既定値） ----
        [Header(Silk Strands)]
        [IntRange] _GooStrands ("束の本数 (Strands)", Range(1, 4))           = 3
        _GooWidth           ("束の太さ 帯幅比 (Strand Width)", Range(0.02, 1)) = 0.24
        _GooSpread          ("束の並ぶ幅 (Spread)", Range(0, 1))             = 0.6
        _GooWobble          ("蛇行の振れ幅 (Wobble)", Range(0, 0.5))          = 0.16
        _GooWobbleFreq      ("蛇行の細かさ uv.x毎 (Wobble Freq)", Float)      = 0.7
        _GooBeads           ("くびれと玉 (Beads)", Range(0, 1))              = 0.55
        _GooBeadFreq        ("玉の細かさ uv.x毎 (Bead Freq)", Float)          = 2.2
        _GooMerge           ("融合の粘り (Merge)", Range(0, 1))              = 0.35
        _GooWeb             ("束の間の膜の量 (Web Amount)", Range(0, 1))      = 0.6
        _GooWebCell         ("穴の間隔 uv.x単位 (Hole Spacing)", Float)       = 0.3
        _GooWebRows         ("幅方向の穴の列数 (Hole Rows)", Range(1, 8))     = 2.5
        _GooWebHole         ("穴の開き具合 (Hole Size)", Range(0, 1))         = 0.85

        // ---- 粘液の質感（蜘蛛糸・繭と同じ塗り） ----
        [Header(Goo Shape)]
        _GooAmount    ("粘液感 0で乾いた糸 (Goo Amount)", Range(0, 1))     = 1

        [Header(Goo Shading)]
        _GooColor           ("明部の色 (Goo Color)", Color)                  = (0.88, 0.87, 0.94, 1)
        _GooShadowColor     ("影部の色 (Goo Shadow)", Color)                 = (0.6, 0.58, 0.72, 1)
        _GooShade           ("影の広さ (Shadow Area)", Range(-0.5, 0.5))      = 0.12
        _GooOutlineColor    ("輪郭線の色 a=濃さ (Outline Color)", Color)      = (0.33, 0.32, 0.45, 0.85)
        _GooOutline         ("輪郭線の太さ (Outline Width)", Range(0, 0.5))    = 0.14
        _GooOpacity         ("不透明度 (Opacity)", Range(0, 1))              = 0.92
        _GooClarity         ("中心の透け (Clarity)", Range(0, 1))            = 0.25

        [Header(Goo Gloss)]
        _GooGlossColor      ("ハイライト色 a=濃さ (Gloss Color)", Color)      = (1, 1, 1, 1)
        _GooGloss           ("ハイライトの強さ (Gloss)", Range(0, 1))         = 1
        _GooGlossWidth      ("ハイライトの太さ (Gloss Width)", Range(0.01, 0.6)) = 0.14
        _GooGlossOffset     ("ハイライトを光源側へ (Gloss Offset)", Range(-1, 1)) = 0.3
        _GooGlossBreak      ("ハイライトの途切れ (Gloss Break)", Range(0, 1))  = 0.3

        [Header(Render State)]
        [ToggleUI] _HideBackFibers ("裏面の糸を隠す (Hide Back Fibers)", Float) = 0

        [Header(Seed)]
        _Seed      ("揺らぎシード (Seed)", Float) = 0


        [Header(Toon Shading)]
        _ToonSteps      ("トゥーン段階数 (Toon Steps)", Range(1, 8)) = 1
        _ToonSmooth     ("段差の柔らかさ (Toon Smooth)", Range(0.001, 0.5)) = 0.03
        _AmbientBoost   ("環境光の底上げ (Ambient Boost)", Range(0, 1)) = 0.35
        _LightInfluence ("シーン光の反映度 (Light Influence)", Range(0, 1)) = 0.35

        [Header(Rim Light)]
        _RimColor    ("リムライト色 (Rim Color)", Color) = (0.8, 0.9, 1.0, 1)
        _RimPower    ("リム幅 / 鋭さ (Rim Power)", Range(0.5, 16)) = 4.0
        _RimStrength ("リム強さ (Rim Strength)", Range(0, 4)) = 0.3
        _RimFloor    ("リムの下限/全体発光 (Rim Floor)", Range(0, 1)) = 0.05


        // 接触追従の変形。捕縛点・追従先は Udon（SurfaceContactDeformer）が
        // MaterialPropertyBlock の配列で毎フレーム渡す
        [Header(Contact Deform)]
        [ToggleUI] _PullEnable ("接触追従の変形 有効 (Pull Enable)", Float) = 0
        _PullRadius     ("引っ張り半径 m (Pull Radius)", Range(0.05, 2)) = 0.5
        _PullFalloff    ("減衰の鋭さ (Pull Falloff)", Range(0.25, 4)) = 1.5
        _PullStrength   ("引っ張り強さ (Pull Strength)", Range(0, 1)) = 1
        _PullMaxStretch ("千切れ開始距離 m 0で無効 (Max Stretch)", Range(0, 5)) = 0
        _PullTearFade   ("千切れフェード幅 m (Tear Fade)", Range(0.01, 2)) = 0.3
        // 捕縛点・追従先は配列 uniform（_PullAnchors[16]/_PullTargets[16]）で、Udon が
        // MaterialPropertyBlock.SetVectorArray で渡す（Properties には書けない）。
        // _PullCount は有効スロット数。0 のままなら頂点シェーダーは従来と同じ
        _PullCount      ("有効スロット数 Udonが設定 (Pull Count)", Float) = 0

        // 投げつけた網が体に覆いかぶさる変形（CGINC/SpiderWeb_Drape.cginc）。
        // 体の形（ボーンから作るカプセル）・網の中心/向きは Udon（CaptureNetDrape）が
        // MaterialPropertyBlock で毎フレーム渡す。WebPlane メッシュ専用（UV で網の位置を決める）
        [Header(Body Drape)]
        [ToggleUI] _DrapeEnable ("体に覆いかぶさる変形 有効 (Drape Enable)", Float) = 0
        _DrapeGap    ("体からの浮き m (Surface Gap)", Range(0, 0.1)) = 0.025
        _DrapeSmooth ("部位間のなじみ幅 m (Blend Width)", Range(0.005, 0.3)) = 0.06
        _DrapeWrap   ("背中側へ巻き込む量 (Wrap Behind)", Range(0, 1)) = 1
        _DrapeCling  ("同じ高さの部位に巻きつく強さ (Cling)", Range(1, 6)) = 3
        _DrapeTail   ("巻き込んだ余りの伸び (Tail Stretch)", Range(0, 1)) = 0.3
        _DrapeSag    ("余りの重力たるみ (Sag)", Range(0, 2)) = 0.2
        _DrapeTurns  ("体に巻きつく最大の周回数 0で従来 (Wrap Turns)", Range(0, 3)) = 0
        _DrapeLayer  ("1周ごとの重なりの厚み m (Layer Thickness)", Range(0, 0.05)) = 0.012
        _DrapeBunch  ("巻ききれない余りのふくらみ m/m (Bunch)", Range(0, 0.2)) = 0.03
        _DrapeStretchFade ("伸びすぎた所を薄くする倍率 (Stretch Fade)", Range(1, 10)) = 3
        // _DrapeFollow / _DrapeCurA/B / _DrapeSkinX/Y/Z は CaptureNetDrape が MaterialPropertyBlock で渡す。
        _DrapeFollowBlend ("姿勢追従: 部位の境目のなじみ幅 m (Follow Blend)", Range(0.005, 0.2)) = 0.05
        _DrapeFollowPush  ("姿勢追従: 体へのめり込みを押し戻す (Follow Push)", Range(0, 1)) = 1
        _DrapeFollowHang     ("姿勢追従: 体から離れた余りを重力で垂らす (Follow Hang)", Range(0, 1)) = 1
        _DrapeFollowHangDist ("姿勢追従: 重力で垂れきる体からの距離 m (Hang Distance)", Range(0.02, 1)) = 0.25
        _DrapeCount  ("有効カプセル数 Udonが設定 (Capsule Count)", Float) = 0


        // エディタ専用: 質感の継承元（蜘蛛糸マテリアル）の目印。描画には使わない（HLSL では宣言しない）。
        // xyz = 継承元 .mat の GUID 先頭 18 桁（24bit ずつ）、w = 状態（0=継承元なし→蜘蛛糸シェーダーの既定値 / 2=リンクあり）。
        // 値は Editor/SpiderSilkLook.cs が読み書きする。手で触らないこと。
        [HideInInspector] _SilkLookLink ("Silk Look Link (editor only)", Vector) = (0, 0, 0, 0)
    }

    SubShader
    {
        Tags
        {
            // 蜘蛛糸（SpiderSilk）は Transparent-10 で巣より「先」に描かれる。
            // 巣の向こうの糸は、この巣が半透明で重なって必ず透けて見える（巣の深度で消えない）。
            // 手前の糸は芯の深度を書いているので、その画素では巣が深度テストに負けて糸の上に重ならない
            // （SpiderSilk 側の説明参照）
            "Queue"           = "Transparent"
            "RenderType"      = "Transparent"
            "IgnoreProjector" = "True"
            "VRCFallback"     = "Hidden"
        }

        // ---- 9 パス構成（一番内側の層の芯の深度 → 内側から色） ----
        // 膜は縁のぼかしや濡れた透け感で半透明になる。1 パス・ZWrite On で半透明のピクセルまで
        // 深度を書くと、透けて見えるはずの奥のものが深度テストで消える。そこで不透明度の高い芯だけ
        // 先に深度へ書き、そのあと内側の層から半透明の色を重ねる。
        //   DEPTHSOLID_L0: 一番内側の層（体に一番近い層）の芯だけを深度へ書く。体の向こう側や
        //     折り返しの膜が手前に透けて濁るのはこれで防げる。外側の層の深度は見た目がほぼ変わらず
        //     頂点の処理（体への覆いかぶさり）が層の数だけ増えるので書かない（2026-10-08 軽量化）。
        //   FORWARD_L0〜L7: 内側から半透明の色を重ねる（無効な層は頂点で潰す）。
        // 共通関数へ層番号の定数を渡し、深度と色で位置・模様・不透明度を一致させる。
        CGINCLUDE
            // これ以上の不透明度のピクセルだけが深度を書く（AreaWebMarker の 0.35 などの
            // 淡い巣は深度を書かない）
            #define SW_DEPTH_SOLID_ALPHA 0.5


            #include "UnityCG.cginc"
            #include "Lighting.cginc"

            // 糸の質感・照明は繭シェーダーと共通の実装を使う。
            // Common.cginc が共通 uniform（_ThreadColor 等）と appdata/v2f を宣言
            // するため、このシェーダーでは巣固有の uniform だけを追加宣言する。
            #include "CGINC/SpiderCocoon_Noise.cginc"
            #include "CGINC/SpiderCocoon_Common.cginc"
            #include "CGINC/SpiderCocoon_Thread.cginc"
            #include "CGINC/SpiderCocoon_Lighting.cginc"
            // 粘液の塗り（蜘蛛糸・繭と共通）
            #include "CGINC/SpiderGoo_Shading.cginc"
            #include "CGINC/SpiderGooSheet_BakedPattern.cginc"

            // ---- 粘液シート固有の uniform（共通 uniform は Common.cginc 宣言を使用） ----
            // 帯の形（_Sheet*）と帯の中の束（_GooStrands など）は焼き込み専用で、実行中は読まない。
            // 粘液感・色・陰影・光沢の uniform は質感 = SpiderSilk_Look.cginc
            float  _WebRadius;
            float  _Seed;
            float _WebLayers, _WebLayerDepth, _WebLayerContactDepth;
            float _WebLayerAdhere, _WebLayerAdhereScale, _WebLayerTwist;
            float _WebLayerShift, _WebLayerOpacity;
            float _WebLayerWidthOuter, _WebLayerWidthJitter;

            // ---- 接触追従の変形（uniform と変位関数は繭と共通の Pull.cginc） ----
            #include "CGINC/SpiderCocoon_Pull.cginc"
            // ---- 投げつけた網が体に覆いかぶさる変形 ----
            #include "CGINC/SpiderWeb_Drape.cginc"

            // 共通の appdata に UV2 を足したもの。UV2.x は扇形の外周までの距離
            //（_FanMeshRim 用。WebPlane など UV2 の無いメッシュでは使わない）
            struct web_appdata
            {
                float4 vertex  : POSITION;
                float3 normal  : NORMAL;
                float4 tangent : TANGENT;
                float2 uv      : TEXCOORD0;
                float2 uv2     : TEXCOORD1;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct web_v2f
            {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 worldPos : TEXCOORD1;
                float3 worldNormal : TEXCOORD2;
                float4 worldTangent : TEXCOORD3;
                float fanRim : TEXCOORD5;   // ハブ→扇の外周の UV 距離（メッシュ提供時のみ）
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            // 回転は模様にだけ適用。頂点変形や伸び率は元のUVで計算する。
            float2 SW_LayerRotate(float2 p, float angle)
            {
                float sn, cs;
                sincos(angle, sn, cs);
                return float2(cs * p.x - sn * p.y, sn * p.x + cs * p.y);
            }

            bool SW_LayerEnabled(float layer)
            {
                return layer < clamp(round(_WebLayers), 1.0, 8.0);
            }

            float SW_LayerGap(float2 uv, float layer)
            {
                if (layer < 0.5) return 0.0;
                // セルの丸い点を並べず、ゆがめた低周波ノイズを2つ混ぜる。
                // 時刻を使わないため、姿勢を変えても接着位置はUVに留まる。
                float2 seedOffset = float2(SC_Hash11(_Seed + 71.3), SC_Hash11(_Seed + 193.7)) * 31.0;
                float2 q = SW_LayerRotate(uv - 0.5, 0.61) * max(_WebLayerAdhereScale, 0.01);
                q *= float2(1.0, 0.73);
                q += seedOffset;
                float2 warp = float2(STG_ValueNoise2(q * 0.53 + 7.1),
                                     STG_ValueNoise2(q * 0.53 + 29.4)) - 0.5;
                q += warp * 0.8;
                float noise = STG_ValueNoise2(q) * 0.7
                            + STG_ValueNoise2(SW_LayerRotate(q, 1.13) * 1.71 + 13.9) * 0.3;
                float center = 1.0 - smoothstep(0.04, 0.48, length(uv - 0.5));
                float field = saturate((noise - 0.5) * 1.8 + 0.5 + center * 0.35);
                float threshold = lerp(1.16, -0.16, saturate(_WebLayerAdhere));
                float adhere = smoothstep(threshold - 0.16, threshold + 0.16, field);
                // 厚さは全層の合計。8層でも最外層は最大0.12m、接着部も最低1mm間隔。
                float count = clamp(round(_WebLayers), 1.0, 8.0);
                float contactDepth = clamp(_WebLayerContactDepth, 0.007, 0.07);
                float depth = max(contactDepth, clamp(_WebLayerDepth, 0.007, 0.12));
                return layer / max(count - 1.0, 1.0) * lerp(contactDepth, depth, 1.0 - adhere);
            }

            web_v2f vert(web_appdata v, float layer)
            {
                web_v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(web_v2f, o);
                UNITY_TRANSFER_INSTANCE_ID(v, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                UNITY_BRANCH
                if (!SW_LayerEnabled(layer))
                {
                    // 全頂点を同じ有効なクリップ座標へ。三角形の面積が0になる。
                    o.pos = float4(0.0, 0.0, 0.0, 1.0);
                }
                else
                {
                    float extraGap = SW_LayerGap(v.uv, layer);

                    float3 wp = mul(unity_ObjectToWorld, v.vertex).xyz;
                    float3 N0 = UnityObjectToWorldNormal(v.normal);
                    float3 T0 = UnityObjectToWorldDir(v.tangent.xyz);
                    o.uv = v.uv;
                    o.fanRim = 0.0; // 焼き込み版はUV2の扇形外周を使わない。

                    // 体に覆いかぶさる網（位置・法線・接線をワールドで直接求める）
                    UNITY_BRANCH
                    if (SW_DrapeActive())
                    {
                        float3 pDr, NDr, TDr;
                        SW_DrapeDeform(v.uv, pDr, NDr, TDr, extraGap);
                        o.pos          = UnityWorldToClipPos(pDr);
                        o.worldPos     = pDr;
                        o.worldNormal  = NDr;
                        o.worldTangent = float4(TDr, v.tangent.w);
                    }
                    else
                    {
                        // 変形が無効（またはどのスロットも未使用）なら従来どおりのパススルー
                        UNITY_BRANCH
                        if (!SC_PullActive())
                        {
                            if (layer > 0.5) wp += normalize(N0) * extraGap;
                            o.pos          = (layer < 0.5) ? UnityObjectToClipPos(v.vertex) : UnityWorldToClipPos(wp);
                            o.worldPos     = wp;
                            o.worldNormal  = N0;
                            o.worldTangent = float4(T0, v.tangent.w);
                        }
                        else
                        {
                            // ---- 接触追従の変形（ワールド空間。法線・接線は変位後の面から再計算） ----
                            float3 pD = wp, N = N0, Tn = T0;
                            SC_PullDeform(pD, N, Tn);
                            if (layer > 0.5) pD += normalize(N) * extraGap;

                            o.pos          = UnityWorldToClipPos(pD);
                            o.worldPos     = pD;
                            o.worldNormal  = N;
                            o.worldTangent = float4(Tn, v.tangent.w);
                        }
                    }
                }
                // 分岐の途中では返さず、初期化済みの出力をここから1回だけ返す。
                return o;
            }

            // 層ごとの糸の太さの倍率（焼いた太さ = 1）。一番内側の層の 1 から、一番外側の層の
            // _WebLayerWidthOuter へ直線で変え、_WebLayerWidthJitter で層ごとにランダムに
            // 太らせる / 細らせる（1 で 0.5〜2 倍）。層番号とマテリアル値だけで決まるので、
            // パス内の全画素で同じ値になり、焼き直しも不要。
            float SGS_LayerWidth(float layer)
            {
                float count = clamp(round(_WebLayers), 1.0, 8.0);
                float t = saturate(layer / max(count - 1.0, 1.0));
                float w = lerp(1.0, _WebLayerWidthOuter, t);
                float jitter = SC_Hash11(_Seed * 17.31 + layer * 29.71 + 5.3) * 2.0 - 1.0;
                w *= exp2(jitter * saturate(_WebLayerWidthJitter));
                return clamp(w, 0.25, 3.0);
            }

            fixed4 fragBaked(web_v2f i, fixed facing, float layer, out float depthAlpha)
            {
                depthAlpha = 0.0;
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // 隣り合う画素の差を使うので、discard で画素を捨てる前に伸び率を調べる。
                float drapeStretchFade = SW_DrapeStretchFade(i.worldPos, i.uv);

                if (!SW_LayerEnabled(layer)) discard;
                if (_BakedSliceCount < 0.5) discard; // 未生成はInspectorに理由を表示。
                float layerAngle = radians(layer * _WebLayerTwist);
                float2 patternUV = SW_LayerRotate(i.uv - 0.5, layerAngle) + 0.5;
                if (layer > 0.5)
                {
                    float direction = SC_Hash11(_Seed * 37.219 + layer * 53.17 + 11.3) * UNITY_TWO_PI;
                    patternUV += float2(cos(direction), sin(direction)) * (clamp(_WebLayerShift, 0.0, 0.5) * _WebRadius);
                }
                SGS_Shape p = SGS_ReadShape(patternUV, layer, _WebLayers, SGS_LayerWidth(layer)); // 微分・LODは全てこの中で確定
                // 外形/裏面も微分の後で判定。補助参照と塗りより前に明らかな空隙を捨てる。
                clip(_WebRadius - length(i.uv - 0.5));
                clip(min(min(i.uv.x, i.uv.y), min(1.0 - i.uv.x, 1.0 - i.uv.y)));
                float2 bakeUV = p.uvSlice.xy;
                clip(min(min(bakeUV.x, bakeUV.y), min(1.0 - bakeUV.x, 1.0 - bakeUV.y)));
                if (_HideBackFibers > 0.5 && facing < 0.0) discard;
                if (p.visibleMask <= 0.0) discard;
                SGS_Detail attributes = SGS_ReadDetail(p);
                float2 gG = SW_LayerRotate(attributes.direction, -layerAngle);
                float3 NfrontG = normalize(i.worldNormal);
                float3 NwG = NfrontG * sign(facing);
                float3 TG = normalize(i.worldTangent.xyz);
                float3 BG = normalize(cross(NfrontG, TG)) * i.worldTangent.w * unity_WorldTransformParams.w;
                float3 VG = normalize(_WorldSpaceCameraPos - i.worldPos);
                float3 LG = STG_GooLightDir();
                STG_GooSurface gs = STG_GooProfile(p.d, p.radius, gG, NwG, TG, BG);
                // 未解像の糸の方向/断面で光沢が点滅しないよう、遠景で面の法線へ寄せる。
                gs.Nt = normalize(lerp(gs.Nt, NwG, p.farWeight));
                float3 colG = STG_GooBaseColor(gs, NwG, LG);
                float detail = saturate(1.6 - p.aaQ * 2.5) * (1.0 - p.farWeight);
                fixed4 goo = STG_GooFinishAAWet(colG, 0.0, gs, p.d, NwG, VG, LG,
                    attributes.glossNoise, detail, p.aaD, p.aaQ, attributes.wet);
                // 丸い断面のcoreの幅平均はπ/4。遠景は輪郭を太らせず面積×平均不透明度へ。
                float farAlpha = p.coverage * _GooOpacity * (1.0 - _GooClarity * attributes.wet * 0.78539816);
                goo.a = lerp(goo.a, farAlpha, p.farWeight);
                // 色・深度の両パスが使う最終不透明度を薄くし、伸びた所の深度も残さない。
                goo.a *= drapeStretchFade;
                if (layer > 0.5) goo.a *= pow(clamp(_WebLayerOpacity, 0.3, 1.0), layer);
                // 色/深度の面積判定と最終alphaは共通。深度の芯だけは未解像になるほど弱める。
                // 遠景の平均被覆率が0.5を超えても、面全体を不透明な深度にしない。
                depthAlpha = goo.a * (1.0 - p.farWeight);
                if (goo.a <= 0.001) discard;
                return goo;
            }

            fixed4 frag(web_v2f i, fixed facing, float layer)
            {
                float depthAlpha;
                return fragBaked(i, facing, layer, depthAlpha);
            }

            // 各層の深度用: 色は使わず、芯（不透明度が高い所）だけ残して深度を書かせる
            fixed4 fragDepth(web_v2f i, fixed facing, float layer)
            {
                float depthAlpha;
                fragBaked(i, facing, layer, depthAlpha);
                clip(depthAlpha - SW_DEPTH_SOLID_ALPHA);
                return 0;
            }

            // 各パスの入口は定数の層番号を共通関数へ渡すだけ。
            web_v2f vertL0(web_appdata v) { return vert(v, 0.0); }
            fixed4 fragL0(web_v2f i, fixed facing : VFACE) : SV_Target { return frag(i, facing, 0.0); }
            fixed4 fragDepthL0(web_v2f i, fixed facing : VFACE) : SV_Target { return fragDepth(i, facing, 0.0); }
            web_v2f vertL1(web_appdata v) { return vert(v, 1.0); }
            fixed4 fragL1(web_v2f i, fixed facing : VFACE) : SV_Target { return frag(i, facing, 1.0); }
            web_v2f vertL2(web_appdata v) { return vert(v, 2.0); }
            fixed4 fragL2(web_v2f i, fixed facing : VFACE) : SV_Target { return frag(i, facing, 2.0); }
            web_v2f vertL3(web_appdata v) { return vert(v, 3.0); }
            fixed4 fragL3(web_v2f i, fixed facing : VFACE) : SV_Target { return frag(i, facing, 3.0); }
            web_v2f vertL4(web_appdata v) { return vert(v, 4.0); }
            fixed4 fragL4(web_v2f i, fixed facing : VFACE) : SV_Target { return frag(i, facing, 4.0); }
            web_v2f vertL5(web_appdata v) { return vert(v, 5.0); }
            fixed4 fragL5(web_v2f i, fixed facing : VFACE) : SV_Target { return frag(i, facing, 5.0); }
            web_v2f vertL6(web_appdata v) { return vert(v, 6.0); }
            fixed4 fragL6(web_v2f i, fixed facing : VFACE) : SV_Target { return frag(i, facing, 6.0); }
            web_v2f vertL7(web_appdata v) { return vert(v, 7.0); }
            fixed4 fragL7(web_v2f i, fixed facing : VFACE) : SV_Target { return frag(i, facing, 7.0); }
        ENDCG

        Pass
        {
            Name "DEPTHSOLID_L0"
            Tags { "LightMode" = "ForwardBase" }
            ColorMask 0
            ZWrite On
            ZTest LEqual
            Cull Off
            CGPROGRAM
            #pragma vertex vertL0
            #pragma fragment fragDepthL0
            #pragma target 3.5
            #pragma require 2darray
            #pragma multi_compile_instancing
            ENDCG
        }

        Pass
        {
            Name "FORWARD_L0"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Off
            CGPROGRAM
            #pragma vertex vertL0
            #pragma fragment fragL0
            #pragma target 3.5
            #pragma require 2darray
            #pragma multi_compile_instancing
            ENDCG
        }

        Pass
        {
            Name "FORWARD_L1"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Off
            CGPROGRAM
            #pragma vertex vertL1
            #pragma fragment fragL1
            #pragma target 3.5
            #pragma require 2darray
            #pragma multi_compile_instancing
            ENDCG
        }

        Pass
        {
            Name "FORWARD_L2"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Off
            CGPROGRAM
            #pragma vertex vertL2
            #pragma fragment fragL2
            #pragma target 3.5
            #pragma require 2darray
            #pragma multi_compile_instancing
            ENDCG
        }

        Pass
        {
            Name "FORWARD_L3"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Off
            CGPROGRAM
            #pragma vertex vertL3
            #pragma fragment fragL3
            #pragma target 3.5
            #pragma require 2darray
            #pragma multi_compile_instancing
            ENDCG
        }

        Pass
        {
            Name "FORWARD_L4"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Off
            CGPROGRAM
            #pragma vertex vertL4
            #pragma fragment fragL4
            #pragma target 3.5
            #pragma require 2darray
            #pragma multi_compile_instancing
            ENDCG
        }

        Pass
        {
            Name "FORWARD_L5"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Off
            CGPROGRAM
            #pragma vertex vertL5
            #pragma fragment fragL5
            #pragma target 3.5
            #pragma require 2darray
            #pragma multi_compile_instancing
            ENDCG
        }

        Pass
        {
            Name "FORWARD_L6"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Off
            CGPROGRAM
            #pragma vertex vertL6
            #pragma fragment fragL6
            #pragma target 3.5
            #pragma require 2darray
            #pragma multi_compile_instancing
            ENDCG
        }

        Pass
        {
            Name "FORWARD_L7"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Off
            CGPROGRAM
            #pragma vertex vertL7
            #pragma fragment fragL7
            #pragma target 3.5
            #pragma require 2darray
            #pragma multi_compile_instancing
            ENDCG
        }

    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}
