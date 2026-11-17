using UnityEditor;
using UnityEngine;

// =============================================================================
// SpiderSilkNetMaterial — 糸の網（mecaota/SpiderSilkNet）のマテリアルの補助（エディタ専用）。
//
//  ・SyncNet: 絵柄の配列（_BakedShape）から、枚数（_NetSliceCount）と種類（_NetKind。Repeat なら籠目）を入れ、
//    体に沿わせる変形の数値（_DrapeEnable）とキーワード _NET_DRAPE をそろえる。
//    SpiderCocoonShaderGUI.SyncKeywords から呼ばれる（表示したとき・値を変えたとき・シェーダーを切り替えたとき）。
//  ・DrawPanel: 絵柄が未設定のときの説明と、標準の絵柄を入れるボタン。
// =============================================================================
public static class SpiderSilkNetMaterial
{
    public const string DrapeKeyword = "_NET_DRAPE";

    public static bool IsNet(Material m) => m != null && m.shader != null && m.shader.name == SpiderSilkNetBaker.ShaderName;

    // 戻り値: 値かキーワードを変えたら true（呼び出し側で SetDirty する）
    public static bool SyncNet(Material m)
    {
        if (!IsNet(m)) return false;
        bool changed = false;
        var arr = m.HasProperty("_BakedShape") ? m.GetTexture("_BakedShape") as Texture2DArray : null;
        float count = arr != null ? arr.depth : 0f;
        float kind = arr != null && arr.wrapModeU != TextureWrapMode.Repeat ? 1f : 0f;
        if (!Mathf.Approximately(m.GetFloat("_NetSliceCount"), count)) { m.SetFloat("_NetSliceCount", count); changed = true; }
        if (arr != null && !Mathf.Approximately(m.GetFloat("_NetKind"), kind)) { m.SetFloat("_NetKind", kind); changed = true; }
        if (arr != null)
        {
            // 1 枚の画素数（ミップの段と陰の帯の幅に使う）
            var range = m.GetVector("_NetBakeRange");
            bool rangeChanged = false;
            if (!Mathf.Approximately(range.w, arr.width)) { range.w = arr.width; rangeChanged = true; }
            // 形の画像の G を焼いた膜の量（同じフォルダの JSON の closedFill）
            float closed = ReadClosedFill(arr);
            if (closed > 0f && !Mathf.Approximately(range.y, closed)) { range.y = closed; rangeChanged = true; }
            if (rangeChanged) { m.SetVector("_NetBakeRange", range); changed = true; }
        }
        bool drape = m.GetFloat("_DrapeEnable") > 0.5f;
        if (m.IsKeywordEnabled(DrapeKeyword) != drape)
        {
            if (drape) m.EnableKeyword(DrapeKeyword); else m.DisableKeyword(DrapeKeyword);
            changed = true;
        }
        return changed;
    }

    // 配列の PNG と同じ名前の JSON（…_Shape.png → ….json）から closedFill を読む。読めなければ 0
    static float ReadClosedFill(Texture2DArray arr)
    {
        string path = AssetDatabase.GetAssetPath(arr);
        if (string.IsNullOrEmpty(path) || !path.EndsWith("_Shape.png", System.StringComparison.Ordinal)) return 0f;
        try
        {
            string json = System.IO.File.ReadAllText(FileUtil.GetPhysicalPath(path.Substring(0, path.Length - "_Shape.png".Length) + ".json"));
            var mt = System.Text.RegularExpressions.Regex.Match(json, @"""closedFill""\s*:\s*([0-9.]+)");
            return mt.Success ? float.Parse(mt.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture) : 0f;
        }
        catch (System.Exception) { return 0f; }
    }

    public static void DrawPanel(MaterialEditor editor)
    {
        var m = editor.target as Material;
        if (!IsNet(m)) return;
        if (!SpiderCocoonShaderGUI.DrawSectionFoldout("糸の網の絵柄の状態", new Color(0.80f, 0.92f, 0.70f))) return;
        if (m.GetFloat("_NetSliceCount") < 0.5f)
            EditorGUILayout.HelpBox("絵柄の配列（形・補助・被覆率）が未設定なので、何も描かれません。下のボタンで標準の絵柄を入れてください。", MessageType.Warning);
        else
            EditorGUILayout.HelpBox((m.GetFloat("_NetKind") < 0.5f ? "籠目（上下左右につながる。並べる回数は整数）" : "張り巣（板 1 枚）") +
                "、" + m.GetFloat("_NetSliceCount") + " 枚。種類と枚数は配列から自動で入ります。", MessageType.Info);
        EditorGUILayout.HelpBox("籠は裏側の描き方と「籠の半分の大きさ」（カメラが中にいるかの判定）を、メッシュに合わせて設定します。張り巣の板は裏側を「表と同じ」にします。\nスクリプトで _DrapeEnable を書いたときは SpiderCocoonShaderGUI.SyncKeywords を呼んでキーワード _NET_DRAPE をそろえてください。", MessageType.None);
        string folder = SpiderSilkNetBaker.PatternFolder();
        using (new EditorGUILayout.HorizontalScope())
        {
            if (GUILayout.Button("標準の籠目を入れる")) Assign(editor, folder, SpiderSilkNetBaker.CageBaseName);
            if (GUILayout.Button("標準の張り巣を入れる")) Assign(editor, folder, SpiderSilkNetBaker.WebBaseName);
            if (GUILayout.Button("ドレープ用の板を入れる")) Assign(editor, folder, SpiderSilkNetBaker.DrapeBaseName);
        }
    }

    static void Assign(MaterialEditor editor, string folder, string baseName)
    {
        if (folder == null) return;
        var shape = AssetDatabase.LoadAssetAtPath<Texture2DArray>(folder + "/" + baseName + "_Shape.png");
        var detail = AssetDatabase.LoadAssetAtPath<Texture2DArray>(folder + "/" + baseName + "_Detail.png");
        var cover = AssetDatabase.LoadAssetAtPath<Texture2DArray>(folder + "/" + baseName + "_Coverage.png");
        if (shape == null || detail == null || cover == null)
        {
            EditorUtility.DisplayDialog("糸の網", baseName + " の配列が見つかりません。取り込み設定（2D Array）を確かめるか、Tools/SpiderShader/糸の網/絵柄を焼き直す を実行してください。", "OK");
            return;
        }
        foreach (Object t in editor.targets)
        {
            if (!(t is Material m) || !IsNet(m)) continue;
            Undo.RecordObject(m, "糸の網の絵柄を入れる");
            m.SetTexture("_BakedShape", shape);
            m.SetTexture("_BakedDetail", detail);
            m.SetTexture("_BakedCoverage", cover);
            SyncNet(m);
            EditorUtility.SetDirty(m);
        }
    }
}
