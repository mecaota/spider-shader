// =============================================================================
// CocoonDecal.shader — 繭デカールシェーダー（深度デカールでプレイヤー体表に繭） (VRChat / Built-in RP)
//
//  胴を囲むボックスメッシュに貼る「スクリーンスペース深度デカール」。
//  各画素で _CameraDepthTexture を読み、その先の表面（＝アバター）のワールド
//  座標を復元。その点を「このボックスのローカル空間」へ変換し、ボックスの
//  内接円筒（local XZ 半径・local Y 高さ）の中なら、本体 Cocoon と
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
//  ★ ミラー（Pass 3）:
//     ミラーでも通常視点と同じ体表 glue を描く。ミラーカメラは自前の深度を
//     持つが、鏡面に沿った斜交（oblique）投影のため LinearEyeDepth は使えず、
//     専用の解析的復元（SC_EyeDepthOblique）で視線深度を求める。
//     ZTest LEqual なので鏡内の遮蔽物に正しく隠れる。
//
//  ★ 視界ジャック（包まれ演出）: カメラが殻円筒の内側に入ると、カメラの周囲に
//     繭の内壁（紡錘形楕円体）を「実寸の深度付き」で描く。壁より手前にある
//     自分のアバターの体などは遮られず見える＝繭に包まれている見え方。
//     実装は Cocoon 本体と共通（CGINC/SpiderCocoon_VisionJack.cginc）。
//     （近クリップ対策として、ジャック中はボックスを頂点で拡大する）
//     捕まった本人の視界（2026-10-25）: 駆動スクリプトが本人の頭の位置（_JackHead）を渡すと、発火は
//     「カメラが本人の頭の近くにあるか」になり（覗き込んだ他の人には出ない）、壁は目の周りの小さな内壁
//     （体を見下ろす向きは開けて、体に張り付いた繭を見せる）か、太さをそろえた筒の内側の面になる（SC_DecalJackWall）。
//
//  ★ 質感: 本体と同じ粘液の帯（CGINC/SpiderCocoon_Goo.cginc）。平たい帯を奥→手前へ
//     重ね、上の帯の縁が下の帯に影を落とす。塗りは蜘蛛糸・蜘蛛の巣と共通
//     （SpiderGoo_Shading.cginc）。粘液感（_GooAmount）を下げると乾いた細い糸に近づく。
//
//  ★ くっついた繭を 1 つに（CGINC/SpiderCocoon_Group.cginc）: CocoonGroupLinker（Udon）が
//     くっついた繭をまとめ、グループの代表にだけ仲間の円筒と共通の巻き座標を
//     MaterialPropertyBlock で渡す。代表は仲間の円筒の和の中だけを共通の向きの帯で巻き、
//     他の繭は描かない。Group Bulge > 0 は体表を厚い外殻へ膨らませ、近い部位間を糸でつなぐ。
//     巻きの端では帯が細って途切れる（_GooEdgeFray）。輪に入り込んだ別の部位の面は
//     体表の向きで除ける（_WrapFacing）。
//
//  ★ 巻きアニメ（_WindEnable / _WindProgress）: 帯（螺旋）を糸に沿って少しずつ伸ばし、
//     糸の先端が体の周りをぐるぐる回りながら進む。層を 1 枚ずつ往復して巻き、帯の間の膜も
//     だんだん育つので、薄く巻かれた状態から完成した繭へ変わっていく。視界ジャックの内壁も
//     同じ関数で塗るので、包まれる本人の視界にも糸が巻かれていく。実装は
//     CGINC/SpiderCocoon_Goo.cginc（SC_CompositeGoo）。OFF（既定）は従来どおり完成した繭。
//
//  ★ 太さをそろえる（_EvenGirth、2026-10-25）: 体に沿って巻いた繭はミイラのように見えるので、
//     体の一番太い所に合わせた「太さのそろった筒」（両端が丸いカプセル）を体の繭と重ね、手前の方を描く。
//     0 で今までどおり、1 で体全体が筒の中に入る。筒は式で交点を求めるので、体の輪郭の外にも描ける。
//     筒の位置と太さは繭プロジェクターの駆動スクリプトが骨から渡す（繭プロジェクターと組まないときは、この箱の円柱）。
//     繭プロジェクターの目印の無い画素の筒は Pass 6（EVEN_GIRTH）が描く。
//
//  ★ 軽量化（2026-10-14。見た目は変えずに、描かれない画素の計算を省く。詳しくは README の「描画の軽量化」）:
//     - Pass 2 は鏡の中、Pass 3 は鏡の外で、頂点の段階で三角形を潰す（フラグメントを出さない）。
//     - Pass 2 は視線が円柱（代表は箱）に届かない画素を、床判定と糸の厚みのループの前に捨てる。
//     - 視界ジャックの深度パス（Pass 0）は不透明度だけを求め、芯と決まった所で残りの層を省く。
//     - 全身の殻（GROUP_SHELL）は、smooth-min に効かない遠い部位・繭同士の接続部位の計算を飛ばす。
//     - 表面の模様はキーワード SC_SURFACE_NET（_SurfaceStyle と同期）で切り替える。
//
//  ★ 必須前提:
//     - ワールドに「影付きリアルタイム Directional Light」（_CameraDepthTexture 供給）。
//     - Quest は screen-space 非対応（PC 専用）。
// =============================================================================
Shader "mecaota/CocoonDecal"
{
    Properties
    {
        // ※ 質感（Look）21 個（_Goo の色・陰影・光沢・粘液感 / トゥーン / リム）は 5 シェーダー
        //   （蜘蛛糸・蜘蛛の巣・繭・繭デカール・蜘蛛の巣ドレープ）で
        //   名前・型・範囲・既定値を完全一致させる（一覧: Editor/SpiderSilkLook.cs、宣言: CGINC/SpiderSilk_Look.cginc）。
        //   巣・繭・繭デカール・蜘蛛の巣ドレープではこの値を「継承元の蜘蛛糸マテリアル」から受け継ぐ。
        // カテゴリ分け・共通/固有の区別は CustomEditor（SpiderCocoonShaderGUI）が担当。
        // [Header] は Editor スクリプトが無い環境（標準インスペクタ）向けの
        // フォールバック表示。カスタム GUI 側は Header 装飾をスキップして描くため
        // 二重表示にはならない。
        // ※ ShaderLab の属性引数は ASCII のみ（日本語を書くとパースエラー）。
        [Header(Thread Design)]
        _ThreadThickness    ("糸の太さ (Thickness)", Range(0.01, 1.0))     = 0.35
        _ThreadJitter       ("太さの乱雑性 (Thickness Jitter)", Range(0, 1))= 0.3
        _ThreadFuzz         ("幅の揺らぎ (Fuzz Amount)", Range(0, 1))       = 0.2
        _ThreadFuzzScale    ("揺らぎの細かさ (Fuzz Scale)", Float)          = 8.0

        [Header(Winding Layout)]
        _WindingCount       ("巻き数 (Winding Count)", Float)               = 24
        _ThreadDensity      ("糸の密度倍率 (Density Mult)", Float)          = 1.0
        _FiberAngle         ("基準の糸の角度 (Base Fiber Angle deg)", Range(-89, 89)) = 0

        [Header(Toon Shading)]
        _ToonSteps          ("トゥーン段階数 (Toon Steps)", Range(1, 8))    = 1
        _ToonSmooth         ("段差の柔らかさ (Toon Smooth)", Range(0.001, 0.5)) = 0.03
        _AmbientBoost       ("環境光の底上げ (Ambient Boost)", Range(0, 1)) = 0.35
        _LightInfluence     ("シーン光の反映度 (Light Influence)", Range(0, 1)) = 0.35

        [Header(Rim Light)]
        _RimColor           ("リムライト色 (Rim Color)", Color)            = (0.8, 0.9, 1.0, 1)
        _RimPower           ("リム幅 / 鋭さ (Rim Power)", Range(0.5, 16))   = 4.0
        _RimStrength        ("リム強さ (Rim Strength)", Range(0, 4))        = 0.3
        _RimFloor           ("リムの下限/全体発光 (Rim Floor)", Range(0, 1)) = 0.05


        [Header(Layer Stack)]
        _LayerCount         ("レイヤー枚数 (Layer Count)", Range(1, 8))     = 3
        _LayerAngleStep     ("レイヤー角度ステップ (Angle Step deg)", Range(-45, 45)) = 8
        _LayerPosStepX      ("レイヤー位置ステップ X 円周 (Pos Step X)", Float) = 0.02
        _LayerPosStepY      ("レイヤー位置ステップ Y 軸 (Pos Step Y)", Float) = 0.0
        _LayerThicknessFalloff ("奥レイヤーの減衰 (Thickness Falloff)", Range(0, 1)) = 0.0

        // ---- 粘液の質感（蜘蛛糸・蜘蛛の巣と同じ塗り） ----
        // 粘液感を下げると太り・玉・膜・ツヤ・透けが一緒に弱まる（0 で乾いた細い糸）
        [Header(Goo Shape)]
        _GooAmount    ("粘液感 0で乾いた糸 (Goo Amount)", Range(0, 1))       = 1
        _GooThick     ("粘液の太さ倍率 (Goo Thickness)", Range(0.5, 4))      = 1.6
        _GooBeads     ("糊の玉の大きさ (Glue Beads)", Range(0, 1))           = 0.15
        _GooBeadFreq  ("糊の玉の細かさ 糸方向UV毎 (Bead Freq)", Float)        = 14
        _GooFlat      ("帯の平たさ (Ribbon Flatness)", Range(0, 0.95))      = 0.45
        _GooFiberMix  ("帯の中の筋の濃さ (Fiber Lines)", Range(0, 1))         = 0.5
        _GooFiberLines("帯1本あたりの筋の本数 (Lines Per Ribbon)", Range(1, 8)) = 4
        _GooOverlapShadow ("重なりの影 (Overlap Shadow)", Range(0, 1))       = 0.6
        _GooWebFill   ("隣の糸との間の膜 (Membrane Fill)", Range(0, 1))       = 0.5
        _GooWebScale  ("膜のまだらの細かさ UV毎 (Membrane Noise)", Float)     = 6

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

        [Header(Projection Fit)]
        _RadiusFit          ("円筒半径 (box内接=0.5)", Range(0.05, 0.5))   = 0.5
        _HeightFit          ("円筒高さ (box一杯=0.5)", Range(0.05, 0.5))   = 0.5
        _ProjectRange       ("投影の許容距離 (Project Range m)", Range(0, 0.5)) = 0.1

        [Header(Glue Thickness)]
        _GlueThickness      ("糸の厚み m 輪郭の外への膨張 (Glue Thickness)", Range(0, 0.2)) = 0.06

        // 体に沿って巻く（ミイラのよう）か、体の一番太い所に合わせた太さのそろった繭にするか（2026-10-25）。
        // 0 = 今までどおり体に沿う。1 = 一番太い所の太さの筒（両端は丸い）で体全体を包む。間は筒が少しずつ太る。
        // 筒の位置と太さは、繭プロジェクターの駆動スクリプト（Cocoon Renderer にこの箱を入れたとき）が骨から毎フレーム渡す
        // （_EvenGirthA / _EvenGirthB）。繭プロジェクターと組むのに渡されていないときは筒を描かない。
        // 繭プロジェクターと組まないときは、この箱の円柱（円筒半径・円筒高さ）を、箱からはみ出さない太さに収めて筒にする
        [Header(Even Girth)]
        _EvenGirth          ("太さをそろえる 0=体に沿う 1=均一な繭 (Even Girth)", Range(0, 1)) = 0
        _EvenGirthMargin    ("そろえた繭の太さの足し引き m (Even Girth Margin)", Range(-0.1, 0.2)) = 0.02
        [HideInInspector] _EvenGirthA ("Even Girth Bottom xyz (script)", Vector) = (0, 0, 0, 0)
        [HideInInspector] _EvenGirthB ("Even Girth Top xyz w=Radius (script)", Vector) = (0, 0, 0, 0)

        // 巻きの端で帯が細って途切れる「ほつれ」の幅（近くの繭とのまとめ描きは
        // CocoonGroupLinker が MaterialPropertyBlock で指示する）
        // 全身繭では Udon が骨から作った部位（最大 16）と、繭同士の接続部位を作る組
        // （_GroupBridgePairs / _GroupBridgeCount）を MaterialPropertyBlock で渡し、
        // 脇や股の凹みをまたいで外形に沿う外殻にする（組が無ければ代表からの放射）
        // プロパティ名の Bridge は繭同士の接続部位のこと。名前は作成済みのマテリアルと、値を渡す Udon
        // （CocoonGroupLinker やワールドのスクリプト）が参照しているので変えない
        [Header(Group Volume)]
        _GroupBulge ("まとめ描きの膨らみ m (Group Bulge)", Range(0, 0.12)) = 0.045
        _GroupBridgeSpan ("繭同士の接続部位を作る距離 m (Group Connection Span)", Range(0, 0.5)) = 0.1
        _GroupRadiusScale ("まとめ繭の半径フィット (Group Radius Fit)", Range(0.25, 1)) = 0.75
        _GroupAxisFollow ("部位の軸に沿う強さ (Axis Follow)", Range(0, 1)) = 0.8
        _GroupAxisBlend ("軸をつなぐ滑らかさ m (Axis Blend)", Range(0.025, 0.4)) = 0.12
        _GroupShellBlend ("部位間の一体感 (Group Shell Blend)", Range(0, 4)) = 0.8
        _GroupMarchSteps ("外殻レイマーチの最大歩数 (Shell March Steps)", Range(32, 160)) = 80
        // 遠い外殻の最大歩数。カメラから箱の中心までが Far Start m までは上の歩数、Far End m 以上はこの歩数で、
        // 間はなめらかに減らす（上の歩数以上にすると減らさない）。遠い外殻は輪郭の外周が 1 画素細る程度
        _GroupMarchStepsFar ("遠くの外殻の最大歩数 (Shell Far March Steps)", Range(32, 160)) = 60
        _GroupMarchFarStart ("歩数を減らし始める距離 m (Shell Far Start)", Float) = 2.5
        _GroupMarchFarEnd   ("遠くの歩数になる距離 m (Shell Far End)", Float) = 5
        // 不透明な物の向こうに完全に隠れた外殻（2x2 の画素単位）を、深度テクスチャで見てレイマーチの前に捨てる（既定 ON）。
        // 深度テクスチャには入るのに深度バッファでは前を隠さない物（キュー 2500 以下で ShadowCaster を持つ ZWrite Off の物、
        // alpha to coverage のカットアウトなど）や、MSAA で 1 画素より細い隙間の向こうでは、見えるはずの外殻が欠けることがある。
        // そういう場面では OFF にする（従来どおり全部レイマーチする）
        [ToggleUI] _GroupDepthCut ("隠れた外殻を quad 単位で捨てる (Shell Depth Cut)", Float) = 1
        // 形を絞った接続部位（_GroupBridgePairs[k].w > 0 の組。全身繭の前腕↔胴など）の
        // 半分の高さ = 短いほうの部位の半分の高さ × この値。w = 0 の組と木の繭には効かない
        _GroupBridgeHeightScale ("絞った繭同士の接続部位の高さ倍率 (Connection Height Scale)", Range(0, 1.5)) = 1

        [Header(Edge Fray)]
        _GooEdgeFray        ("巻きの端のほつれ幅 m (Edge Fray)", Range(0, 0.2)) = 0.03

        // 糸が 1 本ずつ巻かれて繭になっていくアニメーション（CGINC/SpiderCocoon_Goo.cginc）。
        // 通常は Udon（BossSpiderController）が MaterialPropertyBlock で進み具合を渡す。
        // マテリアルで ON にすると進み具合スライダーで見た目を確認できる（OFF で完成した繭）
        [Header(Winding Animation)]
        [ToggleUI] _WindEnable ("巻きアニメ有効 (Winding Animation)", Float) = 0
        _WindProgress ("巻きの進み具合 (Winding Progress)", Range(0, 1)) = 1

        // 体表 glue（Pass 2/3）と全身の殻の表面の模様（CGINC/SpiderCocoon_Sheet.cginc）。
        //   シェーダーキーワード SC_SURFACE_NET（1 のとき ON）で切り替える。キーワードはインスペクタ
        //   （SpiderCocoonShaderGUI）がこの値と自動で揃える。スクリプトで値を変えるときはキーワードも一緒に変えること
        //   （material.EnableKeyword("SC_SURFACE_NET") / DisableKeyword）。キーワードが無ければ 0（繭の帯）として描く。
        //   0 = 従来の繭の帯（斜めに交差して巻いた粘液の帯）
        //   1 = 蜘蛛の巣ドレープ（mecaota/SpiderWebDrape）風: 粘液の束が平行に並び、間の膜に穴が空く。
        //       長さの単位は m（ネットのメッシュ UV 1 = 1 m と同じ数字でよい）。巻きアニメは高さで現れる簡易版。
        //       束・膜の設定は蜘蛛糸（SpiderSilk の粘液モード）・ネットと同じ名前・意味。
        //       玉の 2 つだけは繭の _GooBeads と名前がぶつかるので _SheetBeads / _SheetBeadFreq。
        [Header(Surface Style)]
        [Enum(Cocoon Bands,0,Sticky Net,1)] _SurfaceStyle ("表面の模様 0=繭の帯 1=蜘蛛の巣ドレープ (Surface Style)", Float) = 0
        _SheetBandWidth     ("粘液の帯の幅 m (Band Width)", Range(0.02, 0.5)) = 0.12
        _SheetRotation      ("帯の向き 角度 0=体の周りを水平 (Band Rotation)", Range(0, 180)) = 10
        _SheetAlongScale    ("帯に沿った模様の細かさ (Along Scale)", Range(0.1, 10)) = 3
        _SheetSeed          ("模様のシード (Sheet Seed)", Float) = 0
        [IntRange] _SheetLayers ("重ねる膜の枚数 (Layers)", Range(1, 3)) = 2
        _SheetLayerTwist    ("層ごとの回転 角度 (Layer Twist)", Range(0, 180)) = 8
        _SheetLayerShift    ("2枚目以降の模様のずれ m (Pattern Shift)", Range(0, 0.3)) = 0.08
        _SheetLayerOpacity  ("層ごとの不透明度倍率 (Layer Opacity)", Range(0.3, 1)) = 0.95
        [IntRange] _GooStrands ("束の本数 (Strands)", Range(1, 4))           = 3
        _GooWidth           ("束の太さ 帯幅比 (Strand Width)", Range(0.02, 1)) = 0.24
        _GooSpread          ("束の並ぶ幅 (Spread)", Range(0, 1))             = 0.6
        _GooWobble          ("蛇行の振れ幅 (Wobble)", Range(0, 0.5))          = 0.16
        _GooWobbleFreq      ("蛇行の細かさ uv.x毎 (Wobble Freq)", Float)      = 0.7
        _SheetBeads         ("くびれと玉 (Beads)", Range(0, 1))              = 0.55
        _SheetBeadFreq      ("玉の細かさ uv.x毎 (Bead Freq)", Float)          = 2.2
        _GooMerge           ("融合の粘り (Merge)", Range(0, 1))              = 0.35
        _GooWeb             ("束の間の膜の量 (Web Amount)", Range(0, 1))      = 0.6
        _GooWebCell         ("穴の間隔 uv.x単位 (Hole Spacing)", Float)       = 0.3
        _GooWebRows         ("幅方向の穴の列数 (Hole Rows)", Range(1, 8))     = 2.5
        _GooWebHole         ("穴の開き具合 (Hole Size)", Range(0, 1))         = 0.85

        // 輪の中に入り込んだ別の部位（腕の内側・隣の腿など）を巻かない。巻いている骨の
        // 軸から見て、体表の向き（法線）が外向きの度合いがこの値未満の面を除く。-1 で無効
        [Header(Facing Cull)]
        _WrapFacing         ("他の部位を除く面の向き -1で無効 (Facing Cull)", Range(-1, 1)) = -1

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
        // 捕まった本人の視界を「実際の繭の内側」にする（2026-10-25）。駆動スクリプトが本人の頭の位置（_JackHead）を
        // 渡したときだけ使う。渡されていなければ従来の紡錘形の内壁（上の 2 つ）。
        // 頭の周りの内壁: 目を中心にした球。体の繭と同じ模様で、下（体を見下ろす向き）は開けて体に張り付いた繭を見せる。
        // 太さをそろえる（_EvenGirth）が 0 より大きいときは、内壁をその筒の内側の面にする（外から見える繭と同じ形）
        _JackHoodRadius     ("頭の周りの内壁の半径 m (Jack Hood Radius)", Range(0.08, 0.5)) = 0.15
        _JackHoodOpen       ("頭の周りの内壁の下の開き 度 真下から (Jack Hood Opening)", Range(0, 150)) = 55
        [HideInInspector] _JackHead ("Jack Head xyz w=Gate Radius (script)", Vector) = (0, 0, 0, 0)

        [Header(Render State)]
        // ジャック壁の目印に使うステンシルビット。他のステンシル利用シェーダー
        // （アバター等）と衝突する場合にワールド側で付け替えられるようにする。
        // 本体とデカールの両マテリアルで同じ値に揃えること。
        [IntRange] _StencilRef ("ステンシル ビット (Stencil Bit)", Range(0, 255)) = 128
        // 体表の glue（Pass 2/3）を描く画素のステンシル条件: (stencil & ReadMask) == Ref。
        //   既定 Ref 0 / ReadMask 208 = ジャックのビット(_StencilRef 128)、蜘蛛糸の芯のビット
        //   （SpiderSilk の _SilkStencilBit 64）、蜘蛛の体のビット 16 のどれも立っていない画素に描く。
        //   糸は繭より先に描かれ、芯にビット 64 を立てる。蜘蛛の体（Chaise の皮膚・spider.mat 系の体）は
        //   見えている画素にビット 16 を立てる。どちらも ZTest Always の glue が手前の糸・蜘蛛の脚を上塗りしないための目印。
        //   （2026-10-14: 192 → 208。以前は手前の蜘蛛の脚に奥の被害者ののりが塗られていた）
        //   Projector マスク（CocoonProjector）と組むギミックは Ref 32 / ReadMask 240
        //   = 受け手ビット 32 が立ち、かつ 128 / 64 / 16 が立っていない画素だけに描く（床・壁へ漏れない）。
        //   どれかのビットを付け替えたら本体・デカール・糸・マスク・蜘蛛の体のマテリアルで揃えること。
        [IntRange] _GlueStencilRef      ("glue を描く画素のステンシル値 0=従来 32=繭プロジェクター (Glue Stencil Ref)", Range(0, 255)) = 0
        [IntRange] _GlueStencilReadMask ("glue のステンシル比較ビット 208=ジャック+糸+蜘蛛の体 240=+受け手 (Glue Stencil ReadMask)", Range(0, 255)) = 208

        // エディタ専用: 質感の継承元（蜘蛛糸マテリアル）の目印。描画には使わない（HLSL では宣言しない）。
        // xyz = 継承元 .mat の GUID 先頭 18 桁（24bit ずつ）、w = 状態（0=継承元なし→蜘蛛糸シェーダーの既定値 / 2=リンクあり）。
        // 値は Editor/SpiderSilkLook.cs が読み書きする。手で触らないこと。
        [HideInInspector] _SilkLookLink ("Silk Look Link (editor only)", Vector) = (0, 0, 0, 0)
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
        #include "CGINC/SpiderGoo_Shading.cginc"
        // 表面の模様「蜘蛛の巣ドレープ」（_SurfaceStyle）を使えるようにする。Goo の後に Sheet を読む
        #define SC_COCOON_SHEET_STYLE
        #include "CGINC/SpiderCocoon_Goo.cginc"
        #include "CGINC/SpiderCocoon_Sheet.cginc"
        #include "CGINC/SpiderCocoon_VisionJack.cginc"

        UNITY_DECLARE_SCREENSPACE_TEXTURE(_CameraDepthTexture);

        // ※ _JackRadius / _JackStretch は共通化に伴い Common.cginc 側で宣言
        float _RadiusFit;
        float _HeightFit;
        float _ProjectRange;
        float _GlueThickness;
        // 捕まった本人の視界（実際の繭の内側）。_JackHead は駆動スクリプトが渡す（xyz = 本人の頭、w = 発火の半径 m）
        float  _JackHoodRadius;
        float  _JackHoodOpen;
        float4 _JackHead;

        // 近接した繭を 1 つの繭として描く（CocoonGroupLinker が MPB で指示する）
        #include "CGINC/SpiderCocoon_Group.cginc"

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
            // 戻り値は最後の 1 か所で返す（途中で return すると、VR のステレオ用バリアントで
            // FXC が「未初期化の変数を使うかもしれない」と警告するため。計算の中身は同じ）
            float3 viewPos;
            if (unity_OrthoParams.w > 0.5)
            {
                float x = (ndc.x - UNITY_MATRIX_P._m03) / UNITY_MATRIX_P._m00;
                float y = (ndc.y - UNITY_MATRIX_P._m13) / UNITY_MATRIX_P._m11;
                float z = (ndcZ - UNITY_MATRIX_P._m20 * x - UNITY_MATRIX_P._m21 * y
                           - UNITY_MATRIX_P._m23) / UNITY_MATRIX_P._m22;
                viewPos = float3(x, y, z);
            }
            else
            {
                float K = UNITY_MATRIX_P._m20 * (ndc.x + UNITY_MATRIX_P._m02) / UNITY_MATRIX_P._m00
                        + UNITY_MATRIX_P._m21 * (ndc.y + UNITY_MATRIX_P._m12) / UNITY_MATRIX_P._m11
                        - UNITY_MATRIX_P._m22;
                float denom = ndcZ - K;
                denom = (abs(denom) < 1e-8) ? 1e-8 : denom;
                float w = UNITY_MATRIX_P._m23 / denom;
                viewPos = float3(w * (ndc.x + UNITY_MATRIX_P._m02) / UNITY_MATRIX_P._m00,
                                 w * (ndc.y + UNITY_MATRIX_P._m12) / UNITY_MATRIX_P._m11,
                                 -w);
            }
            return viewPos;
        }

        // 隣接画素の深度を「厳密復元」して表面の世界法線を求め、水平面かを判定する。
        // ・GPU の自動微分(ddx/ddy)は使わない（浅い角度で外積の向きが暴れて過去2回
        //   失敗した原因）。明示的に±2pxの4点をサンプルし、3点から法線を構成する。
        // ・シルエット境界の深度段差は「深度差が小さい側」を選んで回避（古典的な
        //   頑健法線復元）。両側とも段差なら輪郭画素とみなし水平面ではない扱い。
        // 高さゾーンに依存しないため、床の高さを厳密に合わせられない場合
        // （アバター搭載・段差・ジャンプ中など）でも床・天井を識別できる。
        bool SC_SurfaceNormalW(float2 uv, float rawDepth0, float stepW, out float3 nW)
        {
            nW = float3(0.0, 1.0, 0.0);
            float3 p0 = SC_ViewPosAt(uv, rawDepth0);
            float  z0 = -p0.z;

            // サンプル間隔は「世界で約 _GroundDetectScale (m)」を基準にする。
            // 画素数固定だと近距離で対応する実寸が縮み、体表の微細な起伏
            // （肩・胸・服のしわ等の局所的な上向き面）まで床と誤判定して、
            // 近づくほど糸が消える。世界基準なら距離に依らず同じスケールで
            // 面の向きを評価できる。遠距離では最低2pxを確保。
            float2 px;
            px.x = 0.5 * abs(UNITY_MATRIX_P._m00) * stepW / max(z0, 0.05);
            px.y = 0.5 * abs(UNITY_MATRIX_P._m11) * stepW / max(z0, 0.05);
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
            float maxStep = 0.10 + 0.05 * z0 + stepW * 2.0; // 距離とサンプル間隔に応じた許容段差
            if (min(dzR, dzL) > maxStep) return false;
            if (min(dzU, dzD) > maxStep) return false;

            // view 空間の法線 → 世界空間へ（V の回転部の転置＝逆変換）
            float3 nV = cross(dX, dY);
            // 画面端のクランプ等で隣接点が中心と一致し法線が構成できない画素は、
            // 「水平面ではない」扱い（＝糸を描く従来既定）にフォールバックする。
            // ここで (0,1,0) に正規化してしまうと床と誤判定し、画面端に
            // 糸の消える帯が出る（VRでは左右で帯の位置が違い、チラつく）。
            if (dot(nV, nV) < 1e-14) return false;
            nW = mul(nV, (float3x3)UNITY_MATRIX_V);
            nW = normalize(nW + float3(0.0, 1e-6, 0.0));
            return true;
        }

        // 床・天井か（法線が作れない輪郭・画面端は「水平面ではない」扱い）
        bool SC_IsHorizontalSurface(float2 uv, float rawDepth0)
        {
            float3 nW;
            if (!SC_SurfaceNormalW(uv, rawDepth0, _GroundDetectScale, nW)) return false;
            return abs(nW.y) > _GroundNormalY;
        }

        // 体表の向きで「輪の中に入り込んだ別の部位」を除く（_WrapFacing。-1 で無効）
        bool SC_WrapFacingOK(float2 uv, float rawDepth, float3 worldPos)
        {
            if (_WrapFacing <= -0.999) return true;
            float3 nW;
            // 細い手首でも向きが取れるよう、床判定より細かい間隔（約 1cm）で復元する。
            // 向きが取れない輪郭の画素は残す（除くと縁が欠ける）
            if (!SC_SurfaceNormalW(uv, rawDepth, 0.01, nW)) return true;
            if (dot(nW, _WorldSpaceCameraPos - worldPos) < 0.0) nW = -nW;   // 見えている面はカメラを向く
            return SCG_FacingOK(worldPos, nW);
        }

        // 視界ジャック（包まれ演出）の発火判定。vert/frag で同一のこの関数を使い、
        // 判定を一致させる。実体は共通実装（SpiderCocoon_VisionJack.cginc）で、
        // 中央カメラ位置により左右の目で必ず同じ結果になる。
        // ※ SC_CylRadialNormal / SC_ShadeCocoonAt は
        //    SpiderCocoon_Goo.cginc にある（繭と共通）。
        // 駆動スクリプトが本人の頭の位置を渡しているとき（_JackHead.w が 0 でない）は、箱の円柱ではなく
        // 「カメラが本人の頭の近く（w m 以内）にあるか」で決める。捕まった本人の目だけが入るので、
        // 覗き込んだ他の人の視界はジャックされない（w < 0 は「この画面では出さない」）
        bool SC_DecalJackActive()
        {
            if (abs(_JackHead.w) > 1e-5)
            {
                if (_JackHead.w < 0.0 || _VisionJackEnable < 0.5) return false;
                if (SC_IsInMirror() && _VisionJackInMirror < 0.5) return false;
                return distance(SC_MonoCameraPos(), _JackHead.xyz) < _JackHead.w;
            }
            return SC_VisionJackActiveEx(_RadiusFit, _HeightFit);
        }

        // ---------------------------------------------------------------------
        // 早い棄却のための交差判定（Pass 2。2026-10-14 軽量化）
        // 視線上の点 o + d * z（z = 視線深度。o, d は箱のローカル座標）のうち、z <= zMax の部分
        // （カメラの後ろも含む半直線）が、円柱・箱と交わるかを返す。
        // 糸を描ける点は必ずこの範囲にある（Pass 2 の「早い棄却」の説明）ので、交わらない画素は
        // 床判定（深度 4 タップ）や糸の厚みのループ（深度 24 タップ）の前に捨ててよい。
        // 判定は「描くかもしれない」側に倒す（範囲を SC_EARLY_MARGIN だけ広げる）。
        // 浮動小数の誤差で、元は描いていた縁の画素を捨てないため。
        // ---------------------------------------------------------------------
        #define SC_EARLY_MARGIN 0.001   // ローカル座標での余裕（箱が 1 m 前後なら約 1 mm）

        // 半直線と、軸が Y の円柱（xz 半径 R、高さ ±Hh）
        bool SC_RayHitsCylinder(float3 o, float3 d, float zMax, float R, float Hh)
        {
            float zLo = -1e9, zHi = zMax * 1.001 + 0.01;   // 表面の深度にも少し余裕を持たせる
            // 高さ（Y の板）
            if (abs(d.y) > 1e-7)
            {
                float t1 = (-Hh - o.y) / d.y, t2 = (Hh - o.y) / d.y;
                zLo = max(zLo, min(t1, t2)); zHi = min(zHi, max(t1, t2));
            }
            else if (abs(o.y) > Hh) return false;
            // 円（xz）: 視線の xz 成分が円の中心に一番近づく位置 tc を先に求め、そこからの距離で解く。
            // 二次方程式をそのまま解くと、カメラが遠いときに桁落ちで判定がぶれるため。
            float a = dot(d.xz, d.xz);
            if (a > 1e-12)
            {
                float  tc = -dot(o.xz, d.xz) / a;
                float2 q  = o.xz + d.xz * tc;               // 視線が円の中心に一番近づく点
                float  h2 = R * R - dot(q, q);
                if (h2 < 0.0) return false;                 // 円に届かない
                float  hw = sqrt(h2 / a);
                zLo = max(zLo, tc - hw); zHi = min(zHi, tc + hw);
            }
            else if (dot(o.xz, o.xz) > R * R) return false;
            return zLo <= zHi;
        }

        // 半直線と、原点中心の箱（半サイズ hb）
        bool SC_RayHitsBox(float3 o, float3 d, float zMax, float3 hb)
        {
            float zLo = -1e9, zHi = zMax * 1.001 + 0.01;
            [unroll]
            for (int a = 0; a < 3; ++a)
            {
                if (abs(d[a]) > 1e-7)
                {
                    float t1 = (-hb[a] - o[a]) / d[a], t2 = (hb[a] - o[a]) / d[a];
                    zLo = max(zLo, min(t1, t2)); zHi = min(zHi, max(t1, t2));
                }
                else if (abs(o[a]) > hb[a]) return false;
            }
            return zLo <= zHi;
        }

        // 糸の厚みのループ（Pass 2）の 8 方向。sincos を毎回計算せず定数で持つ
        static const float2 SC_GLUE_DIRS[8] =
        {
            float2( 1.0,         0.0        ), float2( 0.70710678,  0.70710678),
            float2( 0.0,         1.0        ), float2(-0.70710678,  0.70710678),
            float2(-1.0,         0.0        ), float2(-0.70710678, -0.70710678),
            float2( 0.0,        -1.0        ), float2( 0.70710678, -0.70710678)
        };

        #include "CGINC/SpiderCocoon_GroupShell.cginc"

        // ---------------------------------------------------------------------
        // ★ 太さをそろえる（_EvenGirth、2026-10-25）
        // 体に沿って巻いた繭（ミイラのような見た目）を、体の一番太い所に合わせた「太さのそろった筒」
        // （両端は丸い＝カプセル）へ近づける。筒と体の繭を重ね、画素ごとに手前にある方を描く。
        // 筒の半径 = _EvenGirth ×（一番太い所の半径 + 足し引き + 糸の厚み）なので、
        //   0   … 筒が無い（今までどおり）
        //   途中 … 細い所（首・脚の間・足首）から先に筒で埋まり、太い所はまだ体の形が見える
        //   1   … 体の繭がすべて筒の中に入り、太さのそろった繭になる
        // 筒は深度テクスチャを使わずに式で交点を求めるので、体の輪郭の外（脚の間の背景など）にも描ける。
        // 見えている面の深さと比べて、筒より手前に物（柱・他の人）がある画素には描かない。
        // 帯の模様は角度と高さで決まる（SC_ShadeCocoonAtEx）ので、体の繭と筒の境目でも帯が続く。
        // 筒の位置と太さは駆動スクリプト（SpiderCocoonProjectorMaskDriver）が骨から渡す。繭プロジェクターと組まないときは
        // この箱の円柱。筒は箱の外へは描かないので、箱は筒が入る大きさにする（はみ出した所は箱の面でほつれて切れる）。
        // まとめ描き（CocoonGroupLinker）の繭では使わない。
        // ---------------------------------------------------------------------
        float  _EvenGirth;
        float  _EvenGirthMargin;
        float4 _EvenGirthA;       // xyz = 筒の下端（ワールド）
        float4 _EvenGirthB;       // xyz = 筒の上端、w = 体の一番太い所の半径 m（0 以下 = 渡されていない）
        float  _GlueStencilRef;   // 繭プロジェクターと組んでいるか（0 でない）を頂点で見る（パス 6）

        // 筒（カプセル）の軸の両端 a・b と半径 r。使わないときは false
        bool SC_GirthCapsule(out float3 a, out float3 b, out float r)
        {
            a = float3(0.0, 0.0, 0.0);
            b = a;
            r = 0.0;
            if (_EvenGirth <= 0.001 || SCG_Lead() || SCG_Hidden()) return false;
            float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
            float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
            float3 colZ = float3(unity_ObjectToWorld._m02, unity_ObjectToWorld._m12, unity_ObjectToWorld._m22);
            float3 lo, hi;
            float  R;
            bool   fromBones = _EvenGirthB.w > 0.0;
            if (fromBones)
            {
                lo = _EvenGirthA.xyz;
                hi = _EvenGirthB.xyz;
                R  = _EvenGirthB.w;
            }
            else
            {
                // 繭プロジェクターと組むときは、駆動スクリプトの値が無い（誰も捕まっていない・骨が取れない・
                // Cocoon Renderer が空）なら筒を描かない（目印の無い画素の Pass 6 が、箱の大きさの筒を宙に描かないように）
                if (_GlueStencilRef >= 0.5) return false;
                // 繭プロジェクターと組まないとき: この箱の円柱（円筒半径・円筒高さ）
                float3 c = float3(unity_ObjectToWorld._m03, unity_ObjectToWorld._m13, unity_ObjectToWorld._m23);
                lo = c - colY * _HeightFit;
                hi = c + colY * _HeightFit;
                R  = _RadiusFit * 0.5 * (length(colX) + length(colZ));
            }
            float k = saturate(_EvenGirth);
            float T = max(_GlueThickness, 0.0);
            r = k * (max(R + _EvenGirthMargin, 0.0) + T);
            // 両端も体の繭（厚み T）を包むよう k·T だけのばし、丸い端がそこで終わるよう軸を半径ぶん縮める
            float3 ab = hi - lo;
            float  L  = length(ab);
            float3 u  = (L > 1e-5) ? ab / L : normalize(colY);
            lo -= u * (k * T);
            hi += u * (k * T);
            L  += 2.0 * k * T;
            if (!fromBones)
            {
                // 箱の円柱から作った筒は、箱の半幅・半分の高さから、ほつれ幅ぶん内側に収める
                // （そのままだと 1 に近づけたとき筒が箱からはみ出し、箱で切れて消えてしまう）
                float fray  = max(_GooEdgeFray, 0.0);
                float halfL = clamp(0.5 * L, 0.0, max(0.5 * length(colY) - fray, 0.0));
                float3 mid  = 0.5 * (lo + hi);
                r  = min(r, 0.5 * min(length(colX), length(colZ)) - fray);
                lo = mid - u * halfL;
                hi = mid + u * halfL;
                L  = 2.0 * halfL;
            }
            float inset = min(r, 0.5 * L);
            a = lo + u * inset;
            b = hi - u * inset;
            return r > 1e-4;
        }

        // 視線と球の手前の交点までの距離（rd は正規化）。当たらない・始点が中なら負
        float SC_RaySphereNear(float3 ro, float3 rd, float3 c, float r)
        {
            float3 oc = ro - c;
            float  b  = dot(oc, rd);
            float  h  = b * b - (dot(oc, oc) - r * r);
            return (h > 0.0) ? -b - sqrt(h) : -1.0;
        }

        // 視線とカプセルの手前の交点までの距離（rd は正規化）。当たらない・始点が中なら負。
        // カプセル = 筒の側面と両端の球。外から入る点は、それぞれに入る点のうち一番手前（筒の平らな端は球の中なので見なくてよい）
        float SC_RayCapsuleNear(float3 ro, float3 rd, float3 pa, float3 pb, float r)
        {
            float  t    = 1e9;
            float3 ba   = pb - pa;
            float  baba = dot(ba, ba);
            if (baba > 1e-8)
            {
                float3 oa   = ro - pa;
                float  bard = dot(ba, rd);
                float  baoa = dot(ba, oa);
                float  qa   = baba - bard * bard;   // 視線が軸と平行に近いと 0 になる（そのときは端の球だけで決まる）
                float  qb   = baba * dot(rd, oa) - baoa * bard;
                float  qc   = baba * dot(oa, oa) - baoa * baoa - r * r * baba;
                float  h    = qb * qb - qa * qc;
                if (qa > 1e-6 * baba && h >= 0.0)
                {
                    float ts = (-qb - sqrt(h)) / qa;
                    float y  = baoa + ts * bard;    // 軸に沿った位置（0〜baba が筒の側面）
                    if (ts > 0.0 && y > 0.0 && y < baba) t = ts;
                }
            }
            float t0 = SC_RaySphereNear(ro, rd, pa, r);
            float t1 = SC_RaySphereNear(ro, rd, pb, r);
            if (t0 > 0.0) t = min(t, t0);
            if (t1 > 0.0) t = min(t, t1);
            return (t < 1e8) ? t : -1.0;
        }

        // 点 p から線分 a〜b までの距離
        float SC_SegmentDist(float3 p, float3 a, float3 b)
        {
            float3 ba = b - a;
            float3 pa = p - a;
            float  h  = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
            return length(pa - ba * h);
        }

        // この画素の視線と筒の手前の交点の、視線方向の深さ m（無ければ 1e6）。
        // rayPerZ = 視線方向の深さ 1 m あたりのワールドの進み（Pass 2 / 3 と同じもの）。
        // カメラが筒の中（捕まった本人・抱きついている人）なら描かない（中から見た繭は視界ジャックの役目）。
        // 中かどうかは左右の目で食い違わないよう、両目の中点で決める
        float SC_GirthDepth(float3 rayPerZ, float3 a, float3 b, float r)
        {
            if (SC_SegmentDist(SC_MonoCameraPos(), a, b) < r) return 1e6;
            float len = max(length(rayPerZ), 1e-6);
            float t   = SC_RayCapsuleNear(_WorldSpaceCameraPos, rayPerZ / len, a, b, r);
            if (t <= 0.0) return 1e6;
            // 箱の外へは描かない（ほかの描き方と同じ約束。筒が箱からはみ出すと、そこは切れて見える）
            float3 p = _WorldSpaceCameraPos + rayPerZ * (t / len);
            if (any(abs(mul(unity_WorldToObject, float4(p, 1.0)).xyz) > 0.5)) return 1e6;
            return t / len;
        }

        // 筒（軸 a〜b）の上の点 p を、体の繭と同じ巻き座標・同じ帯で塗る。透明（α ≒ 0）でも捨てない
        // （筒の隙間・ほつれた所では、呼ぶ側が奥の体の繭を描けるように）。
        // 陰影の向きは筒の面の向き（軸の線分の一番近い点から外向き）なので、丸い両端も丸く見える。
        // ほつれは箱の面の近くだけ（筒が箱からはみ出して切れる所を、硬い切り口でなく糸のほつれにする）
        fixed4 SC_GirthColor(float3 p, float3 a, float3 b, float3 colX, float3 colY, float3 colZ)
        {
            float3 lp     = mul(unity_WorldToObject, float4(p, 1.0)).xyz;
            float3 q      = (abs(lp) - 0.5) * float3(length(colX), length(colY), length(colZ));   // 箱の面までの距離 m（負 = 内側）
            float  edge01 = SCG_Edge01(max(q.x, max(q.y, q.z)));
            float3 ba     = b - a;
            float  h      = saturate(dot(p - a, ba) / max(dot(ba, ba), 1e-8));
            float3 n      = p - (a + ba * h);
            float3 N      = (dot(n, n) > 1e-10) ? normalize(n) : normalize(colY);
            return SC_ShadeCocoonAtExUnclipped(lp, p, N, colX, colY, edge01);
        }

        // 筒の奥に描くものが無いとき用: 透明なら捨てる
        fixed4 SC_ShadeGirthAt(float3 p, float3 a, float3 b, float3 colX, float3 colY, float3 colZ)
        {
            fixed4 c = SC_GirthColor(p, a, b, colX, colY, colZ);
            if (c.a <= 0.001) discard;
            return c;
        }

        // ---------------------------------------------------------------------
        // ★ 捕まった本人の視界を「実際の繭の内側」にする（2026-10-25）
        // 繭プロジェクターの繭は体の表面に貼るので、本人が自分の体を見下ろすと、ほかの人に見えているのと同じ
        // 体に張り付いた繭（Pass 2）が見える。ただし VRChat は本人の頭を消すので、顔の前には繭が出ない。
        // そこで駆動スクリプトが本人の頭の位置（_JackHead）を渡したときは、視界ジャックの壁を次の形にする:
        //   - 太さをそろえる（_EvenGirth）が効いていて、目がその筒の中にある: 筒の内側の面（外から見える繭と同じ形）
        //   - それ以外: 目を中心にした半径 _JackHoodRadius の球（頭の周りの内壁）。体を見下ろす向き
        //     （真下から _JackHoodOpen 度まで）は開けて、体に張り付いた繭が見えるようにする
        // 模様は体の繭と同じ箱の巻き座標で塗るので、体の繭の続きに見える。帯は体に固定（頭を回しても糸は回らない）。
        // 球の中心は両目の中点なので、左右の目は同じ壁を見る（立体視が合う）。
        // 渡されていないとき（_JackHead.w = 0）は従来の紡錘形（箱の円柱から決まる楕円体）。
        // ---------------------------------------------------------------------
        #define SC_JACK_HOOD_FADE_DEG 15.0   // 下の開きの縁をぼかす幅（度）

        // 内側の点 ro から、カプセル（線分 pa〜pb、半径 r）の外へ出る点までの距離（rd は正規化）。出ないときは負
        float SC_RayCapsuleFar(float3 ro, float3 rd, float3 pa, float3 pb, float r)
        {
            float3 ba   = pb - pa;
            float3 oa   = ro - pa;
            float  baba = dot(ba, ba);
            float  bard = dot(ba, rd);
            float  baoa = dot(ba, oa);
            float  qa   = baba - bard * bard;   // 視線が軸と平行に近いと 0 になる（そのときは進む向きの端の球から出る）
            float  qb   = baba * dot(rd, oa) - baoa * bard;
            float  qc   = baba * dot(oa, oa) - baoa * baoa - r * r * baba;
            float  h    = qb * qb - qa * qc;
            bool   top  = bard > 0.0;
            if (qa > 1e-6 * baba && h >= 0.0)
            {
                float ts = (-qb + sqrt(h)) / qa;    // 無限に長い筒から出る点
                float y  = baoa + ts * bard;        // その点の軸に沿った位置（0〜baba なら筒の側面から出る）
                if (y > 0.0 && y < baba) return ts;
                top = y >= baba;                    // 側面の外なら、そちら側の端の球から出る
            }
            float3 oc = top ? (ro - pb) : oa;
            float  b  = dot(rd, oc);
            float  hs = b * b - (dot(oc, oc) - r * r);
            return (hs > 0.0) ? -b + sqrt(hs) : -1.0;
        }

        // 視界ジャックの壁の当たり。worldDir はカメラ→画素のワールドレイ（頂点から補間）。
        // outDepth = 壁の深度（Zバッファ値）、lp / wp = 壁の点（箱のローカル / ワールド）、nOut = 塗りに使う外向きの法線、
        // fade = 頭の周りの内壁の下の開きの縁で薄める倍率（0..1。ほかの形は 1）
        void SC_DecalJackWall(float3 worldDir, out float outDepth, out float3 lp, out float3 wp,
                              out float3 nOut, out float fade)
        {
            // 早い return を使わず、out の値は先に全部決めておく（D3D の「初期化していないかもしれない変数」の警告を出さないため）
            fade     = 1.0;
            outDepth = UNITY_NEAR_CLIP_VALUE;
            lp       = float3(0.0, 0.0, 0.0);
            wp       = _WorldSpaceCameraPos;
            nOut     = float3(0.0, 1.0, 0.0);
            if (abs(_JackHead.w) <= 1e-5)
            {
                float3 nIn;
                SC_VisionJackWallHit(worldDir, _RadiusFit * _JackRadius, _HeightFit * _JackStretch, outDepth, lp, wp, nIn);
                nOut = -nIn;
            }
            else
            {
                float3 rd  = normalize(worldDir);
                float3 eye = SC_MonoCameraPos();
                float3 ga, gb;
                float  gr;
                float  t = -1.0;
                bool   tube = SC_GirthCapsule(ga, gb, gr) && SC_SegmentDist(eye, ga, gb) < gr;
                if (tube) t = SC_RayCapsuleFar(_WorldSpaceCameraPos, rd, ga, gb, gr);
                if (t > 0.0)
                {
                    // 太さをそろえた筒の内側の面。法線は軸から外向き
                    wp = _WorldSpaceCameraPos + rd * t;
                    float3 ba = gb - ga;
                    float  hh = saturate(dot(wp - ga, ba) / max(dot(ba, ba), 1e-8));
                    float3 n  = wp - (ga + ba * hh);
                    nOut = dot(n, n) > 1e-12 ? normalize(n) : -rd;
                }
                else
                {
                    // 頭の周りの内壁: 目（両目の中点）を中心にした球の奥側の面。目は球の中なので必ず当たる
                    float  R  = max(_JackHoodRadius, 0.02);
                    float3 oc = _WorldSpaceCameraPos - eye;
                    float  b  = dot(rd, oc);
                    t  = -b + sqrt(max(b * b - (dot(oc, oc) - R * R), 0.0));
                    wp = _WorldSpaceCameraPos + rd * t;
                    nOut = normalize(wp - eye);
                    // 体を見下ろす向き（体の軸の真下から _JackHoodOpen 度まで）は開ける。縁はぼかす
                    float3 up      = normalize(float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21));
                    float  fromDown = degrees(acos(clamp(-dot(nOut, up), -1.0, 1.0)));
                    fade = smoothstep(_JackHoodOpen, _JackHoodOpen + SC_JACK_HOOD_FADE_DEG, fromDown);
                }
                lp = mul(unity_WorldToObject, float4(wp, 1.0)).xyz;
                // 深度は SC_VisionJackWallHit と同じ変換（カメラの真横〜後ろは最前面）
                float4 clipPos = UnityWorldToClipPos(wp);
                if (clipPos.w <= 1e-4)
                {
                    outDepth = UNITY_NEAR_CLIP_VALUE;
                }
                else
                {
                    float zBuf = clipPos.z / clipPos.w;
                #if !defined(UNITY_REVERSED_Z)
                    zBuf = zBuf * 0.5 + 0.5;
                #endif
                    outDepth = saturate(zBuf);
                }
            }
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
            bool jack = SC_DecalJackActive();
            if (jack) vtx.xyz *= 100.0;
            // グループの代表は「まとめた繭」を包む大きさまで箱を広げる
            else if (SCG_Lead()) vtx.xyz *= SCG_BoxHalf() * 2.0;

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
            // 代表に描画を任せた繭は、ジャック以外では頂点を縮退させて何も描かない
            if (!jack && SCG_Hidden()) o.pos = float4(0.0, 0.0, 0.0, 0.0);
            return o;
        }

        // Pass 0/1（ジャック専用）用の頂点シェーダー。
        // 非ジャック時は頂点を縮退させ、フラグメントを一切発生させない。
        // （Pass 0 は深度、Pass 1 はステンシルを書くため、フラグメント側の discard に
        //   頼らず頂点段階で完全に無効化し、通常時の描画へ影響ゼロを保証する。
        //   これにより視界ジャック以外はレンダーキューを完全に遵守する。）
        v2f_d vertJack(appdata_d v)
        {
            v2f_d o = vert(v);
            if (!SC_DecalJackActive()) o.pos = float4(0.0, 0.0, 0.0, 0.0);
            return o;
        }
        // Pass 2（通常カメラの glue）用の頂点シェーダー。
        // 鏡の中・グループの代表（外殻あり、ジャック以外）・代表に任せた繭は、カメラとマテリアルだけで
        // 決まる（画素ごとに変わらない）ので、フラグメントで discard する代わりに頂点で三角形を潰す。
        // フラグメントが 1 つも出ないので、画面の結果は discard と同じで、処理だけが減る（2026-10-14）。
        v2f_d vertGlue(appdata_d v)
        {
            v2f_d o = vert(v);
            if (SC_IsInMirror() || SCG_Hidden() || (SCG_Lead() && _GroupBulge > 0.0005 && !SC_DecalJackActive()))
                o.pos = float4(0.0, 0.0, 0.0, 0.0);
            return o;
        }
        // Pass 3（鏡専用の glue）用。鏡の外・鏡の中のジャック・外殻ありの代表・代表に任せた繭は頂点で潰す
        v2f_d vertGlueMirror(appdata_d v)
        {
            v2f_d o = vert(v);
            if (!SC_IsInMirror() || SC_DecalJackActive() || SCG_Hidden() || (SCG_Lead() && _GroupBulge > 0.0005))
                o.pos = float4(0.0, 0.0, 0.0, 0.0);
            return o;
        }
        // Only grouped shells rasterize this additional pass.
        v2f_d vertGroupShell(appdata_d v)
        {
            v2f_d o = vert(v);
            if (!SCG_Lead() || _GroupBulge <= 0.0005 || SC_DecalJackActive())
                o.pos = float4(0, 0, 0, 0);
            return o;
        }
        // Pass 6（太さをそろえた繭のうち、繭プロジェクターの目印が無い画素）用。
        // 太さをそろえない・繭プロジェクターと組んでいない（目印を見ない。Pass 2 / 3 が全部の画素で筒も描く）・
        // まとめ描きの繭は、頂点で三角形を潰す
        v2f_d vertGirth(appdata_d v)
        {
            v2f_d o = vert(v);
            if (_EvenGirth <= 0.001 || _GlueStencilRef < 0.5 || SCG_Lead() || SCG_Hidden())
                o.pos = float4(0.0, 0.0, 0.0, 0.0);
            return o;
        }
        ENDCG

        // ================= Pass 0/1: 視界ジャック＝包まれ演出（共通実装） =================
        // ジャック中のみ描画。カメラを囲む繭の内壁（紡錘形楕円体）を「実寸の深度
        // 付き」で描く（実体は SpiderCocoon_VisionJack.cginc / 本体シェーダーと共通）。
        //   半径 = _RadiusFit × _JackRadius（実円筒より小さくできる）
        //   半高 = _HeightFit × _JackStretch（閉じるまでの縦距離）
        // ZTest LEqual ＋ 実深度の比較により、壁より手前にあるもの
        // （自分のアバターの体・同じ繭の中の他プレイヤー）は遮られず見える。
        // 壁より奥の世界は糸に覆われ、隙間からだけ覗ける＝「包まれている」見え方。
        // 深度は濃い芯（不透明度 0.9 以上）だけが書く。半透明の膜や帯は深度を書かず、
        // その奥の蜘蛛の巣や糸を隠さない。色パスも実深度で比較し、手前のものを守る。
        // 色パスが引き続きステンシル bit128 を立て、後続の glue（Pass 2/3、ZTest Always で Z を
        // 無視する）が壁の糸を上塗りしないようにする。壁より手前で glue 対象の
        // 体表には Pass 2 が引き続き糸を描く（体も巻かれたまま包まれる）。
        // Pass 0: 色とステンシルは書かず、芯の深度だけを先に記録する。
        Pass
        {
            Name "VISIONJACKDEPTH"
            // ForwardBase タグ: メインライト・環境光を確実にバインドする
            // （無いと直前の描画の残り値でライティングされ、描画順で見た目が揺れる）
            Tags { "LightMode" = "ForwardBase" }

            ColorMask 0
            ZWrite On
            ZTest  LEqual
            Cull   Front

            CGPROGRAM
            #pragma vertex   vertJack
            #pragma fragment fragJackDepth
            #pragma target   3.5
            #pragma multi_compile_instancing
            #pragma shader_feature_local SC_SURFACE_NET   // 表面の模様（_SurfaceStyle = 1 で蜘蛛の巣ドレープ。インスペクタが揃える）

            fixed4 fragJackDepth(v2f_d i, out float outDepth : SV_Depth) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                outDepth = UNITY_NEAR_CLIP_VALUE;   // 仮値（discard 経路では書き込まれない）

                if (!SC_DecalJackActive()) discard;

                // 芯（不透明度 0.9 以上）の画素だけ深度を書く。色と光は計算しない（深度だけのパス）。
                // 不透明度の式と 0.9 の境目は色パス（Pass 1）と同じなので、書く範囲は従来と同じ。
                // 壁の形は SC_DecalJackWall（従来の紡錘形 / 頭の周りの内壁 / 太さをそろえた筒の内側）。
                // 頭の周りの内壁の下の開きの縁（fade < 1）は、色パスと同じく不透明度に fade を掛けて比べる
                float3 lp, wp, nOut;
                float  fade;
                SC_DecalJackWall(i.worldDir, outDepth, lp, wp, nOut, fade);
                if (fade < SC_JACK_DEPTH_SOLID_ALPHA) discard;   // 掛けても 0.9 に届かない（開きの中と縁）
                float need = SC_JACK_DEPTH_SOLID_ALPHA / fade;
                if (SC_CocoonAlphaAt(lp, wp, nOut, need) < need) discard;
                return 0;
            }
            ENDCG
        }

        // Pass 1: 内壁の色とステンシルを書く。芯と同じ深度も LEqual で通る。
        Pass
        {
            Name "VISIONJACK"
            // ForwardBase タグ: メインライト・環境光を確実にバインドする
            // （無いと直前の描画の残り値でライティングされ、描画順で見た目が揺れる）
            Tags { "LightMode" = "ForwardBase" }

            ZWrite Off
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
            #pragma shader_feature_local SC_SURFACE_NET   // 表面の模様（_SurfaceStyle = 1 で蜘蛛の巣ドレープ。インスペクタが揃える）

            fixed4 fragJack(v2f_d i, out float outDepth : SV_Depth) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                outDepth = UNITY_NEAR_CLIP_VALUE;   // 仮値（discard 経路では書き込まれない）

                if (!SC_DecalJackActive()) discard;

                // 壁の形は深度パスと同じ SC_DecalJackWall。塗りは従来の SC_ShadeCocoonAt と同じ（箱の巻き座標・ほつれ無し）
                float3 lp, wp, nOut;
                float  fade;
                SC_DecalJackWall(i.worldDir, outDepth, lp, wp, nOut, fade);
                if (fade <= 0.001) discard;  // 下の開きの中は塗りを計算しない（体を見下ろす向きは軽くなる）
                float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
                float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
                fixed4 c = SC_ShadeCocoonAtExUnclipped(lp, wp, nOut, colX, colY, 1.0);
                c.a *= fade;
                if (c.a <= 0.001) discard;   // 糸の隙間・下の開き（色・深度・ステンシルとも書かない）
                return c;
            }
            ENDCG
        }

        // ================= Pass 2: 通常カメラ（glue＋糸の厚み） =================
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
            // 同じシェーダーの別インスタンスが後から描かれても上書きできない）。
            // 先に描かれた蜘蛛糸の芯（bit64）の画素にも描かない: ZTest Always なので、
            // そのままだと体の手前を通る糸の上に glue を塗り、糸が繭の下へ潜って見える。
            // （体の奥の糸は体の深度に負けて描かれず、ビットも立たないので glue は塗られる）
            // 蜘蛛の体（bit16。Chaise の皮膚・spider.mat 系の体）が見えている画素にも描かない（同じ理由で、
            // 被害者の手前にある蜘蛛の脚に奥の被害者ののりを塗らない）。
            // Ref / ReadMask はマテリアル設定（_GlueStencilRef / _GlueStencilReadMask）。既定 0 / 208、
            // Projector マスク併用時は 32 / 240（受け手ビット 32 が立つ画素だけに描く）。
            Stencil
            {
                Ref      [_GlueStencilRef]
                ReadMask [_GlueStencilReadMask]
                Comp     Equal
            }

            CGPROGRAM
            #pragma vertex   vertGlue
            #pragma fragment fragMain
            #pragma target   3.5
            #pragma multi_compile_instancing
            #pragma shader_feature_local SC_SURFACE_NET   // 表面の模様（_SurfaceStyle = 1 で蜘蛛の巣ドレープ。インスペクタが揃える）

            fixed4 fragMain(v2f_d i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);                       // unity_ObjectToWorld を per-instance に
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                float2 screenUV = i.screenPos.xy / max(i.screenPos.w, 1e-5);

                // ==== 通常: 深度→体表 glue。輪郭は糸の厚みぶん外へ膨張 ====
                // （視界ジャックは Pass 0/1 が担当）
                // ミラー（Pass 3 が担当）・外殻ありのグループの代表（GROUP_SHELL が担当）・
                // 代表に任せた繭は、頂点シェーダー vertGlue で三角形を潰すので、ここへは来ない。

                float3 camFwd = -UNITY_MATRIX_V[2].xyz;

                float2 duv = SC_DEPTH_UV(screenUV);
                float rawDepth = UNITY_SAMPLE_SCREENSPACE_TEXTURE(_CameraDepthTexture, duv).r;
                bool hasDepth;
                #if defined(UNITY_REVERSED_Z)
                    hasDepth = (rawDepth > 1e-7);
                #else
                    hasDepth = (rawDepth < 1.0 - 1e-7);
                #endif

                float  viewZ   = dot(i.worldDir, camFwd);
                float3 rayPerZ = i.worldDir / max(viewZ, 1e-5);

                // 太さをそろえた繭（筒）の手前の面の深さ（筒を使わない・当たらないときは 1e6）
                float3 girA, girB;
                float  girR;
                float  zGirth = 1e6;
                [branch] if (SC_GirthCapsule(girA, girB, girR)) zGirth = SC_GirthDepth(rayPerZ, girA, girB, girR);
                if (!hasDepth && zGirth > 1e5) discard;   // 投影先の表面も筒も無い（空）なら描かない

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

                // 空（深度が無い）の画素は筒だけ
                if (!hasDepth) return SC_ShadeGirthAt(_WorldSpaceCameraPos + rayPerZ * zGirth, girA, girB, colX, colY, colZ);

                float  eyeZ    = LinearEyeDepth(rawDepth);
                float3 worldPos = _WorldSpaceCameraPos + rayPerZ * eyeZ;
                float3 localPos = mul(unity_WorldToObject, float4(worldPos, 1.0)).xyz;
                // 筒が見えている面より手前にあるか（奥なら、筒は手前の物に隠れている）
                bool   girthFront = zGirth < eyeZ;

                // グループの代表（CocoonGroupLinker）は、自分の円筒の代わりに
                // 「くっついた仲間それぞれの円筒の和」の中を巻く
                // （代表に任せた繭 SCG_Hidden は頂点 vertGlue で潰してある）
                bool   grouped = SCG_Lead();
                float3 boxHalf = SCG_BoxHalf();
                float  T       = _GlueThickness;

                // ==== 早い棄却（円柱の内外判定を、重い床判定と糸の厚みのループより先に）====
                // この画素に糸を描けるのは、次のどちらかのときだけ:
                //   (A) 糸の面（下の zShell。見えている表面そのもの、その T 手前、または近傍の輪郭から
                //       作った点）が、円柱（単独。厚み T ぶん広げたもの）または箱（代表）の中にある。
                //       糸の面はどれも「この画素の視線上で、見えている表面より手前」にある。
                //   (B) 見えている表面が箱の中の床・天井で、床テクスチャを貼る。
                // 視線の「表面より手前の部分」が円柱（箱）と交わらず、表面も箱の外なら、どちらも起きない。
                // その画素は床判定（深度 4 タップ）と糸の厚みのループ（深度 24 タップ）の前に捨てる。
                // 壁の向こうの繭・地下の繭・箱の角（円柱の外）の画素がここで終わる。
                float3 rayO = mul(unity_WorldToObject, float4(_WorldSpaceCameraPos, 1.0)).xyz;
                float3 rayD = mul((float3x3)unity_WorldToObject, rayPerZ);   // 視線深度 1 m あたりのローカルの進み
                bool reach;
                if (grouped)
                {
                    reach = SC_RayHitsBox(rayO, rayD, eyeZ, boxHalf + SC_EARLY_MARGIN);
                }
                else
                {
                    // 厚みがあるときは、糸の面が円柱から厚みぶんはみ出せる（下の shellIn と同じ広げ方）
                    float rCyl = (T < 0.0005) ? limR : min(limR + T / max(sxz, 1e-4), 0.5);
                    float hCyl = (T < 0.0005) ? limH : min(limH + T / max(sy, 1e-4), 0.5);
                    reach = SC_RayHitsCylinder(rayO, rayD, eyeZ, rCyl + SC_EARLY_MARGIN, hCyl + SC_EARLY_MARGIN);
                }
                if (!reach && any(abs(localPos) > 0.5))
                {
                    // 体の繭は描けない。筒だけは視線が円柱を外れても描けることがある
                    if (!girthFront) discard;
                    return SC_ShadeGirthAt(_WorldSpaceCameraPos + rayPerZ * zGirth, girA, girB, colX, colY, colZ);
                }

                // 床・天井の判定: 面の向き（厳密復元した法線が水平面か）で行う。
                // 高さ不問なので、アバター搭載・段差・ジャンプ中でも床を識別できる。
                // 使うのは「表面が箱の中」のときだけ（glue の円柱・床テクスチャはどちらも箱の中）なので、
                // 箱の外の表面では深度 4 タップを読まない。
                bool isFlat = false;
                [branch] if (all(abs(localPos) <= boxHalf))
                    isFlat = SC_IsHorizontalSurface(screenUV, rawDepth);

                // 床・天井ゾーンは糸を glue しない（後段でテクスチャ表示へ）
                bool onGlue = !isFlat && (grouped
                    ? (all(abs(localPos) <= boxHalf) && SCG_GroupSD(worldPos) <= _ProjectRange)
                    : ((abs(localPos.y) <= limH) && (length(localPos.xz) <= limR)));
                // 輪の中に入り込んだ別の部位の面は巻かない（_WrapFacing）
                if (onGlue) onGlue = SC_WrapFacingOK(screenUV, rawDepth, worldPos);

                bool shellHit = false;
                float zHit = eyeZ;   // 体の繭を描く面の深さ（筒と比べる）

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

                    // 視線が円柱（箱）に届かない画素では、近傍から作る糸の面も必ず外になる（上の早い棄却の説明）。
                    // そのときはループ（深度 24 タップ）を丸ごと省く
                    [branch] if (reach)
                    {
                    [loop]
                    for (int ri = 1; ri <= 3; ++ri)
                    {
                        float d    = T * (float)ri / 3.0;                   // 横方向の距離（世界）
                        float lift = sqrt(max(T * T - d * d, 0.0));         // その距離での持ち上げ量
                        float rr   = 0.5 * UNITY_MATRIX_P._m11 * d / zBox;  // 画面 UV での半径

                        // 8 方向は定数表（SC_GLUE_DIRS）。ループを展開して sincos を省く
                        [unroll]
                        for (int di = 0; di < 8; ++di)
                        {
                            float cA = SC_GLUE_DIRS[di].x, sA = SC_GLUE_DIRS[di].y;
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
                            if (grouped)
                            {
                                // 仲間の円筒の中の表面も「盛る対象」＝輪郭がつながって太る
                                if (SCG_GroupSD(pq) > _ProjectRange) continue;
                            }
                            else
                            {
                                float3 lq = mul(unity_WorldToObject, float4(pq, 1.0)).xyz;
                                if (abs(lq.y) > limH) continue;
                                if (length(lq.xz) > limR) continue;
                            }

                            zShell = min(zShell, zN - lift);
                        }
                    }
                    }

                    if (zShell < 1e5 && zShell < eyeZ)
                    {
                        float3 p  = _WorldSpaceCameraPos + rayPerZ * zShell;
                        float3 lp = mul(unity_WorldToObject, float4(p, 1.0)).xyz;
                        // シェルは厚みぶんだけ円筒からはみ出せる（ただし box の外は不可）
                        float exR = T / max(sxz, 1e-4);
                        float exH = T / max(sy, 1e-4);
                        bool shellIn = grouped
                            ? (all(abs(lp) <= boxHalf) && SCG_GroupSD(p) <= _ProjectRange + T)
                            : (abs(lp.y) <= min(limH + exH, 0.5) && length(lp.xz) <= min(limR + exR, 0.5));
                        if (shellIn)
                        {
                            localPos = lp;
                            worldPos = p;
                            shellHit = true;
                            zHit     = zShell;
                        }
                    }
                }

                // 筒が体の繭より手前なら筒を描く（筒の中に入った体の繭は隠れ、筒から出た所だけ体の繭が見える）。
                // 床・天井のテクスチャより手前の筒も筒が勝つ。筒が透明な所（隙間・ほつれ）は、奥の体の繭や床を描く
                if (girthFront && (!shellHit || zGirth < zHit))
                {
                    fixed4 gc = SC_GirthColor(_WorldSpaceCameraPos + rayPerZ * zGirth, girA, girB, colX, colY, colZ);
                    if (gc.a > 0.001) return gc;
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

                // 巻きの境界（単独は自分の円筒、代表は仲間の円筒の和）でほつれさせる。
                // 帯はグループ共通の巻き座標なので、繭をまたいで同じ向きに走る
                float sdm    = grouped ? SCG_GroupSD(worldPos)
                             : max((length(localPos.xz) - limR) * sxz, (abs(localPos.y) - limH) * sy);
                float edge01 = SCG_Edge01(sdm - _ProjectRange * (grouped ? 1.0 : 0.0) - T);
                float3 wrapLocal = SCG_WrapLocal(localPos);   // 代表はグループ共通の軸で巻く
                float3 shadeN = SC_CylRadialNormal(wrapLocal);
                if (grouped) SCG_AxisWrap(worldPos, wrapLocal, colX, colY);
                return SC_ShadeCocoonAtEx(wrapLocal, worldPos, shadeN, colX, colY, edge01);
            }
            ENDCG
        }

        // ================= Pass 3: ミラー専用（体表 glue・ハードウェアZで正しく遮蔽） =================
        Pass
        {
            // ForwardBase タグ: Pass 2 と同じくメインライト・環境光のバインドに必要
            Tags { "LightMode" = "ForwardBase" }

            ZWrite Off
            ZTest  LEqual
            Cull   Back
            Blend  SrcAlpha OneMinusSrcAlpha
            // ジャック（bit128）と手前の蜘蛛糸の芯（bit64）の画素には描かない（Pass 2 と同じ Ref / ReadMask 設定）
            Stencil
            {
                Ref      [_GlueStencilRef]
                ReadMask [_GlueStencilReadMask]
                Comp     Equal
            }

            CGPROGRAM
            #pragma vertex   vertGlueMirror
            #pragma fragment fragMirror
            #pragma target   3.5
            #pragma multi_compile_instancing
            #pragma shader_feature_local SC_SURFACE_NET   // 表面の模様（_SurfaceStyle = 1 で蜘蛛の巣ドレープ。インスペクタが揃える）

            fixed4 fragMirror(v2f_d i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // このパスはミラー内でのみ描く。鏡の外・ミラー内ジャック・外殻ありの代表・
                // 代表に任せた繭は、頂点シェーダー vertGlueMirror で三角形を潰すので、ここへは来ない。
                // ミラー内ジャック時は重ねない。
                // 既知の制限: _VisionJackInMirror=1 でミラー内ジャックが発火して
                // いる間、鏡の中では壁の隙間から見える体表の glue が描かれない
                // （直視では Pass 2 が体表に糸を描き続けるが、このパスは全体を
                //   discard するため）。挙動を直視と完全一致させるには oblique
                //   深度復元での glue 描画をこの分岐に実装する必要がある。
                //   既定値（_VisionJackInMirror=0）では発生しない。

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

                float3 camFwd  = -UNITY_MATRIX_V[2].xyz;
                float  viewZ   = dot(i.worldDir, camFwd);
                float3 rayPerZ = i.worldDir / max(viewZ, 1e-5);

                // 太さをそろえた繭（筒）。Pass 2 と同じ
                float3 girA, girB;
                float  girR;
                float  zGirth = 1e6;
                [branch] if (SC_GirthCapsule(girA, girB, girR)) zGirth = SC_GirthDepth(rayPerZ, girA, girB, girR);
                if (!hasDepth && zGirth > 1e5) discard;   // 投影先の表面も筒も無ければ描かない

                // 円筒＋許容距離の中の表面のみ glue（床・天井ゾーンは除外）
                float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
                float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
                float3 colZ = float3(unity_ObjectToWorld._m02, unity_ObjectToWorld._m12, unity_ObjectToWorld._m22);
                float sxz     = 0.5 * (length(colX) + length(colZ));
                float sy      = length(colY);
                float marginR = _ProjectRange / max(sxz, 1e-4);
                float marginH = _ProjectRange / max(sy, 1e-4);
                // Pass 2 と同じく box の外へは出さない（対象外オブジェクト保護）
                float limR = min(_RadiusFit + marginR, 0.5);
                float limH = min(_HeightFit + marginH, 0.5);

                // 筒が見えている面より手前なら筒を描く（鏡の中の体の繭には厚みが無いので、見えている面と比べるだけでよい）
                // 筒が透明な所（隙間・ほつれ）は、奥の体の繭を描く
                float  eyeZ = hasDepth ? SC_EyeDepthOblique(screenUV, rawDepth) : 1e6;
                if (zGirth < eyeZ)
                {
                    fixed4 gc = SC_GirthColor(_WorldSpaceCameraPos + rayPerZ * zGirth, girA, girB, colX, colY, colZ);
                    if (gc.a > 0.001) return gc;
                    if (!hasDepth) discard;
                }

                float3 wp = _WorldSpaceCameraPos + rayPerZ * eyeZ;
                float3 gl = mul(unity_WorldToObject, float4(wp, 1.0)).xyz;

                // 円柱（代表は仲間の円筒の和）の外は描かない。床判定（深度 4 タップ）より安いので先に調べる
                // （どれも discard するだけの条件なので、順番を入れ替えても結果は同じ）
                float sdmM;
                if (SCG_Lead())
                {
                    // Pass 2 と同じ「仲間の円筒の和」の中だけを巻く
                    if (any(abs(gl) > SCG_BoxHalf())) discard;
                    sdmM = SCG_GroupSD(wp);
                    if (sdmM > _ProjectRange) discard;
                    sdmM -= _ProjectRange;
                }
                else
                {
                    if (abs(gl.y) > limH) discard;
                    if (length(gl.xz) > limR) discard;
                    sdmM = max((length(gl.xz) - limR) * sxz, (abs(gl.y) - limH) * sy);
                }
                if (SC_IsHorizontalSurface(screenUV, rawDepth)) discard;   // 床・天井は描かない
                if (!SC_WrapFacingOK(screenUV, rawDepth, wp)) discard;   // 入り込んだ別の部位は巻かない
                float edge01M = SCG_Edge01(sdmM);
                float3 wrapLocalM = SCG_WrapLocal(gl);
                float3 shadeNM = SC_CylRadialNormal(wrapLocalM);
                if (SCG_Lead()) SCG_AxisWrap(wp, wrapLocalM, colX, colY);
                return SC_ShadeCocoonAtEx(wrapLocalM, wp, shadeNM, colX, colY, edge01M);
            }
            ENDCG
        }

        // Group volume: a world-space axis-derived shell, including empty-background
        // silhouette pixels. Actual displaced depth handles walls and mirrors.
        // 視界ジャック（Pass 0/1）と同じく、深度パスと色パスに分ける。
        //   GROUP_SHELL_DEPTH: 色は塗らず、濃い所（不透明度 SCG_SHELL_DEPTH_ALPHA 以上）だけ深度を書く
        //   GROUP_SHELL      : 深度は書かずに塗る。薄い所は奥の巣や糸を隠さない
        // ※ 外殻の形を探す計算（レイマーチ）を両パスで 1 回ずつ行うので、そのぶん重くなる。
        Pass
        {
            Name "GROUP_SHELL_DEPTH"
            Tags { "LightMode" = "ForwardBase" }
            ColorMask 0
            ZWrite On
            ZTest LEqual
            Cull Front
            // ステンシルは色パスと同じ（ジャックの画素だけ避ける）
            Stencil { Ref [_StencilRef] ReadMask [_StencilRef] Comp NotEqual }
            CGPROGRAM
            #pragma vertex vertGroupShell
            #pragma fragment fragGroupShellDepth
            #pragma target 3.5
            #pragma multi_compile_instancing
            #pragma shader_feature_local SC_SURFACE_NET   // 色パスと同じ模様で不透明度を求める（インスペクタが揃える）
            fixed4 fragGroupShellDepth(v2f_d i, out float depth : SV_Depth) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                // i.pos.xy = SV_Position（画素の中心）。隠れた quad を捨てる判定（SCG_QuadHidden）に使う
                fixed4 col = SCG_ShadeGroupShell(i.screenPos.xy / max(i.screenPos.w, 1e-5), i.worldDir, i.pos.xy, depth);
                clip(col.a - SCG_SHELL_DEPTH_ALPHA);
                return 0;
            }
            ENDCG
        }

        Pass
        {
            Name "GROUP_SHELL"
            Tags { "LightMode" = "ForwardBase" }
            // 深度は GROUP_SHELL_DEPTH が濃い所だけ書いた。同じ深度を出すので LEqual で通る
            ZWrite Off
            ZTest LEqual
            Cull Front
            Blend SrcAlpha OneMinusSrcAlpha
            // ジャックの画素だけ避ける。糸の芯（bit64）は避けない: 外殻は実深度で ZTest するので
            // 手前の糸には負け、奥の糸（先に描画済み）には半透明で重なって透かす
            Stencil { Ref [_StencilRef] ReadMask [_StencilRef] Comp NotEqual }
            CGPROGRAM
            #pragma vertex vertGroupShell
            #pragma fragment fragGroupShell
            #pragma target 3.5
            #pragma multi_compile_instancing
            #pragma shader_feature_local SC_SURFACE_NET   // 表面の模様（_SurfaceStyle = 1 で蜘蛛の巣ドレープ。インスペクタが揃える）
            fixed4 fragGroupShell(v2f_d i, out float depth : SV_Depth) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                // i.pos.xy = SV_Position（画素の中心）。隠れた quad を捨てる判定（SCG_QuadHidden）に使う
                return SCG_ShadeGroupShell(i.screenPos.xy / max(i.screenPos.w, 1e-5), i.worldDir, i.pos.xy, depth);
            }
            ENDCG
        }

        // ================= Pass 6: 太さをそろえた繭（筒）の、繭プロジェクターの目印が無い画素 =================
        // 繭プロジェクターと組む（_GlueStencilRef 32）と、Pass 2 / 3 は目印（ビット 32）のある画素にしか描けない。
        // 筒は体の輪郭の外（脚の間・首の横の背景など）にも広がるので、目印の無い画素の筒はこのパスで描く。
        // 筒は式で求めた形を、見えている面の深さと比べて手前の所だけ描くので、目印が無くても床・壁・他の人へ糸がにじまない。
        // ステンシル: (stencil & _GlueStencilReadMask) == 0 = 目印 32 も、ジャック 128・糸の芯 64・蜘蛛の体 16 も無い画素。
        //   目印のある画素は Pass 2 / 3 が「体の繭と筒の手前の方」を描くので、画素をちょうど分け合う。
        // 通常の視点もミラーも、このパス 1 つで描く（深さはミラーの斜めの近クリップ面でも正しい SC_EyeDepthOblique で戻す）。
        // 繭プロジェクターと組まない（_GlueStencilRef 0）ときは、Pass 2 / 3 が全部の画素で筒も描くので、頂点で潰す（vertGirth）。
        Pass
        {
            Name "EVEN_GIRTH"
            Tags { "LightMode" = "ForwardBase" }
            ZWrite Off
            ZTest  Always
            Cull   Front
            Blend  SrcAlpha OneMinusSrcAlpha
            Stencil
            {
                Ref      0
                ReadMask [_GlueStencilReadMask]
                Comp     Equal
            }
            CGPROGRAM
            #pragma vertex   vertGirth
            #pragma fragment fragGirth
            #pragma target   3.5
            #pragma multi_compile_instancing
            #pragma shader_feature_local SC_SURFACE_NET   // 表面の模様（_SurfaceStyle = 1 で蜘蛛の巣ドレープ。インスペクタが揃える）
            fixed4 fragGirth(v2f_d i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                float3 girA, girB;
                float  girR;
                if (!SC_GirthCapsule(girA, girB, girR)) discard;
                float3 camFwd  = -UNITY_MATRIX_V[2].xyz;
                float3 rayPerZ = i.worldDir / max(dot(i.worldDir, camFwd), 1e-5);
                float  zGirth  = SC_GirthDepth(rayPerZ, girA, girB, girR);
                if (zGirth > 1e5) discard;

                // 筒より手前に物（柱・他の人・床）が見えていれば描かない
                float2 screenUV = i.screenPos.xy / max(i.screenPos.w, 1e-5);
                float  rawDepth = UNITY_SAMPLE_SCREENSPACE_TEXTURE(_CameraDepthTexture, SC_DEPTH_UV(screenUV)).r;
                #if defined(UNITY_REVERSED_Z)
                    bool hasDepth = (rawDepth > 1e-7);
                #else
                    bool hasDepth = (rawDepth < 1.0 - 1e-7);
                #endif
                if (hasDepth && SC_EyeDepthOblique(screenUV, rawDepth) <= zGirth) discard;

                float3 colX = float3(unity_ObjectToWorld._m00, unity_ObjectToWorld._m10, unity_ObjectToWorld._m20);
                float3 colY = float3(unity_ObjectToWorld._m01, unity_ObjectToWorld._m11, unity_ObjectToWorld._m21);
                float3 colZ = float3(unity_ObjectToWorld._m02, unity_ObjectToWorld._m12, unity_ObjectToWorld._m22);
                return SC_ShadeGirthAt(_WorldSpaceCameraPos + rayPerZ * zGirth, girA, girB, colX, colY, colZ);
            }
            ENDCG
        }
    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}
