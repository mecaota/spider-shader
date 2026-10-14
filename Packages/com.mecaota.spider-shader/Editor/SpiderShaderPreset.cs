using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using PresetPart = SpiderCocoonShaderGUI.PresetPart;

// =============================================================================
// SpiderShaderPreset — lilToon のプリセットに相当する「マテリアル設定のひな形」。
//
//  ・1 アセット = 1 プリセット。対象シェーダーと、保存したプロパティの値を持つ。
//  ・マテリアルのインスペクタ先頭の「プリセット」欄に、同じシェーダーの
//    プリセットがカテゴリ別のボタンとして並び、押すと値がマテリアルに入る
//    （Ctrl+Z で戻せる）。
//  ・標準プリセットはパッケージの Presets フォルダに同梱。自分で保存した
//    プリセットはプロジェクト内のどこに置いても自動で見つかる。
//  ・どの値がどのグループに入るかは SpiderCocoonShaderGUI のカテゴリ表で決まる。
//
// ※ Editor 専用。ワールドのビルドには含まれない。
// =============================================================================
public class SpiderShaderPreset : ScriptableObject
{
    [Serializable] public struct FloatValue   { public string name; public float   value; }
    [Serializable] public struct ColorValue   { public string name; public Color   value; }
    [Serializable] public struct VectorValue  { public string name; public Vector4 value; }
    [Serializable] public struct TextureValue { public string name; public Texture value; public Vector4 scaleOffset; }

    [Tooltip("プリセット欄のボタンに出る名前")]
    public string displayName;
    [Tooltip("同じカテゴリのプリセットがまとめて並ぶ")]
    public string category;
    [TextArea(2, 8), Tooltip("ボタンにマウスを乗せると出る説明")]
    public string description;
    [Tooltip("小さいほど前に並ぶ（標準プリセットは 1〜999）")]
    public int order = 1000;
    [Tooltip("このプリセットを使えるシェーダー")]
    public Shader shader;
    [Tooltip("描画順。-1 なら適用しても描画順は変えない")]
    public int renderQueue = -1;

    public List<FloatValue>   floats   = new List<FloatValue>();
    public List<ColorValue>   colors   = new List<ColorValue>();
    public List<VectorValue>  vectors  = new List<VectorValue>();
    public List<TextureValue> textures = new List<TextureValue>();

    public string Label => string.IsNullOrEmpty(displayName) ? name : displayName;
    public int ValueCount => floats.Count + colors.Count + vectors.Count + textures.Count;

    // -------------------------------------------------------------------------
    // 保存: マテリアルの今の値を、includeGroup が true のグループだけ取り込む
    // -------------------------------------------------------------------------
    public void Capture(Material source, Func<string, bool> includeGroup)
    {
        var s = source.shader;
        shader = s;
        floats.Clear(); colors.Clear(); vectors.Clear(); textures.Clear();

        int n = s.GetPropertyCount();
        for (int i = 0; i < n; i++)
        {
            string prop = s.GetPropertyName(i);
            if (!SpiderCocoonShaderGUI.TryGetPresetGroup(s, prop, out var group, out _)) continue;
            if (includeGroup != null && !includeGroup(group)) continue;

            switch (s.GetPropertyType(i))
            {
                case ShaderPropertyType.Float:
                case ShaderPropertyType.Range:
                    floats.Add(new FloatValue { name = prop, value = source.GetFloat(prop) });
                    break;
                case ShaderPropertyType.Int:
                    floats.Add(new FloatValue { name = prop, value = source.GetInteger(prop) });
                    break;
                case ShaderPropertyType.Color:
                    // GetColor は Linear プロジェクトで最下位ビットを落とすので、保存されている生の値を使う
                    colors.Add(new ColorValue { name = prop, value = SpiderSilkLook.GetRawColor(source, prop) });
                    break;
                case ShaderPropertyType.Vector:
                    vectors.Add(new VectorValue { name = prop, value = source.GetVector(prop) });
                    break;
                case ShaderPropertyType.Texture:
                    var scale  = source.GetTextureScale(prop);
                    var offset = source.GetTextureOffset(prop);
                    textures.Add(new TextureValue
                    {
                        name = prop, value = source.GetTexture(prop),
                        scaleOffset = new Vector4(scale.x, scale.y, offset.x, offset.y),
                    });
                    break;
            }
        }

        // シェーダー既定の描画順（-1）のときは保存しない＝適用しても変えない
        renderQueue = new SerializedObject(source).FindProperty("m_CustomRenderQueue").intValue;
    }

    // 上書き保存用: このプリセットが今持っている値のグループを返す
    public HashSet<string> StoredGroups()
    {
        var groups = new HashSet<string>();
        if (shader == null) return groups;
        foreach (var prop in StoredNames())
            if (SpiderCocoonShaderGUI.TryGetPresetGroup(shader, prop, out var g, out _))
                groups.Add(g);
        return groups;
    }

