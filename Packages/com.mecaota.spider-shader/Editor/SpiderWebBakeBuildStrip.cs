// このファイルは C# の null 許容の注釈（nullable）を使わない書き方をしている。利用側のプロジェクトが
// 追加のコンパイラ引数（csc.rsp の -nullable:enable など）で注釈を有効にしても警告が出ないよう、明示的に無効にする。
#nullable disable
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;
using UnityEngine.SceneManagement;

// =============================================================================
// SpiderWebBakeBuildStrip.cs — ビルドのとき、焼き込みの控え（SpiderWebBakeBackup）をシーンから取り除く
//
//  控えはエディター専用（VRC.SDKBase.IEditorOnly・HideFlags.DontSaveInBuild）だが、念のため
//  ワールドのビルド（VRChat の Build & Test / Upload を含む）で処理されるシーンからも外す。
//  Unity はこの関数を Play に入るときにも呼ぶ。そのときは何もしない（Play に一切影響させない）。
//  ビルドで処理されるシーンは、開いているシーンの写しなので、開いているシーンの控えは消えない。
// =============================================================================
internal sealed class SpiderWebBakeBuildStrip : IProcessSceneWithReport
{
    public int callbackOrder { get { return -100; } }

    public void OnProcessScene(Scene scene, BuildReport report)
    {
        // Play に入るとき（report は null・Play への切り替え中）は何もしない
        if (EditorApplication.isPlayingOrWillChangePlaymode) return;
        int removed = StripFromScene(scene);
        if (removed > 0) Debug.Log("[SpiderWebBakeBuildStrip] ビルドするシーン " + scene.name + " から、巣の焼き込みの控えを " + removed + " 個取り除きました（エディター専用）。");
    }

    /// <summary>シーンの中の控えをすべて取り除いた数を返す（ビルドの処理からだけ呼ぶ）。</summary>
    internal static int StripFromScene(Scene scene)
    {
        if (!scene.IsValid() || !scene.isLoaded) return 0;
        int removed = 0;
        foreach (GameObject root in scene.GetRootGameObjects())
            foreach (SpiderWebBakeBackup b in root.GetComponentsInChildren<SpiderWebBakeBackup>(true))
            {
                Object.DestroyImmediate(b);
                removed++;
            }
        return removed;
    }
}
