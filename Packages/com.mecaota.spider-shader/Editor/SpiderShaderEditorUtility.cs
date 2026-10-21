// このファイルは C# の null 許容の注釈（nullable）を使わない書き方をしている。利用側のプロジェクトが
// 追加のコンパイラ引数（csc.rsp の -nullable:enable など）で注釈を有効にしても警告が出ないよう、明示的に無効にする。
#nullable disable
using UnityEditor;

/// <summary>
/// Editor のスクリプトが共通で使う小さな処理（アセットの保存先フォルダの用意など）。
/// </summary>
internal static class SpiderShaderEditorUtility
{
    /// <summary>"Assets/a/b" のようなフォルダを、途中のフォルダも含めて無ければ作る。</summary>
    internal static void EnsureFolder(string folder)
    {
        string[] parts = folder.Split('/');
        string current = parts[0];
        for (int i = 1; i < parts.Length; i++)
        {
            string next = current + "/" + parts[i];
            if (!AssetDatabase.IsValidFolder(next)) AssetDatabase.CreateFolder(current, parts[i]);
            current = next;
        }
    }
}
