// =============================================================================
// SpiderSilk.shader — 蜘蛛糸シェーダー（トレイルパーティクル用）
//
//  - Trail Renderer / Particle System の Trails モジュールで使う前提の
//    リボン（帯）用シェーダー。帯の長さ方向に数本の糸が走る。
//  - 乾いた糸モードの糸（太さの乱雑性・うねり・トゥーン陰影・リムライト・レイヤー重ね）は
//    CGINC/SpiderCocoon_Compose.cginc の SC_CompositeLayers で描く。いまこれを使うのは蜘蛛糸だけで、
//    繭は粘液の帯（SpiderCocoon_Goo.cginc）で描く。ノイズ・糸の位相・リムライトなどの
//    部品（SpiderCocoon_Common / Noise / Thread / Lighting）は繭・巣と共通。
//  - 色・ツヤなどの質感 21 項目は、巣・繭などの「継承元」としてここで決める（SpiderSilk_Look.cginc）。
//  - 揺れアニメ: 糸のパターンを帯の幅方向へ sin 波でずらし、蜘蛛糸が
//    左右にたなびいているように見せる（ジオメトリは動かさないので
//    トレイルの軌跡そのものは崩れない）。
//  - Gravity Sag > 0 は頂点をワールド下方向へたわませる。両端は固定。
//    Particle streams: Position, Color, UV, StableRandomXYZW。Color.b に経路比率。
//    経路上の位置が分からないマテリアル（_GravityUseUV と _GravityTrailColor が両方 0）ではたわませない。
//
//  UV の前提（Unity のトレイルが生成する標準の UV）:
//    uv.x = 軌跡に沿った方向（Texture Mode: Stretch なら 0..1、Tile なら連続増加）
//    uv.y = 帯の幅方向 0..1
//  糸の位相 t = uv.x*cx + uv.y*cy なので、cy=_WindingCount が「幅方向に並ぶ
//  糸の本数」、cx=tan(_FiberAngle) が「軌跡に対する糸の傾き」になる。
//  頂点カラー（Color over Lifetime / Trail の Color）を最後に乗算するので、
//  尻尾に向かって糸がフェードアウトする表現はパーティクル側で設定できる。
//
//  粘液モード（_GooEnable / キーワード _GOO_ON）:
//    細い繊維を並べる代わりに、帯の中へ数本の太い「粘液の束」を距離場で描く
//    （丸い断面のトゥーン陰影・白いハイライトの筋・輪郭線・束同士の融合と
//    糸引き・くびれた玉）。実装は CGINC/SpiderThread_Goo.cginc。
//    頂点アルファは「尻尾ほど細く伸びる」量にも使う（_GooTailThin）。
//    トレイルの Texture Mode は Tile 推奨（uv.x がメートル単位になり、
//    玉や蛇行の間隔がトレイルの長さに関係なく一定になる）。
// =============================================================================
Shader "mecaota/SpiderSilk"
{
    Properties
    {
        // ※ 質感（Look）21 個（_Goo の色・陰影・光沢・粘液感 / トゥーン / リム）は 5 シェーダー
        //   （蜘蛛糸・蜘蛛の巣・繭・繭デカール・蜘蛛の巣ドレープ）で
        //   名前・型・範囲・既定値を完全一致させる（一覧: Editor/SpiderSilkLook.cs、宣言: CGINC/SpiderSilk_Look.cginc）。
        //   巣・繭・繭デカール・蜘蛛の巣ドレープではこの値を「継承元の蜘蛛糸マテリアル」から受け継ぐ。
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
        _ToonSteps          ("トゥーン段階数 (Toon Steps)", Range(1, 8))    = 1
        _ToonSmooth         ("段差の柔らかさ (Toon Smooth)", Range(0.001, 0.5)) = 0.03
        _ShadowColor        ("影色 (Shadow Tint)", Color)                  = (0.55, 0.55, 0.62, 1)
        _AmbientBoost       ("環境光の底上げ (Ambient Boost)", Range(0, 1)) = 0.35
        _LightInfluence     ("シーン光の反映度 (Light Influence)", Range(0, 1)) = 0.35

        [Header(Rim Light)]
        _RimColor           ("リムライト色 (Rim Color)", Color)            = (0.8, 0.9, 1.0, 1)
        _RimPower           ("リム幅 / 鋭さ (Rim Power)", Range(0.5, 16))   = 4.0
        _RimStrength        ("リム強さ (Rim Strength)", Range(0, 4))        = 0.3
        _RimFloor           ("リムの下限/全体発光 (Rim Floor)", Range(0, 1)) = 0.05

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
        [Header(Gravity Sag)]
        _GravitySag ("重力のたわみ m (Gravity Sag)", Range(0, 1)) = 0
        _GravityOscillation ("たゆみの弾み (Elastic Motion)", Range(0, 1)) = 0.6
        _GravitySpeed ("たゆみの速さ (Gravity Speed)", Range(0, 10)) = 2
        _GravityWaves ("たゆみの波数 (Gravity Waves)", Range(0, 4)) = 0.65
        [HideInInspector] _GravityTrailColor ("Trail Blue Is Span", Float) = 0
        [HideInInspector] _GravityUseUV ("Normalized Line UV", Float) = 0
        [HideInInspector] _GravityLineLength ("Line Length", Float) = 1
        [Header(Trail Sway)]
        _SwayAmount         ("揺れ幅 帯幅=1 (Sway Amount)", Range(0, 0.5))  = 0.15
        _SwaySpeed          ("揺れの速さ (Sway Speed)", Range(0, 10))        = 2.0
        _SwayWaves          ("揺れの波数 (Sway Waves)", Range(0, 20))        = 3.0
        _SwayAnchor         ("揺れ始めの距離 uv.x (Sway Anchor)", Range(0, 1)) = 0.2
        _TrailEdgeSoft      ("帯の端のフェード幅 (Edge Soft)", Range(0.001, 0.5)) = 0.15

        // ---- トレイル固有（粘液モード） ----
        // 既定は OFF（既存マテリアルの見た目は変わらない）。ON にすると上の
        // 「糸のデザイン〜レイヤー」は粘液の中に透ける繊維の模様にだけ使われる。
        [Header(Goo Shape)]
        [Toggle(_GOO_ON)] _GooEnable ("粘液モード (Goo Mode)", Float) = 0
        _GooAmount          ("粘液感 0で乾いた糸 (Goo Amount)", Range(0, 1))   = 1
        [IntRange] _GooStrands ("束の本数 (Strands)", Range(1, 4))           = 3
        _GooWidth           ("束の太さ 帯幅比 (Strand Width)", Range(0.02, 1)) = 0.24
        _GooSpread          ("束の並ぶ幅 (Spread)", Range(0, 1))             = 0.6
        _GooWobble          ("蛇行の振れ幅 (Wobble)", Range(0, 0.5))          = 0.16
        _GooWobbleFreq      ("蛇行の細かさ uv.x毎 (Wobble Freq)", Float)      = 0.7
        _GooBeads           ("くびれと玉 (Beads)", Range(0, 1))              = 0.55
        _GooBeadFreq        ("玉の細かさ uv.x毎 (Bead Freq)", Float)          = 2.2
        _GooFlow            ("玉が流れる速さ (Flow Speed)", Float)            = 0.25
        _GooMerge           ("融合の粘り (Merge)", Range(0, 1))              = 0.35
        _GooTailThin        ("尻尾ほど細く伸びる (Tail Thin)", Range(0, 1))   = 0.6

        [Header(Goo Web Membrane)]
        _GooWeb             ("束の間の膜の量 (Web Amount)", Range(0, 1))      = 0.6
        _GooWebCell         ("穴の間隔 uv.x単位 (Hole Spacing)", Float)       = 0.3
        _GooWebRows         ("幅方向の穴の列数 (Hole Rows)", Range(1, 8))     = 2.5
        _GooWebHole         ("穴の開き具合 (Hole Size)", Range(0, 1))         = 0.85

        [Header(Goo Shading)]
        _GooColor           ("明部の色 (Goo Color)", Color)                  = (0.88, 0.87, 0.94, 1)
        _GooShadowColor     ("影部の色 (Goo Shadow)", Color)                 = (0.6, 0.58, 0.72, 1)
        _GooShade           ("影の広さ (Shadow Area)", Range(-0.5, 0.5))      = 0.12
        _GooOutlineColor    ("輪郭線の色 a=濃さ (Outline Color)", Color)      = (0.33, 0.32, 0.45, 0.85)
        _GooOutline         ("輪郭線の太さ (Outline Width)", Range(0, 0.5))    = 0.14
        _GooOpacity         ("不透明度 (Opacity)", Range(0, 1))              = 0.92
        _GooClarity         ("中心の透け (Clarity)", Range(0, 1))            = 0.25
        _GooFiberMix        ("透ける繊維の濃さ (Fiber Mix)", Range(0, 1))     = 0.25

        [Header(Goo Gloss)]
        _GooGlossColor      ("ハイライト色 a=濃さ (Gloss Color)", Color)      = (1, 1, 1, 1)
        _GooGloss           ("ハイライトの強さ (Gloss)", Range(0, 1))         = 1
        _GooGlossWidth      ("ハイライトの太さ (Gloss Width)", Range(0.01, 0.6)) = 0.14
        _GooGlossOffset     ("ハイライトを光源側へ (Gloss Offset)", Range(-1, 1)) = 0.3
        _GooGlossBreak      ("ハイライトの途切れ (Gloss Break)", Range(0, 1))  = 0.3

        // ---- 描画順（蜘蛛の巣・繭との重なり） ----
        // 糸の芯が立てるステンシルビット。繭デカール（CocoonDecal）は、このビットが立った画素へ
        // 体表の glue を上塗りしない（手前を通る糸が繭の下へ潜って見えないように）。
        // 付け替えたらデカール側の _GlueStencilReadMask（既定 208 = 128 + 64 + 16）も合わせること。
        [Header(Render Order)]
        [IntRange] _SilkStencilBit ("糸のステンシル ビット (Silk Stencil Bit)", Range(0, 255)) = 64
    }

    SubShader
    {
        Tags
        {
            // ★ 糸は巣・繭・網（Transparent 3000）より「先」に描く。
            //   巣や繭は半透明なのに、立体の前後関係を保つため不透明度の高い所だけ深度を書く。
            //   以前は糸を後（Transparent+10）に描いていたので、その深度に糸が負けて
            //   「繭や巣の向こうの糸」が透けて見えるはずの所で消えていた
            //   （視界ジャックの内壁・顔にかぶさった網・まとめ描きの外殻・繭メッシュ）。
            //   先に描いた糸の上に巣や繭が半透明で重なる＝向こうの糸は必ず透けて見える。
            //   手前の糸は Pass 0 が芯の深度を書くので、奥の巣・繭はその画素で深度テストに負け、
            //   糸の上には描かれない（前後関係も正しい）。
            "Queue"           = "Transparent-10"
            "RenderType"      = "Transparent"
            "IgnoreProjector" = "True"
            "PreviewType"     = "Plane"
            "VRCFallback"     = "Hidden"
        }

        // 頂点・フラグメントの処理は両パス共通（CGINCLUDE）。Pass 0 は不透明度しか使わない。
        CGINCLUDE
            // これ以上の不透明度の芯だけが深度とステンシルを書く（巣の DEPTHSOLID と同じ境目）。
            // 縁のぼかしや尻尾のフェードは書かない
            #define STT_DEPTH_SOLID_ALPHA 0.5

            #include "UnityCG.cginc"
            #include "Lighting.cginc"

            #include "CGINC/SpiderCocoon_Noise.cginc"
            #include "CGINC/SpiderCocoon_Common.cginc"
            #include "CGINC/SpiderCocoon_Thread.cginc"
            #include "CGINC/SpiderCocoon_Lighting.cginc"
            #include "CGINC/SpiderCocoon_Compose.cginc"
            #include "CGINC/SpiderGoo_Shading.cginc"
            #include "CGINC/SpiderThread_Goo.cginc"
            #include "CGINC/SpiderSilk_Motion.cginc"

            // トレイル固有 uniform（共通分は SpiderCocoon_Common.cginc で宣言済み）
            float _GravitySag, _GravityOscillation, _GravitySpeed, _GravityWaves, _GravityUseUV, _GravityLineLength, _GravityTrailColor;
            float _SwayAmount;
            float _SwaySpeed;
            float _SwayWaves;
            float _SwayAnchor;
            float _TrailEdgeSoft;

            // トレイルは頂点カラー（Color over Lifetime）を持つので専用の構造体を使う
            // uv.zw: パーティクルの Custom Trail Vertex Streams に
            //        「Position, Color, UV, StableRandom.xyzw」を指定すると、
            //        粒ごとの固定乱数が入る（TEXCOORD0.zw に詰められる）。
            //        粘液モードはこれでトレイルごとに模様をずらす。
            //        指定なし（通常の Trail Renderer 等）は 0 のまま＝全部同じ模様。
            struct appdata_t
            {
                float4 vertex : POSITION;
                fixed4 color  : COLOR;
                float4 uv     : TEXCOORD0;

                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f_t
            {
                float4 pos      : SV_POSITION;
                float4 uv       : TEXCOORD0;
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

                o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
                // 経路上の位置（0..1）が分かるのは、UV を正規化したとき（_GravityUseUV）か、
                // 頂点色の青に位置を入れたとき（_GravityTrailColor）だけ。どちらも無ければたわませない
                bool hasSpan = (_GravityUseUV > 0.5) || (_GravityTrailColor > 0.5);
                float along = (_GravityUseUV > 0.5) ? v.uv.x : v.color.b;
                // Particle color is converted from gamma to linear by Unity.
                #ifndef UNITY_COLORSPACE_GAMMA
                if (_GravityUseUV < 0.5) along = LinearToGammaSpaceExact(along);
                #endif
                // Tile distance / normalized span estimates trail length without a CPU update.
                float sagAmount = hasSpan ? _GravitySag : 0.0;
                if (_GravityTrailColor > 0.5 && _GravityUseUV < 0.5)
                    sagAmount = min(sagAmount, max(v.uv.x, 0.0) / max(along, 1e-4) * 0.08);
                // Move the ribbon itself, independently of camera orientation.
                o.worldPos.y -= SSM_GravitySag(along, sagAmount, _GravityOscillation,
                    _GravityWaves, _Time.y * _GravitySpeed, v.uv.z * UNITY_TWO_PI);
                o.pos = UnityWorldToClipPos(o.worldPos);
                o.uv       = v.uv;
                if (_GravityUseUV > 0.5) o.uv.x *= _GravityLineLength;
                o.color    = v.color;
                // Tile-mode PercentageAlongTrail is not normalized in Unity 2022.3.
                // Dedicated shot materials reserve blue for Color over Trail 0..1.
                if (_GravityTrailColor > 0.5 && _GravityUseUV < 0.5) o.color.b = 1.0;
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

                // たわみが実際に効いているときだけ揺れを止める（vert と同じ条件）
                bool hasSpan = (_GravityUseUV > 0.5) || (_GravityTrailColor > 0.5);
                float swayMul = (hasSpan && _GravitySag > 0.0) ? 0.0 : 1.0;
                float2 suv = float2(i.uv.x, i.uv.y + sway * swayMul);

                // ==== 陰影用の基底（トレイルには法線・接線が無いので導出する） ====
                // N: トレイルはカメラ正対の帯なので「カメラへ向く法線」で近似。
                //    Cull Off でも常に視線側を向くため VFACE 分岐が不要になる。
                // T/B: ワールド座標と UV の画面微分から「uv.x / uv.y が増える
                //    ワールド方向」を解く（コタンジェントフレームの定石）。
                float3 V   = _WorldSpaceCameraPos - i.worldPos;
                float3 N   = normalize(V);

                float3 dpx = ddx(i.worldPos);
                float3 dpy = ddy(i.worldPos);
                float2 dux = ddx(i.uv.xy);
                float2 duy = ddy(i.uv.xy);
                float  det = dux.x * duy.y - duy.x * dux.y;
                float  sgn = (det >= 0.0) ? 1.0 : -1.0;
                float3 T   = (dpx * duy.y - dpy * dux.y) * sgn;  // ∂worldPos/∂uv.x 方向
                float3 B   = (dpy * dux.x - dpx * duy.x) * sgn;  // ∂worldPos/∂uv.y 方向
                // 長さの比 = 「uv.x 1 あたりのメートル / uv.y 1 あたりのメートル」
                // （正規化前の T, B は同じ係数 |det| 倍なので、比を取れば打ち消える）
                float  aspect = clamp(sqrt(dot(T, T) / max(dot(B, B), 1e-20)), 1e-3, 1e4);
                T = (dot(T, T) > 1e-16) ? normalize(T) : float3(0.0, 1.0, 0.0);
                B = (dot(B, B) > 1e-16) ? normalize(B) : normalize(cross(N, T));

                // 帯の上下端をフェード: 揺れで端に寄った糸が帯の縁でスパッと
                // 切れて見えないよう、端に近い糸ほど薄くする。
                float edge = smoothstep(0.0, _TrailEdgeSoft,
                                        min(i.uv.y, 1.0 - i.uv.y));

            #if defined(_GOO_ON)
                // ==== 粘液モード ====
                fixed4 col = STG_ShadeGoo(suv, i.uv.z, N, T, B, i.worldPos, aspect, i.color.a);

                // 頂点アルファは尻尾の「細り」にも使っているので、_GooTailThin が
                // 大きいほどフェードは尻尾の最後の方へ寄せる（細く伸びてから消える）。
                float fadeA = lerp(i.color.a, saturate(i.color.a * 3.0), _GooTailThin);
                col.rgb *= i.color.rgb;
                col.a   *= fadeA * edge;
                if (col.a <= 0.002) discard;
                return col;
            #else
                // AA 幅は揺れ適用後の座標で取る（揺れの勾配ぶんも滑らかになる）
                float2 aaUV = float2(fwidth(suv.x), fwidth(suv.y));

                // 乾いた糸のレイヤー合成（SpiderCocoon_Compose.cginc）。uv.x はシーム無しの連続
                // 座標（Stretch/Tile どちらでも巻き戻らない）なので snapCx /
                // foldFuzz は不要（メッシュ版と同じ扱い）。
                fixed4 col = SC_CompositeLayers(suv, N, T, B, i.worldPos, aaUV,
                                                false, false, false);

                // 頂点カラー（Trail の Color / Color over Lifetime）を乗算 →
                // 尻尾へ向けて糸が消えていく等の演出はパーティクル側で制御できる
                col.rgb *= i.color.rgb;
                col.a   *= i.color.a * edge;
                return col;
            #endif
            }

            // Pass 0 用: 色は使わず、芯（不透明度が高い所）だけ残して深度とステンシルを書かせる
            // （戻り値の色は使わないので、色と光の計算はコンパイラが省く）
            fixed4 fragDepth(v2f_t i) : SV_Target
            {
                // ★ 早い棄却（2026-10-14 軽量化。結果は最後の clip と同じ）
                //   最後の不透明度 = 糸の模様の不透明度 × 頂点アルファのフェード × 帯の縁のフェード（frag と同じ式）。
                //   模様の不透明度には上限があるので、上限 × フェードが芯の境目に届かない画素
                //   （尻尾の消えかけ・帯の縁）は、模様の計算の前に捨てる。
                float edge = smoothstep(0.0, _TrailEdgeSoft, min(i.uv.y, 1.0 - i.uv.y));
            #if defined(_GOO_ON)
                // 粘液: 上限は STG_GooAlphaCeiling（透ける繊維 extraAlpha の上限は _GooFiberMix）
                float fadeA = lerp(i.color.a, saturate(i.color.a * 3.0), _GooTailThin);
                float alphaCeiling = STG_GooAlphaCeiling(_GooFiberMix) * abs(fadeA * edge);
            #else
                // 繊維の重ね合わせ: 1 層の不透明度は _ThreadColor.a 以下、重ねても max(1, _ThreadColor.a) 以下
                float alphaCeiling = max(1.0, abs(_ThreadColor.a)) * abs(i.color.a * edge);
            #endif
                if (alphaCeiling < STT_DEPTH_SOLID_ALPHA) discard;

                fixed4 c = frag(i);
                clip(c.a - STT_DEPTH_SOLID_ALPHA);
                return 0;
            }
        ENDCG

        // Pass 0: 糸の芯の深度＋ステンシル。後から描く巣・繭・網は、手前に糸の芯がある画素で
        // 深度テストに負ける（糸の上に重ならない）。ステンシルは ZTest Always で体表に貼る
        // デカールの glue が、手前を通る糸を上塗りしないための目印。
        Pass
        {
            Name "DEPTHSOLID"
            Tags { "LightMode" = "ForwardBase" }

            ColorMask 0
            ZWrite On
            Cull   Off
            Stencil
            {
                Ref       [_SilkStencilBit]
                WriteMask [_SilkStencilBit]
                Comp      Always
                Pass      Replace
            }

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment fragDepth
            #pragma target   3.5
            #pragma multi_compile_instancing
            #pragma shader_feature_local _GOO_ON
            ENDCG
        }

        Pass
        {
            Name "FORWARD"
            // ForwardBase タグ: メインライト・環境光（_WorldSpaceLightPos0 /
            // _LightColor0 / SH）を確実にバインドするために必要（繭と同じ）。
            Tags { "LightMode" = "ForwardBase" }

            Cull   Off          // 帯はどちら側からも見える
            ZWrite Off          // 深度は Pass 0 が芯だけ書いた（縁のぼかしは奥を隠さない）
            Blend  SrcAlpha OneMinusSrcAlpha

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment frag
            #pragma target   3.5
            #pragma multi_compile_instancing
            // 粘液モードはキーワードで切替（実行時の if 分岐にすると、分岐内の
            // fwidth のせいで両方の処理が常に走るため）
            #pragma shader_feature_local _GOO_ON
            ENDCG
        }
    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}
