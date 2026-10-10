using System;
using System.Collections.Generic;
using System.Reflection;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

// =============================================================================
// 繭・デカール・吐いた糸・蜘蛛の巣・ねばねばネット系で共用のカスタムインスペクタ。
// lilToon 風にカテゴリごとの折りたたみボックスで整理し、色分けして表示する。
//   ・紫系「質感」: 蜘蛛糸の質感 21 項目（Editor/SpiderSilkLook.cs）。吐いた糸のマテリアルで
//     決めて、巣・繭・デカール・ねばねばネットはそれを継承する（継承先では「蜘蛛糸の質感（継承）」欄に
//     読み取り専用で出る）
//   ・青系「共通」: 複数のシェーダーが同じ名前で持つ値（単位はシェーダーごとに違うこともある）
//   ・オレンジ系「固有」: そのシェーダー専用の値
// 先頭の「プリセット」欄（緑系）は SpiderShaderPresetPanel が描く。
//
// ※ Editor 専用スクリプト。ワールドのビルドには含まれない。
//   このファイルを削除してもシェーダーは既定のインスペクタで動作する。
// =============================================================================
public class SpiderCocoonShaderGUI : ShaderGUI
{
    // プリセット適用時の区分。見た目(Look)は常に適用し、
    // 形(Shape)・変形ギミック(Gimmick)はプリセット欄のチェックで外せる
    internal enum PresetPart { Look, Shape, Gimmick }

    private class Category
    {
        public string   Title;
        public bool     Common;   // 複数のシェーダーが同じ名前で持つ値か（青系）
        public bool     SilkLook; // 蜘蛛糸の質感（紫系。巣・繭・デカール・ねばねばネットでは継承して読み取り専用）
        public string   Require;  // このプロパティを持つシェーダーにだけ表示（null=常時）
        public string[] Props;
        public PresetPart Part;   // プリセット適用時の区分（既定は見た目）
        public string[] Hidden;   // インスペクタに出さないがプリセットには含める値
    }

    // 質感の 4 カテゴリは正本（SpiderSilkLook.Props）のグループから作る
    private static string[] LookProps(string group)
    {
        var list = new List<string>();
        foreach (var p in SpiderSilkLook.Props) if (p.Group == group) list.Add(p.Name);
        return list.ToArray();
    }

