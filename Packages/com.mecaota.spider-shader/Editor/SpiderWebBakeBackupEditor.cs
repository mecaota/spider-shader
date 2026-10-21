// このファイルは C# の null 許容の注釈（nullable）を使わない書き方をしている。利用側のプロジェクトが
// 追加のコンパイラ引数（csc.rsp の -nullable:enable など）で注釈を有効にしても警告が出ないよう、明示的に無効にする。
#nullable disable
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using UnityEditor;
using UnityEngine;

// =============================================================================
// SpiderWebBakeBackupEditor.cs — 焼き込みの控え（SpiderWebBakeBackup）のインスペクター
//
//  控えの中身（元のマテリアル・焼いた設定・各ミップ段の被覆率・同意した注意事項・作ったアセット）を
//  読み取り専用で見せ、「元に戻す…」で焼く前の状態に戻す（確認ダイアログ → Undo 1 回分）。
//  元のマテリアルのアセットが消えていたら、控えの値から作り直す。焼いたアセットは消さない。
// =============================================================================
[CustomEditor(typeof(SpiderWebBakeBackup))]
public sealed class SpiderWebBakeBackupEditor : Editor
{
    private bool showConsent;
    private bool showCoverage;
    private bool showAssets = true;
    private bool showDiff;
    // 元のマテリアルが焼いたあとで変わったか（スロット → 違いの一覧）。開いたとき・「調べ直す」で求める
    private Dictionary<int, List<string>> diffs = new Dictionary<int, List<string>>();

    private void OnEnable()
    {
        RefreshDiffs();
    }

    private void RefreshDiffs()
    {
        try { diffs = SpiderWebLilToonBaker.DiffOriginals(target as SpiderWebBakeBackup); }
        catch (Exception) { diffs = new Dictionary<int, List<string>>(); }
    }