    // このプリセットに「形」「変形ギミック」区分の値が入っているか（チェック欄を出すかの判定）
    internal bool HasPart(PresetPart part)
    {
        if (shader == null) return false;
        foreach (var prop in StoredNames())
            if (SpiderCocoonShaderGUI.TryGetPresetGroup(shader, prop, out _, out var p) && p == part)
                return true;
        return false;
    }

    private IEnumerable<string> StoredNames()
    {
        foreach (var v in floats)   yield return v.name;
        foreach (var v in colors)   yield return v.name;
        foreach (var v in vectors)  yield return v.name;
        foreach (var v in textures) yield return v.name;
    }

    // -------------------------------------------------------------------------
    // 適用: 同じシェーダーのマテリアルにだけ値を入れる。
    // applyShape / applyGimmick が false の区分は今の値を残す。
    // -------------------------------------------------------------------------
    public int Apply(IList<Material> materials, bool applyShape, bool applyGimmick)
    {
        var targets = new List<Material>();
        foreach (var m in materials)
            if (m != null && shader != null && m.shader == shader) targets.Add(m);
        if (targets.Count == 0) return 0;

        Undo.RecordObjects(targets.ToArray(), "プリセット適用: " + Label);
        foreach (var m in targets)
        {
            foreach (var v in floats)
            {
                if (!CanApply(m, v.name, applyShape, applyGimmick)) continue;
                int index = m.shader.FindPropertyIndex(v.name);
                if (m.shader.GetPropertyType(index) == ShaderPropertyType.Int)
                    m.SetInteger(v.name, Mathf.RoundToInt(v.value));
                else
                    m.SetFloat(v.name, v.value);
            }
            foreach (var v in colors)
                if (CanApply(m, v.name, applyShape, applyGimmick)) m.SetColor(v.name, v.value);
            foreach (var v in vectors)
                if (CanApply(m, v.name, applyShape, applyGimmick)) m.SetVector(v.name, v.value);
            foreach (var v in textures)
            {
                if (!CanApply(m, v.name, applyShape, applyGimmick)) continue;
                m.SetTexture(v.name, v.value);
                m.SetTextureScale(v.name,  new Vector2(v.scaleOffset.x, v.scaleOffset.y));
                m.SetTextureOffset(v.name, new Vector2(v.scaleOffset.z, v.scaleOffset.w));
            }
            if (renderQueue >= 0) m.renderQueue = renderQueue;

            // [Toggle(_GOO_ON)] などのキーワードを、入れた数値に合わせて付け直す
            MaterialEditor.ApplyMaterialPropertyDrawers(m);
            // 繭デカールの表面の模様（_SurfaceStyle → キーワード SC_SURFACE_NET）も同じく付け直す
            SpiderCocoonShaderGUI.SyncKeywords(m);
            EditorUtility.SetDirty(m);
        }
        // 吐いた糸に当てたら、その質感を継承している巣・繭・デカールにも伝える
        SpiderSilkLook.NotifyChanged(targets);
        return targets.Count;
    }

    private static bool CanApply(Material m, string prop, bool applyShape, bool applyGimmick)
    {
        // シェーダー側で消えた・対象外になったプロパティは飛ばす
        if (!SpiderCocoonShaderGUI.TryGetPresetGroup(m.shader, prop, out _, out var part)) return false;
        if (part == PresetPart.Shape   && !applyShape)   return false;
        if (part == PresetPart.Gimmick && !applyGimmick) return false;
        // マテリアルバリアントで親がロックしている値は子から変えられない
        if (m.IsPropertyLockedByAncestor(prop)) return false;
        return true;
    }

    // マテリアルの値がこのプリセットと全部同じか（プリセット欄の ✓ 表示用）
    public bool Matches(Material m)
    {
        if (m == null || shader == null || m.shader != shader || ValueCount == 0) return false;
        // プリセットの対象外になった値（巣・繭・デカールの質感など）は比べない
        System.Func<string, bool> skip = n => !m.HasProperty(n) || !SpiderCocoonShaderGUI.TryGetPresetGroup(m.shader, n, out _, out _);
        foreach (var v in floats)
            if (!skip(v.name) && Mathf.Abs(m.GetFloat(v.name) - v.value) > 1e-4f) return false;
        foreach (var v in colors)
            if (!skip(v.name) && !Near((Vector4)m.GetColor(v.name), (Vector4)v.value)) return false;
        foreach (var v in vectors)
            if (!skip(v.name) && !Near(m.GetVector(v.name), v.value)) return false;
        foreach (var v in textures)
            if (!skip(v.name) && m.GetTexture(v.name) != v.value) return false;
        return true;
    }

