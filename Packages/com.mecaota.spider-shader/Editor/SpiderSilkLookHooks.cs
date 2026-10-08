using System;
using System.Collections.Generic;
using System.Text;
using UnityEditor;
using UnityEngine;

// =============================================================================
// 質感の継承まわりの「きっかけ」とメニュー。
//  ・アセットの取り込み・削除・移動 → 一覧（SpiderSilkLookIndex）を作り直す。
//    シェーダー・cginc なら一致チェックもやり直す。
//  ・継承元（蜘蛛糸マテリアル）を削除しようとしたら、継承しているマテリアルを Console に出す
//    （削除は止めない。継承先は値をそのまま保ち、「継承元が見つかりません」と警告する）。
//    ※ 自動処理（MCP など）を止めないよう、モーダルダイアログは出さない。
//  ・メニュー: 同期 / 親と同じ値の上書きの掃除。
//  ・VRChat のアップロード前に全体を同期して保存する（VRChat SDK があるときだけ）。
// =============================================================================
internal sealed class SpiderSilkLookAssetPostprocessor : AssetPostprocessor
{
    internal static Action<string[]> s_AssetsChanged;   // 自動同期が受け取る（取り込まれた .mat のパス）

    static void OnPostprocessAllAssets(string[] imported, string[] deleted, string[] moved, string[] movedFrom)
    {
        bool mat = false, shader = false;
        foreach (var list in new[] { imported, deleted, moved, movedFrom })
            foreach (var p in list)
            {
                if (p.EndsWith(".mat", StringComparison.OrdinalIgnoreCase)) mat = true;
                else if (p.Contains("com.mecaota.spider-shader") &&
                         (p.EndsWith(".shader", StringComparison.OrdinalIgnoreCase) || p.EndsWith(".cginc", StringComparison.OrdinalIgnoreCase)))
                    shader = true;
            }
        if (mat || shader) SpiderSilkLookIndex.Invalidate();
        if (shader) SpiderSilkLookValidator.ScheduleCheck();
        if (mat || shader)
        {
            // エディタ自身の保存（Ctrl+S など）による取り込みは「外から来た変更」として扱わない
            var mats = new List<string>();
            foreach (var p in imported)
                if (p.EndsWith(".mat", StringComparison.OrdinalIgnoreCase) && !SpiderSilkLookAssetWatcher.s_SavedByEditor.Remove(p)) mats.Add(p);
            foreach (var p in moved) if (p.EndsWith(".mat", StringComparison.OrdinalIgnoreCase)) mats.Add(p);
            s_AssetsChanged?.Invoke(mats.ToArray());
        }
    }
}

internal sealed class SpiderSilkLookAssetWatcher : AssetModificationProcessor
{
    internal static readonly HashSet<string> s_SavedByEditor = new HashSet<string>();

    // エディタが .mat を保存する直前（保存後の取り込みと、VCS 更新などの外からの取り込みを区別する）
    static string[] OnWillSaveAssets(string[] paths)
    {
        foreach (var p in paths) if (p.EndsWith(".mat", StringComparison.OrdinalIgnoreCase)) s_SavedByEditor.Add(p);
        return paths;
    }

    static AssetDeleteResult OnWillDeleteAsset(string path, RemoveAssetOptions options)
    {
        if (!path.EndsWith(".mat", StringComparison.OrdinalIgnoreCase)) return AssetDeleteResult.DidNotDelete;
        var m = AssetDatabase.LoadAssetAtPath<Material>(path);
        if (m == null || SpiderSilkLook.GetRole(m.shader) != SpiderSilkLook.Role.Source) return AssetDeleteResult.DidNotDelete;
        var deps = SpiderSilkLookIndex.DependentsOf(m);
        if (deps.Count > 0)
        {
            var sb = new StringBuilder();
            sb.AppendLine("[蜘蛛糸の質感] 継承元「" + m.name + "」を削除します。次の " + deps.Count + " 個のマテリアルが質感を継承していました。");
            sb.AppendLine("値はそのまま保たれますが「継承元が見つかりません」の状態になります。インスペクタで新しい継承元を選んでください（削除の取り消しは Ctrl+Z ではなく VCS / ゴミ箱から）。");
            foreach (var d in deps) sb.AppendLine("  " + AssetDatabase.GetAssetPath(d));
            Debug.LogWarning(sb.ToString(), m);
        }
        SpiderSilkLookIndex.Invalidate();
        return AssetDeleteResult.DidNotDelete;
    }
}

