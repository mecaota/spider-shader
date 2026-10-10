using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

// =============================================================================
// SpiderSilkLook — 「蜘蛛糸の質感」の継承を扱う中心クラス（エディタ専用・実行時の処理はゼロ）。
//
//  吐いた糸（SpiderThreadTrail）のマテリアルを「継承元」にして、巣（SpiderWeb）・
//  繭（SpiderCocoon）・デカール・ねばねばネット系（四角・絡みつき・水玉）へ、色・陰影・
//  ツヤ・トゥーン・リムなど 21 個の値（Props）を書き写す。
//  Web でいえば「元データ（継承元）から派生データ（継承先の値）を作り直す」仕組みで、
//  継承先の質感は常に継承元から計算し直して決まる（継承先では編集しない）。
//
//  ・どの継承元を使うかは、継承先マテリアルの隠しプロパティ _SilkLookLink に記録する
//    （普通のプロパティなので、複製・Material Variant・Undo が Unity 標準の動きになる）。
//  ・継承元を指定していない継承先は、蜘蛛糸シェーダーの既定値にそろう。
//  ・値は .mat に普通に保存されるので、VRChat では通常のマテリアルとして動く。
//
// ※ Linear 色空間のプロジェクトでは Material.GetColor / GetVector が、保存されている
//   色から最下位ビットを落とした値を返す（SetColor は渡した値をそのまま保存する）。
//   GetColor → SetColor で写すと 1 回ごとに少しずつずれていくので、色は
//   シリアライズされた生の値（m_SavedProperties）を読んで写す。
// =============================================================================
public static class SpiderSilkLook
{
    public const string SourceShaderName = "mecaota/SpiderThreadTrail";
    public static readonly string[] InheritorShaderNames =
        { "mecaota/SpiderWeb", "mecaota/SpiderCocoon", "mecaota/SpiderCocoonDepthDecal",
          "mecaota/SpiderGooSilkSheet" };

    /// <summary>継承先に「どの蜘蛛糸マテリアルを継承元にするか」を記録する隠しプロパティ（描画には使わない）。</summary>
    public const string LinkProperty = "_SilkLookLink";
    const float LinkedFlag = 2f;   // _SilkLookLink.w: 0=継承元なし（既定値） / 2=リンクあり

    /// <summary>シェーダーの役割。継承元になれるのは吐いた糸シェーダーだけ。</summary>
    public enum Role { None, Source, Inheritor }
    /// <summary>None=継承元なし（シェーダー既定値）/ Linked=つながっている / Broken=継承元が見つからない（値は止めて警告）。</summary>
    public enum LinkState { None, Linked, Broken }

    // ---- 継承する 21 項目（唯一の正本。シェーダー側との一致は SpiderSilkLookValidator が確認） ----
    public const string GroupGoo   = "質感: 粘液の色と陰影";
    public const string GroupGloss = "質感: 粘液のハイライト";
    public const string GroupToon  = "質感: トゥーン陰影";
    public const string GroupRim   = "質感: リムライト";
    public static readonly string[] Groups = { GroupGoo, GroupGloss, GroupToon, GroupRim };

    public sealed class Prop
    {
        public readonly string Name;
        public readonly bool   IsColor;
        public readonly string Group;   // インスペクタのカテゴリ名
        internal Prop(string name, bool isColor, string group) { Name = name; IsColor = isColor; Group = group; }
    }

    public static readonly Prop[] Props =
    {
        new Prop("_GooAmount",       false, GroupGoo),
        new Prop("_GooColor",        true,  GroupGoo),
        new Prop("_GooShadowColor",  true,  GroupGoo),
        new Prop("_GooShade",        false, GroupGoo),
        new Prop("_GooOutlineColor", true,  GroupGoo),
        new Prop("_GooOutline",      false, GroupGoo),
        new Prop("_GooOpacity",      false, GroupGoo),
        new Prop("_GooClarity",      false, GroupGoo),
        new Prop("_GooGlossColor",   true,  GroupGloss),
        new Prop("_GooGloss",        false, GroupGloss),
        new Prop("_GooGlossWidth",   false, GroupGloss),
        new Prop("_GooGlossOffset",  false, GroupGloss),
        new Prop("_GooGlossBreak",   false, GroupGloss),
        new Prop("_ToonSteps",       false, GroupToon),
        new Prop("_ToonSmooth",      false, GroupToon),
        new Prop("_AmbientBoost",    false, GroupToon),
        new Prop("_LightInfluence",  false, GroupToon),
        new Prop("_RimColor",        true,  GroupRim),
        new Prop("_RimPower",        false, GroupRim),
        new Prop("_RimStrength",     false, GroupRim),
        new Prop("_RimFloor",        false, GroupRim),
    };

