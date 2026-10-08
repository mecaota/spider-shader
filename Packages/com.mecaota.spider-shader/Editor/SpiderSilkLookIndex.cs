using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;

// =============================================================================
// SpiderSilkLookIndex — プロジェクト内の「蜘蛛糸マテリアル（継承元）」と
// 「巣・繭・デカール・ねばねばネットのマテリアル（継承先）」の一覧。
//
//  全マテリアルを読み込むと重いので、.mat ファイルの先頭（m_Shader の行）から
//  蜘蛛シェーダーの GUID を探して絞り込み、当たったものだけを読み込む。
//  まだ保存していない変更（インスペクタでシェーダーを切り替えた直後など）も拾うため、
//  読み込み済みで未保存（dirty）のマテリアルはメモリ上のシェーダーで判定して足す。
//  .mat が追加・変更・削除されたら（postprocessor / ObjectChangeEvents）作り直す。
// =============================================================================
public static class SpiderSilkLookIndex
{
    static List<Material> s_Sources;
    static List<Material> s_Inheritors;
    static HashSet<Material> s_All;
    static Dictionary<string, Material> s_SourceByPrefix;
    static readonly HashSet<string> s_Missing = new HashSet<string>();   // 作り直しても見つからなかった GUID 先頭
    static bool s_Dirty = true;

    public static void Invalidate() { s_Dirty = true; s_Missing.Clear(); }

    public static IReadOnlyList<Material> Sources    { get { Ensure(); return s_Sources; } }
    public static IReadOnlyList<Material> Inheritors { get { Ensure(); return s_Inheritors; } }

    /// <summary>一覧（継承元・継承先）に入っているか。</summary>
    public static bool Contains(Material m) { Ensure(); return m != null && s_All.Contains(m); }

    /// <summary>GUID の先頭 18 桁から継承元（吐いた糸のマテリアル）を探す。</summary>
    public static Material FindSourceByPrefix(string prefix)
    {
        if (string.IsNullOrEmpty(prefix)) return null;
        Ensure();
        if (TryGetSource(prefix, out var m)) return m;
        // 見つからない継承元を探すたびに全体を読み直すと重いので、作り直しは Invalidate ごとに 1 回だけ
        if (s_Missing.Contains(prefix)) return null;
        s_Dirty = true; Ensure();
        if (TryGetSource(prefix, out m)) return m;
        s_Missing.Add(prefix);
        return null;
    }

    static bool TryGetSource(string prefix, out Material m) =>
        s_SourceByPrefix.TryGetValue(prefix, out m) && m != null && SpiderSilkLook.GetRole(m.shader) == SpiderSilkLook.Role.Source;

    /// <summary>この蜘蛛糸マテリアルの質感を受け継いでいるマテリアル（蜘蛛糸の Material Variant 経由の継承元も含む）。</summary>
    public static List<Material> DependentsOf(Material source)
    {
        var list = new List<Material>();
        if (source == null) return list;
        foreach (var m in Inheritors)
        {
            var link = SpiderSilkLook.GetLink(m);
            if (link.State != SpiderSilkLook.LinkState.Linked) continue;
            for (var s = link.Source; s != null; s = s.parent)
                if (s == source) { list.Add(m); break; }
        }
        return list;
    }

    /// <summary>この蜘蛛糸マテリアルを親に持つ蜘蛛糸の Material Variant（継承元どうしの親子）。</summary>
    public static List<Material> SourceVariantsOf(Material source)
    {
        var list = new List<Material>();
        if (source == null) return list;
        foreach (var s in Sources)
            for (var p = s.parent; p != null; p = p.parent)
                if (p == source) { list.Add(s); break; }
        return list;
    }

    static void Ensure()
    {
        if (!s_Dirty && s_Sources != null) return;
        s_Sources = new List<Material>();
        s_Inheritors = new List<Material>();
        s_All = new HashSet<Material>();
        s_SourceByPrefix = new Dictionary<string, Material>();
        s_Dirty = false;

        var shaderGuids = new List<string>();
        var srcGuid = ShaderGuid(SpiderSilkLook.SourceShaderName);
        if (srcGuid != null) shaderGuids.Add(srcGuid);
        foreach (var n in SpiderSilkLook.InheritorShaderNames) { var g = ShaderGuid(n); if (g != null) shaderGuids.Add(g); }

        if (shaderGuids.Count > 0)
            foreach (var guid in AssetDatabase.FindAssets("t:Material"))
            {
                string path = AssetDatabase.GUIDToAssetPath(guid);
                if (!path.EndsWith(".mat", StringComparison.OrdinalIgnoreCase)) continue;
                string shaderLine = ReadShaderLine(path);
                if (shaderLine == null) continue;
                bool hit = false;
                foreach (var g in shaderGuids) if (shaderLine.Contains(g)) { hit = true; break; }
                if (hit) Add(AssetDatabase.LoadAssetAtPath<Material>(path));
            }

        // 未保存の変更（ディスクの m_Shader がまだ古い）を、読み込み済みのマテリアルで補う
        foreach (var m in Resources.FindObjectsOfTypeAll<Material>())
        {
            if (m == null || !EditorUtility.IsPersistent(m) || !EditorUtility.IsDirty(m) || !AssetDatabase.IsMainAsset(m)) continue;
            if (!AssetDatabase.GetAssetPath(m).EndsWith(".mat", StringComparison.OrdinalIgnoreCase)) continue;
            Add(m);
        }

        s_Sources.Sort((a, b) => string.CompareOrdinal(AssetDatabase.GetAssetPath(a), AssetDatabase.GetAssetPath(b)));
        s_Inheritors.Sort((a, b) => string.CompareOrdinal(AssetDatabase.GetAssetPath(a), AssetDatabase.GetAssetPath(b)));
    }

    // メモリ上のシェーダーで役割を決めて一覧に入れる（重複は入れない）
    static void Add(Material m)
    {
        if (m == null || s_All.Contains(m)) return;
        var role = SpiderSilkLook.GetRole(m.shader);
        if (role == SpiderSilkLook.Role.Source)
        {
            s_Sources.Add(m); s_All.Add(m);
            var prefix = SpiderSilkLook.GuidPrefix(AssetDatabase.AssetPathToGUID(AssetDatabase.GetAssetPath(m)));
            if (prefix != null) s_SourceByPrefix[prefix] = m;
        }
        else if (role == SpiderSilkLook.Role.Inheritor) { s_Inheritors.Add(m); s_All.Add(m); }
    }

    // .mat の先頭だけを読んで m_Shader の行を返す（全文を読まない。バイナリ形式などは null）
    static string ReadShaderLine(string path)
    {
        try
        {
            using (var reader = new StreamReader(path))
            {
                for (int i = 0; i < 40; i++)
                {
                    var line = reader.ReadLine();
                    if (line == null) return null;
                    if (line.Contains("m_Shader:")) return line;
                }
            }
        }
        catch { }
        return null;
    }

    static string ShaderGuid(string shaderName)
    {
        var s = Shader.Find(shaderName);
        if (s == null) return null;
        var g = AssetDatabase.AssetPathToGUID(AssetDatabase.GetAssetPath(s));
        return string.IsNullOrEmpty(g) ? null : g;
    }
}
