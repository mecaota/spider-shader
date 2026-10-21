// このファイルは C# の null 許容の注釈（nullable）を使わない書き方をしている。利用側のプロジェクトが
// 追加のコンパイラ引数（csc.rsp の -nullable:enable など）で注釈を有効にしても警告が出ないよう、明示的に無効にする。
#nullable disable
using System;
using System.Collections.Generic;
using System.Globalization;
using UnityEditor;
using UnityEngine;

// =============================================================================
// SpiderWebMaterialSnapshotUtil.cs — マテリアルの「全部の値の写し」を取る・作り直す・比べる（Editor 専用）
//
//  巣を lilToon に焼き込むとき（SpiderWebLilToonBaker）、元のマテリアルの値を控えのコンポーネント
//  （Runtime/WebBake/SpiderWebBakeBackup.cs）に残すために使う。
//  元のマテリアルのアセットが消えても、この写しから同じ値のマテリアルを作り直せる。
//
//  ■ 値の取り方
//    ・保存されている生の値（SerializedObject の m_SavedProperties）を読む。
//      Material.GetColor は、Linear 色空間のプロジェクトでは 1 ULP ずれた値を返すことがあるため使わない。
//    ・マテリアルバリアントは、自分が上書きした値しか持っていない。親 → 子の順に重ねて、実際に効いている値にする。
//    ・シェーダーにあるのに保存されていない値は、Material の API で読む（シェーダーの既定値）。
// =============================================================================
public static class SpiderWebMaterialSnapshotUtil
{
    /// <summary>マテリアルの全部の値の写しを取る（マテリアルは変えない）。</summary>
    public static SpiderWebMaterialSnapshot Capture(Material material, int slot)
    {
        if (material == null) throw new ArgumentNullException(nameof(material));
        var s = new SpiderWebMaterialSnapshot { slot = slot, name = material.name };
        string path = AssetDatabase.GetAssetPath(material);
        s.assetPath = path ?? "";
        s.assetGuid = string.IsNullOrEmpty(path) ? "" : AssetDatabase.AssetPathToGUID(path);
        Shader shader = material.shader;
        s.shaderName = shader != null ? shader.name : "";
        string shaderPath = shader != null ? AssetDatabase.GetAssetPath(shader) : "";
        s.shaderGuid = string.IsNullOrEmpty(shaderPath) ? "" : AssetDatabase.AssetPathToGUID(shaderPath);
        Material parent = material.parent;
        if (parent != null)
        {
            s.parentPath = AssetDatabase.GetAssetPath(parent) ?? "";
            s.parentGuid = string.IsNullOrEmpty(s.parentPath) ? "" : AssetDatabase.AssetPathToGUID(s.parentPath);
        }

        // 親から順に重ねる（バリアントの子が上書きした値が勝つ）
        var chain = new List<Material>();
        for (Material m = material; m != null && chain.Count < 32; m = m.parent) chain.Insert(0, m);

        var floats = new SortedDictionary<string, float>(StringComparer.Ordinal);
        var ints = new SortedDictionary<string, int>(StringComparer.Ordinal);
        var colors = new SortedDictionary<string, Color>(StringComparer.Ordinal);
        var textures = new SortedDictionary<string, SpiderWebSnapshotTexture>(StringComparer.Ordinal);
        var tags = new SortedDictionary<string, string>(StringComparer.Ordinal);
        var disabled = new SortedSet<string>(StringComparer.Ordinal);
        int queue = -1;
        foreach (Material m in chain)
        {
            var so = new SerializedObject(m);
            ReadPairs(so.FindProperty("m_SavedProperties.m_Floats"), p => floats[p.Key] = p.Value.floatValue);
            ReadPairs(so.FindProperty("m_SavedProperties.m_Ints"), p => ints[p.Key] = p.Value.intValue);
            ReadPairs(so.FindProperty("m_SavedProperties.m_Colors"), p => colors[p.Key] = p.Value.colorValue);
            ReadPairs(so.FindProperty("m_SavedProperties.m_TexEnvs"), p =>
            {
                Texture tex = p.Value.FindPropertyRelative("m_Texture").objectReferenceValue as Texture;
                textures[p.Key] = new SpiderWebSnapshotTexture
                {
                    name = p.Key,
                    texture = tex,
                    textureGuid = GuidOf(tex),
                    scale = p.Value.FindPropertyRelative("m_Scale").vector2Value,
                    offset = p.Value.FindPropertyRelative("m_Offset").vector2Value,
                };
            });
            ReadPairs(so.FindProperty("stringTagMap"), p => tags[p.Key] = p.Value.stringValue);
            var passes = so.FindProperty("disabledShaderPasses");
            if (passes != null && passes.isArray)
                for (int i = 0; i < passes.arraySize; i++) disabled.Add(passes.GetArrayElementAtIndex(i).stringValue);
            var q = so.FindProperty("m_CustomRenderQueue");
            if (q != null && q.intValue >= 0) queue = q.intValue;
        }

        // シェーダーにあるのに保存されていない値（シェーダーの既定値）を補う
        if (shader != null)
        {
            int n = shader.GetPropertyCount();
            for (int i = 0; i < n; i++)
            {
                string prop = shader.GetPropertyName(i);
                switch (shader.GetPropertyType(i))
                {
                    case UnityEngine.Rendering.ShaderPropertyType.Float:
                    case UnityEngine.Rendering.ShaderPropertyType.Range:
                        if (!floats.ContainsKey(prop)) floats[prop] = material.GetFloat(prop);
                        break;
                    case UnityEngine.Rendering.ShaderPropertyType.Int:
                        if (!ints.ContainsKey(prop)) ints[prop] = material.GetInteger(prop);
                        break;
                    case UnityEngine.Rendering.ShaderPropertyType.Color:
                    case UnityEngine.Rendering.ShaderPropertyType.Vector:
                        if (!colors.ContainsKey(prop)) colors[prop] = (Color)material.GetVector(prop);
                        break;
                    case UnityEngine.Rendering.ShaderPropertyType.Texture:
                        if (!textures.ContainsKey(prop))
                        {
                            Texture tex = material.GetTexture(prop);
                            textures[prop] = new SpiderWebSnapshotTexture
                            {
                                name = prop, texture = tex, textureGuid = GuidOf(tex),
                                scale = material.GetTextureScale(prop), offset = material.GetTextureOffset(prop),
                            };
                        }
                        break;
                }
            }
        }

        s.customRenderQueue = queue;
        s.keywords = material.shaderKeywords ?? new string[0];
        Array.Sort(s.keywords, StringComparer.Ordinal);
        s.enableInstancing = material.enableInstancing;
        s.doubleSidedGI = material.doubleSidedGI;
        s.globalIlluminationFlags = (int)material.globalIlluminationFlags;
        s.tagKeys = new string[tags.Count];
        s.tagValues = new string[tags.Count];
        int t = 0;
        foreach (var kv in tags) { s.tagKeys[t] = kv.Key; s.tagValues[t] = kv.Value; t++; }
        s.disabledPasses = new string[disabled.Count];
        disabled.CopyTo(s.disabledPasses);

        s.floats = new SpiderWebSnapshotFloat[floats.Count];
        int k = 0;
        foreach (var kv in floats) s.floats[k++] = new SpiderWebSnapshotFloat { name = kv.Key, value = kv.Value };
        s.ints = new SpiderWebSnapshotInt[ints.Count];
        k = 0;
        foreach (var kv in ints) s.ints[k++] = new SpiderWebSnapshotInt { name = kv.Key, value = kv.Value };
        s.colors = new SpiderWebSnapshotColor[colors.Count];
        k = 0;
        foreach (var kv in colors) s.colors[k++] = new SpiderWebSnapshotColor { name = kv.Key, value = kv.Value };
        s.textures = new SpiderWebSnapshotTexture[textures.Count];
        textures.Values.CopyTo(s.textures, 0);
        return s;
    }