    static readonly Dictionary<string, int> s_Index = new Dictionary<string, int>();
    static SpiderSilkLook()
    {
        for (int i = 0; i < Props.Length; i++) s_Index[Props[i].Name] = i;
    }

    // -------------------------------------------------------------------------
    // 役割の判定
    // -------------------------------------------------------------------------
    public static Role GetRole(Shader shader)
    {
        if (shader == null) return Role.None;
        if (shader.name == SourceShaderName) return Role.Source;
        return Array.IndexOf(InheritorShaderNames, shader.name) >= 0 ? Role.Inheritor : Role.None;
    }

    public static bool IsLookProperty(string name) => name != null && s_Index.ContainsKey(name);

    /// <summary>このシェーダーでは、このプロパティを継承元から受け継ぐ（自分では編集しない）か。</summary>
    public static bool IsInheritedProperty(Shader shader, string name) =>
        GetRole(shader) == Role.Inheritor && IsLookProperty(name);

    // -------------------------------------------------------------------------
    // 変更の通知（自動同期 SpiderSilkLookAutoSync があれば、そこへ渡す）
    // -------------------------------------------------------------------------
    internal static Action<Material> s_Notify;
    public static void NotifyChanged(Material material) { if (material != null) s_Notify?.Invoke(material); }
    public static void NotifyChanged(IEnumerable<Material> materials) { foreach (var m in materials) NotifyChanged(m); }

    // -------------------------------------------------------------------------
    // リンク（継承元）の読み書き
    // -------------------------------------------------------------------------
    public struct LinkInfo
    {
        public LinkState State;
        public Material  Source;      // Linked のとき
        public bool      FromParent;  // Material Variant の親から継承元を受け継いでいる
        public string    Detail;      // Broken の理由など
    }

    public static LinkInfo GetLink(Material material)
    {
        var info = new LinkInfo { State = LinkState.None };
        if (material == null || GetRole(material.shader) != Role.Inheritor || !material.HasProperty(LinkProperty))
            return info;

        info.FromParent = material.parent != null && !material.IsPropertyOverriden(LinkProperty);
        var v = material.GetVector(LinkProperty);
        if (v.w == 0f && v.x == 0f && v.y == 0f && v.z == 0f) return info;

        string prefix = v.w == LinkedFlag ? DecodePrefix(v) : null;
        if (prefix == null)
        {
            info.State  = LinkState.Broken;
            info.Detail = "継承元の記録が壊れています（_SilkLookLink = " + v + "）";
            return info;
        }
        var src = SpiderSilkLookIndex.FindSourceByPrefix(prefix);
        if (src == null)
        {
            info.State  = LinkState.Broken;
            info.Detail = "継承元の蜘蛛糸マテリアルが見つかりません（削除された・シェーダーが変わった可能性。GUID 先頭 " + prefix + "）";
            return info;
        }
        info.State  = LinkState.Linked;
        info.Source = src;
        return info;
    }

    /// <summary>継承元を _SilkLookLink の値に変換する（null = 継承元なし）。</summary>
    public static Vector4 EncodeLink(Material source)
    {
        if (source == null) return Vector4.zero;
        string guid = AssetDatabase.AssetPathToGUID(AssetDatabase.GetAssetPath(source));
        if (string.IsNullOrEmpty(guid) || guid.Length < 18) return Vector4.zero;
        // GUID（16 進 32 桁）の先頭 18 桁を 6 桁 = 24bit ずつ 3 つに分ける。
        // 24bit 以下の整数は float で誤差なく表せる（保存→読み込みで完全に戻る）。
        return new Vector4(Convert.ToInt32(guid.Substring(0, 6), 16),
                           Convert.ToInt32(guid.Substring(6, 6), 16),
                           Convert.ToInt32(guid.Substring(12, 6), 16),
                           LinkedFlag);
    }