    private static readonly Category[] Categories =
    {
        // ---- 質感（蜘蛛糸 → 巣・繭・デカール・ねばねばネットへ継承） ----
        new Category{ Title = SpiderSilkLook.GroupGoo,   SilkLook = true, Props = LookProps(SpiderSilkLook.GroupGoo) },
        new Category{ Title = SpiderSilkLook.GroupGloss, SilkLook = true, Props = LookProps(SpiderSilkLook.GroupGloss) },
        new Category{ Title = SpiderSilkLook.GroupToon,  SilkLook = true, Props = LookProps(SpiderSilkLook.GroupToon) },
        new Category{ Title = SpiderSilkLook.GroupRim,   SilkLook = true, Props = LookProps(SpiderSilkLook.GroupRim) },

        // ---- 共通（複数のシェーダーが同じ名前で持つ） ----
        new Category{ Title = "糸のデザイン", Common = true,
            Props = new[]{ "_ThreadColor", "_ThreadThickness", "_ThreadJitter", "_ThreadFuzz", "_ThreadFuzzScale" } },
        new Category{ Title = "巻きのレイアウト", Common = true,
            Props = new[]{ "_WindingCount", "_ThreadDensity", "_FiberAngle" } },
        // 粘液モード OFF の吐いた糸だけが使う陰影（継承しない）
        new Category{ Title = "乾いた糸の陰影（粘液モード OFF）", Common = false, Require = "_FiberNormalStrength",
            Props = new[]{ "_ShadowColor", "_FiberNormalStrength", "_RimShadowColor", "_RimShadowStrength" } },
        new Category{ Title = "レイヤー", Common = true,
            Props = new[]{ "_LayerCount", "_LayerAngleStep", "_LayerPosStepX", "_LayerPosStepY", "_LayerThicknessFalloff" } },
        // 揺れアニメは対応シェーダー（SpiderWeb / SpiderCocoon 本体）だけに表示
        new Category{ Title = "揺れアニメ", Common = true, Require = "_SwayAnimEnable",
            Props = new[]{ "_SwayAnimEnable", "_SwayAnimAmount", "_SwayAnimSpeed", "_SwayAnimWaves", "_SwayAnimAnchor" } },
        // 粘液の形（色・陰影・光沢・粘液感は上の「質感」）。シェーダーごとに持つ項目が違うが、
        // 実在するプロパティだけが描画される。同じ名前でも単位がシェーダーごとに違うので継承しない
        new Category{ Title = "粘液の形", Common = true, Require = "_GooAmount",
            Props = new[]{ "_GooEnable", "_GooThick", "_GooFlat", "_GooBeads", "_GooBeadFreq", "_GooMerge" } },
        new Category{ Title = "粘液の膜", Common = true, Require = "_GooAmount",
            Props = new[]{ "_GooWebFill", "_GooWebScale", "_GooWeb", "_GooWebCell", "_GooWebRows", "_GooWebHole" } },
        new Category{ Title = "粘液の細部", Common = true, Require = "_GooAmount",
            Props = new[]{ "_GooFiberMix", "_GooFiberLines", "_GooOverlapShadow" } },

        // ---- メッシュ版（SpiderCocoon）固有 ----
        new Category{ Title = "ビルボード", Common = false, Require = "_Billboard",
            Props = new[]{ "_Billboard", "_BillboardSeamOffset" } },
        new Category{ Title = "裏面と視界ジャック", Common = false, Require = "_VisionJackRadius",
            Props = new[]{ "_HideBackFibers", "_VisionJackEnable", "_VisionJackRadius", "_VisionJackHeight", "_VisionJackInMirror", "_JackRadius", "_JackStretch" } },
        // 繭のジャック（_StencilRef）・蜘蛛糸の芯（_SilkStencilBit）・デカールが glue を描かない
        // 画素（_StencilSkipMask）のステンシル。シェーダーごとに持つ項目が違うが、
        // 実在するプロパティだけが描画される（どれも持たないシェーダーには出ない）
        new Category{ Title = "レンダーステート", Common = false,
            Props = new[]{ "_ZWrite", "_StencilRef", "_StencilSkipMask", "_SilkStencilBit" } },

        // ---- デカール版（SpiderCocoonDepthDecal）固有 ----
        new Category{ Title = "投影フィット", Common = false, Require = "_RadiusFit",
            Props = new[]{ "_RadiusFit", "_HeightFit", "_ProjectRange" } },
        new Category{ Title = "繭まとめ描きのボリューム", Common = false, Require = "_GroupBulge",
            Props = new[]{ "_GroupBulge", "_GroupBridgeSpan", "_GroupShellBlend", "_GroupRadiusScale", "_GroupAxisFollow", "_GroupAxisBlend" } },
        new Category{ Title = "糸の厚み", Common = false, Require = "_GlueThickness",
            Props = new[]{ "_GlueThickness" } },
        new Category{ Title = "巻きの端のほつれ", Common = false, Require = "_GooEdgeFray",
            Props = new[]{ "_GooEdgeFray" } },
        // 糸が巻かれて繭になっていくアニメ（通常は Udon が MPB で進み具合を渡す）
        new Category{ Title = "巻きアニメ", Common = false, Require = "_WindEnable",
            Props = new[]{ "_WindEnable", "_WindProgress" } },
        new Category{ Title = "他の部位を巻かない", Common = false, Require = "_WrapFacing",
            Props = new[]{ "_WrapFacing" } },
        new Category{ Title = "床・天井", Common = false, Require = "_GroundTex",
            Props = new[]{ "_GroundTex", "_GroundColor", "_GroundDetectScale", "_GroundNormalY" } },
        // Require はデカール専用プロパティにする（_JackRadius は本体シェーダーにも
        // 追加されたため、それを条件にすると本体側で重複表示されてしまう）
        new Category{ Title = "視界ジャック", Common = false, Require = "_RadiusFit",
            Props = new[]{ "_VisionJackEnable", "_VisionJackInMirror", "_JackRadius", "_JackStretch" } },

        // ---- トレイル版（SpiderThreadTrail）固有 ----
        // _GravityTrailColor（トレイルの頂点色の青を全長として使う）は
        // パーティクルのトレイル用マテリアルだけが ON にする隠し設定
        new Category{ Title = "重力によるたゆみ", Common = false, Require = "_GravitySag",
            Props = new[]{ "_GravitySag", "_GravityOscillation", "_GravitySpeed", "_GravityWaves" },
            Hidden = new[]{ "_GravityTrailColor" } },
        new Category{ Title = "トレイルの揺れ", Common = false, Require = "_SwayAmount",
            Props = new[]{ "_SwayAmount", "_SwaySpeed", "_SwayWaves", "_SwayAnchor", "_TrailEdgeSoft" } },
        // 粘液モード（_GooEnable=ON で有効）の束の形。吐いた糸だけが持つ
        new Category{ Title = "吐いた糸の粘液の束", Common = false, Require = "_GooStrands",
            Props = new[]{ "_GooStrands", "_GooWidth", "_GooSpread", "_GooWobble", "_GooWobbleFreq",
                           "_GooFlow", "_GooTailThin" } },

        // ---- ねばねばネット（蜘蛛糸の粘液シート、SpiderGooSilkSheet）固有 ----
        // 帯の中の形は「吐いた糸の粘液の束」「粘液の形」「粘液の膜」に吐いた糸と同じ名前で出る。
        // 焼き込みの入力だけをここへ。形状・質感・変形の既存項目は元のカテゴリに1回ずつ表示。
        new Category{ Title = "粘液シートの形", Common = false, Require = "_SheetBandWidth",
            Part = PresetPart.Shape,
            Props = new[]{ "_WebRadius", "_SheetBandWidth", "_SheetRotation", "_SheetAlongScale", "_Seed", "_HideBackFibers" } },
        new Category{ Title = "粘液シートの焼き込み設定", Common = false, Require = "_BakedVariants",
            Part = PresetPart.Shape,
            Props = new[]{ "_BakedVariants", "_BakeResolution", "_BakeCompression", "_BakePadding" } },
        new Category{ Title = "粘液シートの重なり", Common = false, Require = "_WebLayers",
            Part = PresetPart.Shape,
            Props = new[]{ "_WebLayers", "_WebLayerDepth", "_WebLayerContactDepth", "_WebLayerAdhere",
                           "_WebLayerAdhereScale", "_WebLayerTwist", "_WebLayerShift", "_WebLayerOpacity",
                           "_WebLayerWidthOuter", "_WebLayerWidthJitter" } },

        // ---- 蜘蛛の巣版（SpiderWeb）固有 ----
        // 巣の形・配置はメッシュ（平面 / 木の扇形）ごとに決まるので、プリセットでは
        // 「形」区分にして、適用時に今の値を残せるようにする
        // Require は蜘蛛の巣だけが持つ _RadialCount（粘液シートも _WebRadius を持つため）
        new Category{ Title = "蜘蛛の巣カスタマイズ(個別)", Common = false, Require = "_RadialCount",
            Part = PresetPart.Shape,
            Props = new[]{ "_HubOffsetX", "_HubOffsetY", "_WebRadius", "_Thickness",
                           "_RadialCount", "_RingCount", "_Sag", "_SpokeExtend",
                           "_Irregular", "_Seed", "_HideBackFibers" } },
        new Category{ Title = "扇形の巣", Common = false, Require = "_FanEnable",
            Part = PresetPart.Shape,
            Props = new[]{ "_FanEnable", "_FanAngle", "_FanRotation", "_FanMeshRim" } },
        new Category{ Title = "粘着糸の質感", Common = false, Require = "_JunctionSize",
            Props = new[]{ "_SpokeWidth", "_RingWidth", "_Organic", "_JunctionSize", "_SpokeGoo", "_RingGoo" } },
        // 足捕縛の変形。捕縛点・追従先の配列（_PullAnchors/_PullTargets）は MPB 専用でインスペクターに出ない
        // 変形 2 種は Udon 側の仕掛け（SurfaceContactDeformer / CaptureNetDrape）と
        // 組で使う設定なので、プリセットでは「変形ギミック」区分
        new Category{ Title = "接触追従の変形", Common = false, Require = "_PullEnable",
            Part = PresetPart.Gimmick,
            Props = new[]{ "_PullEnable", "_PullRadius", "_PullFalloff", "_PullStrength",
                           "_PullMaxStretch", "_PullTearFade", "_PullCount" } },
        // 投げつけた網が体に覆いかぶさる変形（体のカプセル・網の向きは MPB 専用）
        new Category{ Title = "体に覆いかぶさる変形", Common = false, Require = "_DrapeEnable",
            Part = PresetPart.Gimmick,
            Props = new[]{ "_DrapeEnable", "_DrapeGap", "_DrapeSmooth", "_DrapeWrap", "_DrapeCling", "_DrapeTail",
                           "_DrapeSag", "_DrapeTurns", "_DrapeLayer", "_DrapeBunch", "_DrapeStretchFade",
                           "_DrapeFollowBlend", "_DrapeFollowPush", "_DrapeFollowHang", "_DrapeFollowHangDist",
                           "_DrapeCount" } },
        // 巨大な空中の巣をカメラ距離で表示（下端は Udon が Renderer ごとに MPB で設定）
        new Category{ Title = "近接表示（巨大な空中の巣）", Common = false, Require = "_RevealEnable",
            Part = PresetPart.Gimmick,
            Props = new[]{ "_RevealEnable", "_RevealNear", "_RevealFar", "_RevealNoise", "_RevealNoiseScale", "_ClipLine" } },
    };

