using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

// =============================================================================
// SpiderSilkLookValidator — 質感 21 項目が全対応シェーダーでそろっているかの自動チェック。
//
//  ShaderLab の Properties ブロックは include できないので、対応する各 .shader に
//  同じ行を書き写して管理している。書き写し漏れ（範囲・既定値の違いなど）があると
//  「継承元の値をそのまま写す」前提が崩れるので、ここで機械的に確かめる。
//   ・Properties: 型・範囲・既定値（完全一致）・フラグ・属性（[Header] などの装飾は除く）
//   ・_SilkLookLink が巣・繭・繭デカール・蜘蛛の巣ドレープにだけある（Vector・既定値 0・HideInInspector）
//   ・HLSL: 質感 21 個の uniform 宣言は CGINC/SpiderSilk_Look.cginc の 1 か所だけ
//
//  実行: メニュー Tools/SpiderShader/質感プロパティの一致チェック、
//        およびシェーダー・cginc の取り込み後（問題があるときだけ Console に警告）。
//  一致していない間は、自動同期（SpiderSilkLook.Sync）を止める。
// =============================================================================
public static class SpiderSilkLookValidator
{
    static bool?  s_Valid;
    static string s_Error;

    /// <summary>同期してよい状態か（Properties の一致だけを見る軽いチェック。結果はシェーダーの取り込みまで覚えておく）。</summary>
    public static bool IsShaderSetValid(out string error)
    {
        if (s_Valid == null)
        {
            var problems = CheckProperties();
            s_Valid = problems.Count == 0;
            s_Error = problems.Count == 0 ? null : problems[0] + (problems.Count > 1 ? "（ほか " + (problems.Count - 1) + " 件）" : "");
        }
        error = s_Error;
        return s_Valid.Value;
    }

    public static void Invalidate() { s_Valid = null; s_Error = null; SpiderSilkLook.InvalidateCaches(); }

    /// <summary>すべてのチェック（Properties ＋ HLSL の宣言）。日本語のメッセージ一覧を返す（空なら問題なし）。</summary>
    public static List<string> Validate()
    {
        var list = CheckProperties();
        list.AddRange(CheckHlsl());
        return list;
    }

    static Shader[] LoadShaders(List<string> problems)
    {
        var names = new List<string> { SpiderSilkLook.SourceShaderName };
        names.AddRange(SpiderSilkLook.InheritorShaderNames);
        var shaders = new Shader[names.Count];
        for (int i = 0; i < names.Count; i++)
        {
            shaders[i] = Shader.Find(names[i]);
            if (shaders[i] == null) problems.Add(names[i] + " が見つかりません");
        }
        return shaders;
    }

