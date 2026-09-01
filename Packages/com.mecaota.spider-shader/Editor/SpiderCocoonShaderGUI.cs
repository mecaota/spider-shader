using System.Collections.Generic;
using System.Reflection;
using UnityEditor;
using UnityEngine;

// =============================================================================
// SpiderCocoon / SpiderCocoonDepthDecal / SpiderThreadTrail / SpiderWeb 共用のカスタムインスペクタ。
// lilToon 風にカテゴリごとの折りたたみボックスで整理し、
// 「共通（本体とデカールで同じ見た目パラメータ・青系）」と
// 「固有（そのシェーダー専用・オレンジ系）」を色分けして表示する。
//
// ※ Editor 専用スクリプト。ワールドのビルドには含まれない。
//   このファイルを削除してもシェーダーは既定のインスペクタで動作する。
// =============================================================================
public class SpiderCocoonShaderGUI : ShaderGUI
{
    private class Category
    {
        public string   Title;
        public bool     Common;   // 本体/デカール共通の見た目パラメータか
        public string   Require;  // このプロパティを持つシェーダーにだけ表示（null=常時）
        public string[] Props;
    }

    private static readonly Category[] Categories =
    {
        // ---- 共通（本体とデカールで値を揃えると外観が一致する） ----
        new Category{ Title = "糸のデザイン", Common = true,
            Props = new[]{ "_ThreadColor", "_ThreadThickness", "_ThreadJitter", "_ThreadFuzz", "_ThreadFuzzScale" } },
        new Category{ Title = "巻きのレイアウト", Common = true,
            Props = new[]{ "_WindingCount", "_ThreadDensity", "_FiberAngle" } },
        new Category{ Title = "トゥーン陰影", Common = true,
            Props = new[]{ "_ToonSteps", "_ToonSmooth", "_ShadowColor", "_AmbientBoost", "_LightInfluence" } },
        new Category{ Title = "リムライト", Common = true,
            Props = new[]{ "_RimColor", "_RimPower", "_RimStrength", "_RimFloor" } },
        new Category{ Title = "糸ごとの陰影", Common = true,
            Props = new[]{ "_FiberNormalStrength", "_RimShadowColor", "_RimShadowStrength" } },
        new Category{ Title = "レイヤー", Common = true,
            Props = new[]{ "_LayerCount", "_LayerAngleStep", "_LayerPosStepX", "_LayerPosStepY", "_LayerThicknessFalloff" } },
        // 揺れアニメは対応シェーダー（SpiderWeb / SpiderCocoon 本体）だけに表示
        new Category{ Title = "揺れアニメ", Common = true, Require = "_SwayAnimEnable",
            Props = new[]{ "_SwayAnimEnable", "_SwayAnimAmount", "_SwayAnimSpeed", "_SwayAnimWaves", "_SwayAnimAnchor" } },

        // ---- メッシュ版（SpiderCocoon）固有 ----
        new Category{ Title = "ビルボード", Common = false, Require = "_Billboard",
            Props = new[]{ "_Billboard", "_BillboardSeamOffset" } },
        new Category{ Title = "裏面と視界ジャック", Common = false, Require = "_VisionJackRadius",
            Props = new[]{ "_HideBackFibers", "_VisionJackEnable", "_VisionJackRadius", "_VisionJackHeight", "_VisionJackInMirror", "_JackRadius", "_JackStretch" } },
        // _StencilRef は本体・デカール両方が持つ（実在するプロパティだけが描画される）
        new Category{ Title = "レンダーステート", Common = false, Require = "_StencilRef",
            Props = new[]{ "_ZWrite", "_StencilRef" } },

        // ---- デカール版（SpiderCocoonDepthDecal）固有 ----
        new Category{ Title = "投影フィット", Common = false, Require = "_RadiusFit",
            Props = new[]{ "_RadiusFit", "_HeightFit", "_ProjectRange" } },
        new Category{ Title = "糸の厚み", Common = false, Require = "_GlueThickness",
            Props = new[]{ "_GlueThickness" } },
        new Category{ Title = "床・天井", Common = false, Require = "_GroundTex",
            Props = new[]{ "_GroundTex", "_GroundColor", "_GroundDetectScale", "_GroundNormalY" } },
        // Require はデカール専用プロパティにする（_JackRadius は本体シェーダーにも
        // 追加されたため、それを条件にすると本体側で重複表示されてしまう）
        new Category{ Title = "視界ジャック", Common = false, Require = "_RadiusFit",
            Props = new[]{ "_VisionJackEnable", "_VisionJackInMirror", "_JackRadius", "_JackStretch" } },

        // ---- トレイル版（SpiderThreadTrail）固有 ----
        new Category{ Title = "トレイルの揺れ", Common = false, Require = "_SwayAmount",
            Props = new[]{ "_SwayAmount", "_SwaySpeed", "_SwayWaves", "_SwayAnchor", "_TrailEdgeSoft" } },

        // ---- 蜘蛛の巣版（SpiderWeb）固有 ----
        new Category{ Title = "蜘蛛の巣カスタマイズ(個別)", Common = false, Require = "_WebRadius",
            Props = new[]{ "_HubOffsetX", "_HubOffsetY", "_WebRadius", "_Thickness",
                           "_RadialCount", "_RingCount", "_Sag", "_SpokeExtend",
                           "_Irregular", "_Seed", "_HideBackFibers" } },
        // 足捕縛の変形（Anchor/Target は通常 Udon の MaterialPropertyBlock が上書きする。
        // インスペクタで直接入れれば Udon 無しの見た目確認に使える）
        // 捕縛点・追従先の配列（_PullAnchors/_PullTargets）は MPB 専用でインスペクターに出ない
        new Category{ Title = "接触追従の変形", Common = false, Require = "_PullEnable",
            Props = new[]{ "_PullEnable", "_PullRadius", "_PullFalloff", "_PullStrength",
                           "_PullMaxStretch", "_PullTearFade", "_PullCount" } },
    };

