using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;
using PresetPart = SpiderCocoonShaderGUI.PresetPart;

// =============================================================================
// マテリアルのインスペクタ先頭に出す「プリセット」欄（lilToon のプリセット欄と同じ役割）。
//
//  ・同じシェーダーのプリセットがカテゴリごとにボタンで並ぶ。クリックで適用。
//    今のマテリアルと値が全部一致するプリセットは緑色の太字になる。
//  ・右クリックで「プロジェクトで表示」「このマテリアルの値で上書き保存」。
//  ・「巣の形・配置」「変形ギミック」のチェックを外すと、その区分は今の値を残す
//    （例: 木の扇形の巣に、投げ網の質感だけを入れたいとき）。
//  ・「今の設定をプリセットとして保存…」で SpiderShaderPresetSaveWindow を開く。
// =============================================================================
internal static class SpiderShaderPresetPanel
{
    private const string PrefApplyShape   = "SpiderShaderPreset_ApplyShape";
    private const string PrefApplyGimmick = "SpiderShaderPreset_ApplyGimmick";

    private static readonly Color PresetColor = new Color(0.74f, 0.95f, 0.72f);  // プリセット欄＝緑系
    private static readonly Color MatchColor  = new Color(0.55f, 1.00f, 0.55f);

    private static GUIStyle _matchStyle;

    public static void Draw(MaterialEditor editor)
    {
        var materials = new List<Material>();
        foreach (var t in editor.targets)
            if (t is Material m) materials.Add(m);
        if (materials.Count == 0) return;
        var shader = materials[0].shader;

        if (!SpiderCocoonShaderGUI.DrawSectionFoldout("プリセット", PresetColor))
        {
            EditorGUILayout.Space(2);
            return;
        }

        var presets = SpiderShaderPresetLibrary.For(shader);
        // 継承元の蜘蛛糸に当てると、継承している巣・繭・デカール・ねばねばネットにも伝わることを知らせる
        if (SpiderSilkLook.GetRole(shader) == SpiderSilkLook.Role.Source && materials.Count == 1)
        {
            int deps = SpiderSilkLookIndex.DependentsOf(materials[0]).Count;
            if (deps > 0)
                EditorGUILayout.HelpBox("このマテリアルは " + deps + " 個の巣・繭・デカール・ねばねばネットの質感の継承元です。プリセットを当てると質感がそれらにも反映されます。", MessageType.Info);
        }
        else if (SpiderSilkLook.GetRole(shader) == SpiderSilkLook.Role.Inheritor)
            EditorGUILayout.HelpBox("質感（色・陰影・ツヤ・トゥーン・リム）は継承元の蜘蛛糸で決まるので、プリセットでは形などだけが変わります。", MessageType.None);
        if (presets.Count == 0)
        {
            EditorGUILayout.HelpBox(
                "このシェーダーのプリセットはまだありません。下のボタンで今の設定を保存できます。",
                MessageType.None);
        }
        else
        {
            bool applyShape   = EditorPrefs.GetBool(PrefApplyShape, true);
            bool applyGimmick = EditorPrefs.GetBool(PrefApplyGimmick, true);
            var  single       = materials.Count == 1 ? materials[0] : null;

            int   columns = EditorGUIUtility.currentViewWidth > 380f ? 2 : 1;
            float width   = (EditorGUIUtility.currentViewWidth - 52f - 4f * (columns - 1)) / columns;

            string currentCategory = null;
            int    column          = 0;
            bool   rowOpen         = false;
            foreach (var p in presets)
            {
                string cat = string.IsNullOrEmpty(p.category) ? "その他" : p.category;
                if (cat != currentCategory)
                {
                    if (rowOpen) EditorGUILayout.EndHorizontal();
                    rowOpen = false;
                    column  = 0;
                    currentCategory = cat;
                    EditorGUILayout.LabelField(cat, EditorStyles.miniBoldLabel);
                }
                if (column == 0)
                {
                    EditorGUILayout.BeginHorizontal();
                    GUILayout.Space(14f);
                    rowOpen = true;
                }

                if (DrawPresetButton(p, single, width))
                {
                    p.Apply(materials, applyShape, applyGimmick);
                    editor.PropertiesChanged();
                    GUIUtility.ExitGUI();  // 値が変わったので、この回の描画は打ち切って描き直す
                }

                if (++column >= columns)
                {
                    EditorGUILayout.EndHorizontal();
                    rowOpen = false;
                    column  = 0;
                }
            }
            if (rowOpen) EditorGUILayout.EndHorizontal();

            // 適用範囲（このシェーダーのプリセットに該当する区分があるときだけ出す）
            bool anyShape = false, anyGimmick = false;
            foreach (var p in presets)
            {
                anyShape   |= p.HasPart(PresetPart.Shape);
                anyGimmick |= p.HasPart(PresetPart.Gimmick);
            }
            if (anyShape || anyGimmick) EditorGUILayout.Space(2);
            if (anyShape)
                DrawPrefToggle(PrefApplyShape, applyShape, new GUIContent(
                    "巣の形・配置（個別）も上書きする",
                    "OFF にすると「蜘蛛の巣カスタマイズ(個別)」「扇形の巣」は今の値を残す。\n" +
                    "メッシュ（平面 / 木の扇形）に合わせた形を保ったまま質感だけ入れたいときに使う"));
            if (anyGimmick)
                DrawPrefToggle(PrefApplyGimmick, applyGimmick, new GUIContent(
                    "変形ギミック（接触追従・覆いかぶさり）も上書きする",
                    "OFF にすると「接触追従の変形」「体に覆いかぶさる変形」は今の値を残す。\n" +
                    "Udon の仕掛けと組で使う設定なので、既存の巣の見た目だけ変えたいときは OFF に"));
        }

        EditorGUILayout.BeginHorizontal();
        GUILayout.FlexibleSpace();
        using (new EditorGUI.DisabledScope(materials.Count != 1))
        {
            if (GUILayout.Button(new GUIContent("今の設定をプリセットとして保存…",
                    "このマテリアルの値を新しいプリセットアセットとして保存する（マテリアルを 1 つだけ選んでいるとき）"),
                    GUILayout.Width(230f)))
                SpiderShaderPresetSaveWindow.Open(materials[0]);
        }
        EditorGUILayout.EndHorizontal();
        EditorGUILayout.Space(6);
    }