    /// <summary>写しから新しいマテリアルを作る（アセットにはしない。保存は呼び出し側）。</summary>
    public static Material Recreate(SpiderWebMaterialSnapshot s)
    {
        if (s == null) throw new ArgumentNullException(nameof(s));
        Shader shader = string.IsNullOrEmpty(s.shaderName) ? null : Shader.Find(s.shaderName);
        if (shader == null && !string.IsNullOrEmpty(s.shaderGuid))
            shader = AssetDatabase.LoadAssetAtPath<Shader>(AssetDatabase.GUIDToAssetPath(s.shaderGuid));
        if (shader == null)
            throw new InvalidOperationException("元のシェーダーが見つからないので作り直せません: " + s.shaderName);
        var m = new Material(shader) { name = s.name };
        foreach (var f in s.floats) m.SetFloat(f.name, f.value);
        foreach (var i in s.ints) m.SetInteger(i.name, i.value);
        // SetColor は渡した値をそのまま保存する（GetColor のずれは起きない）
        foreach (var c in s.colors) m.SetColor(c.name, c.value);
        foreach (var t in s.textures)
        {
            Texture tex = t.texture;
            if (tex == null && !string.IsNullOrEmpty(t.textureGuid))
                tex = AssetDatabase.LoadAssetAtPath<Texture>(AssetDatabase.GUIDToAssetPath(t.textureGuid));
            m.SetTexture(t.name, tex);
            m.SetTextureScale(t.name, t.scale);
            m.SetTextureOffset(t.name, t.offset);
        }
        m.shaderKeywords = s.keywords ?? new string[0];
        for (int i = 0; i < s.tagKeys.Length && i < s.tagValues.Length; i++) m.SetOverrideTag(s.tagKeys[i], s.tagValues[i]);
        foreach (string pass in s.disabledPasses) m.SetShaderPassEnabled(pass, false);
        m.enableInstancing = s.enableInstancing;
        m.doubleSidedGI = s.doubleSidedGI;
        m.globalIlluminationFlags = (MaterialGlobalIlluminationFlags)s.globalIlluminationFlags;
        m.renderQueue = s.customRenderQueue;   // -1 ならシェーダーの値
        // シェーダーに無い古い値（以前のシェーダーの名残り）は API では保存されないので、保存されている形で直接足す。
        // 描画には使われないが、元のマテリアルと同じ中身にしておく
        AddMissingSaved(m, s);
        return m;
    }