    public static string GuidPrefix(string guid) =>
        string.IsNullOrEmpty(guid) || guid.Length < 18 ? null : guid.Substring(0, 18).ToLowerInvariant();

    static string DecodePrefix(Vector4 v)
    {
        var parts = new[] { v.x, v.y, v.z };
        var sb = new System.Text.StringBuilder(18);
        foreach (var f in parts)
        {
            if (f < 0f || f > 16777215f || f != Mathf.Floor(f)) return null;
            sb.Append(((int)f).ToString("x6"));
        }
        return sb.ToString();
    }

    /// <summary>継承元として使えるか（吐いた糸シェーダーの .mat アセット本体か）。null は「継承元なし」として OK。</summary>
    public static bool TryValidateSource(Material candidate, out string reason)
    {
        reason = null;
        if (candidate == null) return true;
        if (GetRole(candidate.shader) != Role.Source)
        {
            reason = "継承元にできるのは吐いた糸（" + SourceShaderName + "）のマテリアルだけです";
            return false;
        }
        string path = AssetDatabase.GetAssetPath(candidate);
        if (string.IsNullOrEmpty(path) || !path.EndsWith(".mat", StringComparison.OrdinalIgnoreCase) || !AssetDatabase.IsMainAsset(candidate))
        {
            reason = "継承元はプロジェクト内の .mat アセットにしてください（シーン内やサブアセットのマテリアルは使えません）";
            return false;
        }
        return true;
    }

    /// <summary>
    /// 継承元を設定し、すぐ値を書き写す（リンクと値が Ctrl+Z 1 回で一緒に戻る）。null = 蜘蛛糸シェーダーの既定値。
    /// まだアセットになっていないマテリアル（CreateAsset の前）にはリンクだけを書く（CreateAsset 後の自動同期で値がそろう）。
    /// 1 つも設定できなかったら false。
    /// </summary>
    public static bool SetSource(IList<Material> targets, Material sourceOrNull)
    {
        if (!TryValidateSource(sourceOrNull, out var reason)) { Debug.LogWarning("[蜘蛛糸の質感] " + reason); return false; }
        var v = EncodeLink(sourceOrNull);
        var list = new List<Material>();
        bool any = false;
        foreach (var m in targets)
        {
            if (m == null || GetRole(m.shader) != Role.Inheritor) continue;
            if (string.IsNullOrEmpty(AssetDatabase.GetAssetPath(m))) { m.SetVector(LinkProperty, v); any = true; continue; }
            if (!IsEditable(m)) { Debug.LogWarning("[蜘蛛糸の質感] 書き込めないため継承元を設定できません: " + AssetDatabase.GetAssetPath(m), m); continue; }
            list.Add(m);
        }
        if (list.Count == 0) return any;

        Undo.RecordObjects(list.ToArray(), "継承元の変更");
        foreach (var m in list) { m.SetVector(LinkProperty, v); EditorUtility.SetDirty(m); }
        s_LinkSetByApi?.Invoke(list);
        Sync(list);
        return true;
    }

    /// <summary>【移行・ツール用】リンクだけを書く（同期も Undo も無し）。</summary>
    public static void SetSourceRaw(Material target, Material sourceOrNull)
    {
        if (target == null || GetRole(target.shader) != Role.Inheritor) return;
        target.SetVector(LinkProperty, EncodeLink(sourceOrNull));
        EditorUtility.SetDirty(target);
        s_LinkSetByApi?.Invoke(new[] { target });
    }

    /// <summary>【ツール用】from と同じ継承元にする（スクリプトでマテリアルを作ったとき用）。</summary>
    public static void CopySourceFrom(Material target, Material from)
    {
        if (target == null || from == null || GetRole(target.shader) != Role.Inheritor || !from.HasProperty(LinkProperty)) return;
        target.SetVector(LinkProperty, from.GetVector(LinkProperty));
        EditorUtility.SetDirty(target);
        s_LinkSetByApi?.Invoke(new[] { target });
    }

    // 自動同期の「予期しないリンクの外れ」検出用（SetSource 系で変えたものは正常な変更）
    internal static Action<IEnumerable<Material>> s_LinkSetByApi;