    // true = クリックされた（適用する）
    private static bool DrawPresetButton(SpiderShaderPreset p, Material single, float width)
    {
        bool match = single != null && p.Matches(single);
        string tip = (string.IsNullOrEmpty(p.description) ? "" : p.description + "\n\n") +
                     (match ? "（今のマテリアルはこのプリセットと同じ値）\n" : "") +
                     "クリック: 適用（Ctrl+Z で戻せる） / 右クリック: 表示・上書き保存";
        var content = new GUIContent(p.Label, tip);

        if (_matchStyle == null)
            _matchStyle = new GUIStyle(GUI.skin.button) { fontStyle = FontStyle.Bold };
        var style = match ? _matchStyle : GUI.skin.button;

        var rect = GUILayoutUtility.GetRect(content, style, GUILayout.Width(width), GUILayout.Height(20f));
        var e = Event.current;
        if (((e.type == EventType.MouseDown && e.button == 1) || e.type == EventType.ContextClick) &&
            rect.Contains(e.mousePosition))
        {
            if (e.type == EventType.MouseDown) ShowContextMenu(p, single);
            e.Use();
            return false;
        }

        var prev = GUI.backgroundColor;
        if (match) GUI.backgroundColor = MatchColor;
        bool clicked = GUI.Button(rect, content, style);
        GUI.backgroundColor = prev;
        return clicked;
    }

    private static void ShowContextMenu(SpiderShaderPreset p, Material single)
    {
        var menu = new GenericMenu();
        menu.AddItem(new GUIContent("プロジェクトで表示"), false, () => EditorGUIUtility.PingObject(p));
        menu.AddItem(new GUIContent("プリセットを選択（名前・説明を編集）"), false, () => Selection.activeObject = p);
        menu.AddSeparator("");
        if (single != null)
            menu.AddItem(new GUIContent("このマテリアルの値で上書き保存"), false, () => Overwrite(p, single));
        else
            menu.AddDisabledItem(new GUIContent("このマテリアルの値で上書き保存"));
        menu.ShowAsContext();
    }