    static List<string> CheckProperties()
    {
        var problems = new List<string>();
        var shaders = LoadShaders(problems);
        if (problems.Count > 0) return problems;
        var t = shaders[0];

        foreach (var p in SpiderSilkLook.Props)
        {
            int ti = t.FindPropertyIndex(p.Name);
            if (ti < 0) { problems.Add(t.name + " に " + p.Name + " がありません"); continue; }
            var tType = t.GetPropertyType(ti);
            if (p.IsColor != (tType == ShaderPropertyType.Color))
                problems.Add(t.name + " の " + p.Name + " の型（" + tType + "）が一覧（Editor/SpiderSilkLook.cs）と違います");

            for (int k = 1; k < shaders.Length; k++)
            {
                var s = shaders[k];
                int si = s.FindPropertyIndex(p.Name);
                string head = "[蜘蛛糸の質感チェック] " + Short(s) + " の " + p.Name + ": ";
                string tail = "。" + Short(s) + ".shader の Properties のこの行を SpiderSilk.shader と同じ「型・範囲・既定値」にしてください（一覧: Editor/SpiderSilkLook.cs）";
                if (si < 0) { problems.Add(head + "プロパティがありません" + tail); continue; }
                var sType = s.GetPropertyType(si);
                if (sType != tType) { problems.Add(head + "型 " + sType + " が蜘蛛糸の " + tType + " と違います" + tail); continue; }
                if (tType == ShaderPropertyType.Range)
                {
                    var a = t.GetPropertyRangeLimits(ti); var b = s.GetPropertyRangeLimits(si);
                    if (!Same(a.x, b.x) || !Same(a.y, b.y))
                        problems.Add(head + "範囲 " + R(b.x) + "〜" + R(b.y) + " が蜘蛛糸の " + R(a.x) + "〜" + R(a.y) + " と違います" + tail);
                }
                if (tType == ShaderPropertyType.Color || tType == ShaderPropertyType.Vector)
                {
                    var a = t.GetPropertyDefaultVectorValue(ti); var b = s.GetPropertyDefaultVectorValue(si);
                    if (!Same(a.x, b.x) || !Same(a.y, b.y) || !Same(a.z, b.z) || !Same(a.w, b.w))
                        problems.Add(head + "既定値 " + b + " が蜘蛛糸の " + a + " と違います" + tail);
                }
                else
                {
                    float a = t.GetPropertyDefaultFloatValue(ti), b = s.GetPropertyDefaultFloatValue(si);
                    if (!Same(a, b)) problems.Add(head + "既定値 " + R(b) + " が蜘蛛糸の " + R(a) + " と違います" + tail);
                }
                if (t.GetPropertyFlags(ti) != s.GetPropertyFlags(si))
                    problems.Add(head + "フラグ " + s.GetPropertyFlags(si) + " が蜘蛛糸の " + t.GetPropertyFlags(ti) + " と違います" + tail);
                if (Attrs(t, ti) != Attrs(s, si))
                    problems.Add(head + "属性 [" + Attrs(s, si) + "] が蜘蛛糸の [" + Attrs(t, ti) + "] と違います" + tail);
            }
        }

        // リンク用の隠しプロパティ
        if (t.FindPropertyIndex(SpiderSilkLook.LinkProperty) >= 0)
            problems.Add(t.name + " に " + SpiderSilkLook.LinkProperty + " があります（継承先の巣・繭・繭デカール・蜘蛛の巣ドレープだけが持つプロパティです）");
        for (int k = 1; k < shaders.Length; k++)
        {
            var s = shaders[k];
            int li = s.FindPropertyIndex(SpiderSilkLook.LinkProperty);
            if (li < 0) { problems.Add(Short(s) + " に " + SpiderSilkLook.LinkProperty + " がありません"); continue; }
            if (s.GetPropertyType(li) != ShaderPropertyType.Vector ||
                (s.GetPropertyFlags(li) & ShaderPropertyFlags.HideInInspector) == 0 ||
                s.GetPropertyDefaultVectorValue(li) != Vector4.zero)
                problems.Add(Short(s) + " の " + SpiderSilkLook.LinkProperty + " は [HideInInspector] の Vector・既定値 (0,0,0,0) にしてください");
        }
        return problems;
    }

    static readonly Regex s_Decl = new Regex(@"^\s*(?:uniform\s+)?(float|half|fixed)([234]?)\s+([^;(){}=]+);", RegexOptions.Multiline);