    // -------------------------------------------------------------------------
    // 値の読み書き（色は生の値）
    // -------------------------------------------------------------------------

    // 1 回の同期の間だけ使う「マテリアル → シリアライズされた色」の控え
    internal sealed class RawCache
    {
        readonly Dictionary<Material, Dictionary<string, Color>> m_Colors = new Dictionary<Material, Dictionary<string, Color>>();

        public bool TryGet(Material m, string name, out Color c)
        {
            if (!m_Colors.TryGetValue(m, out var map))
            {
                map = new Dictionary<string, Color>();
                var arr = new SerializedObject(m).FindProperty("m_SavedProperties.m_Colors");
                if (arr != null)
                    for (int i = 0; i < arr.arraySize; i++)
                    {
                        var e = arr.GetArrayElementAtIndex(i);
                        map[e.FindPropertyRelative("first").stringValue] = e.FindPropertyRelative("second").colorValue;
                    }
                m_Colors[m] = map;
            }
            return map.TryGetValue(name, out c);
        }

        public void Forget(Material m) => m_Colors.Remove(m);
    }

    /// <summary>保存されている色そのもの（GetColor のように最下位ビットを落とさない）。バリアントは親をたどる。</summary>
    public static Color GetRawColor(Material material, string name) => GetRawColor(material, name, new RawCache());

    internal static Color GetRawColor(Material material, string name, RawCache cache)
    {
        for (var m = material; m != null; m = m.parent)
            if (cache.TryGet(m, name, out var c)) return c;
        return material.GetColor(name);
    }

    /// <summary>マテリアルの今の質感（21 値。色は生の値、float は x に入る）。</summary>
    public static Vector4[] ReadValues(Material material) => ReadValues(material, new RawCache());

    internal static Vector4[] ReadValues(Material material, RawCache cache)
    {
        var v = new Vector4[Props.Length];
        for (int i = 0; i < Props.Length; i++)
            v[i] = Props[i].IsColor ? (Vector4)GetRawColor(material, Props[i].Name, cache)
                                    : new Vector4(material.GetFloat(Props[i].Name), 0, 0, 0);
        return v;
    }

    static Vector4[] s_Defaults;

    /// <summary>蜘蛛糸シェーダーの既定値の質感（新しく作ったマテリアルが実際に持つ値）。</summary>
    public static Vector4[] DefaultValues()
    {
        if (s_Defaults != null) return s_Defaults;
        var shader = Shader.Find(SourceShaderName);
        if (shader == null) return null;
        var fresh = new Material(shader) { hideFlags = HideFlags.HideAndDontSave };
        try { s_Defaults = ReadValues(fresh); }
        finally { UnityEngine.Object.DestroyImmediate(fresh); }
        return s_Defaults;
    }

    /// <summary>シェーダーが取り込み直されたら既定値の控えを捨てる。</summary>
    public static void InvalidateCaches() { s_Defaults = null; }

    static bool SameBits(Vector4 a, Vector4 b, bool color)
    {
        if (BitConverter.SingleToInt32Bits(a.x) != BitConverter.SingleToInt32Bits(b.x)) return false;
        if (!color) return true;
        return BitConverter.SingleToInt32Bits(a.y) == BitConverter.SingleToInt32Bits(b.y) &&
               BitConverter.SingleToInt32Bits(a.z) == BitConverter.SingleToInt32Bits(b.z) &&
               BitConverter.SingleToInt32Bits(a.w) == BitConverter.SingleToInt32Bits(b.w);
    }

    /// <summary>継承先の質感が、継承元（継承元なしなら既定値）とビット単位で一致しているか。Broken は true（書かないので）。</summary>
    public static bool IsInSync(Material m)
    {
        var link = GetLink(m);
        if (GetRole(m != null ? m.shader : null) != Role.Inheritor || link.State == LinkState.Broken) return true;
        var cache = new RawCache();
        var goal = link.State == LinkState.Linked ? ReadValues(link.Source, cache) : DefaultValues();
        if (goal == null) return true;
        var cur = ReadValues(m, cache);
        for (int i = 0; i < Props.Length; i++)
            if (!SameBits(cur[i], goal[i], Props[i].IsColor)) return false;
        return true;
    }

