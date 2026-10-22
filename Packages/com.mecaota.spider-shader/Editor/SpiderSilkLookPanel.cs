using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;

// =============================================================================
// インスペクタの「蜘蛛糸の質感（継承）」欄（紫系）。
//  ・巣・繭・繭デカール（継承先）: 継承元の蜘蛛糸マテリアルを選ぶ欄と状態の説明。
//    継承している値は読み取り専用で表示する（変えるときは継承元を編集する）。
//  ・蜘蛛糸（継承元）: この質感を継承しているマテリアルの一覧。
// =============================================================================
internal static class SpiderSilkLookPanel
{
    internal static readonly Color LookColor = new Color(0.86f, 0.80f, 1.00f);   // 質感＝紫系
    const string PrefShowValues = "SpiderSilkLook_ShowInheritedValues";
    const string PrefShowDeps   = "SpiderSilkLook_ShowDependents";

    // ---- 継承先（蜘蛛の巣・繭・繭デカール） ----
    public static void DrawInheritor(MaterialEditor editor, Dictionary<string, MaterialProperty> map)
    {
        var mats = Targets(editor, SpiderSilkLook.Role.Inheritor);
        if (mats.Count == 0) return;
        if (!SpiderCocoonShaderGUI.DrawSectionFoldout("蜘蛛糸の質感（継承）", LookColor)) { EditorGUILayout.Space(2); return; }

        var first = mats[0];
        var link  = SpiderSilkLook.GetLink(first);
        bool mixed = false;
        var v0 = first.GetVector(SpiderSilkLook.LinkProperty);
        foreach (var m in mats) if (m.GetVector(SpiderSilkLook.LinkProperty) != v0) mixed = true;
        bool locked = false;
        foreach (var m in mats) if (m.IsPropertyLockedByAncestor(SpiderSilkLook.LinkProperty)) locked = true;

        using (new EditorGUI.DisabledScope(locked || EditorApplication.isPlayingOrWillChangePlaymode))
        {
            EditorGUILayout.BeginHorizontal();
            EditorGUI.showMixedValue = mixed;
            EditorGUI.BeginChangeCheck();
            var picked = (Material)EditorGUILayout.ObjectField(
                new GUIContent("継承元の蜘蛛糸", "質感（色・陰影・ツヤ・トゥーン・リム）をもらう蜘蛛糸のマテリアル。なし＝蜘蛛糸シェーダーの既定値"),
                link.Source, typeof(Material), false);
            bool changed = EditorGUI.EndChangeCheck();
            EditorGUI.showMixedValue = false;
            if (GUILayout.Button(new GUIContent("▼", "プロジェクト内の蜘蛛糸マテリアルから選ぶ"), EditorStyles.miniButton, GUILayout.Width(24f)))
                ShowSourceMenu(mats);
            EditorGUILayout.EndHorizontal();
            if (changed) Pick(mats, picked);
        }

        if (link.Source != null && !mixed)
        {
            EditorGUILayout.BeginHorizontal();
            GUILayout.FlexibleSpace();
            if (GUILayout.Button(new GUIContent("継承元を開く", "継承元の蜘蛛糸マテリアルを別ウィンドウで開く（質感はそこで変える）"), EditorStyles.miniButtonLeft, GUILayout.Width(100f)))
                EditorUtility.OpenPropertyEditor(link.Source);
            if (GUILayout.Button(new GUIContent("場所", "プロジェクトウィンドウで継承元を示す"), EditorStyles.miniButtonRight, GUILayout.Width(48f)))
                EditorGUIUtility.PingObject(link.Source);
            EditorGUILayout.EndHorizontal();
        }

        // 状態の説明
        if (mixed)
            EditorGUILayout.HelpBox("選んでいるマテリアルの継承元がばらばらです。ここで選ぶと全部に同じ継承元が入ります。", MessageType.None);
        else if (link.State == SpiderSilkLook.LinkState.Broken)
            EditorGUILayout.HelpBox(link.Detail + "\n値は最後の状態のまま止まっています。継承元を選び直してください。", MessageType.Warning);
        else if (link.State == SpiderSilkLook.LinkState.Linked)
        {
            string msg = "「" + link.Source.name + "」の質感を継承しています。紫の項目はこのマテリアルでは変えられません（継承元を編集すると自動で反映）。";
            if (link.FromParent && first.parent != null) msg += "\n継承元は親マテリアル「" + first.parent.name + "」から受け継いでいます。";
            if (link.Source.HasProperty("_GooEnable") && link.Source.GetFloat("_GooEnable") < 0.5f)
                msg += "\n※ 継承元は粘液モード OFF ですが、巣・繭・繭デカールは粘液の塗りで描かれるので、粘液の色・ツヤの値がそのまま使われます。";
            EditorGUILayout.HelpBox(msg, MessageType.None);
        }
        else
            EditorGUILayout.HelpBox("継承元なし: 質感は蜘蛛糸シェーダーの既定値になります（このマテリアルでは変えられません）。", MessageType.None);
        if (locked)
            EditorGUILayout.HelpBox("親マテリアルで継承元がロックされているため変更できません。", MessageType.None);
        if (EditorApplication.isPlayingOrWillChangePlaymode)
            EditorGUILayout.HelpBox("Play 中は継承の同期を止めています。", MessageType.None);
        else if (!mixed && link.State != SpiderSilkLook.LinkState.Broken && !SpiderSilkLook.IsInSync(first))
        {
            if (SpiderSilkLookAutoSync.IsHeld(first))
                EditorGUILayout.HelpBox("継承元の記録が想定外の方法で変わったため、質感の自動同期を止めています（今の値を保っています）。" +
                                        "意図した変更なら上の欄で継承元を選び直してください。元に戻すなら Ctrl+Z。", MessageType.Warning);
            else if (!SpiderSilkLook.IsEditable(first))
                EditorGUILayout.HelpBox("書き込めないマテリアル（読み取り専用パッケージ・VCS のロックなど）なので、質感を同期できません。", MessageType.Warning);
            else if (LockedLook(first))
                EditorGUILayout.HelpBox("質感の項目が親マテリアルでロックされているため、同期できない値があります。", MessageType.Warning);
            else if (!SpiderSilkLook.AutoSyncReaches(first))
                EditorGUILayout.HelpBox("このマテリアルか Variant の親が Assets フォルダの外にあるので、自動では同期しません。" +
                                        "メニュー「Tools/SpiderShader/質感の継承を同期」で合わせられます。", MessageType.None);
            else
                EditorGUILayout.LabelField("（継承元と値がずれています。まもなく同期されます）", EditorStyles.miniLabel);
        }

        // 継承元なしで既定値にそろえたマテリアル: そろえる前の質感で継承元を作り直せる
        if (!mixed && mats.Count == 1 && link.State == SpiderSilkLook.LinkState.None &&
            SpiderSilkLook.TryGetPreResetValues(first, out var preReset))
        {
            EditorGUILayout.HelpBox("このマテリアルは継承元が無かったため、質感を蜘蛛糸シェーダーの既定値にそろえました。" +
                                    "前の見た目に戻すには、そろえる前の質感で継承元を作ります。", MessageType.Info);
            EditorGUILayout.BeginHorizontal();
            GUILayout.FlexibleSpace();
            if (GUILayout.Button("そろえる前の質感で継承元を作る…", GUILayout.Width(230f)))
            {
                CreateSource(first, link, preReset);
                GUIUtility.ExitGUI();
            }
            EditorGUILayout.EndHorizontal();
        }

        EditorGUILayout.BeginHorizontal();
        GUILayout.FlexibleSpace();
        using (new EditorGUI.DisabledScope(mats.Count != 1 || EditorApplication.isPlayingOrWillChangePlaymode))
        {
            if (GUILayout.Button(new GUIContent("今の質感から新しい継承元を作る…",
                    "このマテリアルの今の質感を持つ蜘蛛糸マテリアルを作り、継承元にする（見た目は変わらない）。\n" +
                    "今の継承元があれば、その Material Variant として作る"), GUILayout.Width(230f)))
            {
                CreateSource(first, link, null);
                GUIUtility.ExitGUI();   // 保存ダイアログ（モーダル）の後は、この回の描画を打ち切る
            }
        }
        EditorGUILayout.EndHorizontal();

        // 継承している値（読み取り専用）
        bool show = EditorPrefs.GetBool(PrefShowValues, false);
        bool next = EditorGUILayout.Foldout(show, "継承している値を見る（変更不可）", true);
        if (next != show) EditorPrefs.SetBool(PrefShowValues, next);
        if (next)
        {
            using (new EditorGUI.DisabledScope(true))
            {
                EditorGUI.indentLevel++;
                string group = null;
                foreach (var p in SpiderSilkLook.Props)
                {
                    if (p.Group != group) { group = p.Group; EditorGUILayout.LabelField(group, EditorStyles.miniBoldLabel); }
                    if (map.TryGetValue(p.Name, out var mp)) SpiderCocoonShaderGUI.DrawPropertyNoDecorators(editor, mp);
                }
                EditorGUI.indentLevel--;
            }
        }
        EditorGUILayout.Space(4);
    }

