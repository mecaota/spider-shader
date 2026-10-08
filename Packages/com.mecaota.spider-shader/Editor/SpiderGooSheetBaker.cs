using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using UnityEditor;
using UnityEngine;

/// <summary>
/// ねばねばネット（蜘蛛糸の粘液シート、mecaota/SpiderGooSilkSheet）の模様を Texture2DArray へ焼く Editor 専用処理。
/// 吐いた糸（SpiderThreadTrail）の粘液の帯をすき間なく並べた模様を焼く（Editor/CGINC/SpiderGooSheet_BakeSource.cginc）。
/// シーン・Prefab は扱わない。同じ有効入力と生成コードからは同じ 3 アセットを共有する。
/// </summary>
public static class SpiderGooSheetBaker
{
    public const string ShaderName = "mecaota/SpiderGooSilkSheet";
    public const string BakeShaderName = "Hidden/mecaota/SpiderGooSheetBake";
    public const string DefaultFolder = "Assets/mecaota/GooNet/Baked";
    // C# 側の座標・模様数・エンコード・ミップ処理を変えたら必ず更新する。
    // HLSL / include 側は AssetDatabase の依存ハッシュでも自動検出する。
    public const string GeneratorVersion = "SGS-1.0";
    private const string HashTag = "MecaotaGooSheetBakeHash";

    // 正本: SGS_Evaluate が読むマテリアルの入力。Inspector の説明にも使う。
    // 帯の中の形（_Goo*）は吐いた糸の粘液モードと同じ名前・意味。
    public static readonly string[] ShapeInputs =
    {
        "_Seed", "_SheetBandWidth", "_SheetRotation", "_SheetAlongScale",
        "_GooAmount", "_GooStrands", "_GooWidth", "_GooSpread", "_GooWobble", "_GooWobbleFreq",
        "_GooBeads", "_GooBeadFreq", "_GooMerge", "_GooWeb", "_GooWebCell", "_GooWebRows", "_GooWebHole",
    };

    public sealed class Plan
    {
        public string Hash;
        public int Resolution;
        public int Variants;
        public bool Compressed;
        public float UVSpan;
        public Vector4 WetParams;
        public Vector4[] Windows;
        public Dictionary<string, float>[] Inputs;
        public long TextureBytes;
    }

    public static bool IsBaked(Material material)
    {
        return material != null && material.shader != null && material.shader.name == ShaderName;
    }

    private static float Value(Material material, string name)
    {
        if (!material.HasProperty(name)) throw new InvalidOperationException("焼き込み入力がありません: " + name);
        float value = material.GetFloat(name);
        if (float.IsNaN(value) || float.IsInfinity(value))
            throw new InvalidOperationException("有限の数を指定してください: " + name);
        return value;
    }