    static string Fmt(Vector4 v, bool color) => color ? "(" + v.x.ToString("R") + ", " + v.y.ToString("R") + ", " + v.z.ToString("R") + ", " + v.w.ToString("R") + ")" : v.x.ToString("R");

    /// <summary>書き込めるマテリアルか（読み取り専用パッケージや VCS でロックされたものは書かない）。</summary>
    public static bool IsEditable(Material m)
    {
        string path = AssetDatabase.GetAssetPath(m);
        if (string.IsNullOrEmpty(path)) return false;
        if (path.StartsWith("Packages/", StringComparison.Ordinal))
        {
            var info = UnityEditor.PackageManager.PackageInfo.FindForAssetPath(path);
            if (info != null && info.source != UnityEditor.PackageManager.PackageSource.Embedded &&
                info.source != UnityEditor.PackageManager.PackageSource.Local) return false;
        }
        return AssetDatabase.IsOpenForEdit(m);
    }

    /// <summary>自動同期で書く場所か（Assets/ 配下だけ。VPM などで入れた他のパッケージの .mat は書かない）。</summary>
    public static bool IsAutoSyncTarget(Material m) =>
        AssetDatabase.GetAssetPath(m).StartsWith("Assets/", StringComparison.Ordinal);

    /// <summary>自分と Material Variant の親がすべて Assets/ 配下か（親が外にあると、親から伝わる値は自動同期で変わらない）。</summary>
    public static bool AutoSyncReaches(Material m)
    {
        for (var x = m; x != null; x = x.parent)
            if (!IsAutoSyncTarget(x)) return false;
        return true;
    }

    // -------------------------------------------------------------------------
    // 同期
    // -------------------------------------------------------------------------
    public sealed class SyncOptions
    {
        public bool DryRun;   // 書かずに「書く予定」だけ報告する
        public bool Save;     // 書いたマテリアルを 1 個ずつ保存する（明示操作・ビルド前）
        internal Func<Material, LinkInfo, bool> Hold;   // true を返したマテリアルは書かない（自動同期の安全装置）
        internal bool ReportHeld;                       // 止めたマテリアルを Problems に載せる（明示操作・ビルド前）
        internal bool AssetsOnly;                       // Assets/ の外は警告せずに飛ばす（自動同期）
    }

    public sealed class SyncReport
    {
        public readonly List<Material> Changed  = new List<Material>();
        public readonly List<string>   Planned  = new List<string>();   // DryRun の「書く予定」
        public readonly List<string>   Problems = new List<string>();
        public int Writes;
        public override string ToString() =>
            "書き込み " + Writes + " 件 / 変更したマテリアル " + Changed.Count + " 個 / 予定 " + Planned.Count + " 件 / 問題 " + Problems.Count + " 件";
    }

    /// <summary>プロジェクト内のすべての継承先を、継承元（または既定値）に合わせる。</summary>
    public static SyncReport SyncAll(SyncOptions options = null) => Sync(SpiderSilkLookIndex.Inheritors, options);

