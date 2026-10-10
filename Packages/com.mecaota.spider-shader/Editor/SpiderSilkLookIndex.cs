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
//  .mat の取り込み・削除・移動（postprocessor）は、その .mat だけを反映する。
//  蜘蛛シェーダーの取り込みや、蜘蛛シェーダーとそれ以外の切り替え（ObjectChangeEvents）では全体を作り直す。
//  蜘蛛シェーダーどうしの切り替え（吐いた糸 ↔ 巣など）は、その .mat だけを反映する。
// =============================================================================
public static class SpiderSilkLookIndex
{
    static List<Material> s_Sources;
    static List<Material> s_Inheritors;
    static HashSet<Material> s_All;
    static Dictionary<string, Material> s_SourceByPrefix;
    static List<string> s_ShaderGuids = new List<string>();
    static readonly HashSet<string> s_Missing = new HashSet<string>();   // 作り直しても見つからなかった GUID 先頭
    static readonly HashSet<string> s_Changed = new HashSet<string>();   // 取り込み・削除・移動された .mat（次に使うときに反映）
    static bool s_Dirty = true;

    public static void Invalidate() { s_Dirty = true; s_Missing.Clear(); }

    /// <summary>取り込み・削除・移動された .mat を、次に使うときに一覧へ反映する（全体は作り直さない）。</summary>
    public static void MarkChanged(IEnumerable<string> paths)
    {
        if (s_Dirty || s_Sources == null) return;   // どのみち全体を作り直す
        foreach (var p in paths) s_Changed.Add(p);
    }

    /// <summary>一覧に記録した役割が、今のシェーダーの役割と違うか（蜘蛛シェーダーどうしの切り替え）。</summary>
    public static bool RoleChanged(Material m)
    {
        Ensure();
        if (m == null) return false;
        var role = SpiderSilkLook.GetRole(m.shader);
        return (role == SpiderSilkLook.Role.Source) != s_Sources.Contains(m) ||
               (role == SpiderSilkLook.Role.Inheritor) != s_Inheritors.Contains(m);
    }

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
        if (!s_Dirty && s_Sources != null)
        {
            if (s_Changed.Count > 0) ApplyChanges();
            return;
        }
        s_Sources = new List<Material>();
        s_Inheritors = new List<Material>();
        s_All = new HashSet<Material>();
        s_SourceByPrefix = new Dictionary<string, Material>();
        s_Changed.Clear();
        s_Dirty = false;

        s_ShaderGuids = new List<string>();
        var srcGuid = ShaderGuid(SpiderSilkLook.SourceShaderName);
        if (srcGuid != null) s_ShaderGuids.Add(srcGuid);
        foreach (var n in SpiderSilkLook.InheritorShaderNames) { var g = ShaderGuid(n); if (g != null) s_ShaderGuids.Add(g); }

        if (s_ShaderGuids.Count > 0)
            foreach (var guid in AssetDatabase.FindAssets("t:Material"))
            {
                string path = AssetDatabase.GUIDToAssetPath(guid);
                if (path.EndsWith(".mat", StringComparison.OrdinalIgnoreCase) && UsesSpiderShader(path))
                    Add(AssetDatabase.LoadAssetAtPath<Material>(path));
            }

        // 未保存の変更（ディスクの m_Shader がまだ古い）を、読み込み済みのマテリアルで補う
        foreach (var m in Resources.FindObjectsOfTypeAll<Material>())
        {
            if (m == null || !EditorUtility.IsPersistent(m) || !EditorUtility.IsDirty(m) || !AssetDatabase.IsMainAsset(m)) continue;
            if (!AssetDatabase.GetAssetPath(m).EndsWith(".mat", StringComparison.OrdinalIgnoreCase)) continue;
            Add(m);
        }

        Sort();
    }

    // 変わった .mat だけを反映する
    static void ApplyChanges()
    {
        // 削除されたもの（パスが無い）と、取り込み・移動されたもの（一覧にある、または蜘蛛シェーダーを使う .mat）を集める
        var byPath = new Dictionary<string, Material>();
        var gone = new List<Material>();
        foreach (var m in s_All)
        {
            string p = m != null ? AssetDatabase.GetAssetPath(m) : null;
            if (string.IsNullOrEmpty(p)) gone.Add(m);
            else byPath[p] = m;
        }
        var touched = new List<Material>();
        foreach (var path in s_Changed)
        {
            if (byPath.TryGetValue(path, out var m)) touched.Add(m);
            else if (UsesSpiderShader(path))
            {
                m = AssetDatabase.LoadAssetAtPath<Material>(path);
                if (m != null) touched.Add(m);
            }
        }
        s_Changed.Clear();
        if (gone.Count == 0 && touched.Count == 0) return;

        // 呼び出し元が一覧を反復中かもしれないので、書き換えずに複製して差し替える
        s_Sources        = new List<Material>(s_Sources);
        s_Inheritors     = new List<Material>(s_Inheritors);
        s_All            = new HashSet<Material>(s_All);
        s_SourceByPrefix = new Dictionary<string, Material>(s_SourceByPrefix);
        foreach (var m in gone) Remove(m);
        foreach (var m in touched) { Remove(m); Add(m); }   // メモリ上のシェーダーで役割を決め直す
        Sort();
    }

    static void Sort()
    {
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

    // 一覧から外す（削除済みで null 扱いのマテリアルも外せるよう、参照で比べる）
    static void Remove(Material m)
    {
        if (ReferenceEquals(m, null) || !s_All.Remove(m)) return;
        s_Sources.Remove(m);
        s_Inheritors.Remove(m);
        string key = null;
        foreach (var kv in s_SourceByPrefix) if (ReferenceEquals(kv.Value, m)) { key = kv.Key; break; }
        if (key != null) s_SourceByPrefix.Remove(key);
    }

    // .mat の m_Shader 行が蜘蛛シェーダーの GUID か（マテリアルは読み込まない）
    static bool UsesSpiderShader(string path)
    {
        string line = ReadShaderLine(path);
        if (line == null) return false;
        foreach (var g in s_ShaderGuids) if (line.Contains(g)) return true;
        return false;
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