    /// <summary>
    /// 読み取りのみ。シェーダーの編集入力を、実際に GPU へ渡す入力へ確定する。
    /// 中心（ハブ）が無いので窓を使わず、メッシュ UV の中心 (0.5, 0.5) をそのまま焼く（z = 1）。
    /// 読取 UV 全幅 = 外形の円＋層のずれ上限＋余白。模様（スライス）ごとに乱数の種だけを変える。
    /// </summary>
    public static Plan Describe(Material material)
    {
        if (!IsBaked(material)) throw new ArgumentException("ねばねばネット（粘液シート）のマテリアルを指定してください。");
        var bakeShader = Shader.Find(BakeShaderName);
        if (bakeShader == null) throw new InvalidOperationException("焼き込み専用シェーダーが見つかりません。");
        var plan = new Plan
        {
            Resolution = Mathf.RoundToInt(Value(material, "_BakeResolution")),
            Variants = Mathf.Clamp(Mathf.RoundToInt(Value(material, "_BakedVariants")), 1, 3),
            Compressed = Value(material, "_BakeCompression") > 0.5f,
        };
        if (plan.Resolution != 512 && plan.Resolution != 1024 && plan.Resolution != 2048)
            throw new InvalidOperationException("解像度は512・1024・2048のいずれかにしてください。");
        var inputs = new Dictionary<string, float>();
        foreach (string name in ShapeInputs) inputs.Add(name, Value(material, name));
        if (inputs["_SheetBandWidth"] <= 0f || inputs["_SheetAlongScale"] <= 0f)
            throw new InvalidOperationException("帯の幅・帯に沿った長さは0より大きくしてください。");
        float webRadius = Value(material, "_WebRadius");
        if (webRadius <= 0f) throw new InvalidOperationException("膜の外形の半径は0より大きくしてください。");

        float shift = Mathf.Clamp(Value(material, "_WebLayerShift"), 0f, 0.5f);
        float padding = Mathf.Clamp(Value(material, "_BakePadding"), 0.02f, 0.3f);
        // 円と UV 正方形の共通領域。回転の包絡円に、全層共通のずれ上限と余白を加える。
        // ずれは層番号で増やさないため、1〜8 層で同じ UV 幅・解像度を使える。
        float renderRadius = Mathf.Min(webRadius, Mathf.Sqrt(0.5f));
        plan.UVSpan = 2f * (renderRadius + shift * webRadius + padding);
        // 濡れ具合は粘液感そのまま（実行中の wet = x × lerp(z, y, 補助) = 粘液感）。
        plan.WetParams = new Vector4(Mathf.Clamp01(inputs["_GooAmount"]), 1f, 1f, 0f);
        plan.Windows = new Vector4[plan.Variants];
        plan.Inputs = new Dictionary<string, float>[plan.Variants];
        for (int slice = 0; slice < plan.Variants; slice++)
        {
            var values = new Dictionary<string, float>(inputs);
            values["_Seed"] = inputs["_Seed"] + slice * 19.193f;
            plan.Inputs[slice] = values;
            plan.Windows[slice] = new Vector4(0.5f, 0.5f, 1f, plan.UVSpan);
        }

        // 色、光沢、Drape、全層の厚さ、回転、層数はハッシュへ入れない。
        // 形状以外の質感が違うマテリアルでも同じ配列を共有できる。
        var key = new StringBuilder(GeneratorVersion);
        key.Append('|').Append(AssetDatabase.GetAssetDependencyHash(AssetDatabase.GetAssetPath(bakeShader)));
        key.Append('|').Append(plan.Resolution).Append('|').Append(plan.Variants).Append('|').Append(plan.Compressed ? 1 : 0);
        Append(key, plan.UVSpan);
        Append(key, plan.WetParams.x); Append(key, plan.WetParams.y); Append(key, plan.WetParams.z);
        foreach (var values in plan.Inputs)
            foreach (string name in ShapeInputs) { key.Append('|').Append(name); Append(key, values[name]); }
        foreach (Vector4 window in plan.Windows)
        {
            Append(key, window.x); Append(key, window.y); Append(key, window.z); Append(key, window.w);
        }
        using (var sha = SHA256.Create())
            plan.Hash = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(key.ToString()))).Replace("-", "").ToLowerInvariant();
        plan.TextureBytes = SpiderGooSheetTextureUtility.TextureBytes(plan.Resolution, plan.Variants, plan.Compressed);
        return plan;
    }

    private static void Append(StringBuilder key, float value)
    {
        key.Append('|').Append(value.ToString("R", CultureInfo.InvariantCulture));
    }

    private static bool ValidArray(Texture2DArray texture, Plan plan, TextureFormat format)
    {
        return texture != null && texture.width == plan.Resolution && texture.height == plan.Resolution &&
            texture.depth == plan.Variants && texture.format == format && texture.mipmapCount == Mathf.RoundToInt(Mathf.Log(plan.Resolution, 2f)) + 1 &&
            !texture.isDataSRGB && texture.wrapMode == TextureWrapMode.Clamp && texture.filterMode == FilterMode.Trilinear;
    }

    private static TextureFormat ShapeFormat(Plan plan) => plan.Compressed ? TextureFormat.BC5 : TextureFormat.RGHalf;
    private static TextureFormat DetailFormat(Plan plan) => plan.Compressed ? TextureFormat.BC7 : TextureFormat.RGBA32;
    private static Vector4 TexelSize(Plan plan) => new Vector4(1f / plan.Resolution, 1f / plan.Resolution, plan.Resolution, plan.Resolution);

    [Serializable]
    private sealed class EncodingInfo
    {
        public string hash;
        public Vector4 distanceRange;
        public Vector4 radiusRange;
    }

    // 圧縮範囲は実際に焼いた画素から決める。共有キャッシュを別マテリアルへ割り当てる際も
    // 復号値を再現できるよう、shapeアセットのImporter.userDataへUnity APIで保存する。
    private static EncodingInfo ReadEncoding(string shapePath, Plan plan)
    {
        if (string.IsNullOrEmpty(shapePath)) return null;
        var importer = AssetImporter.GetAtPath(shapePath);
        if (importer == null || string.IsNullOrEmpty(importer.userData)) return null;
        EncodingInfo info;
        try { info = JsonUtility.FromJson<EncodingInfo>(importer.userData); }
        catch (ArgumentException) { return null; }
        if (info == null || info.hash != plan.Hash || info.distanceRange.w != 3f ||
            info.radiusRange.w != (plan.Compressed ? 1f : 0f)) return null;
        for (int i = 0; i < plan.Variants; i++)
            if (!(info.distanceRange[i] > 0f) || float.IsInfinity(info.distanceRange[i]) ||
                !(info.radiusRange[i] > 0f) || float.IsInfinity(info.radiusRange[i])) return null;
        return info;
    }

    private static void SaveEncoding(string shapePath, EncodingInfo info)
    {
        var importer = AssetImporter.GetAtPath(shapePath);
        if (importer == null) throw new InvalidOperationException("焼き込み情報の保存先がありません: " + shapePath);
        importer.userData = JsonUtility.ToJson(info);
        EditorUtility.SetDirty(importer);
        AssetDatabase.WriteImportSettingsIfDirty(shapePath);
        // .metaへ書くだけでは取り込み済みの設定が古いまま残り、次のスクリプト再読み込み後に
        // userDataが空に戻って「焼き直してください」と出た（2026-10-08）。書いた直後に取り込み直す。
        AssetDatabase.ImportAsset(shapePath, ImportAssetOptions.ForceUpdate);
    }

    /// <summary>状態の確認だけで生成・同期・保存をしない。</summary>
    public static bool IsCurrent(Material material, out string message)
    {
        try
        {
            Plan plan = Describe(material);
            var shape = material.GetTexture("_BakedShape") as Texture2DArray;
            var detail = material.GetTexture("_BakedDetail") as Texture2DArray;
            var coverage = material.GetTexture("_BakedCoverage") as Texture2DArray;
            string shapePath = AssetDatabase.GetAssetPath(shape);
            EncodingInfo encoding = ReadEncoding(shapePath, plan);
            bool valid = material.GetTag(HashTag, false, "") == plan.Hash && encoding != null &&
                ValidArray(shape, plan, ShapeFormat(plan)) && ValidArray(detail, plan, DetailFormat(plan)) &&
                ValidArray(coverage, plan, TextureFormat.R8) &&
                shapePath.EndsWith("/" + plan.Hash + "-shape.asset", StringComparison.Ordinal) &&
                AssetDatabase.GetAssetPath(detail).EndsWith("/" + plan.Hash + "-detail.asset", StringComparison.Ordinal) &&
                AssetDatabase.GetAssetPath(coverage).EndsWith("/" + plan.Hash + "-coverage.asset", StringComparison.Ordinal) &&
                Mathf.Approximately(material.GetFloat("_BakedUVSpan"), plan.UVSpan) &&
                material.GetFloat("_BakedSliceCount") == plan.Variants &&
                material.GetVector("_BakedWetParams") == plan.WetParams &&
                material.GetVector("_BakedTexelSize") == TexelSize(plan) &&
                material.GetVector("_BakedDistanceRange") == encoding.distanceRange &&
                material.GetVector("_BakedRadiusRange") == encoding.radiusRange;
            message = valid ? "焼き込み済み（現在の形状・形式と一致）" : "未生成、または形状・生成形式が変わっています。焼き直してください。";
            return valid;
        }
        catch (Exception e) { message = e.Message; return false; }
    }

    /// <summary>Editorから呼ぶ。force=falseなら既存の同じ形状を再利用する。</summary>
    public static void Bake(Material material, bool force = false, string folder = DefaultFolder)
    {
        if (EditorApplication.isPlayingOrWillChangePlaymode || EditorApplication.isCompiling)
            throw new InvalidOperationException("編集モードで、コンパイル完了後に焼き込んでください。");
        if (!IsBaked(material)) throw new ArgumentException("ねばねばネット（粘液シート）のマテリアルではありません。");
        // 継承元のGooAmountも形状入力。親の最新値を写してから識別子を作る。
        var sync = SpiderSilkLook.Sync(new[] { material });
        if (sync.Problems.Count > 0) throw new InvalidOperationException(string.Join("\n", sync.Problems));
        Plan plan = Describe(material);
        folder = folder.Replace('\\', '/').TrimEnd('/');
        if (!folder.StartsWith("Assets/", StringComparison.Ordinal) || folder.Contains(".."))
            throw new ArgumentException("生成先はAssets以下のフォルダーを指定してください。");
        EnsureFolder(folder);
        string shapePath = folder + "/" + plan.Hash + "-shape.asset";
        string detailPath = folder + "/" + plan.Hash + "-detail.asset";
        string coveragePath = folder + "/" + plan.Hash + "-coverage.asset";
        var shape = AssetDatabase.LoadAssetAtPath<Texture2DArray>(shapePath);
        var detail = AssetDatabase.LoadAssetAtPath<Texture2DArray>(detailPath);
        var coverage = AssetDatabase.LoadAssetAtPath<Texture2DArray>(coveragePath);
        EncodingInfo encoding = ReadEncoding(shapePath, plan);
        if (force || encoding == null || !ValidArray(shape, plan, ShapeFormat(plan)) ||
            !ValidArray(detail, plan, DetailFormat(plan)) || !ValidArray(coverage, plan, TextureFormat.R8))
        {
            Texture2DArray generatedShape = null, generatedDetail = null, generatedCoverage = null;
            try
            {
                Generate(plan, out generatedShape, out generatedDetail, out generatedCoverage, out encoding);
                shape = SaveArray(generatedShape, shapePath);
                detail = SaveArray(generatedDetail, detailPath);
                coverage = SaveArray(generatedCoverage, coveragePath);
                SaveEncoding(shapePath, encoding);
                // 取り込み直した配列を参照し直す（同じGUIDのまま）。
                shape = AssetDatabase.LoadAssetAtPath<Texture2DArray>(shapePath);
            }
            finally
            {
                DestroyTransient(generatedShape);
                DestroyTransient(generatedDetail);
                DestroyTransient(generatedCoverage);
            }
        }
        Undo.RecordObject(material, "粘液シートを焼き直す");
        material.SetTexture("_BakedShape", shape);
        material.SetTexture("_BakedDetail", detail);
        material.SetTexture("_BakedCoverage", coverage);
        material.SetFloat("_BakedUVSpan", plan.UVSpan);
        material.SetFloat("_BakedSliceCount", plan.Variants);
        material.SetVector("_BakedWetParams", plan.WetParams);
        material.SetVector("_BakedTexelSize", TexelSize(plan));
        material.SetVector("_BakedDistanceRange", encoding.distanceRange);
        material.SetVector("_BakedRadiusRange", encoding.radiusRange);
        material.SetOverrideTag(HashTag, plan.Hash);
        EditorUtility.SetDirty(material);
        if (AssetDatabase.Contains(material)) AssetDatabase.SaveAssetIfDirty(material);
    }

    private static void Generate(Plan plan, out Texture2DArray shape, out Texture2DArray detail,
        out Texture2DArray coverage, out EncodingInfo encoding)
    {
        shape = null; detail = null; coverage = null; encoding = null;
        if (!SystemInfo.supports2DArrayTextures || !SystemInfo.SupportsTextureFormat(ShapeFormat(plan)) ||
            !SystemInfo.SupportsTextureFormat(DetailFormat(plan)) || !SystemInfo.SupportsTextureFormat(TextureFormat.R8) ||
            !SystemInfo.SupportsTextureFormat(TextureFormat.RGBAFloat) || !SystemInfo.SupportsRenderTextureFormat(RenderTextureFormat.ARGBFloat))
            throw new InvalidOperationException("指定した配列形式・浮動小数点RTに対応したPCで焼き込んでください（圧縮はBC5/BC7が必要です）。");
        var shader = Shader.Find(BakeShaderName);
        if (shader == null || !shader.isSupported || ShaderUtil.ShaderHasError(shader))
            throw new InvalidOperationException("焼き込み専用シェーダーのコンパイル状態を確認してください。");

        Material bake = null;
        RenderTexture rt = null;
        Texture2D readback = null;
        RenderTexture previousRT = RenderTexture.active;
        bool previousSRGB = GL.sRGBWrite;
        try
        {
            bake = new Material(shader) { hideFlags = HideFlags.HideAndDontSave };
            string kind = "Goo sheet ";
            shape = NewArray(plan, ShapeFormat(plan), kind + "shape " + plan.Hash);
            detail = NewArray(plan, DetailFormat(plan), kind + "detail " + plan.Hash);
            coverage = NewArray(plan, TextureFormat.R8, kind + "coverage " + plan.Hash);
            encoding = new EncodingInfo { hash = plan.Hash, distanceRange = new Vector4(1f, 1f, 1f, 3f),
                radiusRange = new Vector4(1f, 1f, 1f, plan.Compressed ? 1f : 0f) };
            rt = RenderTexture.GetTemporary(plan.Resolution, plan.Resolution, 0, RenderTextureFormat.ARGBFloat, RenderTextureReadWrite.Linear);
            readback = new Texture2D(plan.Resolution, plan.Resolution, TextureFormat.RGBAFloat, false, true)
                { hideFlags = HideFlags.HideAndDontSave };
            GL.sRGBWrite = false;
            bake.SetFloat("_BakeTexelSize", 1f / plan.Resolution);
            for (int slice = 0; slice < plan.Variants; slice++)
            {
                foreach (var input in plan.Inputs[slice]) bake.SetFloat(input.Key, input.Value);
                bake.SetVector("_BakeWindow", plan.Windows[slice]);
                var mip = new SpiderGooSheetTextureUtility.Mip { Size = plan.Resolution,
                    Shape = ReadPass(bake, rt, readback, 0), Detail = ReadPass(bake, rt, readback, 1) };
                Color[] mask = ReadPass(bake, rt, readback, 2);
                mip.Coverage = new float[mask.Length];
                for (int i = 0; i < mask.Length; i++)
                {
                    CheckFinite(mip.Shape[i].r); CheckFinite(mip.Shape[i].g);
                    CheckFinite(mip.Detail[i].r); CheckFinite(mip.Detail[i].g);
                    CheckFinite(mip.Detail[i].b); CheckFinite(mip.Detail[i].a); CheckFinite(mask[i].r);
                    mip.Coverage[i] = Mathf.Clamp01(mask[i].r);
                }
                SpiderGooSheetTextureUtility.WriteSlice(shape, detail, coverage, mip, slice, plan.UVSpan,
                    plan.Compressed, out float distanceRange, out float radiusRange);
                encoding.distanceRange[slice] = distanceRange;
                encoding.radiusRange[slice] = radiusRange;
            }
            // 手作業のミップを上書きしない。CPUコピーを解放し、配列だけを保存する。
            shape.Apply(false, true);
            detail.Apply(false, true);
            coverage.Apply(false, true);
        }
        catch
        {
            DestroyTransient(shape); DestroyTransient(detail); DestroyTransient(coverage);
            shape = null; detail = null; coverage = null; encoding = null;
            throw;
        }
        finally
        {
            RenderTexture.active = previousRT;
            GL.sRGBWrite = previousSRGB;
            if (rt != null) RenderTexture.ReleaseTemporary(rt);
            DestroyTransient(readback); DestroyTransient(bake);
        }
    }

    private static Color[] ReadPass(Material bake, RenderTexture rt, Texture2D readback, int pass)
    {
        Graphics.Blit(Texture2D.blackTexture, rt, bake, pass);
        RenderTexture.active = rt;
        // ARGBFloatとRGBAFloatは同じRGBA 32bit浮動小数点形式。CPU読み取りだけなのでApply不要。
        readback.ReadPixels(new Rect(0, 0, rt.width, rt.height), 0, 0, false);
        return readback.GetPixels();
    }

    private static void CheckFinite(float value)
    {
        if (float.IsNaN(value) || float.IsInfinity(value))
            throw new InvalidOperationException("焼き込み結果に非有限値があります。形状入力・シェーダーを確認してください。");
    }

    private static Texture2DArray NewArray(Plan plan, TextureFormat format, string name)
    {
        return new Texture2DArray(plan.Resolution, plan.Resolution, plan.Variants, format, true, true)
        {
            name = name, wrapMode = TextureWrapMode.Clamp, filterMode = FilterMode.Trilinear, anisoLevel = 1,
        };
    }

    private static Texture2DArray SaveArray(Texture2DArray generated, string path)
    {
        var main = AssetDatabase.LoadMainAssetAtPath(path);
        if (main != null && !(main is Texture2DArray))
            throw new InvalidOperationException("生成先に別種のアセットがあります: " + path);
        var existing = main as Texture2DArray;
        if (existing == null)
        {
            AssetDatabase.CreateAsset(generated, path);
            AssetDatabase.SaveAssetIfDirty(generated);
            return generated;
        }
        // 同じ識別子を強制再生成してもGUIDと参照先を保持する。
        EditorUtility.CopySerialized(generated, existing);
        EditorUtility.SetDirty(existing);
        AssetDatabase.SaveAssetIfDirty(existing);
        return existing;
    }

    private static void DestroyTransient(UnityEngine.Object obj)
    {
        if (obj != null && !AssetDatabase.Contains(obj)) UnityEngine.Object.DestroyImmediate(obj);
    }

    private static void EnsureFolder(string folder)
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