    /// <summary>指定した継承先を継承元に合わせる。同じ値なら何もしない（何度呼んでも結果は同じ）。</summary>
    public static SyncReport Sync(IEnumerable<Material> targets, SyncOptions options = null)
    {
        options = options ?? new SyncOptions();
        var report = new SyncReport();
        if (!SpiderSilkLookValidator.IsShaderSetValid(out var schemaError))
        {
            report.Problems.Add("質感プロパティの一致チェックに失敗しているため同期を止めています: " + schemaError);
            return report;
        }
        var defaults = DefaultValues();
        if (defaults == null) { report.Problems.Add(SourceShaderName + " が見つかりません"); return report; }

        // 継承先だけを重複なしで集め、Material Variant の親が先になるよう並べる
        var list = new List<Material>();
        var seen = new HashSet<Material>();
        foreach (var m in targets)
            if (m != null && GetRole(m.shader) == Role.Inheritor && seen.Add(m)) list.Add(m);
        list.Sort((a, b) => Depth(a).CompareTo(Depth(b)));

        var cache   = new RawCache();
        var goals   = new Dictionary<Material, Vector4[]>();
        var changed = new HashSet<Material>();
        var waiting = new HashSet<Material>();
        var reported = new HashSet<string>();
        var resetNoted = new HashSet<Material>();
        System.Action<string> problem = s => { if (reported.Add(s)) report.Problems.Add(s); };

        int passes = options.DryRun ? 1 : 4;
        for (int pass = 0; pass < passes; pass++)
        {
            int writes = 0;
            waiting.Clear();
            foreach (var m in list)
            {
                var link = GetLink(m);
                if (options.AssetsOnly && !IsAutoSyncTarget(m))
                {
                    // 書かないが、安全装置の判定は通す（リンクの想定外の変化を、後のメニュー同期やビルド前の同期でも止められるように）
                    if (pass == 0) options.Hold?.Invoke(m, link);
                    continue;
                }
                string path = AssetDatabase.GetAssetPath(m);
                if (link.State == LinkState.Broken) { problem(path + ": " + link.Detail); continue; }
                if (options.Hold != null && options.Hold(m, link))
                {
                    if (options.ReportHeld)
                        problem(path + ": 継承元の記録がインスペクタの継承元欄以外の方法で変わったため、値を書き換えずに止めています（継承元を選び直すと再開）");
                    continue;
                }

                Vector4[] goal;
                if (link.State == LinkState.Linked)
                {
                    if (!goals.TryGetValue(link.Source, out goal)) goals[link.Source] = goal = ReadValues(link.Source, cache);
                }
                else goal = defaults;

                var cur = ReadValues(m, cache);
                bool? editable = null;   // 重いので、値がずれていたときだけ調べる
                for (int i = 0; i < Props.Length; i++)
                {
                    var p = Props[i];
                    if (SameBits(cur[i], goal[i], p.IsColor)) continue;
                    editable ??= IsEditable(m);
                    if (!editable.Value) { problem(path + ": 書き込めないため質感を合わせられません"); break; }
                    if (m.IsPropertyLockedByAncestor(p.Name)) { problem(path + ": " + p.Name + " が親マテリアルでロックされています"); continue; }
                    // 親から継承元を受け継いでいて、この項目を上書きしていない子は、親を合わせれば値が伝わる
                    if (link.FromParent && !m.IsPropertyOverriden(p.Name))
                    {
                        // 自動同期で親が書かれない（Assets/ の外にある）なら、伝わるのを待たない
                        if (!options.AssetsOnly || AutoSyncReaches(m)) waiting.Add(m);
                        continue;
                    }
                    if (options.DryRun)
                    {
                        report.Planned.Add(path + " " + p.Name + ": " + Fmt(cur[i], p.IsColor) + " → " + Fmt(goal[i], p.IsColor));
                        continue;
                    }
                    // 継承元なしで既定値にそろえるときは、元の値を控えておく（あとで継承元として作り直せる）
                    if (link.State == LinkState.None && resetNoted.Add(m)) NotePreReset(m, cur, goal);
                    if (p.IsColor) m.SetColor(p.Name, (Color)goal[i]);
                    else           m.SetFloat(p.Name, goal[i].x);
                    writes++;
                    changed.Add(m);
                    cache.Forget(m);   // 子が親の色を読み直せるように
                }
            }
            report.Writes += writes;
            if (writes == 0) break;
        }
        if (resetNoted.Count > 0) SavePreReset();   // 控えはまとめて保存する

        // 親を合わせても値が伝わらない子（通常は起きない）
        foreach (var m in waiting)
        {
            var link = GetLink(m);
            Vector4[] goal = link.State == LinkState.Linked ? ReadValues(link.Source, new RawCache()) : defaults;
            var cur = ReadValues(m, new RawCache());
            for (int i = 0; i < Props.Length; i++)
                if (!SameBits(cur[i], goal[i], Props[i].IsColor))
                {
                    if (options.DryRun)
                        report.Planned.Add(AssetDatabase.GetAssetPath(m) + " " + Props[i].Name + "（親マテリアルの同期で変わる予定）");
                    else
                        problem(AssetDatabase.GetAssetPath(m) + ": " + Props[i].Name + " が親マテリアルから伝わっていません");
                }
        }

        foreach (var m in changed)
        {
            EditorUtility.SetDirty(m);
            if (options.Save) AssetDatabase.SaveAssetIfDirty(m);
            report.Changed.Add(m);
        }
        if (changed.Count > 0) UnityEditorInternal.InternalEditorUtility.RepaintAllViews();
        return report;
    }

