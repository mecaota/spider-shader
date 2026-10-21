// このファイルは C# の null 許容の注釈（nullable）を使わない書き方をしている。利用側のプロジェクトが
// 追加のコンパイラ引数（csc.rsp の -nullable:enable など）で注釈を有効にしても警告が出ないよう、明示的に無効にする。
#nullable disable
using System.Collections.Generic;
using System.Linq;
using UnityEditor;
using UnityEngine;

// =============================================================================
// SpiderWebLilToonBakePanel.cs — 巣のマテリアル（mecaota/SpiderWeb）のインスペクターの「lilToon に焼き込む」欄
//
//  マテリアル単体では焼かない。シーンで選んでいる巣のオブジェクト（このマテリアルを使うレンダラー）を対象に、
//  確認画面（SpiderWebLilToonBakeWindow）を開くだけ。SpiderCocoonShaderGUI.OnGUI から呼ぶ。
// =============================================================================
internal static class SpiderWebLilToonBakePanel
{
    private static readonly Color PanelColor = new Color(0.85f, 0.80f, 0.98f);

    public static void Draw(MaterialEditor editor)
    {
        var material = editor.target as Material;
        if (material == null || material.shader == null || material.shader.name != SpiderWebLilToonBaker.WebShaderName) return;
        if (!SpiderCocoonShaderGUI.DrawSectionFoldout("lilToon に焼き込む（軽量化）", PanelColor, "SpiderWebLilToonBake")) return;

        EditorGUILayout.HelpBox("巣の模様をテクスチャに焼き、選んでいるレンダラーのマテリアルを lilToon に差し替えます（マテリアル単体では焼きません）。" +
                                "焼く前に、失われる機能（揺れ・触れたときの変形・体への巻き付き・近接表示・Udon の演出など）と注意事項を確認する画面が開きます。" +
                                "焼いたあとは、付いた控えのコンポーネントからいつでも元に戻せます。", MessageType.Info);
        if (!SpiderWebLilToonBaker.IsLilToonAvailable(out string reason))
        {
            EditorGUILayout.HelpBox(reason, MessageType.Warning);
            return;
        }

        var renderers = new List<Renderer>();
        foreach (GameObject go in Selection.gameObjects)
            foreach (Renderer r in go.GetComponents<Renderer>())
                if (r.sharedMaterials.Contains(material) && !renderers.Contains(r)) renderers.Add(r);
        if (renderers.Count == 0)
        {
            EditorGUILayout.HelpBox("シーンで、このマテリアルを使う巣のオブジェクトを選ぶと、ここから焼き込みの確認画面を開けます。", MessageType.None);
            return;
        }
        foreach (Renderer r in renderers.Take(8))
        {
            bool baked = r.GetComponent<SpiderWebBakeBackup>() != null;
            using (new EditorGUI.DisabledScope(baked))
            {
                if (GUILayout.Button((baked ? "焼き込み済み: " : "lilToon に焼き込む…（") + r.gameObject.name + (baked ? "" : "）")))
                    SpiderWebLilToonBakeWindow.Open(r);
            }
        }
        if (renderers.Count > 8) EditorGUILayout.LabelField("ほか " + (renderers.Count - 8) + " 個（1 つずつ選んでください）");
    }
}