    private static void AddMissingSaved(Material m, SpiderWebMaterialSnapshot s)
    {
        var so = new SerializedObject(m);
        bool changed = false;
        changed |= AddPairs(so.FindProperty("m_SavedProperties.m_Floats"), s.floats, x => x.name, (p, x) => p.floatValue = x.value);
        changed |= AddPairs(so.FindProperty("m_SavedProperties.m_Ints"), s.ints, x => x.name, (p, x) => p.intValue = x.value);
        changed |= AddPairs(so.FindProperty("m_SavedProperties.m_Colors"), s.colors, x => x.name, (p, x) => p.colorValue = x.value);
        changed |= AddPairs(so.FindProperty("m_SavedProperties.m_TexEnvs"), s.textures, x => x.name, (p, x) =>
        {
            Texture tex = x.texture;
            if (tex == null && !string.IsNullOrEmpty(x.textureGuid))
                tex = AssetDatabase.LoadAssetAtPath<Texture>(AssetDatabase.GUIDToAssetPath(x.textureGuid));
            p.FindPropertyRelative("m_Texture").objectReferenceValue = tex;
            p.FindPropertyRelative("m_Scale").vector2Value = x.scale;
            p.FindPropertyRelative("m_Offset").vector2Value = x.offset;
        });
        if (changed) so.ApplyModifiedPropertiesWithoutUndo();
    }

    // 「名前と値の組」の配列に、まだ無い名前の組を足す
    private static bool AddPairs<T>(SerializedProperty array, T[] items, Func<T, string> name, Action<SerializedProperty, T> set)
    {
        if (array == null || !array.isArray || items == null) return false;
        var have = new HashSet<string>(StringComparer.Ordinal);
        for (int i = 0; i < array.arraySize; i++)
        {
            SerializedProperty first = array.GetArrayElementAtIndex(i).FindPropertyRelative("first");
            if (first != null) have.Add(first.stringValue);
        }
        bool changed = false;
        foreach (T item in items)
        {
            if (have.Contains(name(item))) continue;
            array.InsertArrayElementAtIndex(array.arraySize);
            SerializedProperty pair = array.GetArrayElementAtIndex(array.arraySize - 1);
            pair.FindPropertyRelative("first").stringValue = name(item);
            set(pair.FindPropertyRelative("second"), item);
            changed = true;
        }
        return changed;
    }