    // 保存するグループは今のプリセットと同じ（シェーダーに足された新しい値も一緒に入る）
    private static void Overwrite(SpiderShaderPreset p, Material source)
    {
        // 同梱の標準プリセットは、パッケージを更新すると元に戻るので別名保存をすすめる
        if (AssetDatabase.GetAssetPath(p).StartsWith(SpiderShaderPresetLibrary.StandardFolder + "/", System.StringComparison.Ordinal))
        {
            int choice = EditorUtility.DisplayDialogComplex("標準プリセットの上書き",
                $"「{p.Label}」はパッケージに同梱の標準プリセットです。\n" +
                "上書きしても、パッケージを更新すると元に戻ります。\n" +
                "自分用のプリセットとして別名で保存しますか？",
                "別名で保存…", "キャンセル", "それでも上書き");
            if (choice == 0) SpiderShaderPresetSaveWindow.Open(source, p);
            if (choice != 2) return;
        }
        else if (!EditorUtility.DisplayDialog("プリセットの上書き",
                $"「{p.Label}」を、マテリアル「{source.name}」の今の値で上書きします。\n" +
                "保存する項目は今のプリセットと同じです。",
                "上書き", "キャンセル"))
            return;

        var groups = p.StoredGroups();
        Undo.RecordObject(p, "プリセット上書き: " + p.Label);
        p.Capture(source, groups.Contains);
        EditorUtility.SetDirty(p);
        AssetDatabase.SaveAssetIfDirty(p);
    }

    private static void DrawPrefToggle(string key, bool value, GUIContent label)
    {
        EditorGUILayout.BeginHorizontal();
        GUILayout.Space(14f);
        bool next = EditorGUILayout.ToggleLeft(label, value);
        EditorGUILayout.EndHorizontal();
        if (next != value) EditorPrefs.SetBool(key, next);
    }
}

// =============================================================================
// 「今の設定をプリセットとして保存…」のウィンドウ。
// 保存する項目はインスペクタのカテゴリ単位で選ぶ（lilToon の保存画面と同じ考え方）。
// =============================================================================
internal class SpiderShaderPresetSaveWindow : EditorWindow
{
    private const string PrefLastFolder = "SpiderShaderPreset_LastFolder";

    [SerializeField] private Material     _source;
    [SerializeField] private string       _displayName = "";
    [SerializeField] private string       _category    = "";
    [SerializeField] private string       _description = "";
    [SerializeField] private List<string> _excluded    = new List<string>();
    private Vector2 _scroll;

    // from を渡すと、その名前・カテゴリ・説明と保存する項目を引き継ぐ（標準プリセットの別名保存）
    public static void Open(Material source, SpiderShaderPreset from = null)
    {
        var w = CreateInstance<SpiderShaderPresetSaveWindow>();
        w.titleContent = new GUIContent("プリセットを保存");
        w._source      = source;
        w._displayName = source.name;
        if (from != null)
        {
            w._displayName = from.Label + "（自分用）";   // 標準プリセットと同じ名前のボタンが並ばないように
            w._category    = from.category ?? "";
            w._description = from.description ?? "";
            var stored = from.StoredGroups();
            foreach (var g in SpiderCocoonShaderGUI.GetPresetGroups(source.shader))
                if (!stored.Contains(g.Title)) w._excluded.Add(g.Title);
        }
        w.minSize      = new Vector2(380f, 460f);
        w.ShowUtility();
    }