    static void Pick(List<Material> mats, Material picked)
    {
        if (!SpiderSilkLook.TryValidateSource(picked, out var reason))
        {
            Debug.LogWarning("[蜘蛛糸の質感] " + reason);
            EditorWindow.focusedWindow?.ShowNotification(new GUIContent(reason));
            return;
        }
        if (!SpiderSilkLook.SetSource(mats, picked))
            EditorWindow.focusedWindow?.ShowNotification(new GUIContent("継承元を設定できませんでした（Console を見てください）"));
    }

    static bool LockedLook(Material m)
    {
        foreach (var p in SpiderSilkLook.Props) if (m.IsPropertyLockedByAncestor(p.Name)) return true;
        return false;
    }

    static void ShowSourceMenu(List<Material> mats)
    {
        var menu = new GenericMenu();
        var cur = SpiderSilkLook.GetLink(mats[0]).Source;
        menu.AddItem(new GUIContent("なし（蜘蛛糸シェーダーの既定値）"), cur == null, () => SpiderSilkLook.SetSource(mats, null));
        menu.AddSeparator("");
        foreach (var s in SpiderSilkLookIndex.Sources)
        {
            var src = s;
            string label = AssetDatabase.GetAssetPath(src).Replace("Assets/", "").Replace(".mat", "");
            menu.AddItem(new GUIContent(label.Replace("/", "／")), src == cur, () => SpiderSilkLook.SetSource(mats, src));
        }
        menu.ShowAsContext();
    }