    /// <summary>
    /// 2 つの写しの「値」の違いを並べる（名前・場所・GUID・親は比べない）。空なら同じ。
    /// 浮動小数は 1 ビットも違わないことを確かめる（BitConverter で比較）。
    /// </summary>
    public static List<string> Compare(SpiderWebMaterialSnapshot a, SpiderWebMaterialSnapshot b)
    {
        var diff = new List<string>();
        if (a.shaderName != b.shaderName) diff.Add("shader " + a.shaderName + " / " + b.shaderName);
        if (a.customRenderQueue != b.customRenderQueue) diff.Add("queue " + a.customRenderQueue + " / " + b.customRenderQueue);
        if (string.Join(" ", a.keywords) != string.Join(" ", b.keywords))
            diff.Add("keywords [" + string.Join(" ", a.keywords) + "] / [" + string.Join(" ", b.keywords) + "]");
        if (a.enableInstancing != b.enableInstancing) diff.Add("instancing");
        if (a.doubleSidedGI != b.doubleSidedGI) diff.Add("doubleSidedGI");
        if (a.globalIlluminationFlags != b.globalIlluminationFlags) diff.Add("giFlags " + a.globalIlluminationFlags + " / " + b.globalIlluminationFlags);
        if (string.Join("|", a.tagKeys) + "=" + string.Join("|", a.tagValues) != string.Join("|", b.tagKeys) + "=" + string.Join("|", b.tagValues))
            diff.Add("tags");
        if (string.Join("|", a.disabledPasses) != string.Join("|", b.disabledPasses)) diff.Add("disabledPasses");
        CompareList(diff, "float", a.floats, b.floats, x => x.name, x => BitConverter.ToInt32(BitConverter.GetBytes(x.value), 0).ToString(CultureInfo.InvariantCulture) + "(" + x.value.ToString("R", CultureInfo.InvariantCulture) + ")");
        CompareList(diff, "int", a.ints, b.ints, x => x.name, x => x.value.ToString(CultureInfo.InvariantCulture));
        CompareList(diff, "color", a.colors, b.colors, x => x.name, x => Bits(x.value.r) + "," + Bits(x.value.g) + "," + Bits(x.value.b) + "," + Bits(x.value.a));
        CompareList(diff, "texture", a.textures, b.textures, x => x.name,
            x => (x.texture != null ? x.texture.GetInstanceID().ToString(CultureInfo.InvariantCulture) : "null") + " " + Bits(x.scale.x) + "," + Bits(x.scale.y) + "," + Bits(x.offset.x) + "," + Bits(x.offset.y));
        return diff;
    }

    private static string Bits(float v)
    {
        return BitConverter.ToInt32(BitConverter.GetBytes(v), 0).ToString("X8", CultureInfo.InvariantCulture);
    }

    private static void CompareList<T>(List<string> diff, string kind, T[] a, T[] b, Func<T, string> key, Func<T, string> value)
    {
        var da = new Dictionary<string, string>(StringComparer.Ordinal);
        var db = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (T x in a) da[key(x)] = value(x);
        foreach (T x in b) db[key(x)] = value(x);
        foreach (var kv in da)
        {
            if (!db.TryGetValue(kv.Key, out string other)) diff.Add(kind + " " + kv.Key + " missing in second");
            else if (other != kv.Value) diff.Add(kind + " " + kv.Key + " " + kv.Value + " / " + other);
        }
        foreach (var kv in db)
            if (!da.ContainsKey(kv.Key)) diff.Add(kind + " " + kv.Key + " missing in first");
    }

    private static string GuidOf(UnityEngine.Object obj)
    {
        if (obj == null) return "";
        string path = AssetDatabase.GetAssetPath(obj);
        return string.IsNullOrEmpty(path) ? "" : AssetDatabase.AssetPathToGUID(path);
    }

    // m_SavedProperties などの「名前と値の組」の配列を 1 つずつ渡す
    private static void ReadPairs(SerializedProperty array, Action<KeyValuePair<string, SerializedProperty>> each)
    {
        if (array == null || !array.isArray) return;
        for (int i = 0; i < array.arraySize; i++)
        {
            SerializedProperty pair = array.GetArrayElementAtIndex(i);
            SerializedProperty first = pair.FindPropertyRelative("first");
            SerializedProperty second = pair.FindPropertyRelative("second");
            if (first == null || second == null) continue;
            each(new KeyValuePair<string, SerializedProperty>(first.stringValue, second));
        }
    }
}