    // ---- 既定値にそろえる前の値の控え（Library のファイルにも保存し、再起動後も残す。Console にも出す） ----
    const string PreResetKey  = "SpiderSilkLook_PreReset";
    const string PreResetFile = "Library/SpiderSilkLook_PreReset.txt";
    static Dictionary<string, Vector4[]> s_PreReset;

    static Dictionary<string, Vector4[]> PreReset()
    {
        if (s_PreReset != null) return s_PreReset;
        s_PreReset = new Dictionary<string, Vector4[]>();
        // 同じセッションなら SessionState、再起動後はファイルから読む
        string data = SessionState.GetString(PreResetKey, "");
        if (data.Length == 0)
        {
            try { if (File.Exists(PreResetFile)) data = File.ReadAllText(PreResetFile); }
            catch (Exception e) { Debug.LogWarning("[蜘蛛糸の質感] 控えのファイルを読めません: " + PreResetFile + "\n" + e.Message); }
        }
        var c = System.Globalization.CultureInfo.InvariantCulture;
        var style = System.Globalization.NumberStyles.Float;
        foreach (var entry in data.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = entry.Split('=');
            if (kv.Length != 2) continue;
            var nums = kv[1].Split(',');
            if (nums.Length != Props.Length * 4) continue;
            var f = new float[nums.Length];
            bool ok = true;
            for (int i = 0; i < nums.Length && ok; i++) ok = float.TryParse(nums[i], style, c, out f[i]);
            if (!ok) continue;
            var v = new Vector4[Props.Length];
            for (int i = 0; i < Props.Length; i++) v[i] = new Vector4(f[i * 4], f[i * 4 + 1], f[i * 4 + 2], f[i * 4 + 3]);
            s_PreReset[kv[0]] = v;
        }
        return s_PreReset;
    }

    static void SavePreReset()
    {
        var c = System.Globalization.CultureInfo.InvariantCulture;
        var sb = new System.Text.StringBuilder();
        foreach (var kv in PreReset())
        {
            sb.Append(kv.Key).Append('=');
            for (int i = 0; i < kv.Value.Length; i++)
            {
                var v = kv.Value[i];
                if (i > 0) sb.Append(',');
                sb.Append(v.x.ToString("R", c)).Append(',').Append(v.y.ToString("R", c)).Append(',').Append(v.z.ToString("R", c)).Append(',').Append(v.w.ToString("R", c));
            }
            sb.Append(';');
        }
        string data = sb.ToString();
        SessionState.SetString(PreResetKey, data);
        // 空になったらファイルも消す
        try
        {
            if (data.Length > 0) File.WriteAllText(PreResetFile, data);
            else if (File.Exists(PreResetFile)) File.Delete(PreResetFile);
        }
        catch (Exception e) { Debug.LogWarning("[蜘蛛糸の質感] 控えのファイルを保存できません: " + PreResetFile + "\n" + e.Message); }
    }

    // 控えに入れて Console に出す（ファイルへの保存は Sync の最後にまとめて行う）
    static void NotePreReset(Material m, Vector4[] old, Vector4[] goal)
    {
        string guid = AssetDatabase.AssetPathToGUID(AssetDatabase.GetAssetPath(m));
        if (string.IsNullOrEmpty(guid)) return;
        PreReset()[guid] = (Vector4[])old.Clone();
        var sb = new System.Text.StringBuilder("[蜘蛛糸の質感] 継承元なしのため、質感を蜘蛛糸シェーダーの既定値にそろえました: " + AssetDatabase.GetAssetPath(m) +
            "\n元の見た目に戻すには、インスペクタの「そろえる前の質感で継承元を作る…」を押してください（元の値は下のとおり）");
        for (int i = 0; i < Props.Length; i++)
            if (!SameBits(old[i], goal[i], Props[i].IsColor))
                sb.Append("\n  ").Append(Props[i].Name).Append(": ").Append(Fmt(old[i], Props[i].IsColor)).Append(" → ").Append(Fmt(goal[i], Props[i].IsColor));
        Debug.LogWarning(sb.ToString(), m);
    }