    public override void OnGUI(MaterialEditor materialEditor, MaterialProperty[] properties)
    {
        // lilToon と同じく、プリセット（よく使う設定のひな形）を一番上に置く
        SpiderShaderPresetPanel.Draw(materialEditor);

        var map = new Dictionary<string, MaterialProperty>();
        foreach (var p in properties) map[p.name] = p;

        var drawn = new HashSet<string>();

        // 質感の継承: 巣・繭・デカール・ねばねばネットは継承元の欄（質感は読み取り専用でその中に表示）、
        // 吐いた糸はこの質感を継承しているマテリアルの一覧
        var role = SpiderSilkLook.GetRole(((Material)materialEditor.target).shader);
        if (role == SpiderSilkLook.Role.Inheritor)
        {
            SpiderSilkLookPanel.DrawInheritor(materialEditor, map);
            foreach (var p in SpiderSilkLook.Props) drawn.Add(p.Name);
        }
        else if (role == SpiderSilkLook.Role.Source)
            SpiderSilkLookPanel.DrawSourceSummary(materialEditor);

        foreach (var cat in Categories)
        {
            if (cat.Require != null && !map.ContainsKey(cat.Require)) continue;
            if (cat.SilkLook && role == SpiderSilkLook.Role.Inheritor) continue;

            // このマテリアルに実在するプロパティだけ集める。
            // [HideInInspector] の値は出さない（巣の _SwayAnimWaves など、そのシェーダーでは効かない値）
            var list = new List<MaterialProperty>();
            foreach (var name in cat.Props)
                if (map.TryGetValue(name, out var mp) &&
                    (mp.flags & MaterialProperty.PropFlags.HideInInspector) == 0)
                    list.Add(mp);
            if (list.Count == 0) continue;

            foreach (var mp in list) drawn.Add(mp.name);

            string label = cat.SilkLook
                ? cat.Title + (role == SpiderSilkLook.Role.Source ? "（巣・繭・デカール・ねばねばネットへ継承）" : "")
                : cat.Title + (cat.Common ? "（共通）" : "（固有）");
            bool open = cat.SilkLook ? DrawSectionFoldout(label, SpiderSilkLookPanel.LookColor) : DrawSectionFoldout(label, cat.Common);
            if (open)
            {
                EditorGUI.indentLevel++;
                foreach (var mp in list)
                    DrawPropertyNoDecorators(materialEditor, mp);
                EditorGUI.indentLevel--;
                EditorGUILayout.Space(2);
            }
        }

        SpiderGooSheetBakePanel.Draw(materialEditor);

        // カテゴリ表に無い新規プロパティの取りこぼし防止
        var leftovers = new List<MaterialProperty>();
        foreach (var p in properties)
            if (!drawn.Contains(p.name) &&
                (p.flags & MaterialProperty.PropFlags.HideInInspector) == 0)
                leftovers.Add(p);

        if (leftovers.Count > 0 && DrawSectionFoldout("その他（未分類）", false))
        {
            EditorGUI.indentLevel++;
            foreach (var mp in leftovers)
                DrawPropertyNoDecorators(materialEditor, mp);
            EditorGUI.indentLevel--;
        }

        EditorGUILayout.Space(6);
        if (DrawSectionFoldout("詳細設定", false))
        {
            EditorGUI.indentLevel++;
            materialEditor.RenderQueueField();
            materialEditor.EnableInstancingField();
            materialEditor.DoubleSidedGIField();
            EditorGUI.indentLevel--;
        }
    }