    public override void OnGUI(MaterialEditor materialEditor, MaterialProperty[] properties)
    {
        var map = new Dictionary<string, MaterialProperty>();
        foreach (var p in properties) map[p.name] = p;

        var drawn = new HashSet<string>();

        foreach (var cat in Categories)
        {
            if (cat.Require != null && !map.ContainsKey(cat.Require)) continue;

            // このマテリアルに実在するプロパティだけ集める
            var list = new List<MaterialProperty>();
            foreach (var name in cat.Props)
                if (map.TryGetValue(name, out var mp)) list.Add(mp);
            if (list.Count == 0) continue;

            foreach (var mp in list) drawn.Add(mp.name);

            string label = cat.Title + (cat.Common ? "（共通）" : "（固有）");
            if (DrawSectionFoldout(label, cat.Common))
            {
                EditorGUI.indentLevel++;
                foreach (var mp in list)
                    DrawPropertyNoDecorators(materialEditor, mp);
                EditorGUI.indentLevel--;
                EditorGUILayout.Space(2);
            }
        }

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

    private static void DrawPropertyNoDecorators(MaterialEditor editor, MaterialProperty prop)
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
            catch { _handlerReflectionFailed = true; }
        }

        // フォールバック（[Header] も一緒に描かれる）
        editor.ShaderProperty(prop, prop.displayName);
    }

    // lilToon などと同系の「モジュールタイトル」風フォールドアウト。
    // 開閉状態は EditorPrefs に保存（セッションをまたいで維持）。
    private static GUIStyle _sectionStyle;

    private static bool DrawSectionFoldout(string title, bool common)
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

        string key   = "SpiderCocoonGUI_" + title;
        bool   state = EditorPrefs.GetBool(key, true);

        var rect = GUILayoutUtility.GetRect(16f, 22f, _sectionStyle);
        var prev = GUI.backgroundColor;
        GUI.backgroundColor = common ? new Color(0.70f, 0.88f, 1.00f)   // 共通＝青系
                                     : new Color(1.00f, 0.87f, 0.70f);  // 固有＝オレンジ系
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
