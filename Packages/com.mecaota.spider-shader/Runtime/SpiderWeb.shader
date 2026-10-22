// =============================================================================
// SpiderWeb.shader — 蜘蛛の巣シェーダー (VRChat / Built-in RP 専用)
//
//  平面（Quad など）の UV 空間に、縦糸（放射スポーク）と横糸（渦巻きリング）を
//  テクスチャ無しの数式（距離場）で描く。
//
//  ■ 描き方のしくみ（シェーダー入門向けの要約）
//    1. ピクセルごとに「一番近い縦糸までの距離」「一番近い横糸までの距離」を
//       計算する（これを距離場と呼ぶ）。距離が糸の太さ以下なら糸として塗る。
//    2. 縦糸はハブ（中心結節点）からの放射線。角度を縦糸の本数で等分し、
//       糸ごとにランダムな角度ずれ（揺らぎ）を足す。
//    3. 横糸は同心円。縦糸と縦糸の間で中心側へ「垂れ下がり」、区間ごとに
//       ランダムな垂れ幅（揺らぎ）を足す。
//
//  ■ 揺らぎで糸が切れない理由（過去バグの修正ポイント）
//    横糸の垂れ・揺らぎは「どの縦糸間の区間にいるか」で決まる。この区間の
//    切り替わり位置を『揺らぎでずれた後の縦糸の実際の位置』に厳密に合わせ、
//    さらに区間ごとの揺らぎ量に sagCurve（縦糸上で必ず 0 になる曲線）を
//    掛けてあるため、区間が切り替わる瞬間も横糸の半径は連続＝糸は繋がる。
//
//  ■ 中心結節点（ハブ）の偏心
//    外周円（UV中央・_WebRadius）と縦糸の終端（メッシュ端の位置）は固定の
//    まま、糸が集まるハブだけを _HubOffsetX/Y でずらせる。縦糸は
//    「ハブ→メッシュ端の固定終端」を結ぶ1本の直線のままで、終端を支点に
//    傾くだけ。実物の蜘蛛の巣のように、ハブに近い側はリング間隔が密に、
//    遠い側は疎になる。
//
//  ■ 扇形（_FanEnable）
//    ハブから _FanAngle の範囲だけに縦糸を張り、横糸は扇の外周まで並べる。
//    外周は「メッシュの端」: 平面メッシュでは UV 正方形の縁、_FanMeshRim ON なら
//    メッシュが UV2.x で渡すハブ→外周の距離（木の幹に張り付く巣のメッシュは
//    地面との接地線をここに入れてある）。_WebRadius はそれより内側で止めたい
//    ときの上限。メッシュを曲面にしても模様は UV に貼りつくので、UV を曲面の
//    展開図（ほぼ等長）にしておけば糸の太さはどこでもほぼ同じになる。
//
//  ■ 縦糸の延長（係留糸）
//    _SpokeExtend を ON にすると、縦糸が外周円で止まらずメッシュの端まで
//    見える。OFF は同じ直線の外周円から外側を透明にしているだけなので、
//    ON/OFF やハブ操作で縦糸の向き・終端位置は変わらない（横糸は延長しない）。
//
//  ■ 揺れアニメ（_SwayAnimEnable）
//    緯糸（リング）のみ揺らす。縦糸・ハブ・接続点は固定。
//    弾性の波形は蜘蛛糸と SpiderSilk_Motion.cginc で共通化。
//    横糸は区間ごとに弧全体を動かすので、波の細かさ（_SwayAnimWaves）は使わない。
//    接触追従の変形（_PullEnable）とは別の処理で、触れていても揺れは止めない。
//
//  ■ 質感（粘液）
//    縦糸・横糸の距離場を smooth-min で融合し、すき間の角を水かき状の膜で
//    埋め、横糸に糊の玉を付ける。塗り（丸い断面のトゥーン・ハイライトの筋・
//    輪郭線・透け）は蜘蛛糸・繭と共通の CGINC/SpiderGoo_Shading.cginc。
//    _SpokeGoo / _RingGoo で縦横の粘液を独立調整。交点は常につなぐ。
//    縦糸と横糸は粘液の量によらず 1 つの距離場でつなぐ（交点は切れない）。_SpokeGoo を
//    下げると縦糸の太り・玉・膜・ツヤだけが弱まり、0 で太さ一定の乾いた細い直線になる。
//    飛ばした巣（パーティクル・着弾した網）は 1、固定設置の巣は 0
//    （実物の円網と同じく横糸だけが粘着）。
//    粘液感（_GooAmount）を下げると、太り・玉・膜・ツヤ・透けが一緒に弱まり、
//    乾いた細い糸に近づく。糸の太さの乱雑性（SC_ThreadWidthMul）・リムライト
//    （SC_RimLight）は繭シェーダーと共通の CGINC 実装。
//
//  ■ 接触追従の変形（_PullEnable）
//    巣に手足が触れた場所をその手足に追従させ、上げれば伸び・押せば凹む表現。
//    実装は繭シェーダーと共通（CGINC/SpiderCocoon_Pull.cginc）。最大 16 スロット
//    （複数プレイヤーの両足・両手・腰・頭など）の捕縛点 _PullAnchors[]／追従先
//    _PullTargets[] を Udon（SurfaceContactDeformer）が MaterialPropertyBlock の
//    SetVectorArray で毎フレーム渡す（配列は MPB 専用。_PullCount が有効本数）。
//    半径の外は厳密に 0 なのでメッシュ端（係留）は不動。模様は UV で決まるため、
//    頂点が動いても糸は面に貼りついたまま伸びる。法線・接線は変位後の面から
//    有限差分で求め直す。_PullMaxStretch>0 なら伸びすぎた糸が千切れて戻る。
//    細かい変形には細分化した平面メッシュが必要（Tools/SpiderShader/Generate
//    WebPlane Mesh で生成。バウンズも拡張済み）。
//
//  ■ 体に覆いかぶさる変形（_DrapeEnable）
//    投げつけた網が当たった人の体の形に沿ってかぶさる表現。体はボーンから作った
//    カプセル（最大 20 本）で近似し、Udon（CaptureNetDrape）が毎フレーム渡す。
//    網の UV から「飛んできた方向に垂直な円盤」上の位置を決め、その位置から
//    飛んできた方向へ光線を伸ばして体に当たった所へ頂点を置く。体の輪郭の外に
//    はみ出した部分は背中側へ回り込み、余りは垂れる。詳しくは
//    CGINC/SpiderWeb_Drape.cginc。有効な間は接触追従の変形より優先。
//  ■ 近接表示（_RevealEnable）：巨大な空中の巣をカメラ距離で表示。_ClipLine は Renderer ごとの下端（uv.x=0 と 1 のワールド Y）を Udon が MaterialPropertyBlock で設定。
// =============================================================================
Shader "mecaota/SpiderWeb"
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
        [Header(Web Shape)]
        _HubOffsetX ("中心結節点オフセット X (Hub Offset X)", Range(-1, 1)) = 0
        _HubOffsetY ("中心結節点オフセット Y (Hub Offset Y)", Range(-1, 1)) = 0
        _WebRadius ("巣の半径 (Web Radius)", Range(0.05, 1.5)) = 0.45
        _Thickness ("糸の太さ (Thread Width)", Range(0.0005, 0.02)) = 0.0025
        [IntRange] _RadialCount ("縦糸の本数 放射 (Radial Count)", Range(3, 36)) = 14
        [IntRange] _RingCount   ("横糸の本数 渦巻 (Ring Count)", Range(1, 30)) = 9
        _Sag ("垂れ下がり具合 (Sag)", Range(0, 1)) = 0.4
        [ToggleUI] _SpokeExtend ("縦糸をメッシュ端まで延長 (Extend Spokes)", Float) = 0

        [Header(Fan Web)]
        [ToggleUI] _FanEnable ("扇形の巣 (Fan Web)", Float) = 0
        _FanAngle ("扇の開き角度 (Fan Angle)", Range(15, 330)) = 90
        _FanRotation ("扇の向き (Fan Rotation)", Range(-180, 180)) = 45
        // 扇形の外周をメッシュの UV2.x（ハブ→外周の UV 距離）から取る。
        // 木の幹に張り付く巣のメッシュ（TreeWebFanBuilder が生成）用。OFF は UV 正方形の端
        [ToggleUI] _FanMeshRim ("外周をメッシュUV2から取得 (Rim From Mesh)", Float) = 0

        [Header(Sticky Silk)]
        _SpokeWidth ("支持糸の太さ倍率 (Spoke Width)", Range(0.25, 3)) = 1
        _RingWidth ("横糸の太さ倍率 (Ring Width)", Range(0.25, 3)) = 1
        _Organic ("自然な太細の偏り (Organic Width)", Range(0, 1)) = 0
        _JunctionSize ("交点の粘着だまり (Sticky Junction)", Range(0, 4)) = 0

        // ---- 粘液の質感（蜘蛛糸・繭と同じ塗り） ----
        // 粘液感を下げると太り・玉・膜・ツヤ・透けが一緒に弱まる（0 で乾いた細い糸）
        [Header(Goo Shape)]
        _GooAmount    ("粘液感 0で乾いた糸 (Goo Amount)", Range(0, 1))     = 1
        _GooThick     ("粘液の太さ倍率 (Goo Thickness)", Range(0.5, 4))    = 1.6
        _GooBeads     ("粘着玉の大きさ (Glue Beads)", Range(0, 1))         = 0.5
        _GooBeadFreq  ("粘着玉の細かさ UV毎 (Bead Freq)", Float)           = 30
        _GooWebFill   ("すき間を埋める膜 (Membrane Fill)", Range(0, 1))     = 0.35
        // 縦糸（放射状の支持糸）の粘液。1 で縦糸と横糸が一体の粘液（融合・すき間の膜）。
        // 下げると縦糸の太り・玉・膜・ツヤだけが弱まる（横糸との交点はつながったまま）。
        // 0 で太さ一定の乾いた細い直線＝実物の円網と同じく横糸だけが粘着
        _RingGoo ("横糸の粘液感 (Ring Goo)", Range(0, 1)) = 1
        _SpokeGoo     ("縦糸の粘液感 0で乾いた直線 (Spoke Goo)", Range(0, 1)) = 1
        _GooWebScale  ("膜のまだらの細かさ UV毎 (Membrane Noise)", Float)   = 7

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

        [Header(Irregularity)]
        _Irregular ("揺らぎの強さ (Irregularity)", Range(0, 1)) = 0.35
        _Seed      ("揺らぎシード (Seed)", Float) = 0

        [Header(Sway Animation)]
        [ToggleUI] _SwayAnimEnable ("緯糸の揺れ有効 (Ring Sway Enable)", Float) = 0
        _SwayAnimAmount ("揺れ幅 (Sway Amount)", Range(0, 0.05)) = 0.012
        _SwayAnimSpeed  ("揺れの速さ (Sway Speed)", Range(0, 10)) = 1.5
        // 巣では効かない（横糸は弧全体を動かすため）。インスペクタには出さない
        [HideInInspector] _SwayAnimWaves  ("波の細かさ (Sway Waves)", Range(0, 10)) = 2.0
        _SwayAnimAnchor ("端の固定幅 0で固定なし (Edge Anchor)", Range(0, 0.5)) = 0.15

        [Header(Thread Design)]
        _ThreadJitter    ("太さの乱雑性 (Thickness Jitter)", Range(0, 1)) = 0.3
        _ThreadFuzz      ("幅の揺らぎ (Fuzz Amount)", Range(0, 1)) = 0.2
        _ThreadFuzzScale ("揺らぎの細かさ (Fuzz Scale)", Float) = 8.0

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

        [Toggle(SW_REVEAL)] _RevealEnable ("近接表示 有効 (Reveal Enable)", Float) = 0
        _RevealNear ("完全に見える距離 m (Reveal Near)", Range(0, 50)) = 3.5
        _RevealFar ("見えなくなる距離 m (Reveal Far)", Range(0.1, 100)) = 8
        _RevealNoise ("境界のばらつき m (Reveal Noise)", Range(0, 5)) = 1.5
        _RevealNoiseScale ("ばらつきの細かさ 1/m (Reveal Noise Scale)", Range(0.05, 4)) = 0.6
        _ClipLine ("下端 ワールドY 左,右 Udonが設定 (Clip Line)", Vector) = (-100000, -100000, 0, 0)

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

        // ---- 2 パス構成（深度は「ほぼ不透明な糸の芯」だけが書く） ----
        // 糸は縁のぼかしや濡れた透け感で半透明になる。以前は 1 パス・ZWrite On で
        // 半透明のピクセルまで深度を書いていたため、手前の巣が先に描かれた時に
        // 「透けて見えるはずの奥の巣」が深度テストで消えていた（巣どうしの描画順は
        // バウンズ中心の距離で決まり、カメラ位置で入れ替わるので「たまに」起きる）。
        //   Pass 0 DEPTHSOLID: 色は塗らず、不透明度 SW_DEPTH_SOLID_ALPHA 以上の芯だけ深度を書く
        //                      → 立体メッシュ（スフィア・体にかぶさった網）でも自分の手前/奥の
        //                        糸の前後関係は従来どおり正しい
        //   Pass 1 FORWARD   : 深度は書かずに全ピクセルを塗る（ZTest LEqual で芯の奥は隠れる）
        //                      → 半透明の部分は奥の巣を隠さない
        // 頂点・フラグメントの処理は両パス共通（CGINCLUDE）。Pass 0 は不透明度しか使わないので
        // 色の計算はコンパイラが省く。
        CGINCLUDE
            // 頂点・フラグメントの処理（巣の模様の計算）は CGINC/SpiderWeb_Core.cginc にある。
            // 2026-10-14: lilToon への焼き込み（Editor/Shaders/SpiderWebBaker.shader）と同じ式を使うため、
            // シェーダー本体から切り出した。中身は切り出す前と同じ（描画が画素一致することを確認済み）。
            #include "CGINC/SpiderWeb_Core.cginc"
        ENDCG

        Pass
        {
            Name "DEPTHSOLID"
            Tags { "LightMode" = "ForwardBase" }
            ColorMask 0
            ZWrite On
            Cull Off

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment fragDepth
            #pragma target   3.5
            #pragma multi_compile_instancing
            #pragma shader_feature_local SW_REVEAL
            ENDCG
        }

        Pass
        {
            Name "FORWARD"
            // ForwardBase タグ: メインライト・環境光を確実にバインドする
            Tags { "LightMode" = "ForwardBase" }

            Blend SrcAlpha OneMinusSrcAlpha
            // 深度は Pass 0 が芯だけ書いたので、ここでは書かない（半透明が奥を隠さない）
            ZWrite Off
            Cull Off   // 両面描画（薄い巣は裏からも見える）

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment frag
            #pragma target   3.5
            #pragma multi_compile_instancing
            #pragma shader_feature_local SW_REVEAL
            ENDCG
        }
    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}