    // インスペクタで値が変わったとき（Unity が全ターゲットについて呼ぶ）。
    // 吐いた糸の質感が変われば継承先へ、継承先の継承元が変われば値の書き写しを依頼する
    public override void ValidateMaterial(Material material)
    {
        base.ValidateMaterial(material);
        SpiderSilkLook.NotifyChanged(material);
    }

    // -------------------------------------------------------------------------
    // シェーダー側の [Header(...)] は「Editor スクリプトが無い環境（標準
    // インスペクタ）」向けのフォールバック用の見出し。カスタム GUI では
    // 折りたたみボックスが見出しの役割を担うため、通常の ShaderProperty() で
    // 描くと見出しが二重になる。そこで内部 API（MaterialPropertyHandler）に
    // 反射でアクセスし、[Toggle] や [Enum] の描画ドロワーは活かしたまま
    // [Header] などの装飾ドロワーだけをスキップして描画する。
    // 反射が使えない Unity バージョンでは従来どおり ShaderProperty() へ
    // フォールバック（見出しが重複表示されるだけで、機能は損なわれない）。
    // -------------------------------------------------------------------------
    private static bool         _handlerReflectionFailed;
    private static MethodInfo   _getHandler;
    private static PropertyInfo _propertyDrawer;

    internal static void DrawPropertyNoDecorators(MaterialEditor editor, MaterialProperty prop)
    {
        if (!_handlerReflectionFailed && _getHandler == null)
        {
            try
            {
                var t = typeof(MaterialEditor).Assembly.GetType("UnityEditor.MaterialPropertyHandler");
                _getHandler     = t?.GetMethod("GetHandler",
                    BindingFlags.NonPublic | BindingFlags.Static);
                _propertyDrawer = t?.GetProperty("propertyDrawer",
                    BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
                if (_getHandler == null || _propertyDrawer == null)
                    _handlerReflectionFailed = true;
            }
            catch { _handlerReflectionFailed = true; }
        }

        if (!_handlerReflectionFailed)
        {
            try
            {
                var shader  = ((Material)editor.target).shader;
                var handler = _getHandler.Invoke(null, new object[] { shader, prop.name });
                var drawer  = (handler != null)
                    ? _propertyDrawer.GetValue(handler, null) as MaterialPropertyDrawer
                    : null;

                if (drawer != null)
                {
                    // [Toggle] / [Enum] 等の本体ドロワーだけを直接呼ぶ（装飾は呼ばない）
                    float h = drawer.GetPropertyHeight(prop, prop.displayName, editor);
                    Rect  r = EditorGUILayout.GetControlRect(true, h);
                    drawer.OnGUI(r, prop, new GUIContent(prop.displayName), editor);
                }
                else
                {
                    // ドロワー無し: 型どおりの既定描画（装飾は適用されない）
                    editor.DefaultShaderProperty(prop, prop.displayName);
                }
                return;
            }
            // オブジェクトピッカーを開いたときなどに Unity が投げる「描画の打ち切り」は通す
            catch (ExitGUIException) { throw; }
            catch { _handlerReflectionFailed = true; }
        }

        // フォールバック（[Header] も一緒に描かれる）
        editor.ShaderProperty(prop, prop.displayName);
    }

    // -------------------------------------------------------------------------
    // プリセット（SpiderShaderPreset）用のグループ分け。
    // 上のカテゴリ表をそのまま使い、1 カテゴリ = プリセット保存時の 1 チェック項目。
    // カテゴリ表に無い表示プロパティは「その他（未分類）」にまとめる。
    // インスペクタに出ない値（Udon が MaterialPropertyBlock で毎フレーム渡す
    // 数など）は、カテゴリの Hidden に書いたもの以外は保存しない。
    // -------------------------------------------------------------------------
    internal const string OtherPresetGroup = "その他（未分類）";

    // [HideInInspector] ではないが Udon が実行時に上書きする値（保存しても意味がない）
    private static readonly HashSet<string> RuntimeOnlyProps = new HashSet<string>
    {
        "_PullCount", "_DrapeCount",
        "_ClipLine",
        "_BakedShape", "_BakedDetail", "_BakedUVSpan", "_BakedSliceCount", "_BakedWetParams",
        "_BakedCoverage", "_BakedTexelSize", "_BakedDistanceRange", "_BakedRadiusRange",
    };

    internal class PresetGroup
    {
        public string       Title;
        public PresetPart   Part;
        public List<string> Props = new List<string>();
    }

    // prop がプリセットのどのグループに入るか。false = プリセットの対象外
    internal static bool TryGetPresetGroup(Shader shader, string prop, out string group, out PresetPart part)
    {
        group = null;
        part  = PresetPart.Look;
        if (shader == null || RuntimeOnlyProps.Contains(prop)) return false;
        // 巣・繭・デカール・ねばねばネットの質感は継承元の蜘蛛糸マテリアルが決める（プリセットでは扱わない）
        if (SpiderSilkLook.IsInheritedProperty(shader, prop)) return false;
        int index = shader.FindPropertyIndex(prop);
        if (index < 0) return false;

        // インスペクタと同じく、Require を満たす最初のカテゴリに属する
        bool hidden = (shader.GetPropertyFlags(index) & ShaderPropertyFlags.HideInInspector) != 0;
        foreach (var cat in Categories)
        {
            if (cat.Require != null && shader.FindPropertyIndex(cat.Require) < 0) continue;
            if ((!hidden && Array.IndexOf(cat.Props, prop) >= 0) ||
                (cat.Hidden != null && Array.IndexOf(cat.Hidden, prop) >= 0))
            {
                group = cat.Title;
                part  = cat.Part;
                return true;
            }
        }

        if (hidden) return false;
        group = OtherPresetGroup;
        return true;
    }

    // シェーダーが持つグループを、インスペクタの並び順で返す（保存ウィンドウ用）
    internal static List<PresetGroup> GetPresetGroups(Shader shader)
    {
        var groups = new List<PresetGroup>();
        if (shader == null) return groups;
        var byTitle = new Dictionary<string, PresetGroup>();

        foreach (var cat in Categories)
        {
            if (byTitle.ContainsKey(cat.Title)) continue;
            byTitle[cat.Title] = new PresetGroup { Title = cat.Title, Part = cat.Part };
        }
        byTitle[OtherPresetGroup] = new PresetGroup { Title = OtherPresetGroup };

        int n = shader.GetPropertyCount();
        for (int i = 0; i < n; i++)
        {
            string prop = shader.GetPropertyName(i);
            if (TryGetPresetGroup(shader, prop, out var title, out _))
                byTitle[title].Props.Add(prop);
        }

        foreach (var cat in Categories)
            if (byTitle.TryGetValue(cat.Title, out var g) && g.Props.Count > 0 && !groups.Contains(g))
                groups.Add(g);
        if (byTitle[OtherPresetGroup].Props.Count > 0) groups.Add(byTitle[OtherPresetGroup]);
        return groups;
    }

    // lilToon などと同系の「モジュールタイトル」風フォールドアウト。
    // 開閉状態は EditorPrefs に保存（セッションをまたいで維持）。
    private static GUIStyle _sectionStyle;

    private static readonly Color CommonColor = new Color(0.70f, 0.88f, 1.00f);  // 共通＝青系
    private static readonly Color OwnColor    = new Color(1.00f, 0.87f, 0.70f);  // 固有＝オレンジ系

    private static bool DrawSectionFoldout(string title, bool common)
    {
        return DrawSectionFoldout(title, common ? CommonColor : OwnColor);
    }

    // prefKey: 開閉状態を覚えるキー（見出しに数などが入って変わるときは固定のキーを渡す）
    internal static bool DrawSectionFoldout(string title, Color color, string prefKey = null)
    {
        if (_sectionStyle == null)
        {
            _sectionStyle = new GUIStyle("ShurikenModuleTitle")
            {
                font          = EditorStyles.boldLabel.font,
                fontSize      = 12,
                border        = new RectOffset(15, 7, 4, 4),
                fixedHeight   = 22,
                contentOffset = new Vector2(20f, -2f),
            };
        }

        string key   = "SpiderCocoonGUI_" + (prefKey ?? title);
        bool   state = EditorPrefs.GetBool(key, true);

        var rect = GUILayoutUtility.GetRect(16f, 22f, _sectionStyle);
        var prev = GUI.backgroundColor;
        GUI.backgroundColor = color;
        GUI.Box(rect, title, _sectionStyle);
        GUI.backgroundColor = prev;

        var e = Event.current;
        var toggleRect = new Rect(rect.x + 4f, rect.y + 2f, 13f, 13f);
        if (e.type == EventType.Repaint)
            EditorStyles.foldout.Draw(toggleRect, false, false, state, false);
        if (e.type == EventType.MouseDown && rect.Contains(e.mousePosition))
        {
            state = !state;
            EditorPrefs.SetBool(key, state);
            e.Use();
        }
        return state;
    }
}
