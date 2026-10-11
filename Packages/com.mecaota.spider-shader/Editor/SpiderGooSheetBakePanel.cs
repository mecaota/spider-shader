using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;

/// <summary>既存 ShaderGUI から呼ぶ、ねばねばネット（粘液シート）の焼き込み状態と明示的な再生成ボタン。</summary>
internal static class SpiderGooSheetBakePanel
{
    public static void Draw(MaterialEditor editor)
    {
        var material = editor.target as Material;
        if (!SpiderGooSheetBaker.IsBaked(material)) return;
        if (!SpiderCocoonShaderGUI.DrawSectionFoldout("焼き込みの状態", new Color(0.80f, 0.92f, 0.70f))) return;
        EditorGUILayout.HelpBox("帯の幅・向き・沿った長さ、帯の中の形（束・玉・膜・蛇行）、模様のずれ、膜の外形の半径を変えたら焼き直してください。質感の「粘液感」も形を変えます。色・光沢・全層の厚さ・回転・層数・層ごとの太さは焼き直し不要です。", MessageType.Info);
        EditorGUILayout.HelpBox("吐いた糸の粘液の帯をすき間なく並べた模様を焼き、層ごとに少し回転・ずらして重ねます。Pull による変形と Drape（体に覆いかぶさる変形）はそのまま使えます。", MessageType.None);
        EditorGUILayout.HelpBox("圧縮は BC5（距離・半径）＋BC7（補助）。被覆率は両モードとも R8 です。切り替え後に焼き直すと別の配列を生成します。", MessageType.Info);
        bool allCurrent = true;
        foreach (UnityEngine.Object target in editor.targets)
        {
            var selected = target as Material;
            if (!SpiderGooSheetBaker.IsBaked(selected)) continue;
            bool current = SpiderGooSheetBaker.IsCurrent(selected, out string status);
            allCurrent &= current;
            EditorGUILayout.HelpBox(selected.name + ": " + status, current ? MessageType.Info : MessageType.Warning);
        }
        try
        {
            var plan = SpiderGooSheetBaker.Describe(material);
            EditorGUILayout.LabelField("配列3個のGPUメモリ（全ミップ）", (plan.TextureBytes / (1024.0 * 1024.0)).ToString("F2") + " MiB");
            EditorGUILayout.LabelField("読取UV全幅", plan.UVSpan.ToString("F3"));
        }
        catch (Exception e) { EditorGUILayout.HelpBox(e.Message, MessageType.Error); }
        using (new EditorGUI.DisabledScope(true))
        {
            EditorGUILayout.ObjectField("形状配列", material.GetTexture("_BakedShape"), typeof(Texture2DArray), false);
            EditorGUILayout.ObjectField("補助配列", material.GetTexture("_BakedDetail"), typeof(Texture2DArray), false);
            EditorGUILayout.ObjectField("被覆率配列", material.GetTexture("_BakedCoverage"), typeof(Texture2DArray), false);
        }
        using (new EditorGUI.DisabledScope(EditorApplication.isPlayingOrWillChangePlaymode || EditorApplication.isCompiling))
        {
            if (GUILayout.Button(allCurrent ? "焼き直す（同じアセットを更新）" : "焼き直す"))
            {
                // UI イベント中の再インポートを避け、次の Editor 更新で実行する。
                var targets = new List<Material>();
                foreach (UnityEngine.Object target in editor.targets)
                    if (SpiderGooSheetBaker.IsBaked(target as Material)) targets.Add((Material)target);
                EditorApplication.delayCall += () => BakeSelected(targets);
            }
            if (GUILayout.Button("使われていない焼き込みを削除…"))
                EditorApplication.delayCall += DeleteUnused;
        }
    }

    private static void DeleteUnused()
    {
        List<string> unused = SpiderGooSheetBaker.FindUnused();
        if (unused.Count == 0)
        {
            EditorUtility.DisplayDialog("使われていない焼き込み", "削除できる焼き込み配列はありません。", "OK");
            return;
        }
        long bytes = 0;
        string projectRoot = Path.GetDirectoryName(Application.dataPath);
        foreach (string path in unused)
        {
            var file = new FileInfo(Path.Combine(projectRoot, path));
            if (file.Exists) bytes += file.Length;
        }
        string message = SpiderGooSheetBaker.DefaultFolder + " の焼き込み配列のうち、どのマテリアル・Prefab・シーンからも使われていない "
            + unused.Count + " 個（" + (bytes / (1024.0 * 1024.0)).ToString("F1") + " MiB）をゴミ箱へ移します。\n"
            + "このあと焼き直しを Ctrl+Z で取り消すと、ゴミ箱へ移した配列を参照して表示が崩れます。そのときは焼き直してください。";
        if (!EditorUtility.DisplayDialog("使われていない焼き込みを削除", message, "ゴミ箱へ移す", "キャンセル")) return;
        int moved = SpiderGooSheetBaker.MoveToTrash(unused);
        Debug.Log("使われていない焼き込み配列を " + moved + " 個ゴミ箱へ移しました。");
    }

    private static void BakeSelected(List<Material> materials)
    {
        var generated = new HashSet<string>();
        foreach (var material in materials)
        {
            if (material == null) continue;
            try
            {
                // 先に親の質感を同期し、同一形状を選択数だけ重複生成しない。
                var sync = SpiderSilkLook.Sync(new[] { material });
                if (sync.Problems.Count > 0) throw new InvalidOperationException(string.Join("\n", sync.Problems));
                string hash = SpiderGooSheetBaker.Describe(material).Hash;
                SpiderGooSheetBaker.Bake(material, generated.Add(hash));
                Debug.Log("ねばねばネット（粘液シート）を焼き直しました: " + material.name, material);
            }
            catch (Exception e) { Debug.LogException(e, material); }
        }
    }
}