    public override void OnInspectorGUI()
    {
        var b = (SpiderWebBakeBackup)target;
        EditorGUILayout.HelpBox("エディター専用の控えです。Play とビルドに影響しません。\n" +
                                "（実行時の処理を持たず、VRChat のエディター専用の印 IEditorOnly を付け、ワールドのビルドでは取り除きます）\n" +
                                "巣を lilToon に焼き込む前の、元のマテリアルと設定を持っています。", MessageType.Info);

        EditorGUILayout.LabelField("焼いた日時", b.bakedAt);
        EditorGUILayout.LabelField("ツール", b.toolVersion + "（控えの書式 " + b.dataVersion + "）");
        if (b.bake != null)
        {
            EditorGUILayout.LabelField("モード", b.bake.mode == "Transparent" ? "Transparent（半透明）" : "Cutout ＋ alpha to coverage（しきい値 " + b.bake.cutoff.ToString("0.00", CultureInfo.InvariantCulture) + "）");
            EditorGUILayout.LabelField("解像度・被覆率のしきい値", b.bake.resolution + " / " + b.bake.coverageThreshold.ToString("0.00", CultureInfo.InvariantCulture));
        }

        EditorGUILayout.Space(4);
        EditorGUILayout.LabelField("元のマテリアル", EditorStyles.boldLabel);
        foreach (SpiderWebMaterialSnapshot s in b.snapshots)
        {
            Material orig = s.slot < b.originalMaterials.Length ? b.originalMaterials[s.slot] : null;
            Material baked = s.slot < b.bakedMaterials.Length ? b.bakedMaterials[s.slot] : null;
            using (new EditorGUI.DisabledScope(true))
            {
                EditorGUILayout.ObjectField("スロット " + s.slot + " 元", orig, typeof(Material), false);
                EditorGUILayout.ObjectField("スロット " + s.slot + " 焼いた", baked, typeof(Material), false);
            }
            if (!string.IsNullOrEmpty(s.parentPath))
                EditorGUILayout.HelpBox("元はマテリアルバリアントでした（親: " + s.parentPath + "）。控えの値で作り直すときは、親を持たない普通のマテリアルになります（値は同じ）。", MessageType.Info);
            if (diffs.TryGetValue(s.slot, out List<string> d))
            {
                EditorGUILayout.HelpBox("元のマテリアルは、焼いたあとで " + d.Count + " か所変わっています。「元に戻す…」で、今の値のまま戻すか、控えの値で作り直すかを選べます。", MessageType.Warning);
                showDiff = EditorGUILayout.Foldout(showDiff, "変わったところ（スロット " + s.slot + "）", true);
                if (showDiff)
                    foreach (string line in d.Take(30)) EditorGUILayout.LabelField("・" + line, EditorStyles.wordWrappedMiniLabel);
            }
            if (orig == null)
            {
                string path = string.IsNullOrEmpty(s.assetGuid) ? "" : AssetDatabase.GUIDToAssetPath(s.assetGuid);
                EditorGUILayout.HelpBox(string.IsNullOrEmpty(path)
                    ? "元のマテリアル（" + s.name + "、" + (string.IsNullOrEmpty(s.assetPath) ? "シーンの中のマテリアル" : s.assetPath) + "）が見つかりません。元に戻すと、控えの値から同じ値のマテリアルを作り直します。"
                    : "参照は切れていますが、同じ GUID のアセットがあります（" + path + "）。元に戻すとそれを使います。", MessageType.Warning);
            }
        }

        if (b.bake != null && b.bake.slots.Length > 0)
        {
            showCoverage = EditorGUILayout.Foldout(showCoverage, "テクスチャと各ミップ段の被覆率", true);
            if (showCoverage)
            {
                foreach (SpiderWebBakedSlot s in b.bake.slots)
                {
                    EditorGUILayout.LabelField("スロット " + s.slot, s.width + "×" + s.height + "、UV (" + s.uvRect.x.ToString("0.###", CultureInfo.InvariantCulture) + ", " +
                                                                     s.uvRect.y.ToString("0.###", CultureInfo.InvariantCulture) + ") 幅 (" + s.uvRect.z.ToString("0.###", CultureInfo.InvariantCulture) + ", " +
                                                                     s.uvRect.w.ToString("0.###", CultureInfo.InvariantCulture) + ")、糸 約 " + s.threadTexels.ToString("0.0", CultureInfo.InvariantCulture) + " テクセル");
                    for (int i = 0; i < s.mipCoverage.Length; i++)
                    {
                        string naive = i < s.mipCoverageNaive.Length ? (s.mipCoverageNaive[i] * 100f).ToString("0.00", CultureInfo.InvariantCulture) + "%" : "-";
                        EditorGUILayout.LabelField("　段 " + i + "（" + Mathf.Max(1, s.width >> i) + "×" + Mathf.Max(1, s.height >> i) + "）",
                            (s.mipCoverage[i] * 100f).ToString("0.00", CultureInfo.InvariantCulture) + "%（単純な平均なら " + naive + "）");
                    }
                }
            }
        }

        showAssets = EditorGUILayout.Foldout(showAssets, "作ったアセット（" + b.createdAssets.Length + "）", true);
        if (showAssets)
        {
            foreach (string p in b.createdAssets)
            {
                using (new EditorGUI.DisabledScope(true))
                    EditorGUILayout.ObjectField(p, AssetDatabase.LoadMainAssetAtPath(p), typeof(UnityEngine.Object), false);
            }
            EditorGUILayout.HelpBox("元に戻しても、作ったアセットは消しません。要らなくなったらご自身で削除してください。", MessageType.None);
        }

        int consentCount = b.acceptedCritical.Length + b.acceptedCaution.Length + b.acceptedInfo.Length;
        showConsent = EditorGUILayout.Foldout(showConsent, "同意した内容（" + consentCount + "）", true);
        if (showConsent)
        {
            foreach (string x in b.acceptedCritical) EditorGUILayout.HelpBox(x, MessageType.Error);
            foreach (string x in b.acceptedCaution) EditorGUILayout.HelpBox(x, MessageType.Warning);
            foreach (string x in b.acceptedInfo) EditorGUILayout.HelpBox(x, MessageType.Info);
        }

        EditorGUILayout.Space(8);
        if (GUILayout.Button("元のマテリアルとの違いを調べ直す")) RefreshDiffs();
        using (new EditorGUI.DisabledScope(EditorApplication.isPlayingOrWillChangePlaymode))
        {
            if (GUILayout.Button("元に戻す…", GUILayout.Height(28f)))
            {
                RefreshDiffs();
                string msg = "焼く前のマテリアルとレンダラーの設定（影など）に戻し、この控えのコンポーネントを外します。\n" +
                             "Undo（Ctrl+Z）で取り消せます。焼いたテクスチャとマテリアルは消しません。";
                bool missing = b.snapshots.Any(s => s.slot >= b.originalMaterials.Length || b.originalMaterials[s.slot] == null);
                if (missing)
                    msg += "\n\n元のマテリアルが見つからないスロットは、控えの値から作り直します。";
                if (b.snapshots.Any(s => !string.IsNullOrEmpty(s.parentPath)) && (missing || diffs.Count > 0))
                    msg += "\n\n元はマテリアルバリアントでした。作り直したマテリアルは親を持たない普通のマテリアルになります（値は同じ）。";
                SpiderWebRevertMode? mode = null;
                if (diffs.Count > 0)
                {
                    int changed = diffs.Values.Sum(x => x.Count);
                    msg += "\n\n元のマテリアルは焼いたあとで " + changed + " か所変わっています（インスペクターの「変わったところ」）。\n" +
                           "・今の元のマテリアルで戻す: 変わった値のまま使います\n・控えの値で作り直して戻す: 焼く前の値で新しいマテリアルを作ります（元のマテリアルはそのまま）";
                    int choice = EditorUtility.DisplayDialogComplex("巣の焼き込みを元に戻す", msg, "今の元のマテリアルで戻す", "キャンセル", "控えの値で作り直して戻す");
                    if (choice == 0) mode = SpiderWebRevertMode.UseOriginal;
                    else if (choice == 2) mode = SpiderWebRevertMode.RecreateFromSnapshot;
                }
                else if (EditorUtility.DisplayDialog("巣の焼き込みを元に戻す", msg, "元に戻す", "キャンセル"))
                {
                    mode = SpiderWebRevertMode.UseOriginal;
                }
                if (mode.HasValue)
                {
                    try
                    {
                        SpiderWebRevertResult res = SpiderWebLilToonBaker.Revert(b, "", mode.Value);
                        EditorUtility.DisplayDialog("巣の焼き込みを元に戻す", string.Join("\n", res.Messages.Take(40)), "OK");
                    }
                    catch (Exception e)
                    {
                        Debug.LogException(e);
                        EditorUtility.DisplayDialog("巣の焼き込みを元に戻す", e.Message, "OK");
                    }
                    GUIUtility.ExitGUI();
                }
            }
        }
    }
}