    private static bool Near(Vector4 a, Vector4 b)
    {
        return Mathf.Abs(a.x - b.x) <= 1e-4f && Mathf.Abs(a.y - b.y) <= 1e-4f &&
               Mathf.Abs(a.z - b.z) <= 1e-4f && Mathf.Abs(a.w - b.w) <= 1e-4f;
    }
}

// =============================================================================
// プロジェクト内の SpiderShaderPreset を集めて、シェーダーごとに返す。
// アセットが増減したら（projectChanged）作り直す。
// =============================================================================
[InitializeOnLoad]
internal static class SpiderShaderPresetLibrary
{
    private static List<SpiderShaderPreset> _all;

    static SpiderShaderPresetLibrary()
    {
        EditorApplication.projectChanged += Invalidate;
    }

    public static void Invalidate() { _all = null; }

    public static List<SpiderShaderPreset> For(Shader shader)
    {
        if (_all == null)
        {
            _all = new List<SpiderShaderPreset>();
            foreach (var guid in AssetDatabase.FindAssets("t:SpiderShaderPreset"))
            {
                var p = AssetDatabase.LoadAssetAtPath<SpiderShaderPreset>(AssetDatabase.GUIDToAssetPath(guid));
                if (p != null) _all.Add(p);
            }
        }

        var list = new List<SpiderShaderPreset>();
        foreach (var p in _all)
            if (p != null && shader != null && p.shader == shader) list.Add(p);
        list.Sort((a, b) =>
        {
            int c = a.order.CompareTo(b.order);
            return c != 0 ? c : string.CompareOrdinal(a.Label, b.Label);
        });
        return list;
    }

    // 標準プリセットの置き場所（このスクリプトの 1 つ上の Presets フォルダ）
    public static string StandardFolder
    {
        get
        {
            var probe  = ScriptableObject.CreateInstance<SpiderShaderPreset>();
            string cs  = AssetDatabase.GetAssetPath(MonoScript.FromScriptableObject(probe));
            UnityEngine.Object.DestroyImmediate(probe);
            if (string.IsNullOrEmpty(cs)) return "Assets";
            string root = Path.GetDirectoryName(Path.GetDirectoryName(cs)).Replace('\\', '/');
            return root + "/Presets";
        }
    }
}

// =============================================================================
// プリセットアセットのインスペクタ。名前・カテゴリ・説明は直接書き換えられる。
// 値の変更は「マテリアルで調整 → プリセット欄でボタンを右クリック → 上書き保存」。
// =============================================================================
[CustomEditor(typeof(SpiderShaderPreset))]
internal class SpiderShaderPresetEditor : Editor
{
    private bool _showValues;

    public override void OnInspectorGUI()
    {
        serializedObject.Update();
        EditorGUILayout.PropertyField(serializedObject.FindProperty("displayName"), new GUIContent("表示名"));
        EditorGUILayout.PropertyField(serializedObject.FindProperty("category"),    new GUIContent("カテゴリ"));
        EditorGUILayout.PropertyField(serializedObject.FindProperty("description"), new GUIContent("説明"));
        EditorGUILayout.PropertyField(serializedObject.FindProperty("order"),       new GUIContent("並び順"));
        EditorGUILayout.PropertyField(serializedObject.FindProperty("shader"),      new GUIContent("シェーダー"));
        EditorGUILayout.PropertyField(serializedObject.FindProperty("renderQueue"), new GUIContent("描画順 (-1=変えない)"));
        serializedObject.ApplyModifiedProperties();

        var p = (SpiderShaderPreset)target;
        EditorGUILayout.Space();
        EditorGUILayout.HelpBox(
            "値を変えたいときは、マテリアル側で調整してから、マテリアルのインスペクタの" +
            "「プリセット」欄でこのプリセットのボタンを右クリック →「このマテリアルの値で上書き保存」。",
            MessageType.Info);

        _showValues = EditorGUILayout.Foldout(_showValues, $"保存されている値（{p.ValueCount} 個）", true);
        if (!_showValues) return;

        using (new EditorGUI.DisabledScope(true))
        {
            foreach (var v in p.floats)   EditorGUILayout.FloatField(Describe(p, v.name), v.value);
            foreach (var v in p.colors)   EditorGUILayout.ColorField(new GUIContent(Describe(p, v.name)), v.value, true, true, true);
            foreach (var v in p.vectors)  EditorGUILayout.Vector4Field(Describe(p, v.name), v.value);
            foreach (var v in p.textures) EditorGUILayout.ObjectField(Describe(p, v.name), v.value, typeof(Texture), false);
        }
    }

    private static string Describe(SpiderShaderPreset p, string prop)
    {
        if (p.shader == null) return prop;
        int i = p.shader.FindPropertyIndex(prop);
        return i < 0 ? prop + "（シェーダーに無い）" : p.shader.GetPropertyDescription(i);
    }
}
