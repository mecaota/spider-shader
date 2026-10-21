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