    static List<string> CheckHlsl()
    {
        var problems = new List<string>();
        var t = Shader.Find(SpiderSilkLook.SourceShaderName);
        if (t == null) return problems;
        string runtime = Path.GetDirectoryName(AssetDatabase.GetAssetPath(t));
        if (string.IsNullOrEmpty(runtime)) return problems;
        string lookPath = Path.Combine(runtime, "CGINC", "SpiderSilk_Look.cginc");
        if (!File.Exists(lookPath)) { problems.Add("CGINC/SpiderSilk_Look.cginc がありません"); return problems; }

        // SpiderSilk_Look.cginc の宣言 = 一覧の 21 個（型も一致）
        var declared = new Dictionary<string, string>();
        foreach (var d in Declarations(File.ReadAllText(lookPath))) declared[d.Key] = d.Value;
        foreach (var p in SpiderSilkLook.Props)
        {
            if (!declared.TryGetValue(p.Name, out var type)) { problems.Add("SpiderSilk_Look.cginc に " + p.Name + " の宣言がありません"); continue; }
            string want = p.IsColor ? "float4" : "float";
            if (type != want) problems.Add("SpiderSilk_Look.cginc の " + p.Name + " は " + want + " で宣言してください（今は " + type + "）");
        }
        foreach (var name in declared.Keys)
            if (!SpiderSilkLook.IsLookProperty(name)) problems.Add("SpiderSilk_Look.cginc に一覧に無い " + name + " が宣言されています");

        // ほかのファイルで質感を宣言していないか（同名の二重宣言はコンパイルエラーの元）
        var files = new List<string>(Directory.GetFiles(Path.Combine(runtime, "CGINC"), "*.cginc"));
        files.AddRange(Directory.GetFiles(runtime, "*.shader"));
        foreach (var f in files)
        {
            if (Path.GetFileName(f) == "SpiderSilk_Look.cginc") continue;
            foreach (var d in Declarations(File.ReadAllText(f)))
                if (SpiderSilkLook.IsLookProperty(d.Key))
                    problems.Add(Path.GetFileName(f) + " で質感の " + d.Key + " が宣言されています（宣言は SpiderSilk_Look.cginc だけにしてください）");
        }
        return problems;
    }

    // コメントを除いてから「型 名前[, 名前…];」の宣言を拾う
    static IEnumerable<KeyValuePair<string, string>> Declarations(string text)
    {
        text = Regex.Replace(text, @"/\*.*?\*/", "", RegexOptions.Singleline);
        text = Regex.Replace(text, @"//[^\n]*", "");
        foreach (Match m in s_Decl.Matches(text))
        {
            string type = m.Groups[1].Value + m.Groups[2].Value;
            foreach (var part in m.Groups[3].Value.Split(','))
            {
                var name = part.Trim();
                int br = name.IndexOf('[');
                if (br >= 0) name = name.Substring(0, br).Trim();
                if (Regex.IsMatch(name, @"^_\w+$")) yield return new KeyValuePair<string, string>(name, type);
            }
        }
    }

    static string Attrs(Shader s, int i)
    {
        var list = new List<string>();
        foreach (var a in s.GetPropertyAttributes(i))
            if (!a.StartsWith("Header", StringComparison.Ordinal) && !a.StartsWith("Space", StringComparison.Ordinal)) list.Add(a);
        return string.Join(",", list);
    }

    static bool Same(float a, float b) => BitConverter.SingleToInt32Bits(a) == BitConverter.SingleToInt32Bits(b);
    static string R(float f) => f.ToString("R");
    static string Short(Shader s) => s.name.Replace("mecaota/", "");

    [MenuItem("Tools/SpiderShader/質感プロパティの一致チェック")]
    static void MenuValidate()
    {
        Invalidate();
        var list = Validate();
        if (list.Count == 0)
        {
            int shaderCount = 1 + SpiderSilkLook.InheritorShaderNames.Length;
            string message = "21 個の質感プロパティは " + shaderCount + " シェーダーで一致しています。";
            Debug.Log("[蜘蛛糸の質感チェック] " + message);
            EditorUtility.DisplayDialog("質感プロパティの一致チェック", message, "OK");
        }
        else
        {
            Debug.LogWarning("[蜘蛛糸の質感チェック] " + list.Count + " 件の不一致:\n" + string.Join("\n", list));
            EditorUtility.DisplayDialog("質感プロパティの一致チェック", list.Count + " 件の不一致があります。詳細は Console を見てください。\n\n" + list[0], "OK");
        }
    }

    // シェーダー・cginc の取り込み後に 1 回だけ確かめる（問題があるときだけ警告）
    internal static void ScheduleCheck()
    {
        Invalidate();
        if (s_Scheduled) return;
        s_Scheduled = true;
        EditorApplication.delayCall += () =>
        {
            s_Scheduled = false;
            var list = Validate();
            if (list.Count > 0) Debug.LogWarning("[蜘蛛糸の質感チェック] " + list.Count + " 件の不一致（一致するまで質感の自動同期を止めます）:\n" + string.Join("\n", list));
        };
    }
    static bool s_Scheduled;
}