internal static class SpiderSilkLookMenu
{
    [MenuItem("Tools/SpiderShader/質感の継承を同期")]
    static void MenuSync()
    {
        if (EditorApplication.isPlayingOrWillChangePlaymode)
        {
            EditorUtility.DisplayDialog("質感の継承を同期", "Play 中は同期できません。Play を止めてから実行してください。", "OK");
            return;
        }
        SpiderSilkLookIndex.Invalidate();
        var report = SpiderSilkLook.SyncAll(SpiderSilkLookAutoSync.ExplicitOptions(save: true));
        Log("同期", report);
        EditorUtility.DisplayDialog("質感の継承を同期",
            "継承先 " + SpiderSilkLookIndex.Inheritors.Count + " 個を確認しました。\n" + report +
            (report.Problems.Count > 0 ? "\n\n問題の詳細は Console を見てください。" : ""), "OK");
    }

    [MenuItem("Tools/SpiderShader/保守/親と同じ値の上書きを掃除（質感）")]
    static void MenuCleanup()
    {
        if (!EditorUtility.DisplayDialog("親と同じ値の上書きを掃除",
                "巣・繭・デカールの Material Variant で、親と同じ値なのに残っている質感と継承元の上書きを外します。\n" +
                "見た目は変わりません。この操作は Ctrl+Z では戻せません。", "実行", "キャンセル")) return;
        int total = 0;
        foreach (var m in SpiderSilkLookIndex.Inheritors)
        {
            int n = SpiderSilkLook.CleanupRedundantOverrides(m);
            if (n > 0) { total += n; AssetDatabase.SaveAssetIfDirty(m); Debug.Log("[蜘蛛糸の質感] " + AssetDatabase.GetAssetPath(m) + ": 上書き " + n + " 個を外しました", m); }
        }
        EditorUtility.DisplayDialog("親と同じ値の上書きを掃除", "外した上書き: " + total + " 個", "OK");
    }

    internal static void Log(string what, SpiderSilkLook.SyncReport report)
    {
        var sb = new StringBuilder("[蜘蛛糸の質感] " + what + ": " + report);
        foreach (var m in report.Changed) sb.Append("\n  変更: " + AssetDatabase.GetAssetPath(m));
        foreach (var p in report.Problems) sb.Append("\n  問題: " + p);
        if (report.Problems.Count > 0) Debug.LogWarning(sb.ToString());
        else if (report.Changed.Count > 0) Debug.Log(sb.ToString());
    }
}

#if SPIDER_SHADER_VRCSDK
// VRChat SDK の「Build & Upload」の直前に、質感の継承を同期して保存する。
// 問題があっても止めない（Console に警告を出す）。
internal sealed class SpiderSilkLookVrcBuildHook : VRC.SDKBase.Editor.BuildPipeline.IVRCSDKBuildRequestedCallback
{
    public int callbackOrder => -50;

    public bool OnBuildRequested(VRC.SDKBase.Editor.BuildPipeline.VRCSDKRequestedBuildType requestedBuildType)
    {
        if (EditorApplication.isPlayingOrWillChangePlaymode) return true;
        try
        {
            SpiderSilkLookIndex.Invalidate();
            // 安全装置で止めているマテリアルは書き換えずに警告だけ出す
            var report = SpiderSilkLook.SyncAll(SpiderSilkLookAutoSync.ExplicitOptions(save: true));
            SpiderSilkLookMenu.Log("アップロード前の同期", report);
        }
        catch (Exception e) { Debug.LogException(e); }
        return true;
    }
}
#endif