    /// <summary>継承元なしで既定値にそろえる前の質感（控えはエディタを閉じても残る）。</summary>
    public static bool TryGetPreResetValues(Material m, out Vector4[] values)
    {
        values = null;
        string guid = AssetDatabase.AssetPathToGUID(AssetDatabase.GetAssetPath(m));
        return !string.IsNullOrEmpty(guid) && PreReset().TryGetValue(guid, out values);
    }

    public static void ForgetPreResetValues(Material m)
    {
        string guid = AssetDatabase.AssetPathToGUID(AssetDatabase.GetAssetPath(m));
        if (!string.IsNullOrEmpty(guid) && PreReset().Remove(guid)) SavePreReset();
    }

    static int Depth(Material m) { int d = 0; for (var p = m.parent; p != null && d < 32; p = p.parent) d++; return d; }

    // -------------------------------------------------------------------------
    // 明示操作
    // -------------------------------------------------------------------------

    /// <summary>
    /// 【明示操作専用・Ctrl+Z では戻せない】Material Variant で、親と同じ値なのに残っている
    /// 質感と継承元の上書き（override）を外す。見た目は変わらない。外した数を返す。
    /// </summary>
    public static int CleanupRedundantOverrides(Material variant)
    {
        if (variant == null || variant.parent == null || GetRole(variant.shader) != Role.Inheritor) return 0;
        var cache = new RawCache();
        int count = 0;
        foreach (var p in Props)
        {
            if (!variant.IsPropertyOverriden(p.Name)) continue;
            bool equal = p.IsColor
                ? SameBits(GetRawColor(variant, p.Name, cache), GetRawColor(variant.parent, p.Name, cache), true)
                : BitConverter.SingleToInt32Bits(variant.GetFloat(p.Name)) == BitConverter.SingleToInt32Bits(variant.parent.GetFloat(p.Name));
            if (!equal) continue;
            variant.RevertPropertyOverride(p.Name);
            cache.Forget(variant);
            count++;
        }
        if (variant.IsPropertyOverriden(LinkProperty))
        {
            var a = variant.GetVector(LinkProperty); var b = variant.parent.GetVector(LinkProperty);
            if (SameBits(a, b, true)) { variant.RevertPropertyOverride(LinkProperty); count++; }
        }
        if (count > 0) EditorUtility.SetDirty(variant);
        return count;
    }

    /// <summary>
    /// 今の質感（21 値）を持つ新しい蜘蛛糸マテリアル（粘液モード ON）を作る。
    /// template があればその Material Variant にする（違う値だけが上書きになる）。
    /// </summary>
    public static Material CreateSourceFromLook(Material lookFrom, string assetPath, Material template = null) =>
        lookFrom == null ? null : CreateSourceFromValues(ReadValues(lookFrom), assetPath, template);

    /// <summary>
    /// 21 値（ReadValues の形）を持つ新しい蜘蛛糸マテリアルを作る。既にあるアセットのパスには作らない
    /// （上書きすると GUID が変わり、そのアセットを使っていた参照や継承がすべて切れるため）。
    /// </summary>
    public static Material CreateSourceFromValues(Vector4[] values, string assetPath, Material template = null)
    {
        var shader = Shader.Find(SourceShaderName);
        if (shader == null || values == null || values.Length != Props.Length || string.IsNullOrEmpty(assetPath)) return null;
        if (AssetDatabase.LoadMainAssetAtPath(assetPath) != null)
        {
            Debug.LogWarning("[蜘蛛糸の質感] 既にあるアセットには上書きしません（参照や継承が切れるため）: " + assetPath);
            return null;
        }
        Material mat;
        if (template != null && GetRole(template.shader) == Role.Source)
        {
            mat = new Material(template);
            mat.parent = template;
        }
        else
        {
            mat = new Material(shader);
            mat.SetFloat("_GooEnable", 1f);
            mat.SetKeyword(new LocalKeyword(shader, "_GOO_ON"), true);
        }
        for (int i = 0; i < Props.Length; i++)
        {
            if (Props[i].IsColor) mat.SetColor(Props[i].Name, (Color)values[i]);
            else                  mat.SetFloat(Props[i].Name, values[i].x);
        }
        string dir = Path.GetDirectoryName(assetPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        AssetDatabase.CreateAsset(mat, assetPath);
        AssetDatabase.SaveAssetIfDirty(mat);
        SpiderSilkLookIndex.Invalidate();
        return mat;
    }
}