    // values が null なら今の質感、あれば（既定値にそろえる前の値など）その値で継承元を作る
    static void CreateSource(Material m, SpiderSilkLook.LinkInfo link, Vector4[] values)
    {
        string dir = Path.GetDirectoryName(AssetDatabase.GetAssetPath(link.Source != null ? link.Source : m)).Replace(Path.DirectorySeparatorChar, '/');
        string unique = AssetDatabase.GenerateUniqueAssetPath(dir + "/" + m.name + "_SilkLook.mat");
        string path = EditorUtility.SaveFilePanelInProject("新しい継承元（蜘蛛糸マテリアル）を作る", Path.GetFileNameWithoutExtension(unique), "mat",
            "質感を持つ蜘蛛糸マテリアルの保存先を選んでください（既にあるファイルは選べません）", dir);
        if (string.IsNullOrEmpty(path)) return;
        if (AssetDatabase.LoadMainAssetAtPath(path) != null)
        {
            EditorUtility.DisplayDialog("新しい継承元を作る",
                "同じ名前のアセットがあります。上書きするとそのアセットを使っている参照や継承が切れるので、別の名前で保存してください。", "OK");
            return;
        }
        var template = link.State == SpiderSilkLook.LinkState.Linked ? link.Source : null;
        var src = values != null ? SpiderSilkLook.CreateSourceFromValues(values, path, template)
                                 : SpiderSilkLook.CreateSourceFromLook(m, path, template);
        if (src == null) return;
        SpiderSilkLook.SetSource(new[] { m }, src);
        if (values != null) SpiderSilkLook.ForgetPreResetValues(m);
        EditorGUIUtility.PingObject(src);
    }

