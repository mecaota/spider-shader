// =============================================================================
// SpiderSilkNet.shader — 糸の網シェーダー（不規則な網の籠・張り巣）（PC / Unity 2022.3 / Built-in RP）
//
//  籠の穴の大小の混在（絵柄「籠目」）と、不規則な張り巣（絵柄「張り巣」）を描く。
//  網の形は Editor で距離の画像に焼いてあり（Editor/SilkNet、データ版 4）、実行時は画像を読んで
//  蜘蛛糸と同じ粘液の塗りで平らな 2 色に塗るだけ。実行時に網の形は計算しない。
//  処理の本体と説明は CGINC/SpiderSilkNet_Core.cginc。
//
//  ・パスは 3 つ: 深度（芯だけ）→ 裏向きの面（Cull Front）→ 表向きの面（Cull Back）。
//  ・Queue 3000。ステンシルは読まない・書かない。深度は深度のパスだけが書く。
//  ・質感 21 項目は蜘蛛糸（SpiderSilk）から継承する（名前・型・範囲・既定値・属性を一致させる）。
//  ・体に沿わせる変形はキーワード _NET_DRAPE（SpiderWeb と同じ _Drape* の契約）。
// =============================================================================
Shader "mecaota/SpiderSilkNet"
{
    Properties
    {
        // ※ 質感（Look）21 個は、蜘蛛糸・蜘蛛の巣・繭・繭デカール・蜘蛛の巣ドレープ・糸の網で
        //   名前・型・範囲・既定値を完全一致させる（一覧: Editor/SpiderSilkLook.cs、宣言: CGINC/SpiderSilk_Look.cginc）。
        //   糸の網ではこの値を「継承元の蜘蛛糸マテリアル」から受け継ぐ。
        // カテゴリ分けは CustomEditor（SpiderCocoonShaderGUI）が担当。
        // [Header] は標準インスペクタ向けのフォールバック表示。
        // ※ ShaderLab の属性引数は ASCII のみ（日本語を書くとパースエラー）。
        [Header(Net Pattern)]
        [NoScaleOffset] _BakedShape ("絵柄: 形 (Baked Shape)", 2DArray) = "" {}
        [NoScaleOffset] _BakedDetail ("絵柄: 補助 (Baked Detail)", 2DArray) = "" {}
        [NoScaleOffset] _BakedCoverage ("絵柄: 被覆率 (Baked Coverage)", 2DArray) = "" {}
        // 絵柄の種類と枚数は、インスペクタが _BakedShape の配列（Repeat なら籠目）から自動で入れる
        [HideInInspector] _NetKind ("Net Kind", Float) = 0
        [HideInInspector] _NetSliceCount ("Net Slice Count", Float) = 0
        [HideInInspector] _NetDataVersion ("Net Data Version", Float) = 4
        // x = 距離の範囲（±画素）, y = 形の画像の G を焼いた膜の量, z = 糸の半径の範囲（画素）, w = 1 枚の画素数
        [HideInInspector] _NetBakeRange ("Net Bake Range", Vector) = (24, 0.3, 16, 512)
        [IntRange] _NetSlice ("使う枚 -1で種から (Slice)", Range(-1, 2)) = 0
        _NetSeed ("ずらしの種 (Seed)", Range(0, 1)) = 0
        _NetTiling ("並べる回数 整数 xy (Tiling)", Vector) = (1, 1, 0, 0)

        [Header(Net Shape)]
        _NetWidth ("糸の太さの倍率 (Width)", Range(0.3, 2)) = 1
        _NetFill ("膜の量 (Membrane Fill)", Range(0, 1)) = 0.25
        // 修正 2 回目から使わない（膜の形は焼いた距離で決まる）。マテリアルの互換のため残す
        [HideInInspector] _NetMerge ("膜と糸の境目の滑らかさ 未使用 (Membrane Merge)", Range(0, 1)) = 0.5
        _NetEdgeFade ("板の縁で糸と膜を細らせる幅 UV (Edge Fade)", Range(0, 0.5)) = 0.03
        _NetProfileShade ("糸の断面の陰 (Profile Shade)", Range(0, 1)) = 1
        _FormShade ("メッシュの丸みの陰 (Form Shade)", Range(0, 1)) = 0

        [Header(Back Side)]
        [Enum(Same,0,ThinStrands,1,Hidden,2,InnerCage,3)] _BackMode ("裏側の描き方 (Back Mode)", Float) = 1
        _NetCageExtent ("籠の半分の大きさ 物体座標 (Cage Extent)", Vector) = (0, 0, 0, 0)
        _BackTint ("奥の壁の色 (Back Tint)", Color) = (0.70, 0.73, 0.80, 1)
        _BackWidth ("奥の壁の糸の太さ (Back Width)", Range(0.3, 1)) = 0.55

        [Header(Distance)]
        _NetSimpleDistance ("一色で塗る距離 m (Simple Distance)", Range(0, 30)) = 6
        _BackHideDistance ("奥の壁を消す距離 m (Back Hide Distance)", Range(0, 30)) = 10

        // ---- 粘液の質感（蜘蛛糸から継承） ----
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

        // 投げつけた網が体に覆いかぶさる変形（CGINC/SpiderWeb_Drape.cginc。SpiderWeb と同じ値）。
        // 体の形・網の中心/向きは Udon（SpiderWebDrapeDriver など）が MaterialPropertyBlock で毎フレーム渡す。
        // 平面メッシュ専用（UV で網の位置を決める）。ON にするとキーワード _NET_DRAPE が付く
        [Header(Body Drape)]
        [Toggle(_NET_DRAPE)] _DrapeEnable ("体に覆いかぶさる変形 有効 (Drape Enable)", Float) = 0
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
        // 値は Editor/SpiderSilkLook.cs が読み書きする。手で触らないこと。
        [HideInInspector] _SilkLookLink ("Silk Look Link (editor only)", Vector) = (0, 0, 0, 0)
    }

    SubShader
    {
        Tags
        {
            // 蜘蛛糸（Transparent-10）より後、巣・繭と同じ Transparent（3000）。ステンシルは使わない
            "Queue"           = "Transparent"
            "RenderType"      = "Transparent"
            "IgnoreProjector" = "True"
            "VRCFallback"     = "Hidden"
            // 籠の中か外かの判定と奥の壁を消す距離は物体の座標を使うので、静的バッチングでまとめさせない
            "DisableBatching" = "True"
        }

        CGINCLUDE
            #include "CGINC/SpiderSilkNet_Core.cginc"
        ENDCG

        // Pass 0: 芯（不透明度 0.5 以上）だけ深度を書く。描かない面は画素を捨てる
        Pass
        {
            Name "DEPTHSOLID"
            Tags { "LightMode" = "ForwardBase" }
            ColorMask 0
            ZWrite On
            Cull Off

            CGPROGRAM
            #pragma vertex   vertDepth
            #pragma fragment fragDepth
            #pragma target   3.5
            #pragma require  2darray
            #pragma multi_compile_instancing
            #pragma shader_feature_local _NET_DRAPE
            ENDCG
        }

        // Pass 1: 裏向きの面（籠の奥の壁）。先に塗る
        Pass
        {
            Name "BACK"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            Cull Front

            CGPROGRAM
            #pragma vertex   vertBack
            #pragma fragment fragBack
            #pragma target   3.5
            #pragma require  2darray
            #pragma multi_compile_instancing
            #pragma shader_feature_local _NET_DRAPE
            ENDCG
        }

        // Pass 2: 表向きの面。後に塗る（奥の糸が手前の膜の上に乗らない）
        Pass
        {
            Name "FRONT"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            Cull Back

            CGPROGRAM
            #pragma vertex   vertFront
            #pragma fragment fragFront
            #pragma target   3.5
            #pragma require  2darray
            #pragma multi_compile_instancing
            #pragma shader_feature_local _NET_DRAPE
            ENDCG
        }
    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}
