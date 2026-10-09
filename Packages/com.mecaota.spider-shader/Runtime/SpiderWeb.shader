// =============================================================================
// SpiderWeb.shader — 蜘蛛の巣 シェーダー (VRChat / Built-in RP 専用)
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
//    弾性の波形は吐いた糸と SpiderSilk_Motion.cginc で共通化。
//    横糸は区間ごとに弧全体を動かすので、波の細かさ（_SwayAnimWaves）は使わない。
//    接触追従の変形（_PullEnable）とは別の処理で、触れていても揺れは止めない。
//
//  ■ 質感（粘液）
//    縦糸・横糸の距離場を smooth-min で融合し、すき間の角を水かき状の膜で
//    埋め、横糸に糊の玉を付ける。塗り（丸い断面のトゥーン・ハイライトの筋・
//    輪郭線・透け）は吐いた糸・繭と共通の CGINC/SpiderGoo_Shading.cginc。
//    _SpokeGoo / _RingGoo で縦横の粘液を独立調整。交点は常につなぐ。
//    1 未満は縦糸を太さ一定の直線として描き、その上に粘液の横糸を重ねる（交点の糊は
//    横糸側のふくらみ）。飛ばした巣（パーティクル・着弾した網）は 1、固定設置の巣は 0
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
        // ※ 質感（Look）21 個（_Goo の色・陰影・光沢・粘液感 / トゥーン / リム）は 4 シェーダーで
        //   名前・型・範囲・既定値を完全一致させる（一覧: Editor/SpiderSilkLook.cs、宣言: CGINC/SpiderSilk_Look.cginc）。
        //   巣・繭・デカールではこの値を「継承元の蜘蛛糸マテリアル」から受け継ぐ。
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

        // ---- 粘液の質感（吐いた糸・繭と同じ塗り） ----
        // 粘液感を下げると太り・玉・膜・ツヤ・透けが一緒に弱まる（0 で乾いた細い糸）
        [Header(Goo Shape)]
        _GooAmount    ("粘液感 0で乾いた糸 (Goo Amount)", Range(0, 1))     = 1
        _GooThick     ("粘液の太さ倍率 (Goo Thickness)", Range(0.5, 4))    = 1.6
        _GooBeads     ("粘着玉の大きさ (Glue Beads)", Range(0, 1))         = 0.5
        _GooBeadFreq  ("粘着玉の細かさ UV毎 (Bead Freq)", Float)           = 30
        _GooWebFill   ("すき間を埋める膜 (Membrane Fill)", Range(0, 1))     = 0.35
        // 縦糸（放射状の支持糸）の粘液。1 で縦糸と横糸が一体の粘液（融合・すき間の膜）。
        // 1 未満は縦糸を太さ一定の直線として描き、その上に粘液の横糸を重ねる
        // （0 で乾いた糸＝実物の円網と同じく横糸だけが粘着）
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
            // 吐いた糸（SpiderThreadTrail）は Transparent-10 で巣より「先」に描かれる。
            // 巣の向こうの糸は、この巣が半透明で重なって必ず透けて見える（巣の深度で消えない）。
            // 手前の糸は芯の深度を書いているので、その画素では巣が深度テストに負けて糸の上に重ならない
            // （SpiderThreadTrail 側の説明参照）
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
            // 粘液の塗り（吐いた糸・繭と共通）
            #include "CGINC/SpiderGoo_Shading.cginc"
            #include "CGINC/SpiderSilk_Motion.cginc"

            // ---- 巣固有の uniform（共通 uniform は Common.cginc 宣言を使用） ----
            float  _HubOffsetX;
            float  _HubOffsetY;
            float  _WebRadius;
            float  _Thickness;
            float  _RadialCount;
            float  _RingCount;
            float  _Sag;
            float  _SpokeExtend;
            float  _Irregular;
            float  _Seed;
            float _FanEnable, _FanAngle, _FanRotation, _FanMeshRim;
            float _SpokeWidth, _RingWidth, _Organic, _JunctionSize;
            // 粘液の形。_GooThick / _GooBeads / _GooBeadFreq / _GooWebFill / _GooWebScale は
            // 吐いた糸・繭と同名なので SpiderCocoon_Common.cginc で宣言済み（巣では UV 単位）。
            // 粘液感・色・陰影・光沢の uniform は質感 = SpiderSilk_Look.cginc
            float _SpokeGoo, _RingGoo;

            // ---- 接触追従の変形（uniform と変位関数は繭と共通の Pull.cginc） ----
            #include "CGINC/SpiderCocoon_Pull.cginc"
            // ---- 投げつけた網が体に覆いかぶさる変形 ----
            #include "CGINC/SpiderWeb_Drape.cginc"
            #if defined(SW_REVEAL)
            float _RevealNear, _RevealFar, _RevealNoise, _RevealNoiseScale;
            float4 _ClipLine;

            float SW_RevealFade(float3 wp, float2 uv)
            {
                float3 cam = SC_MonoCameraPos();
                float n = (STG_ValueNoise2(wp.xy * _RevealNoiseScale) + STG_ValueNoise2(wp.zy * _RevealNoiseScale + 17.3)) * 0.5;
                float d = distance(wp, cam) + (n - 0.5) * 2.0 * _RevealNoise;
                float reveal = 1.0 - smoothstep(_RevealNear, max(_RevealFar, _RevealNear + 0.01), d);
                float clipY = lerp(_ClipLine.x, _ClipLine.y, saturate(uv.x));
                float bottom = saturate((wp.y - clipY) / 0.25);
                return reveal * bottom;
            }
            #endif

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
                float fanRim : TEXCOORD4;   // ハブ→扇の外周の UV 距離（メッシュ提供時のみ）
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            // 縦糸番号を 0..N-1 に折り返す（フロア剰余）。
            // 角度は atan2 で -180°..+180° として得られ、±180° の継ぎ目で
            // 番号が N ずれる。折り返しておくと継ぎ目の両側で同じ乱数になり、
            // 継ぎ目に縦の裂け目が出ない。
            float wrapId(float k, float n)
            {
                return k - n * floor(k / n);
            }

            // 縦糸 k の角度ジッター（セクター単位・最大 ±0.2）。
            // _Seed はハッシュ入力への加算で注入（旧実装とビット等価）。
            // saturate はスクリプト等から Range 外の値が入ってもセル判定の
            // 前提（|ジッター|<=0.2）を守るための保険。
            float spokeJitter(float k, float n)
            {
                if (_FanEnable > 0.5 && (k < 0.5 || k > n - 1.5)) return 0.0;
                return SC_Hash11Signed(wrapId(k, n) + _Seed * 37.219) * 0.2 * saturate(_Irregular);
            }

            // 角度 aVal（セクター単位）を挟む2本の縦糸（ジッター後の実位置）を求める。
            // ジッターで縦糸が動いた結果 aVal が区間外に出ていたら隣のセルへ
            // 1段ずらす（ジッター最大±0.2なので1段で必ず収まる）。
            // これで「セルの切り替わり位置＝実際の縦糸の位置」となり、
            // 垂れ・揺らぎがセル境界でジャンプしない（断裂バグ修正の核心）。
            void spokeCell(float aVal, float n, out float k0, out float a0, out float a1)
            {
                if (_FanEnable > 0.5) aVal = clamp(aVal, 0.0, n - 1.0001);
                k0 = floor(aVal);
                a0 = k0 + spokeJitter(k0, n);
                a1 = (k0 + 1.0) + spokeJitter(k0 + 1.0, n);
                if (aVal < a0)
                {
                    a1 = a0; k0 -= 1.0; a0 = k0 + spokeJitter(k0, n);
                }
                else if (aVal >= a1)
                {
                    a0 = a1; k0 += 1.0; a1 = (k0 + 1.0) + spokeJitter(k0 + 1.0, n);
                }
            }

            float webThreadWidth(float id, float seed, float along)
            {
                float legacy = SC_ThreadWidthMul(id, seed, along);
                // 指数の倍率は常に正。強い太さの揺らぎでも糸を途切れさせない。
                float jitter = SC_Hash11Signed(id + seed);
                float fuzz = SC_ValueNoise1(along * _ThreadFuzzScale + (id + seed) * 7.0) * 2.0 - 1.0;
                float organic = exp2(saturate(_ThreadJitter) * jitter
                                   + saturate(_ThreadFuzz) * 0.75 * fuzz);
                return lerp(legacy, organic, saturate(_Organic));
            }

            web_v2f vert(web_appdata v)
            {
                web_v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(web_v2f, o);
                UNITY_TRANSFER_INSTANCE_ID(v, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                float3 wp = mul(unity_ObjectToWorld, v.vertex).xyz;
                float3 N0 = UnityObjectToWorldNormal(v.normal);
                float3 T0 = UnityObjectToWorldDir(v.tangent.xyz);
                o.uv = v.uv;
                o.fanRim = (_FanMeshRim > 0.5) ? v.uv2.x : 0.0;

                // 体に覆いかぶさる網（位置・法線・接線をワールドで直接求める）
                UNITY_BRANCH
                if (SW_DrapeActive())
                {
                    float3 pDr, NDr, TDr;
                    SW_DrapeDeform(v.uv, pDr, NDr, TDr);
                    o.pos          = UnityWorldToClipPos(pDr);
                    o.worldPos     = pDr;
                    o.worldNormal  = NDr;
                    o.worldTangent = float4(TDr, v.tangent.w);
                    return o;
                }

                // 変形が無効（またはどのスロットも未使用）なら従来どおりのパススルー
                UNITY_BRANCH
                if (!SC_PullActive())
                {
                    o.pos          = UnityObjectToClipPos(v.vertex);
                    o.worldPos     = wp;
                    o.worldNormal  = N0;
                    o.worldTangent = float4(T0, v.tangent.w);
                    return o;
                }

                // ---- 接触追従の変形（ワールド空間。法線・接線は変位後の面から再計算） ----
                float3 pD = wp, N = N0, Tn = T0;
                SC_PullDeform(pD, N, Tn);

                o.pos          = UnityWorldToClipPos(pD);
                o.worldPos     = pD;
                o.worldNormal  = N;
                o.worldTangent = float4(Tn, v.tangent.w);
                return o;
            }

            fixed4 frag(web_v2f i, fixed facing : VFACE) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // 隣り合う画素の差を使うので、discard で画素を捨てる前に伸び率を調べる。
                float drapeStretchFade = SW_DrapeStretchFade(i.worldPos, i.uv);
                #if defined(SW_REVEAL)
                float revealFade = SW_RevealFade(i.worldPos, i.uv);
                #endif

                // 裏面（カメラに背を向けた面）を描かないオプション。
                // スフィア等の立体では奥側の糸が透けて見えるのを防げる
                if (_HideBackFibers > 0.5 && facing < 0.0) discard;

                // 本数は必ず整数に丸める。非整数だと ±180° の継ぎ目で乱数が
                // 食い違い、縦の裂け目が出る（スクリプトやアニメーションから
                // 非整数が入っても壊れないための保険）。
                float N  = max(3.0, round(_RadialCount));
                float NR = max(1.0, round(_RingCount));

                // 縦糸・ハブの座標は動かさず、下の横糸の半径だけを動かす。
                float2 uvW = i.uv;
                float edgeD = 0.5 - max(abs(i.uv.x - 0.5), abs(i.uv.y - 0.5));
                float edgePin = (_SwayAnimAnchor > 1e-4)
                    ? smoothstep(0.0, max(_SwayAnimAnchor, 1e-4), edgeD) : 1.0;
                float ringMotion = (_SwayAnimEnable > 0.5 ? 1.0 : 0.0) * edgePin;

                // ============ ハブ（中心結節点）の偏心幾何 ============
                // 外周円（UV中央・半径 _WebRadius）は固定のまま、糸が
                // 集まるハブだけを _HubOffset（半径に対する比）でずらす。
                float2 hubOfs = float2(_HubOffsetX, _HubOffsetY);
                float  hubLen = length(hubOfs);
                hubOfs *= (hubLen > 0.9) ? 0.9 / hubLen : 1.0;  // 斜め入力でも外周円の内側に制限
                float2 h = hubOfs * _WebRadius;                 // ハブ変位（UV空間）
                // ハブは必ずメッシュの内側に留める（縦糸終端の射影が壊れない保険）
                float hLen = length(h);
                h *= (hLen > 0.45) ? 0.45 / hLen : 1.0;
                bool fan = _FanEnable > 0.5;
                // 扇形では -1/+1 がメッシュ端。円形モードの偏心幾何はそのまま。
                if (fan) h = clamp(float2(_HubOffsetX, _HubOffsetY), -0.999, 0.999) * 0.5;

                float2 p   = (uvW - 0.5) - h;                   // ハブ基準の座標（巣はUV中央）
                float  r   = length(p);
                float2 u   = (r > 1e-5) ? p / r : float2(1.0, 0.0);
                float2 radialDir = u;                           // ハブ→外向き

                // ハブから方向 u に伸ばした半直線が外周円に届くまでの距離 Redge。
                // 「|ハブ + 距離×u - 外周円中心| = 半径」の2次方程式の正の解で、
                // ハブが円の内側にある限り必ず正の実数になる。
                float uh    = dot(u, h);
                float Redge = -uh + sqrt(max(uh * uh + _WebRadius * _WebRadius - dot(h, h), 1e-6));
                // ハブから方向 u に伸ばした半直線がメッシュ端（UV 正方形の縁）に届くまでの距離
                float tqx = (abs(u.x) > 1e-6) ? ((u.x > 0.0 ? 0.5 : -0.5) - h.x) / u.x : 1e6;
                float tqy = (abs(u.y) > 1e-6) ? ((u.y > 0.0 ? 0.5 : -0.5) - h.y) / u.y : 1e6;
                if (fan)
                {
                    // 扇形: 横糸は外周まで並べる。外周はメッシュが UV2 で渡す距離
                    //（木の幹に張り付く巣＝地面との接地線）、無ければ UV 正方形の端。
                    // 巣の半径はそれより内側で止めたいときの上限。最外周の横糸が
                    // メッシュ端で半分に切れないよう、糸の太さぶん内側に置く
                    float rimDist  = (i.fanRim > 1e-4) ? i.fanRim : min(tqx, tqy);
                    float rimInset = _Thickness * max(_RingWidth, 0.05)
                                   * lerp(1.0, _GooThick, saturate(_GooAmount) * saturate(_RingGoo));
                    Redge = max(min(_WebRadius, rimDist - rimInset), 0.001);
                }
                // 正規化半径: ハブで0、外周円上で1。リングはこの空間に等間隔で
                // 並べるので、ハブが偏ると片側が密・反対側が疎になる（実巣と同じ）。
                float rho = r / Redge;

                // ============ 縦糸: 1本の直線・終端はメッシュ端に固定 ============
                // 縦糸 k は「ハブ → メッシュ端の固定終端 E_k」を結ぶ1本の直線。
                // E_k は UV 中央からセクター角 φ_k の方向へ伸ばした線がメッシュ端
                //（UV 正方形の縁）に当たる点で、ハブに依存しない。
                // → ハブを動かしても縦糸の終端は動かず、直線のまま終端を支点に
                //   傾くだけ。延長 OFF は外周円から外側を透明にするだけで、
                //   糸の形そのものは変わらない。
                //
                // セル判定は「ピクセルをハブからの視線でメッシュ端に射影した点の
                // 中心角」で行う。縦糸上のピクセルは必ず自分の終端 E_k に射影
                // される（中心角=φ_k）ため、垂れ・揺らぎの区間切替は厳密に
                // 縦糸の上で起こり、横糸が空中で切れることはない。
                float2 Q  = h + min(tqx, tqy) * u;              // メッシュ端への射影点
                float ang = atan2(Q.y, Q.x);                    // 射影点の中心角
                float fanRotation = radians(_FanRotation);
                float fanHalf = radians(clamp(_FanAngle, 15.0, 330.0)) * 0.5;
                float fanTheta = atan2(sin(atan2(p.y, p.x) - fanRotation),
                                       cos(atan2(p.y, p.x) - fanRotation));
                if (fan)
                {
                    // 扇形の揺れの固定: UV 正方形の縁ではなく、外周と両端の縦糸からの距離で固定する
                    float fanEdgeD = min((1.0 - rho) * Redge, (fanHalf - abs(fanTheta)) * r);
                    float fanPin = (_SwayAnimAnchor > 1e-4)
                        ? smoothstep(0.0, max(_SwayAnimAnchor, 1e-4), fanEdgeD) : 1.0;
                    ringMotion = (_SwayAnimEnable > 0.5 ? 1.0 : 0.0) * fanPin;
                }

                // ---- ジッター後の実位置でセル（区間）を確定 ----
                float sector = UNITY_TWO_PI / N;                // 1区間の角度
                float a = ang / sector;                         // 射影中心角（セクター単位）
                if (fan)
                {
                    sector = (2.0 * fanHalf) / (N - 1.0);
                    a = (fanTheta + fanHalf) / sector;
                    ang = fanTheta;
                }
                float k0, a0, a1;
                spokeCell(a, N, k0, a0, a1);
                float segId = wrapId(k0, N);                    // この区間のID

                // ---- 縦糸の距離場 ----
                // 隣り合う2本それぞれの固定終端 E（UV 中央から角度 φ の方向へ
                // 伸ばした線がメッシュ端に当たる点。max 成分での正規化が
                // 「原点から正方形の縁まで」の閉形式になる）
                float angleOffset = fan ? fanRotation - fanHalf : 0.0;
                float2 e0 = float2(cos(a0 * sector + angleOffset), sin(a0 * sector + angleOffset));
                float2 e1 = float2(cos(a1 * sector + angleOffset), sin(a1 * sector + angleOffset));
                float2 E0 = e0 * (0.5 / max(abs(e0.x), abs(e0.y)));
                float2 E1 = e1 * (0.5 / max(abs(e1.x), abs(e1.y)));
                // 走行方向: ハブ（原点）→ 固定終端。ハブ移動で変わるのはここだけ
                float2 dirA = normalize(E0 - h);
                float2 dirB = normalize(E1 - h);
                if (fan) { dirA = e0; dirB = e1; }

                // ---- 縦糸間での正規化位置 t（垂れ下がりの基準） ----
                // 射影角 a ではなく「ハブから見た実際の角度」で取る。射影角だと
                // メッシュのかどを通る向きで角度の進み方が急変し、垂れた横糸の
                // 弧に折れ目が出るため（ハブ偏心時のみ現れる）。
                // 縦糸上では視線方向が dirA/dirB と一致して t=0/1 になるので、
                // 「sagCurve は縦糸上で厳密に0」の保証はそのまま維持される。
                float thA = atan2(dirA.y, dirA.x);
                float dAB = atan2(dirB.y, dirB.x) - thA;
                dAB += (dAB <= 0.0) ? UNITY_TWO_PI : 0.0;       // 0..2π に巻き戻し
                float dA  = atan2(u.y, u.x) - thA;
                dA  += (dA < 0.0) ? UNITY_TWO_PI : 0.0;
                float t        = saturate(dA / max(dAB, 1e-4));
                float sagCurve = SSM_PinEnvelope(t);            // 縦糸上0・中間1
                // 符号付き垂直距離（2Dの外積＝直線までの厳密距離）。
                // ハブより後ろ側（糸が無い側）ではハブまでの距離 r に切り替える
                //（dot=0 の境界では |外積|=r なので連続につながる）
                float sd0 = dirA.x * p.y - dirA.y * p.x;
                float sd1 = dirB.x * p.y - dirB.y * p.x;
                float dist0 = (dot(p, dirA) >= 0.0) ? abs(sd0) : r;
                float dist1 = (dot(p, dirB) >= 0.0) ? abs(sd1) : r;
                bool  nearLeft    = dist0 < dist1;
                float spokeK      = nearLeft ? k0 : (k0 + 1.0);  // 採用した縦糸の番号
                float spokeSigned = nearLeft ? sd0 : sd1;
                float spokeDist   = nearLeft ? dist0 : dist1;
                // 糸の横断方向（法線曲げ用）: 走行方向に対して垂直
                float2 spokeDir  = nearLeft ? dirA : dirB;
                float2 spokePerp = float2(-spokeDir.y, spokeDir.x);

                // 縦糸の太さ: 糸ごとの個体差＋長さ方向のうねり（繭と共通の式）。
                // 位置ジッターと同じ乱数にならないよう +57 で系列をずらす。
                // 糸に沿った座標は r（ハブからの距離）。
                float hwS = max(_Thickness * webThreadWidth(wrapId(spokeK, N), _Seed * 37.219 + 57.0, r), 1e-4);
                float silkS = SC_ValueNoise1(r * 17.0 + wrapId(spokeK, N) * 19.7 + _Seed);
                hwS *= max(_SpokeWidth, 0.05) * lerp(1.0, 0.45 + 1.25 * silkS, _Organic);

                // ============ 横糸: rho 空間に等間隔配置 → 垂れ＋揺らぎ ============
                // saturate は Range 外の値がスクリプト等から入っても
                // 除算や区間判定が壊れないための保険
                float sag = saturate(_Sag);
                float irr = saturate(_Irregular);
                float sp       = 1.0 / NR;                       // リング間隔（rho空間）
                // A tensioned arc between spokes, not a nearly circular ring.
                // Scale the static bow with angular span and radius, shared by
                // every ring so nested arcs preserve their order. Endpoints stay fixed.
                float bow = 4.0 * t * (1.0 - t);
                float spanVariation = lerp(1.0, 0.8 + 0.4 *
                    SC_Hash11(segId * 311.7 + _Seed * 37.219), irr);
                float warpBase = 1.0 + min(sag * 2.5 * sin(min(dAB, UNITY_PI) * 0.5)
                                           * spanVariation, 0.65) * bow;
                float kc       = round(rho * warpBase / sp);     // 最寄りリングの推定番号

                // 前後2本ずつの候補から最寄りを厳密に選ぶ（揺らぎ・垂れで
                // ずれても取りこぼさない。±2で全パラメータ範囲をカバー）
                float ringSigned = 1e6;
                float ringK      = 0.0;
                [unroll]
                for (int m = -2; m <= 2; m++)
                {
                    float k = kc + (float)m;
                    if (k > 0.5 && k < NR + 0.5)
                    {
                        // 最外周（k==NR）だけは乱数揺らぎを0にして、外周円に
                        // 沿った予測しやすい形に保つ（垂れ自体は残る）
                        float gateOut = (k < NR - 0.5) ? 1.0 : 0.0;
                        // リングごとの半径の揺らぎ
                        float rj = SC_Hash11Signed(k * 7.31 + 113.7 + _Seed * 37.219)
                                 * 0.2 * sp * irr * gateOut;
                        // Both adjacent cells use the same value at each spoke.
                        // Uneven attachment heights break concentric regularity
                        // without leaving detached endpoints at a cell boundary.
                        float j0 = SC_Hash11Signed(k * 73.1 + wrapId(k0, N) * 191.7 + _Seed);
                        float j1 = SC_Hash11Signed(k * 73.1 + wrapId(k0 + 1.0, N) * 191.7 + _Seed);
                        rj += lerp(j0, j1, smoothstep(0.0, 1.0, t)) * 0.12 * sp * irr * gateOut;
                        // 区間（リング×縦糸間）ごとの垂れ幅の揺らぎ。
                        // sagCurve 倍なので縦糸上では必ず0＝区間が替わる瞬間も
                        // リング半径は連続で、糸は縦糸の上で繋がったまま
                        float vs = SC_Hash11Signed(k * 127.1 + segId * 311.7 + _Seed * 37.219)
                                 * 0.04 * sp * irr * sagCurve * gateOut / warpBase;
                        float rhoK = max((k * sp + rj) / warpBase - vs, 1e-4);
                        // Limit to 6% ring spacing: keep ordering and +/-2 candidate search valid.
                        // Spoke junctions remain exactly fixed (sagCurve=0).
                        float amplitude = min(max(_SwayAnimAmount, 0.0),
                                              0.06 * sp * Redge / max(warpBase, 1e-3));
                        float phase = SC_Hash11(k * 127.1 + segId * 311.7 + _Seed) * UNITY_TWO_PI;
                        float ringShift = amplitude * sagCurve * ringMotion
                            // Move the whole arc gently; spatial waves along t
                            // made otherwise dry capture silk look serrated.
                            * SSM_ElasticWave(0.0, _SwayAnimWaves, _Time.y * _SwayAnimSpeed, phase);
                        rhoK += ringShift / max(Redge, 1e-4);
                        float ds   = (rho - rhoK) * Redge;       // UV空間の実距離に換算
                        if (abs(ds) < abs(ringSigned)) { ringSigned = ds; ringK = k; }
                    }
                }
                float ringDist = abs(ringSigned);

                // 横糸の太さ乱雑性。糸に沿った座標は角度だが、±180°の継ぎ目で
                // 値が飛ばないよう折り返して連続化する（繭デカールと同じ手法）
                float foldAng = abs(frac(ang / UNITY_TWO_PI + 0.5) - 0.5) * 2.0;
                float hwR = max(_Thickness * webThreadWidth(ringK, _Seed * 37.219 + 157.0, foldAng), 1e-4);
                // UV位置を使うことで角度の継ぎ目でも太さが連続する。
                float silkR = SC_ValueNoise1(dot(uvW, float2(19.1, 27.7)) + ringK * 13.3 + _Seed);
                hwR *= max(_RingWidth, 0.05) * lerp(1.0, 0.4 + 1.3 * silkR, _Organic);

                // ============ 粘液の糸（塗りは SpiderGoo_Shading.cginc と共通） ============
                // 粘液感（_GooAmount）で太り・玉・膜をまとめて弱める（1 で各設定値そのまま）
                float amt = saturate(_GooAmount);
                // 縦糸の粘液（_SpokeGoo）: 1 で横糸と同じ粘液、0 で乾いた細い糸
                float spokeG = saturate(_SpokeGoo);
                float ringG = saturate(_RingGoo);
                // 1) 太さ: 粘液の太さ倍率 × 粘着玉。実物の巣でも横糸（捕獲糸）には
                //    糊の玉が数珠状に並ぶので、玉は横糸に強く・縦糸には控えめに付ける。
                float alongS = r;                                   // 縦糸に沿った座標
                float alongR = foldAng * UNITY_PI * r;              // 横糸に沿った座標（継ぎ目で折り返して連続）
                float bAmt   = saturate(_GooBeads) * amt;
                float thick  = lerp(1.0, _GooThick, amt);
                float beadS  = smoothstep(0.35, 0.9, SC_ValueNoise1(alongS * _GooBeadFreq
                                          + wrapId(spokeK, N) * 7.13 + _Seed * 3.1));
                float beadR  = smoothstep(0.35, 0.9, SC_ValueNoise1(alongR * _GooBeadFreq
                                          + ringK * 5.71 + _Seed * 3.1 + 17.0));
                hwS = lerp(max(_Thickness * max(_SpokeWidth, 0.05), 1e-4), hwS, spokeG);
                hwR = lerp(max(_Thickness * max(_RingWidth, 0.05), 1e-4), hwR, ringG);
                float gS = hwS * lerp(1.0, thick, spokeG) * lerp(1.0, 1.0 + 0.8 * bAmt, beadS * 0.5 * spokeG);
                float gR = hwR * lerp(1.0, thick, ringG) * lerp(1.0, lerp(1.0 - 0.2 * bAmt, 1.0 + 1.6 * bAmt, beadR), ringG);

                // 2) 糸ごとの距離場（負=粘液の中）。縦糸は延長 OFF なら外周円で止める
                float overG = (rho - 1.0) * Redge;
                float dS    = spokeDist - gS;
                bool  capS  = (_SpokeExtend < 0.5) && (overG > dS);
                if (capS) dS = overG;
                float dR    = ringDist - gR;

                // ---- 塗りの向き（面の法線・接線・視線・光） ----
                float3 NfrontG = normalize(i.worldNormal);
                float3 NwG = NfrontG * sign(facing);
                float3 TG  = normalize(i.worldTangent.xyz);
                float3 BG  = normalize(cross(NfrontG, TG)) * i.worldTangent.w * unity_WorldTransformParams.w;
                float3 VG  = normalize(_WorldSpaceCameraPos - i.worldPos);
                float3 LG  = STG_GooLightDir();

                // A single continuous field for all four wet/dry combinations.
                // Only shading and strand width vary; junction connectivity does not.
                float cellR = sp * Redge / max(warpBase, 1e-3);    // 横糸の間隔（UV）
                float cellS = r * sector;                          // その半径での縦糸の間隔（弧長）
                float fillN = STG_ValueNoise2(uvW * _GooWebScale + _Seed * 1.37);
                float kGoo  = _Thickness * _JunctionSize * 2.5
                            + _GooWebFill * amt * min(spokeG, ringG) * min(cellR, cellS) * lerp(0.2, 2.2, fillN * fillN);
                float hSR;                                         // 縦糸側の重み
                float dGoo  = STG_SMin(dS, dR, kGoo, hSR);

                // 輪郭の外向き（UV 平面内）: 縦糸は横断方向、横糸は放射方向。
                // 融合部分は同じ重みで混ぜる（断面の法線がなめらかにつながる）
                float2 gS2 = (dot(p, spokeDir) >= 0.0)
                           ? spokePerp * ((spokeSigned >= 0.0) ? 1.0 : -1.0) : u;
                if (capS) gS2 = radialDir;
                float2 gR2 = radialDir * ((ringSigned >= 0.0) ? 1.0 : -1.0);
                float2 gG  = lerp(gR2, gS2, hSR);
                gG = (dot(gG, gG) > 1e-8) ? normalize(gG) : radialDir;
                float  rG  = lerp(gR, gS, hSR);

                if (fan)
                {
                    float boundary = (abs(fanTheta) - fanHalf) * r;
                    dGoo = max(dGoo, boundary - gS);
                }

                // 4) 塗り（丸い断面・トゥーン・ハイライト・輪郭線・透け）。
                //    濡れ具合（ツヤ・透け）は縦横それぞれの粘液感に合わせる。
                float spokeness = saturate((hSR - 0.35) / 0.6);
                float wet       = amt * lerp(ringG, spokeG, spokeness);
                STG_GooSurface gs = STG_GooProfile(dGoo, rG, gG, NwG, TG, BG);
                float3 colG = STG_GooBaseColor(gs, NwG, LG);
                // 数 px しかない細い糸では輪郭線・ハイライトを弱める（遠景のにじみ防止）
                float detail = saturate(1.6 - fwidth(gs.q) * 2.5);
                float glossN = SC_ValueNoise1(lerp(alongR, alongS, hSR) * _GooBeadFreq * 0.6 + 3.3);
                fixed4 goo = STG_GooFinishWet(colG, 0.0, gs, dGoo, NwG, VG, LG, glossN, detail, rG, wet);
                // 色・深度の両パスが使う最終不透明度を薄くし、伸びた所の深度も残さない。
                goo.a *= drapeStretchFade;
                #if defined(SW_REVEAL)
                goo.a *= revealFade;
                #endif
                if (goo.a <= 0.001) discard;
                return goo;
            }

            // Pass 0 用: 色は使わず、芯（不透明度が高い所）だけ残して深度を書かせる
            fixed4 fragDepth(web_v2f i, fixed facing : VFACE) : SV_Target
            {
                fixed4 c = frag(i, facing);
                clip(c.a - SW_DEPTH_SOLID_ALPHA);
                return 0;
            }
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
            #pragma multi_compile_fwdbase
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
            #pragma multi_compile_fwdbase
            #pragma shader_feature_local SW_REVEAL
            ENDCG
        }
    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}