    // ---- 継承元（蜘蛛糸） ----
    public static void DrawSourceSummary(MaterialEditor editor)
    {
        var mats = Targets(editor, SpiderSilkLook.Role.Source);
        if (mats.Count == 0) return;
        var deps = new List<Material>();
        var variants = new List<Material>();
        foreach (var m in mats)
        {
            foreach (var d in SpiderSilkLookIndex.DependentsOf(m)) if (!deps.Contains(d)) deps.Add(d);
            foreach (var v in SpiderSilkLookIndex.SourceVariantsOf(m)) if (!variants.Contains(v)) variants.Add(v);
        }
        if (deps.Count == 0 && variants.Count == 0) return;

        if (!SpiderCocoonShaderGUI.DrawSectionFoldout("この質感を継承しているマテリアル（" + deps.Count + " 個）", LookColor, "SilkLookDependents")) { EditorGUILayout.Space(2); return; }
        EditorGUILayout.HelpBox("紫の「質感」の項目を変えると、継承している " + deps.Count + " 個の巣・繭・繭デカールにすぐ反映されます（Ctrl+Z も連動）。" +
                                (variants.Count > 0 ? "\nこのマテリアルを親にする継承元（Material Variant）が " + variants.Count + " 個あり、その先にも伝わります。" : ""),
                                MessageType.None);
        if (mats[0].HasProperty("_GooEnable") && mats[0].GetFloat("_GooEnable") < 0.5f && deps.Count > 0)
            EditorGUILayout.HelpBox("粘液モードが OFF ですが、巣・繭・繭デカールは粘液の塗りで描かれるので、粘液の色・ツヤの値も反映されます。", MessageType.None);

        bool show = EditorPrefs.GetBool(PrefShowDeps, false);
        bool next = EditorGUILayout.Foldout(show, "一覧", true);
        if (next != show) EditorPrefs.SetBool(PrefShowDeps, next);
        if (next)
        {
            foreach (var d in deps) Row(d);
            if (variants.Count > 0)
            {
                EditorGUILayout.LabelField("継承元の Variant", EditorStyles.miniBoldLabel);
                foreach (var v in variants) Row(v);
            }
            EditorGUILayout.BeginHorizontal();
            GUILayout.FlexibleSpace();
            if (GUILayout.Button("まとめて選択", EditorStyles.miniButton, GUILayout.Width(100f)))
                Selection.objects = deps.ToArray();
            EditorGUILayout.EndHorizontal();
        }
        EditorGUILayout.Space(4);
    }

    static void Row(Material m)
    {
        EditorGUILayout.BeginHorizontal();
        using (new EditorGUI.DisabledScope(true)) EditorGUILayout.ObjectField(m, typeof(Material), false);
        if (GUILayout.Button("場所", EditorStyles.miniButton, GUILayout.Width(40f))) EditorGUIUtility.PingObject(m);
        EditorGUILayout.EndHorizontal();
    }

    static List<Material> Targets(MaterialEditor editor, SpiderSilkLook.Role role)
    {
        var list = new List<Material>();
        foreach (var t in editor.targets)
            if (t is Material m && SpiderSilkLook.GetRole(m.shader) == role) list.Add(m);
        return list;
    }
}