    private void OnGUI()
    {
        if (_source == null || _source.shader == null)
        {
            EditorGUILayout.HelpBox("元のマテリアルが見つかりません。ウィンドウを閉じて開き直してください。", MessageType.Warning);
            return;
        }

        using (new EditorGUI.DisabledScope(true))
        {
            EditorGUILayout.ObjectField("元のマテリアル", _source, typeof(Material), false);
            EditorGUILayout.TextField("シェーダー", _source.shader.name);
        }
        EditorGUILayout.Space();

        _displayName = EditorGUILayout.TextField("表示名", _displayName);

        EditorGUILayout.BeginHorizontal();
        _category = EditorGUILayout.TextField("カテゴリ", _category);
        var categories = ExistingCategories(_source.shader);
        using (new EditorGUI.DisabledScope(categories.Count == 0))
        {
            if (GUILayout.Button(new GUIContent("既存…", "このシェーダーのプリセットで使っているカテゴリから選ぶ"),
                    EditorStyles.miniButton, GUILayout.Width(48f)))
            {
                var menu = new GenericMenu();
                foreach (var c in categories)
                {
                    string picked = c;
                    menu.AddItem(new GUIContent(c), c == _category, () => { _category = picked; Repaint(); });
                }
                menu.ShowAsContext();
            }
        }
        EditorGUILayout.EndHorizontal();

        EditorGUILayout.LabelField("説明（ボタンのツールチップ）");
        _description = EditorGUILayout.TextArea(_description, GUILayout.MinHeight(48f));

        EditorGUILayout.Space();
        EditorGUILayout.LabelField("保存する項目", EditorStyles.boldLabel);
        var groups = SpiderCocoonShaderGUI.GetPresetGroups(_source.shader);

        EditorGUILayout.BeginHorizontal();
        if (GUILayout.Button("すべて", EditorStyles.miniButtonLeft)) _excluded.Clear();
        if (GUILayout.Button(new GUIContent("見た目だけ", "巣の形・配置と変形ギミックを外す"), EditorStyles.miniButtonMid))
        {
            _excluded.Clear();
            foreach (var g in groups)
                if (g.Part != PresetPart.Look) _excluded.Add(g.Title);
        }
        if (GUILayout.Button("なし", EditorStyles.miniButtonRight))
        {
            _excluded.Clear();
            foreach (var g in groups) _excluded.Add(g.Title);
        }
        EditorGUILayout.EndHorizontal();

        _scroll = EditorGUILayout.BeginScrollView(_scroll);
        foreach (var g in groups)
        {
            string tag = g.Part == PresetPart.Shape   ? "　［形・配置］"
                       : g.Part == PresetPart.Gimmick ? "　［変形ギミック］" : "";
            bool on   = !_excluded.Contains(g.Title);
            bool next = EditorGUILayout.ToggleLeft($"{g.Title}（{g.Props.Count}）{tag}", on);
            if (next != on)
            {
                if (next) _excluded.Remove(g.Title);
                else      _excluded.Add(g.Title);
            }
        }
        EditorGUILayout.EndScrollView();

        EditorGUILayout.Space();
        bool nothing = groups.TrueForAll(g => _excluded.Contains(g.Title));
        using (new EditorGUI.DisabledScope(string.IsNullOrWhiteSpace(_displayName) || nothing))
        {
            if (GUILayout.Button("保存先を選んで保存…", GUILayout.Height(28f)))
            {
                Save();
                GUIUtility.ExitGUI();   // 保存ダイアログ（モーダル）・Close の後は、この回の描画を打ち切る
            }
        }
        EditorGUILayout.Space(4);
    }

    private void Save()
    {
        string folder = EditorPrefs.GetString(PrefLastFolder, "Assets");
        if (!AssetDatabase.IsValidFolder(folder)) folder = "Assets";

        string path = EditorUtility.SaveFilePanelInProject("プリセットを保存",
            SafeFileName(_displayName.Trim()), "asset", "プリセットの保存先を選んでください", folder);
        if (string.IsNullOrEmpty(path)) return;

        var  preset = AssetDatabase.LoadAssetAtPath<SpiderShaderPreset>(path);
        bool isNew  = preset == null;
        if (isNew && AssetDatabase.LoadMainAssetAtPath(path) != null)
        {
            EditorUtility.DisplayDialog("プリセットを保存", "同じ名前の別の種類のアセットがあります。別の名前で保存してください。", "OK");
            return;
        }

        if (isNew) preset = CreateInstance<SpiderShaderPreset>();
        else       Undo.RecordObject(preset, "プリセット上書き: " + preset.Label);

        preset.displayName = _displayName.Trim();
        preset.category    = _category.Trim();
        preset.description = _description;
        preset.Capture(_source, g => !_excluded.Contains(g));

        if (isNew) AssetDatabase.CreateAsset(preset, path);
        else       EditorUtility.SetDirty(preset);
        AssetDatabase.SaveAssetIfDirty(preset);   // ほかの未保存アセットまで保存しない

        EditorPrefs.SetString(PrefLastFolder, Path.GetDirectoryName(path).Replace('\\', '/'));
        SpiderShaderPresetLibrary.Invalidate();
        EditorGUIUtility.PingObject(preset);
        Close();
    }

    private static List<string> ExistingCategories(Shader shader)
    {
        var list = new List<string>();
        foreach (var p in SpiderShaderPresetLibrary.For(shader))
            if (!string.IsNullOrEmpty(p.category) && !list.Contains(p.category))
                list.Add(p.category);
        return list;
    }

    private static string SafeFileName(string s)
    {
        foreach (char c in Path.GetInvalidFileNameChars()) s = s.Replace(c, '_');
        return string.IsNullOrEmpty(s) ? "SpiderPreset" : s;
    }
}
