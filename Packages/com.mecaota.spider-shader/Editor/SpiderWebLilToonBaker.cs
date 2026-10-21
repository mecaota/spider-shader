// このファイルは C# の null 許容の注釈（nullable）を使わない書き方をしている。利用側のプロジェクトが
// 追加のコンパイラ引数（csc.rsp の -nullable:enable など）で注釈を有効にしても警告が出ないよう、明示的に無効にする。
#nullable disable
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

// =============================================================================
// SpiderWebLilToonBaker.cs — 蜘蛛の巣（mecaota/SpiderWeb）を lilToon に焼き込む（Editor 専用）
//
//  巣の模様（縦糸・横糸・粘液）は、シェーダーが画素ごとに計算している。これをテクスチャに焼いて、
//  lilToon（Cutout + alpha to coverage、または Transparent）のマテリアルに差し替える。
//  画素ごとの計算が無くなるので描画は軽くなるが、揺れ・触れたときの変形・体への巻き付き・近接表示など、
//  シェーダーの動きは失われる。
//
//  ■ 流れ
//    1. Analyze  : 焼けるか、失われる機能と注意事項を調べる（何も変えない）
//    2. 同意画面 : SpiderWebLilToonBakeWindow が一覧を出し、ユーザーが同意したときだけ「同意の印」を作る
//    3. Bake     : 同意の印が無い・内容が変わった場合は断る。焼いて、控えのコンポーネントを付けて、差し替える
//    4. Revert   : 控え（SpiderWebBakeBackup）から元のマテリアルと設定に戻す
//
//  ■ lilToon への依存
//    lilToon は任意の依存。lilToon を入れていないプロジェクトでもコンパイルが通るよう、lilToon の型は直接使わない。
//    シェーダーは Shader.Find、マテリアルの設定関数はリフレクションで探す。無ければ焼き込みは使えない。
//
//  ■ ワールド側のスクリプト
//    巣のレンダラーを参照しているスクリプトは、名前を知らなくても「参照している」と注意を出す。
//    焼くと効かなくなる演出を持つスクリプトは、ワールド側の Editor コードから RegisterKnownScript で
//    名前と説明を登録すると、確認画面に【重大】として出る（焼けないものは blocksBake = true で断る）。
//
//  ■ 焼いた色
//    「光や見る向きに依らない色」（正面から見て、正面から照らした丸い断面の色。リム・艶・輪郭線を含む）。
//    シーン光の明暗は焼かず、lilToon のライティングに任せる（_AsUnlit = 1 − シーン光の反映度）。
// =============================================================================

public enum SpiderWebBakeMode
{
    Cutout = 0,        // Cutout + alpha to coverage（既定）
    Transparent = 1,   // 半透明
}

public enum SpiderWebBakeSeverity
{
    Critical = 0,   // 重大
    Caution = 1,    // 注意
    Info = 2,       // 参考
}

[Serializable]
public sealed class SpiderWebBakeSettings
{
    public int resolution = 2048;                        // 長い辺のテクセル数（1024 / 2048 / 4096）
    public SpiderWebBakeMode mode = SpiderWebBakeMode.Cutout;
    public float cutoff = 0.5f;                          // Cutout のしきい値（＝被覆率を保つしきい値）
    public string outputFolder = "";                     // 空なら Assets/mecaota/BakedWebs/<シーン名・prefab 名>

    public SpiderWebBakeSettings Clone() { return (SpiderWebBakeSettings)MemberwiseClone(); }
}

public sealed class SpiderWebBakeItem
{
    public SpiderWebBakeSeverity Severity;
    public string Title;
    public string Detail;

    public string Label
    {
        get
        {
            switch (Severity)
            {
                case SpiderWebBakeSeverity.Critical: return "【重大】";
                case SpiderWebBakeSeverity.Caution: return "【注意】";
                default: return "【参考】";
            }
        }
    }

    public string Line { get { return Label + Title + "：" + Detail; } }
}

public sealed class SpiderWebBakeSlotPlan
{
    public int Slot;
    public int SubMesh;
    public Material Source;
    public Vector2 UvMin;
    public Vector2 UvSize;
    public int Width;
    public int Height;
    public float ThreadTexels;   // 糸 1 本の太さ（テクセル）の目安
    public long Bytes;           // BC7・ミップ込みの容量
    // 陰影の向き: 焼くときのシーンの太陽（光の来る向き。ワールド）と、レンダラーの Transform
    public Vector3 LightDir = Vector3.up;
    public string LightName = "";
    public Matrix4x4 ObjectToWorld = Matrix4x4.identity;
}

/// <summary>焼き込みの事前確認の結果（何も変えない）。</summary>
public sealed class SpiderWebBakeAnalysis
{
    public Renderer Renderer;
    public SpiderWebBakeSettings Settings;
    public readonly List<string> Blockers = new List<string>();                 // 焼けない理由
    public readonly List<SpiderWebBakeItem> Lost = new List<SpiderWebBakeItem>();  // 失われる機能
    public readonly List<SpiderWebBakeItem> Notes = new List<SpiderWebBakeItem>(); // 注意事項
    public readonly List<SpiderWebBakeSlotPlan> Slots = new List<SpiderWebBakeSlotPlan>();
    public readonly List<string> References = new List<string>();               // このレンダラーを参照しているもの
    public string OutputFolder = "";
    public string Hash = "";                                                     // 確認内容の指紋

    public bool CanBake { get { return Blockers.Count == 0; } }

    public IEnumerable<SpiderWebBakeItem> AllItems { get { return Lost.Concat(Notes); } }
}

/// <summary>
/// 同意の印。作れるのは同意画面（SpiderWebLilToonBakeWindow、同じアセンブリ）だけ。
/// 焼き込みの API は、この印が無い・確認したときから内容が変わった場合に実行を断る。
/// </summary>
public sealed class SpiderWebBakeConsent
{
    internal SpiderWebBakeConsent(SpiderWebBakeAnalysis analysis)
    {
        AnalysisHash = analysis.Hash;
        RendererId = analysis.Renderer != null ? analysis.Renderer.GetInstanceID() : 0;
        At = DateTime.Now;
        Critical = analysis.AllItems.Where(x => x.Severity == SpiderWebBakeSeverity.Critical).Select(x => x.Line).ToArray();
        Caution = analysis.AllItems.Where(x => x.Severity == SpiderWebBakeSeverity.Caution).Select(x => x.Line).ToArray();
        Info = analysis.AllItems.Where(x => x.Severity == SpiderWebBakeSeverity.Info).Select(x => x.Line).ToArray();
    }

    public string AnalysisHash { get; private set; }
    public int RendererId { get; private set; }
    public DateTime At { get; private set; }
    public string[] Critical { get; private set; }
    public string[] Caution { get; private set; }
    public string[] Info { get; private set; }
}

/// <summary>元に戻すとき、元のマテリアルがあればそれを使うか、控えの値で作り直すか。</summary>
public enum SpiderWebRevertMode
{
    UseOriginal = 0,            // 元のマテリアル（今の値のまま）を使う。無ければ控えの値で作り直す
    RecreateFromSnapshot = 1,   // 元のマテリアルがあっても、控えの値で新しく作り直して使う
}

public sealed class SpiderWebRevertResult
{
    public Renderer Renderer;
    public readonly List<string> Recreated = new List<string>();   // 作り直したマテリアルの場所
    public readonly List<string> Messages = new List<string>();
}

public static class SpiderWebLilToonBaker
{
    // 焼き方（座標・色・ミップ・lilToon の設定）を変えたら上げる
    public const string ToolVersion = "SWL-1.0";
    public const string WebShaderName = "mecaota/SpiderWeb";
    public const string BakeShaderName = "Hidden/mecaota/SpiderWebBake";
    public const string LilCutoutShaderName = "Hidden/lilToonCutout";
    public const string LilTransparentShaderName = "Hidden/lilToonTransparent";
    public const string DefaultRoot = "Assets/mecaota/BakedWebs";
    public static readonly int[] Resolutions = { 1024, 2048, 4096 };
    // Transparent のとき被覆率を保つしきい値（巣の深度パス SW_DEPTH_SOLID_ALPHA と同じ）
    public const float TransparentCoverageThreshold = 0.5f;

    // =========================================================================
    // lilToon
    // =========================================================================

    /// <summary>lilToon（Cutout・Transparent のシェーダーと、マテリアル設定の関数）が使えるか。</summary>
    public static bool IsLilToonAvailable(out string reason)
    {
        if (Shader.Find(LilCutoutShaderName) == null || Shader.Find(LilTransparentShaderName) == null)
        {
            reason = "lilToon が見つかりません（シェーダー " + LilCutoutShaderName + " / " + LilTransparentShaderName +
                     "）。lilToon を入れたプロジェクトでだけ焼き込めます。";
            return false;
        }
        if (FindLilToonSetup(out Type rm, out Type tm, out _) == null)
        {
            reason = "lilToon のマテリアル設定の関数（SetupMaterialWithRenderingMode）が見つかりません。lilToon の版が想定（2.3.x）と違う可能性があります。";
            return false;
        }
        if (!Enum.IsDefined(rm, "Cutout") || !Enum.IsDefined(rm, "Transparent") || !Enum.IsDefined(tm, "Normal"))
        {
            reason = "lilToon の RenderingMode / TransparentMode に Cutout・Transparent・Normal がありません。lilToon の版が想定（2.3.x）と違う可能性があります。";
            return false;
        }
        reason = "";
        return true;
    }

    /// <summary>
    /// lilToon のレンダリングモード設定の関数を探す（リフレクション）。
    /// 1. lilToon.lilMaterialUtils.SetupMaterialWithRenderingMode（内部・7 引数）: 引数をすべて明示でき、
    ///    lilToon のインスペクターの状態（直前に開いたマテリアル）に左右されない。
    /// 2. 無ければ lilToon.lilToonInspector の公開版（7 引数）。
    /// </summary>
    internal static MethodInfo FindLilToonSetup(out Type renderingMode, out Type transparentMode, out bool isInternal)
    {
        // 探した結果は覚えておく（インスペクターの再描画のたびに探さない。スクリプトの再読み込みで消える）
        if (!s_lilSearched)
        {
            s_lilSearched = true;
            s_lilSetup = SearchLilToonSetup(out s_lilRenderingMode, out s_lilTransparentMode, out s_lilInternal);
        }
        renderingMode = s_lilRenderingMode;
        transparentMode = s_lilTransparentMode;
        isInternal = s_lilInternal;
        return s_lilSetup;
    }

    private static bool s_lilSearched;
    private static MethodInfo s_lilSetup;
    private static Type s_lilRenderingMode, s_lilTransparentMode;
    private static bool s_lilInternal;

    private static MethodInfo SearchLilToonSetup(out Type renderingMode, out Type transparentMode, out bool isInternal)
    {
        renderingMode = null;
        transparentMode = null;
        isInternal = false;
        Assembly asm = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetName().Name == "lilToon.Editor");
        if (asm == null) return null;
        renderingMode = asm.GetType("lilToon.RenderingMode");
        transparentMode = asm.GetType("lilToon.TransparentMode");
        if (renderingMode == null || transparentMode == null) return null;
        var sig = new[] { typeof(Material), renderingMode, transparentMode, typeof(bool), typeof(bool), typeof(bool), typeof(bool) };
        const BindingFlags flags = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;
        MethodInfo mi = asm.GetType("lilToon.lilMaterialUtils")?.GetMethod("SetupMaterialWithRenderingMode", flags, null, sig, null);
        if (mi != null) { isInternal = true; return mi; }
        return asm.GetType("lilToon.lilToonInspector")?.GetMethod("SetupMaterialWithRenderingMode", flags, null, sig, null);
    }

    private static void SetupLilToon(Material material, bool transparent)
    {
        MethodInfo mi = FindLilToonSetup(out Type rmType, out Type tmType, out _);
        if (mi == null) throw new InvalidOperationException("lilToon のマテリアル設定の関数が見つかりません。");
        object rm = Enum.Parse(rmType, transparent ? "Transparent" : "Cutout");
        object tm = Enum.Parse(tmType, "Normal");
        // (material, renderingMode, transparentMode, isoutl, islite, istess, ismulti)
        try { mi.Invoke(null, new object[] { material, rm, tm, false, false, false, false }); }
        catch (TargetInvocationException e)
        {
            Exception inner = e.InnerException ?? e;
            throw new InvalidOperationException("lilToon のマテリアル設定の関数で失敗しました: " + inner.Message, inner);
        }
        string expected = transparent ? LilTransparentShaderName : LilCutoutShaderName;
        if (material.shader == null || material.shader.name != expected)
            throw new InvalidOperationException("lilToon の設定でシェーダーが " + expected + " になりませんでした（" +
                                                (material.shader != null ? material.shader.name : "null") + "）。");
    }

    // =========================================================================
    // 事前確認
    // =========================================================================

    private static float F(Material m, string name, float fallback = 0f)
    {
        return m != null && m.HasProperty(name) ? m.GetFloat(name) : fallback;
    }

    /// <summary>そのレンダラーの、巣のシェーダーのスロット番号（無ければ空）。</summary>
    public static List<int> WebSlots(Renderer r)
    {
        var list = new List<int>();
        if (r == null) return list;
        Material[] mats = r.sharedMaterials;
        for (int i = 0; i < mats.Length; i++)
            if (mats[i] != null && mats[i].shader != null && mats[i].shader.name == WebShaderName) list.Add(i);
        return list;
    }

    /// <summary>焼けるか・失われる機能・注意事項を調べる。シーンもアセットも変えない。</summary>
    public static SpiderWebBakeAnalysis Analyze(Renderer r, SpiderWebBakeSettings settings)
    {
        return Analyze(r, settings, false);
    }

    /// <summary>fresh = true のときは、覚えておいた参照の走査を使わずに調べ直す（焼く直前の確認用）。</summary>
    internal static SpiderWebBakeAnalysis Analyze(Renderer r, SpiderWebBakeSettings settings, bool fresh)
    {
        var a = new SpiderWebBakeAnalysis { Renderer = r, Settings = settings != null ? settings.Clone() : new SpiderWebBakeSettings() };
        SpiderWebBakeSettings s = a.Settings;
        if (r == null) { a.Blockers.Add("レンダラーが選ばれていません。巣のオブジェクト（MeshRenderer）を選んでください。"); Finish(a); return a; }

        // ---- 対象外 ----
        if (r is ParticleSystemRenderer)
            a.Blockers.Add("パーティクル（ParticleSystemRenderer）は対象外です。飛ばす巣は粒ごとに形と向きが変わるので、1 枚のテクスチャに焼けません。");
        else if (r is SkinnedMeshRenderer)
            a.Blockers.Add("SkinnedMeshRenderer は対象外です（体に巻き付く網などは、形が実行時に変わるため焼けません）。");
        else if (!(r is MeshRenderer))
            a.Blockers.Add(r.GetType().Name + " は対象外です。焼けるのは MeshRenderer の巣だけです。");
        if (EditorUtility.IsPersistent(r))
            a.Blockers.Add("Project の prefab アセットの中のレンダラーは焼けません（prefab 本体を書き換え、使っている全部のシーンに波及するため）。シーンに置いたインスタンスを選んでください。");
        else if (PrefabStageUtility.GetPrefabStage(r.gameObject) != null)
            a.Blockers.Add("Prefab Mode（prefab の編集画面）の中では焼けません（prefab 本体を書き換え、使っている全部のシーンに波及するため）。シーンに置いたインスタンスを選んでください。");
        if (r.GetComponent<SpiderWebBakeBackup>() != null)
            a.Blockers.Add("このレンダラーはもう焼き込み済みです（控えのコンポーネント SpiderWebBakeBackup が付いています）。焼き直すときは、先に控えの「元に戻す」で戻してください。");
        if (!Resolutions.Contains(s.resolution))
            a.Blockers.Add("解像度は 1024・2048・4096 のどれかにしてください。");
        if (s.mode == SpiderWebBakeMode.Cutout && !(s.cutoff > 0.01f && s.cutoff < 0.99f))
            a.Blockers.Add("Cutout のしきい値は 0.01〜0.99 にしてください。");
        if (EditorApplication.isPlayingOrWillChangePlaymode)
            a.Blockers.Add("Play 中は焼けません。Play を止めてから焼いてください。");

        Mesh mesh = null;
        if (r is MeshRenderer)
        {
            var mf = r.GetComponent<MeshFilter>();
            mesh = mf != null ? mf.sharedMesh : null;
            if (mesh == null) a.Blockers.Add("MeshFilter にメッシュがありません。");
        }
        List<int> slots = WebSlots(r);
        if (slots.Count == 0)
        {
            var others = r.sharedMaterials.Where(m => m != null && m.shader != null).Select(m => m.shader.name).Distinct().ToArray();
            a.Blockers.Add("巣のシェーダー（" + WebShaderName + "）のマテリアルがありません" +
                           (others.Length > 0 ? "（このレンダラー: " + string.Join("、", others) + "）" : "") +
                           "。糸・繭・繭デカール・捕獲網・ねばねばネットは対象外です。");
        }

        // ---- スロットごとの UV 範囲と、テクスチャの大きさ ----
        // サブメッシュが 1 つも無いメッシュは、描く三角形が無い（スロットの計画は作らない）
        if (mesh != null && slots.Count > 0 && mesh.subMeshCount == 0)
            a.Blockers.Add("メッシュ（" + mesh.name + "）にサブメッシュがありません（描く三角形がありません）。");
        else if (mesh != null && slots.Count > 0)
        {
            foreach (int slot in slots)
            {
                var plan = new SpiderWebBakeSlotPlan { Slot = slot, Source = r.sharedMaterials[slot] };
                // マテリアルがサブメッシュより多いときは、余りのマテリアルは最後のサブメッシュを描く（Unity の決まり）
                plan.SubMesh = Mathf.Min(slot, mesh.subMeshCount - 1);
                if (!TryGetUvRange(mesh, plan.SubMesh, out plan.UvMin, out plan.UvSize, out string uvError))
                {
                    a.Blockers.Add("スロット " + slot + ": " + uvError);
                    continue;
                }
                PlanTexture(plan, s.resolution);
                plan.LightDir = FindSunDirection(r, out plan.LightName);
                plan.ObjectToWorld = r.transform.localToWorldMatrix;
                a.Slots.Add(plan);
            }
        }

        a.OutputFolder = string.IsNullOrEmpty(s.outputFolder) ? DefaultFolderFor(r) : s.outputFolder.Replace('\\', '/').TrimEnd('/');
        if (!a.OutputFolder.StartsWith("Assets/", StringComparison.Ordinal) || a.OutputFolder.Contains(".."))
            a.Blockers.Add("保存先は Assets/ の下のフォルダにしてください: " + a.OutputFolder);

        if (a.Slots.Count > 0)
        {
            AddMaterialItems(a);
            AddReferenceItems(a, r, fresh);
            AddAnimationItems(a, r);
            AddNotes(a, r);
        }
        Finish(a);
        return a;
    }

    // ---- 失われる機能（マテリアルの値から） ----
    private static void AddMaterialItems(SpiderWebBakeAnalysis a)
    {
        SpiderWebBakeSettings s = a.Settings;
        bool sway = false, pull = false, drape = false, reveal = false, viewDep = false, hideBack = false, link = false, translucent = false;
        var lowCeiling = new List<string>();
        var hdr = new List<string>();
        foreach (SpiderWebBakeSlotPlan p in a.Slots)
        {
            Material m = p.Source;
            sway |= F(m, "_SwayAnimEnable") > 0.5f;
            pull |= F(m, "_PullEnable") > 0.5f;
            drape |= F(m, "_DrapeEnable") > 0.5f;
            reveal |= F(m, "_RevealEnable") > 0.5f || m.IsKeywordEnabled("SW_REVEAL");
            float amt = Mathf.Clamp01(F(m, "_GooAmount", 1f));
            float gloss = F(m, "_GooGloss") * (m.HasProperty("_GooGlossColor") ? m.GetColor("_GooGlossColor").a : 0f) * amt;
            viewDep |= gloss > 1e-4f || F(m, "_RimStrength") > 1e-4f || F(m, "_LightInfluence") > 1e-4f;
            hideBack |= F(m, "_HideBackFibers") > 0.5f;
            link |= SpiderSilkLook.GetLink(m).State == SpiderSilkLook.LinkState.Linked;
            float opacity = F(m, "_GooOpacity", 1f), clarity = F(m, "_GooClarity");
            translucent |= opacity < 0.999f || clarity * amt > 1e-4f;
            // 不透明度の上限（SpiderGoo_Shading.cginc の STG_GooAlphaCeiling と同じ式）
            if (m.HasProperty("_GooGlossColor") && m.GetColor("_GooGlossColor").maxColorComponent > 1.0001f && gloss > 1e-4f) hdr.Add(m.name + " の艶（_GooGlossColor）");
            if (m.HasProperty("_RimColor") && m.GetColor("_RimColor").maxColorComponent * F(m, "_RimStrength") > 1.0001f) hdr.Add(m.name + " のリム（_RimColor × _RimStrength）");
            if (m.HasProperty("_GooColor") && m.GetColor("_GooColor").maxColorComponent > 1.0001f) hdr.Add(m.name + " の明部の色（_GooColor）");
            float outlineA = m.HasProperty("_GooOutlineColor") ? m.GetColor("_GooOutlineColor").a : 0f;
            float ceiling = Mathf.Abs(opacity) * Mathf.Max(Mathf.Max(1f, Mathf.Abs(1f - clarity)), Mathf.Abs(outlineA));
            float threshold = s.mode == SpiderWebBakeMode.Cutout ? s.cutoff : TransparentCoverageThreshold;
            if (ceiling < threshold + 0.05f)
                lowCeiling.Add(m.name + "（上限 " + ceiling.ToString("0.00", CultureInfo.InvariantCulture) + "）");
        }
        if (sway)
            a.Lost.Add(Item(SpiderWebBakeSeverity.Caution, "揺れ（緯糸の揺れアニメ）",
                "焼いた模様は止まった絵になり、横糸の揺れは無くなります。"));
        if (pull)
            a.Lost.Add(Item(SpiderWebBakeSeverity.Caution, "触れたときの変形（Pull）",
                "手足が触れたときに巣が引っぱられて伸びる・凹む変形は無くなります（lilToon は頂点を動かしません）。"));
        if (drape)
            a.Blockers.Add("体に覆いかぶさる網（_DrapeEnable が ON の捕獲網）は対象外です。焼くと体への巻き付きが無くなり、網を動かす Udon がマテリアルの値（_DrapeGap など）を毎フレーム読んでいる場合は、毎フレームエラーログが出ます。");
        if (reveal)
            a.Lost.Add(Item(SpiderWebBakeSeverity.Critical, "近接表示のフェード（SW_REVEAL）",
                "近づくにつれて少しずつ現れるフェード（_RevealNear〜_RevealFar）と、下端の切り取り（_ClipLine）が無くなります。レンダラーが表示されている間は、距離に関係なく全体が見えます。"));
        if (viewDep)
            a.Lost.Add(Item(SpiderWebBakeSeverity.Caution, "見る角度・光の向きで動く艶・リム・陰影",
                "焼くときのシーンの太陽の向きで照らし、面を正面から見た形で焼き付けます。太陽が動く・斜めから見る、で陰影の境目や艶・リムが動くことは無くなります（裏から見ても表と同じ陰影）。光の色と明るさは lilToon のライティングに置き換えます（_AsUnlit = 1 − シーン光の反映度、明るさの下限 0.25・上限 1.35）。"));
        if (hideBack)
            a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "裏面の糸を隠す（_HideBackFibers）",
                "lilToon の裏面カリング（Cull Back）に置き換えます。見え方は同じです。"));
        if (link)
            a.Lost.Add(Item(SpiderWebBakeSeverity.Caution, "質感の継承（蜘蛛糸マテリアルから）",
                "焼いた巣は、あとで継承元の蜘蛛糸マテリアルの質感を変えても変わりません。変えたときは焼き直しが必要です。"));
        if (translucent && s.mode == SpiderWebBakeMode.Cutout)
            a.Lost.Add(Item(SpiderWebBakeSeverity.Caution, "半透明（中心の透け・不透明度）",
                "Cutout では、しきい値より濃い所は不透明、薄い所は透明になります。糸の中心が透ける感じは無くなります（alpha to coverage で縁だけなめらかにします）。"));
        if (hdr.Count > 0)
            a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "1 を超える明るさ（HDR）",
                string.Join("、", hdr) + "が 1 を超えています。焼いたテクスチャは 8bit なので、1 を超えた分は 1 で切られ（saturate）、光って見える部分が少し弱まります。"));
        if (lowCeiling.Count > 0)
            a.Lost.Add(Item(SpiderWebBakeSeverity.Critical, "糸がほとんど見えなくなる",
                "このマテリアルの不透明度の上限が、しきい値（" + (s.mode == SpiderWebBakeMode.Cutout ? s.cutoff : TransparentCoverageThreshold).ToString("0.00", CultureInfo.InvariantCulture) +
                "）に近いか、それより低いです: " + string.Join("、", lowCeiling) +
                (s.mode == SpiderWebBakeMode.Cutout ? "。Cutout では巣がほぼ消えます。Transparent を選ぶか、しきい値を下げてください。"
                                                    : "。遠くで細い糸を保つミップの効き目が弱くなります。")));
    }

    // ---- 失われる機能（このレンダラーを参照しているスクリプトから） ----

    // 名前を知っているスクリプト。焼くレンダラー（または GameObject）を参照していると、汎用の「参照している」の
    // 代わりに【重大】で詳しい説明を出す（BlocksBake なら焼けない理由にする）。
    // 最初から持つのはこのパッケージのスクリプトだけ。ワールド側のスクリプトは RegisterKnownScript で登録する。
    private sealed class KnownScript
    {
        public Func<Component[], string> Describe;
        public bool BlocksBake;
    }

    private static readonly Dictionary<string, KnownScript> s_knownScripts = new Dictionary<string, KnownScript>(StringComparer.Ordinal)
    {
        { "SurfaceContactDeformer", new KnownScript { Describe = DescribeSurfaceContactDeformer } },
    };

    // 同梱の SurfaceContactDeformer。matchFanShape が ON なら、捕まる範囲が変わる副作用も出す
    private static string DescribeSurfaceContactDeformer(Component[] owners)
    {
        string detail = "手足が触れたときに巣を引っぱる変形が止まります（Udon は毎フレーム値を送り続けますが、lilToon は使いません）。";
        if (owners.Any(IsMatchFanShapeOn))
            detail += " さらに matchFanShape が ON なので、扇形の捕獲範囲をマテリアル（_FanEnable など）から読めなくなり、捕まる範囲が扇形から平面全体に変わります（ゲーム上の副作用）。";
        return detail;
    }

    // matchFanShape は U# の表側（C# の欄を持つコンポーネント）にある。裏側の UdonBehaviour では見つからない
    private static bool IsMatchFanShapeOn(Component owner)
    {
        if (owner == null) return false;
        using (var so = new SerializedObject(owner))
        {
            SerializedProperty fan = so.FindProperty("matchFanShape");
            return fan != null && fan.propertyType == SerializedPropertyType.Boolean && fan.boolValue;
        }
    }

    /// <summary>
    /// 焼くと効かなくなる演出を持つスクリプトを登録する。ワールド側の Editor コード（[InitializeOnLoadMethod] など）から呼ぶ。
    /// 焼く巣のレンダラー（または GameObject）をこのスクリプトが参照していると、確認画面に【重大】として detail を出す。
    /// blocksBake = true なら、そのレンダラーは焼けない（焼くと網として働かなくなるものなど。detail が焼けない理由になる。
    /// 説明が空でも必ず断る）。
    /// <para>scriptName はクラス名。UdonSharp のスクリプトは元のクラス名で、裏側の UdonBehaviour もプログラムの元のクラス名で照らし合わせる。
    /// 同じ名前をもう一度登録すると上書きする。登録はスクリプトの再読み込み（ドメインのリロード）で消えるので、そのたびに登録し直す。</para>
    /// </summary>
    public static void RegisterKnownScript(string scriptName, string detail, bool blocksBake = false)
    {
        if (string.IsNullOrEmpty(detail)) throw new ArgumentException("detail が空です。", nameof(detail));
        RegisterKnownScript(scriptName, _ => detail, blocksBake);
    }

    /// <summary>
    /// <see cref="RegisterKnownScript(string, string, bool)"/> の、説明をその場で作る版（スクリプトの設定値を説明に入れるときに使う）。
    /// describe には、そのレンダラーを参照している同じオブジェクトの同じスクリプトのコンポーネントが渡る
    /// （UdonSharp なら、C# の欄を持つ表側と、裏側の UdonBehaviour の両方）。
    /// null か空文字を返すと、登録していないときと同じ汎用の説明になる。ただし blocksBake = true のときは例外で、
    /// 汎用の「焼けません」の文で必ず断る。
    /// </summary>
    public static void RegisterKnownScript(string scriptName, Func<Component[], string> describe, bool blocksBake = false)
    {
        if (string.IsNullOrEmpty(scriptName)) throw new ArgumentException("scriptName が空です。", nameof(scriptName));
        if (describe == null) throw new ArgumentNullException(nameof(describe));
        s_knownScripts[scriptName] = new KnownScript { Describe = describe, BlocksBake = blocksBake };
    }

    private static string DescribeKnown(KnownScript known, string scriptName, Component[] owners)
    {
        try { return known.Describe(owners); }
        catch (Exception e)
        {
            // 登録した側の不具合で確認画面を止めない（説明の代わりに理由を出す）
            return scriptName + " の説明を作れませんでした（" + e.GetType().Name + ": " + e.Message + "）。";
        }
    }

    private static void AddReferenceItems(SpiderWebBakeAnalysis a, Renderer r, bool fresh)
    {
        // 同じスクリプト（U# の表側と、裏側の UdonBehaviour）は 1 つにまとめる
        var groups = new List<KeyValuePair<string, List<RefInfo>>>();
        foreach (RefInfo info in FindReferencesCached(r, fresh))
        {
            a.References.Add(HierarchyPath(info.Owner.transform) + " の " + info.ScriptName + "（" + info.Field + "）" + (info.ToGameObject ? " → GameObject" : " → Renderer"));
            string key = info.Owner.gameObject.GetInstanceID() + "|" + info.ScriptName;
            int gi = groups.FindIndex(g => g.Key == key);
            if (gi < 0) groups.Add(new KeyValuePair<string, List<RefInfo>>(key, new List<RefInfo> { info }));
            else groups[gi].Value.Add(info);
        }
        foreach (var g in groups)
        {
            RefInfo first = g.Value[0];
            string fields = string.Join("・", g.Value.Where(x => !x.Field.StartsWith("publicVariables", StringComparison.Ordinal)).Select(x => x.Field).Distinct());
            if (fields.Length == 0) fields = first.Field;
            string where = HierarchyPath(first.Owner.transform) + " の " + first.ScriptName + "（" + fields + "）";
            bool toRenderer = g.Value.Any(x => !x.ToGameObject);
            if (s_knownScripts.TryGetValue(first.ScriptName, out KnownScript known))
            {
                string detail = DescribeKnown(known, first.ScriptName, g.Value.Select(x => x.Owner).Distinct().ToArray());
                if (known.BlocksBake)
                {
                    // 焼けないものとして登録されたスクリプトは、説明が空でも必ず断る
                    a.Blockers.Add(where + ": " + (string.IsNullOrEmpty(detail)
                        ? first.ScriptName + " が参照しているため焼けません（ワールド側で焼けないものとして登録されています）。"
                        : detail));
                    continue;
                }
                if (!string.IsNullOrEmpty(detail))
                {
                    a.Lost.Add(Item(SpiderWebBakeSeverity.Critical, first.ScriptName + " が操作している効果", where + ": " + detail));
                    continue;
                }
            }
            if (toRenderer)
            {
                a.Lost.Add(Item(SpiderWebBakeSeverity.Caution, "スクリプトがこのレンダラーを参照している",
                    where + "。実行時にマテリアルの値を読んだり、MaterialPropertyBlock で変えたりしている場合は、焼いたあと効かなくなります。"));
            }
            else
            {
                a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "スクリプトがこのオブジェクトを参照している",
                    where + "（GameObject として）。そこからこのレンダラーのマテリアルを触っている場合は、焼いたあと効かなくなります。"));
            }
        }
        if (r.HasPropertyBlock())
            a.Notes.Add(Item(SpiderWebBakeSeverity.Caution, "MaterialPropertyBlock が付いている",
                "このレンダラーには今 MaterialPropertyBlock が付いています。焼き込みはマテリアルの値で焼くので、MPB の値（_Seed など）は焼かれません。"));
    }

    private static void AddAnimationItems(SpiderWebBakeAnalysis a, Renderer r)
    {
        var found = new HashSet<string>(StringComparer.Ordinal);
        foreach (Animator anim in r.GetComponentsInParent<Animator>(true))
        {
            if (anim.runtimeAnimatorController == null) continue;
            string path = AnimationUtility.CalculateTransformPath(r.transform, anim.transform);
            foreach (AnimationClip clip in anim.runtimeAnimatorController.animationClips)
                CheckClip(clip, path, r, found);
        }
        foreach (Animation anim in r.GetComponentsInParent<Animation>(true))
        {
            string path = AnimationUtility.CalculateTransformPath(r.transform, anim.transform);
            foreach (AnimationClip clip in AnimationUtility.GetAnimationClips(anim.gameObject))
                CheckClip(clip, path, r, found);
        }
        foreach (string f in found)
            a.Lost.Add(Item(SpiderWebBakeSeverity.Critical, "アニメーションがマテリアルの値を動かしている",
                f + "。lilToon のマテリアルには同じ名前の値が無いので、そのアニメーションは効かなくなります。"));
    }

    private static void CheckClip(AnimationClip clip, string path, Renderer r, HashSet<string> found)
    {
        if (clip == null) return;
        foreach (EditorCurveBinding b in AnimationUtility.GetCurveBindings(clip))
            if (b.path == path && b.type != null && typeof(Renderer).IsAssignableFrom(b.type) && b.propertyName.StartsWith("material.", StringComparison.Ordinal))
                found.Add("クリップ " + clip.name + " の " + b.propertyName);
    }

    // ---- 注意事項 ----
    private static void AddNotes(SpiderWebBakeAnalysis a, Renderer r)
    {
        SpiderWebBakeSettings s = a.Settings;
        int queue = a.Slots.Max(p => p.Source.renderQueue);
        string queueText = queue + "（" + QueueName(queue) + "）";
        if (s.mode == SpiderWebBakeMode.Cutout)
            a.Notes.Add(Item(SpiderWebBakeSeverity.Caution, "描画順が変わる",
                (queue == 2450 ? "キューは 2450（AlphaTest）のままですが、" : "キューが " + queueText + "から 2450（AlphaTest）に変わり、") +
                "深度を書いて深度テクスチャに入ります。繭デカール（SpiderCocoonDepthDecal）ののりが巣の上に塗られることがあります。半透明の巣・繭・糸との前後関係も変わります。"));
        else
            a.Notes.Add(Item(SpiderWebBakeSeverity.Caution, "描画順が変わる",
                (queue == 3000 ? "キューは 3000（半透明）のままですが、" : "キューが " + queueText + "から 3000（半透明）に変わり、") +
                "深度を書きません（元の巣は糸の芯だけ深度を書いていました）。巣どうし・繭・糸との前後関係が変わることがあります。"));
        a.Notes.Add(Item(SpiderWebBakeSeverity.Caution, "影",
            "レンダラーの影を切ります（落とさない・受けない）。元の巣も影を落としていませんでしたが、lilToon は影を落とせるので、念のため切ります。元の値は控えに残し、元に戻すと戻ります。"));

        SpiderWebBakeSlotPlan first = a.Slots[0];
        a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "陰影の向き",
            string.IsNullOrEmpty(first.LightName)
                ? "このシーンに有効な Directional Light が無いので、真上からの光で糸の丸い断面の陰影とハイライトを焼きます（巣のシェーダーのライトが無いときと同じ）。"
                : "糸の丸い断面の陰影とハイライトは、このシーンの太陽（Directional Light「" + first.LightName + "」、光の来る向き " + V3(first.LightDir) + "）の向きで焼きます。"));
        long bytes = a.Slots.Sum(p => p.Bytes);
        float minTexels = a.Slots.Count > 0 ? a.Slots.Min(p => p.ThreadTexels) : 0f;
        string sizes = string.Join("、", a.Slots.Select(p => "スロット " + p.Slot + " = " + p.Width + "×" + p.Height));
        a.Notes.Add(Item(minTexels < 2f ? SpiderWebBakeSeverity.Caution : SpiderWebBakeSeverity.Info, "テクスチャの容量と細さ",
            "テクスチャ " + a.Slots.Count + " 枚（" + sizes + "）、合計 約 " + (bytes / (1024.0 * 1024.0)).ToString("0.0", CultureInfo.InvariantCulture) +
            " MiB（BC7、ミップ込み）。糸 1 本は約 " + minTexels.ToString("0.0", CultureInfo.InvariantCulture) + " テクセル" +
            (minTexels < 2f ? "で、2 テクセル未満です。近くで見ると糸がにじみます。解像度を上げてください。" : "です。")));
        a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "描画のパス",
            "基本のパスは 2 回（糸の芯の深度 ＋ 色）から 1 回に減ります。ただし lilToon は、ポイントライト・スポットライトが当たると ForwardAdd のパスが増え、影を有効にすると ShadowCaster のパスが増えます（焼き込みではレンダラーの影を切ります）。巣 1 つにマテリアル 1 つなのは変わりません。"));
        if (s.mode == SpiderWebBakeMode.Cutout)
            a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "遠くの糸",
                "遠くの細い糸は、被覆率を保つミップ（しきい値 " + s.cutoff.ToString("0.00", CultureInfo.InvariantCulture) +
                " を超える画素の割合を各段で保つ）で消えにくくしています。alpha to coverage の効き方はアンチエイリアス（MSAA）の設定によります。MSAA なしでは縁がギザギザになります。"));
        else
            a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "遠くの糸",
                "遠くの細い糸は、被覆率を保つミップ（しきい値 " + TransparentCoverageThreshold.ToString("0.00", CultureInfo.InvariantCulture) +
                "）で薄くなりすぎないようにしています。"));

        int sharedUsers = CountOtherUsers(r, a.Slots.Select(p => p.Source).ToList());
        a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "共有マテリアル",
            "このレンダラーだけを新しいマテリアルに差し替えます。同じマテリアルを使う他のレンダラー" +
            (sharedUsers > 0 ? "（このシーンに " + sharedUsers + " 個）" : "") + "は変わりません。"));
        if (PrefabUtility.IsPartOfPrefabInstance(r))
            a.Notes.Add(Item(SpiderWebBakeSeverity.Caution, "prefab のインスタンス",
                "prefab のインスタンスなので、マテリアルの差し替えと控えのコンポーネントは、このシーンでの上書き（オーバーライド）になります。prefab 本体は変わりません。元に戻すと、焼く前に上書きでなかった値は prefab の値へ戻します（上書きを残しません。控えの値から作り直したマテリアルのスロットだけは、上書きとして残します）。"));
        a.Notes.Add(Item(SpiderWebBakeSeverity.Caution, "ビルダーの再実行",
            "この巣を作ったり設定したりするエディター拡張（ワールド側のビルダーやセットアップ用のメニューなど）を実行し直すと、マテリアルが元に戻ることがあります。そのときは控えのコンポーネントが残るので、焼き直すか、控えの「元に戻す」で整理してください。"));
        a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "実行時の値",
            "実行時に Udon が MaterialPropertyBlock で変える値は焼けません。編集時のマテリアルの値（_Seed・_GooOpacity など）で焼きます。"));
        bool outside = a.Slots.Any(p => p.UvMin.x < -1e-4f || p.UvMin.y < -1e-4f || p.UvMin.x + p.UvSize.x > 1.0001f || p.UvMin.y + p.UvSize.y > 1.0001f);
        a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "UV の範囲",
            string.Join("、", a.Slots.Select(p => "スロット " + p.Slot + " の UV " + V2(p.UvMin) + "〜" + V2(p.UvMin + p.UvSize))) +
            " を焼き、lilToon のタイリング・オフセット（_MainTex_ST）で合わせます" + (outside ? "（0〜1 をはみ出す UV もそのまま焼きます）。" : "。")));
        a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "保存先と元に戻す",
            "テクスチャ（PNG）と lilToon のマテリアルを " + a.OutputFolder + " に作ります。元の値はレンダラーに付ける控えのコンポーネント（SpiderWebBakeBackup）に残り、その「元に戻す」で戻せます。作ったアセットは元に戻しても消しません（削除はご自身で）。"));
        a.Notes.Add(Item(SpiderWebBakeSeverity.Info, "lilToon が必要",
            "焼いたマテリアルは lilToon（" + LilToonVersion() + "）のシェーダーを使います。lilToon の無いプロジェクトでは表示できません。"));
    }

    private static string QueueName(int q)
    {
        if (q < 2450) return "不透明";
        if (q <= 2500) return "AlphaTest";
        if (q < 3000) return "半透明より " + (3000 - q) + " 手前";
        if (q < 4000) return "半透明";
        return "Overlay";
    }

    private static SpiderWebBakeItem Item(SpiderWebBakeSeverity severity, string title, string detail)
    {
        return new SpiderWebBakeItem { Severity = severity, Title = title, Detail = detail };
    }

    private static string V3(Vector3 v)
    {
        return "(" + v.x.ToString("0.00", CultureInfo.InvariantCulture) + ", " + v.y.ToString("0.00", CultureInfo.InvariantCulture) + ", " + v.z.ToString("0.00", CultureInfo.InvariantCulture) + ")";
    }

    /// <summary>
    /// 焼くときの太陽の向き（光の来る向き）。巣のシェーダーの _WorldSpaceLightPos0 と同じく、ライトの前向きの逆。
    /// RenderSettings.sun（同じシーンで有効なら）→ そのシーンでいちばん明るい有効な Directional Light → 無ければ真上。
    /// </summary>
    internal static Vector3 FindSunDirection(Renderer r, out string name)
    {
        Light best = null;
        Scene scene = r.gameObject.scene;
        Light sun = RenderSettings.sun;
        if (sun != null && sun.type == LightType.Directional && sun.isActiveAndEnabled && sun.gameObject.scene == scene) best = sun;
        if (best == null && scene.IsValid())
            foreach (GameObject root in scene.GetRootGameObjects())
                foreach (Light l in root.GetComponentsInChildren<Light>(false))
                    if (l.type == LightType.Directional && l.isActiveAndEnabled && (best == null || l.intensity > best.intensity)) best = l;
        if (best == null) { name = ""; return Vector3.up; }
        name = best.name;
        return -best.transform.forward;
    }

    private static string V2(Vector2 v)
    {
        return "(" + v.x.ToString("0.###", CultureInfo.InvariantCulture) + ", " + v.y.ToString("0.###", CultureInfo.InvariantCulture) + ")";
    }

    private static string LilToonVersion()
    {
        var info = UnityEditor.PackageManager.PackageInfo.FindForAssetPath("Packages/jp.lilxyzw.liltoon/package.json");
        return info != null ? "jp.lilxyzw.liltoon " + info.version : "版は不明";
    }

    private static int CountOtherUsers(Renderer r, List<Material> mats)
    {
        int n = 0;
        Scene scene = r.gameObject.scene;
        if (!scene.IsValid()) return 0;
        foreach (GameObject root in scene.GetRootGameObjects())
            foreach (Renderer other in root.GetComponentsInChildren<Renderer>(true))
                if (other != r && other.sharedMaterials.Any(m => m != null && mats.Contains(m))) n++;
        return n;
    }

    // 確認内容の指紋。対象・設定・元のマテリアルの全部の値・表示する文言が 1 つでも変われば変わる
    private static void Finish(SpiderWebBakeAnalysis a)
    {
        var sb = new StringBuilder(ToolVersion);
        Renderer r = a.Renderer;
        sb.Append('|').Append(r != null ? r.GetInstanceID() : 0);
        var mf = r != null ? r.GetComponent<MeshFilter>() : null;
        sb.Append('|').Append(mf != null && mf.sharedMesh != null ? mf.sharedMesh.GetInstanceID() : 0);
        SpiderWebBakeSettings s = a.Settings;
        sb.Append('|').Append(s.resolution).Append('|').Append((int)s.mode).Append('|').Append(s.cutoff.ToString("R", CultureInfo.InvariantCulture)).Append('|').Append(a.OutputFolder);
        foreach (SpiderWebBakeSlotPlan p in a.Slots)
        {
            sb.Append("|slot").Append(p.Slot).Append(':').Append(p.Source != null ? p.Source.GetInstanceID() : 0).Append(':').Append(p.SubMesh)
              .Append(':').Append(p.LightDir.ToString("R")).Append(':').Append(p.ObjectToWorld.ToString("R"));
            if (p.Source != null) sb.Append(':').Append(JsonUtility.ToJson(SpiderWebMaterialSnapshotUtil.Capture(p.Source, p.Slot)));
        }
        foreach (string b in a.Blockers) sb.Append("|B:").Append(b);
        foreach (SpiderWebBakeItem i in a.AllItems) sb.Append("|I:").Append(i.Line);
        foreach (string x in a.References) sb.Append("|R:").Append(x);
        using (var sha = SHA256.Create())
            a.Hash = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(sb.ToString()))).Replace("-", "").ToLowerInvariant();
    }

    // =========================================================================
    // 参照の検出（シーン・prefab の中のスクリプトの、配列を含む全部の参照を見る）
    // =========================================================================
    internal sealed class RefInfo
    {
        public Component Owner;
        public string ScriptName;
        public string Field;
        public bool ToGameObject;
        public bool Implicit;      // 同じオブジェクトの空の Renderer 欄（スクリプトが GetComponent<Renderer>() で補う）
    }

    // 参照の走査は重い（シーンの全スクリプト）ので、レンダラーごとに覚えておく。
    // 階層が変わったとき・Undo/Redo のときに捨てる。焼く直前（Bake の中の Analyze）は必ず走査し直す
    private static readonly Dictionary<int, List<RefInfo>> s_refCache = new Dictionary<int, List<RefInfo>>();

    [InitializeOnLoadMethod]
    private static void HookReferenceCache()
    {
        EditorApplication.hierarchyChanged -= ClearReferenceCache;
        EditorApplication.hierarchyChanged += ClearReferenceCache;
        Undo.undoRedoPerformed -= ClearReferenceCache;
        Undo.undoRedoPerformed += ClearReferenceCache;
    }

    internal static void ClearReferenceCache()
    {
        s_refCache.Clear();
    }

    internal static List<RefInfo> FindReferencesCached(Renderer r, bool fresh)
    {
        int id = r.GetInstanceID();
        if (!fresh && s_refCache.TryGetValue(id, out List<RefInfo> got) && got.All(x => x.Owner != null)) return got;
        List<RefInfo> list = FindReferences(r);
        s_refCache[id] = list;
        return list;
    }

    // 中を見なくてよい配列（バイト列など。Udon の program のバイト列は大きい）
    private static readonly HashSet<string> PrimitiveArrayTypes = new HashSet<string>(StringComparer.Ordinal)
    {
        "UInt8", "SInt8", "char", "UInt16", "SInt16", "UInt32", "SInt32", "int", "UInt64", "SInt64", "float", "double",
        "bool", "string", "Vector2", "Vector3", "Vector4", "Quaternion", "Color", "Matrix4x4f",
    };

    internal static List<RefInfo> FindReferences(Renderer r)
    {
        var list = new List<RefInfo>();
        Scene scene = r.gameObject.scene;
        IEnumerable<GameObject> roots = scene.IsValid() ? scene.GetRootGameObjects() : new[] { r.transform.root.gameObject };
        foreach (GameObject root in roots)
        {
            foreach (MonoBehaviour mb in root.GetComponentsInChildren<MonoBehaviour>(true))
            {
                if (mb == null || mb is SpiderWebBakeBackup) continue;   // スクリプトが見つからない（Missing）ものと控えは飛ばす
                // VRChat のシーン記述子（ネットワーク ID の表）などは、マテリアルを触らないので除く
                string typeName = mb.GetType().Name;
                if (typeName == "VRCSceneDescriptor" || typeName == "PipelineManager") continue;
                var so = new SerializedObject(mb);
                SerializedProperty it = so.GetIterator();
                bool enter = true;
                while (it.Next(enter))
                {
                    enter = !(it.propertyType == SerializedPropertyType.String ||
                              (it.isArray && PrimitiveArrayTypes.Contains(it.arrayElementType)));
                    if (it.propertyType != SerializedPropertyType.ObjectReference) continue;
                    if (it.propertyPath == "m_GameObject") continue;   // 同じオブジェクトに付いているだけ（参照ではない）
                    Object o = it.objectReferenceValue;
                    if (o == null)
                    {
                        // 同じオブジェクトのスクリプトで、Renderer の欄が空のもの（配列の要素は除く）。
                        // SurfaceContactDeformer などは、空なら GetComponent<Renderer>() でこのレンダラーを使う
                        if (mb.gameObject == r.gameObject && !it.propertyPath.Contains(".Array.data[") && IsRendererField(it.type))
                        {
                            list.Add(new RefInfo { Owner = mb, ScriptName = ScriptNameOf(mb), Field = it.propertyPath + " が空 → 同じオブジェクトのレンダラー", Implicit = true });
                        }
                        continue;
                    }
                    bool toRenderer = o == r;
                    bool toGo = o == r.gameObject;
                    if (!toRenderer && !toGo) continue;
                    list.Add(new RefInfo { Owner = mb, ScriptName = ScriptNameOf(mb), Field = it.propertyPath, ToGameObject = toGo });
                }
            }
        }
        return list;
    }

    // 欄の型が Renderer（または MeshRenderer）か。SerializedProperty.type は "PPtr<$Renderer>" のような形
    private static bool IsRendererField(string type)
    {
        return type == "PPtr<$Renderer>" || type == "PPtr<Renderer>" || type == "PPtr<$MeshRenderer>" || type == "PPtr<MeshRenderer>";
    }

    // UdonBehaviour（U# の裏側・Udon グラフ）は、プログラムの名前で呼ぶ
    private static string ScriptNameOf(MonoBehaviour mb)
    {
        string type = mb.GetType().Name;
        if (type != "UdonBehaviour") return type;
        var so = new SerializedObject(mb);
        SerializedProperty src = so.FindProperty("programSource");
        Object program = src != null ? src.objectReferenceValue : null;
        if (program == null) return type;
        // U# のプログラムアセットは、元のクラス（sourceCsScript）の名前で呼ぶ
        var pso = new SerializedObject(program);
        SerializedProperty cs = pso.FindProperty("sourceCsScript");
        if (cs != null && cs.objectReferenceValue != null) return cs.objectReferenceValue.name;
        return program.name;
    }

    private static string HierarchyPath(Transform t)
    {
        var parts = new List<string>();
        for (; t != null; t = t.parent) parts.Insert(0, t.name);
        return string.Join("/", parts);
    }

    // =========================================================================
    // UV の範囲とテクスチャの大きさ
    // =========================================================================
    internal static bool TryGetUvRange(Mesh mesh, int subMesh, out Vector2 min, out Vector2 size, out string error)
    {
        min = Vector2.zero;
        size = Vector2.one;
        error = "";
        // 読み取り不可（isReadable = false）のメッシュも、エディターでは読める（Read/Write を切ったモデルや、ツールで作ったメッシュなど）
        using (Mesh.MeshDataArray data = Mesh.AcquireReadOnlyMeshData(mesh))
        {
            Mesh.MeshData d = data[0];
            if (!d.HasVertexAttribute(VertexAttribute.TexCoord0)) { error = "メッシュに UV がありません。"; return false; }
            var uvs = new Unity.Collections.NativeArray<Vector2>(d.vertexCount, Unity.Collections.Allocator.Temp);
            try
            {
                d.GetUVs(0, uvs);
                SubMeshDescriptor sm = d.GetSubMesh(subMesh);
                var idx = new Unity.Collections.NativeArray<int>(sm.indexCount, Unity.Collections.Allocator.Temp);
                try
                {
                    d.GetIndices(idx, subMesh);
                    Vector2 mn = new Vector2(float.MaxValue, float.MaxValue), mx = new Vector2(float.MinValue, float.MinValue);
                    for (int i = 0; i < idx.Length; i++)
                    {
                        Vector2 u = uvs[idx[i]];
                        if (float.IsNaN(u.x) || float.IsNaN(u.y) || float.IsInfinity(u.x) || float.IsInfinity(u.y)) { error = "UV に数でない値があります。"; return false; }
                        mn = Vector2.Min(mn, u);
                        mx = Vector2.Max(mx, u);
                    }
                    if (idx.Length == 0) { error = "サブメッシュ " + subMesh + " に三角形がありません。"; return false; }
                    Vector2 sz = mx - mn;
                    if (sz.x < 1e-5f || sz.y < 1e-5f) { error = "UV の範囲が線か点になっています。"; return false; }
                    min = mn;
                    size = sz;
                    return true;
                }
                finally { idx.Dispose(); }
            }
            finally { uvs.Dispose(); }
        }
    }

    // 長い辺を解像度に、短い辺はテクセルが縦長にならないよう 2 のべき乗で切り上げる
    private static void PlanTexture(SpiderWebBakeSlotPlan p, int resolution)
    {
        float su = p.UvSize.x, sv = p.UvSize.y;
        if (su >= sv)
        {
            p.Width = resolution;
            p.Height = Mathf.Clamp(resolution >> Mathf.Max(0, Mathf.FloorToInt(Mathf.Log(su / sv, 2f))), 64, resolution);
        }
        else
        {
            p.Height = resolution;
            p.Width = Mathf.Clamp(resolution >> Mathf.Max(0, Mathf.FloorToInt(Mathf.Log(sv / su, 2f))), 64, resolution);
        }
        // 糸の太さ（UV）: 直径 = 2 × _Thickness × 太さ倍率 × 粘液の太さ（細い方の糸で見る）
        Material m = p.Source;
        float thickness = F(m, "_Thickness", 0.0025f);
        float amt = Mathf.Clamp01(F(m, "_GooAmount", 1f));
        float spoke = Mathf.Max(F(m, "_SpokeWidth", 1f), 0.05f) * Mathf.Lerp(1f, F(m, "_GooThick", 1f), amt * Mathf.Clamp01(F(m, "_SpokeGoo", 1f)));
        float ring = Mathf.Max(F(m, "_RingWidth", 1f), 0.05f) * Mathf.Lerp(1f, F(m, "_GooThick", 1f), amt * Mathf.Clamp01(F(m, "_RingGoo", 1f)));
        float diameterUv = 2f * thickness * Mathf.Min(spoke, ring);
        float texelsPerUv = Mathf.Min(p.Width / p.UvSize.x, p.Height / p.UvSize.y);
        p.ThreadTexels = diameterUv * texelsPerUv;
        long bytes = 0;
        for (int w = p.Width, h = p.Height; ; w = Mathf.Max(1, w / 2), h = Mathf.Max(1, h / 2))
        {
            bytes += (long)((w + 3) / 4) * ((h + 3) / 4) * 16;   // BC7: 4×4 で 16 バイト
            if (w == 1 && h == 1) break;
        }
        p.Bytes = bytes;
    }

    internal static string DefaultFolderFor(Renderer r)
    {
        string owner = "Scene";
        PrefabStage stage = PrefabStageUtility.GetPrefabStage(r.gameObject);
        if (stage != null) owner = Path.GetFileNameWithoutExtension(stage.assetPath);
        else if (r.gameObject.scene.IsValid() && !string.IsNullOrEmpty(r.gameObject.scene.name)) owner = r.gameObject.scene.name;
        return DefaultRoot + "/" + Sanitize(owner);
    }

    private static string Sanitize(string name)
    {
        var sb = new StringBuilder();
        foreach (char c in name ?? "") sb.Append(Path.GetInvalidFileNameChars().Contains(c) || c == '/' || c == '\\' ? '_' : c);
        string s = sb.ToString().Trim();
        return s.Length == 0 ? "Web" : s;
    }

    // =========================================================================
    // 同意の印（同意画面だけが作る）
    // =========================================================================
    internal static SpiderWebBakeConsent CreateConsent(SpiderWebBakeAnalysis analysis)
    {
        if (analysis == null || !analysis.CanBake) throw new InvalidOperationException("焼けない状態では同意の印を作れません。");
        return new SpiderWebBakeConsent(analysis);
    }

    // =========================================================================
    // 焼き込み
    // =========================================================================

    /// <summary>
    /// 焼き込む。同意画面で作った「同意の印」が必要（無い・確認したときから対象や設定・マテリアルの値・
    /// 表示する内容が変わった場合は、何もせずに例外で断る）。戻り値は付けた控えのコンポーネント。
    /// </summary>
    public static SpiderWebBakeBackup Bake(Renderer renderer, SpiderWebBakeSettings settings, SpiderWebBakeConsent consent)
    {
        if (consent == null)
            throw new InvalidOperationException("同意の印がありません。焼き込みは、失われる機能と注意事項を確認する画面（Tools/SpiderShader/SpiderWeb を lilToon に焼き込む…）で同意してから行ってください。");
        if (EditorApplication.isPlayingOrWillChangePlaymode || EditorApplication.isCompiling)
            throw new InvalidOperationException("編集モードで、コンパイルが終わってから焼いてください。");
        if (!IsLilToonAvailable(out string lilReason)) throw new InvalidOperationException(lilReason);
        SpiderWebBakeAnalysis a = Analyze(renderer, settings, true);
        if (!a.CanBake) throw new InvalidOperationException("焼けません: " + string.Join(" / ", a.Blockers));
        if (consent.RendererId != renderer.GetInstanceID() || consent.AnalysisHash != a.Hash)
            throw new InvalidOperationException("同意したあとで、対象・設定・マテリアルの値・確認内容のどれかが変わりました。もう一度確認画面で内容を見て、同意し直してください。");
        Shader bakeShader = Shader.Find(BakeShaderName);
        if (bakeShader == null || !bakeShader.isSupported || ShaderUtil.ShaderHasError(bakeShader))
            throw new InvalidOperationException("焼き込み用のシェーダー（" + BakeShaderName + "）のコンパイル状態を確認してください。");

        SpiderWebBakeSettings s = a.Settings;
        bool transparent = s.mode == SpiderWebBakeMode.Transparent;
        float threshold = transparent ? TransparentCoverageThreshold : s.cutoff;
        Mesh mesh = renderer.GetComponent<MeshFilter>().sharedMesh;
        SpiderShaderEditorUtility.EnsureFolder(a.OutputFolder);

        var created = new List<string>();
        var slotRecords = new List<SpiderWebBakedSlot>();
        var bakedMats = new Dictionary<int, Material>();
        string baseName = Sanitize(renderer.gameObject.name) + "_" + a.Hash.Substring(0, 8);
        try
        {
            foreach (SpiderWebBakeSlotPlan plan in a.Slots)
            {
                string slotName = baseName + (a.Slots.Count > 1 ? "_s" + plan.Slot : "");
                var rec = new SpiderWebBakedSlot
                {
                    slot = plan.Slot, subMesh = plan.SubMesh, width = plan.Width, height = plan.Height,
                    uvRect = new Vector4(plan.UvMin.x, plan.UvMin.y, plan.UvSize.x, plan.UvSize.y), threadTexels = plan.ThreadTexels,
                };
                Texture2D tex = BakeTexture(bakeShader, mesh, plan, threshold, a.OutputFolder + "/" + slotName + ".png", rec);
                created.Add(rec.texturePath);
                Material mat = CreateLilToonMaterial(plan.Source, tex, plan, s);
                rec.materialPath = AssetDatabase.GenerateUniqueAssetPath(a.OutputFolder + "/" + slotName + ".mat");
                AssetDatabase.CreateAsset(mat, rec.materialPath);
                // lilToon の設定関数が残した Undo の記録を消す（あとで Undo を重ねたとき、焼いたマテリアルが壊れないように）
                Undo.ClearUndo(mat);
                created.Add(rec.materialPath);
                bakedMats[plan.Slot] = mat;
                slotRecords.Add(rec);
            }
            AssetDatabase.SaveAssets();
        }
        catch (Exception e)
        {
            throw new InvalidOperationException("焼き込みの途中で失敗しました。レンダラーは変えていません。作ったアセット（削除はご自身で）: " +
                                                (created.Count > 0 ? string.Join(", ", created) : "なし") + "\n" + e.Message, e);
        }

        // ---- ここから Undo 1 回分: 控えを付けてから差し替える ----
        Undo.IncrementCurrentGroup();
        int group = Undo.GetCurrentGroup();
        Undo.SetCurrentGroupName("巣を lilToon に焼き込む");
        Material[] original = renderer.sharedMaterials;
        // prefab のインスタンスなら、焼く前から上書きになっていたレンダラーの値を控える（元に戻すとき、それ以外は prefab の値へ戻す）
        bool prefabInstance = PrefabUtility.IsPartOfPrefabInstance(renderer);
        string[] overriddenBefore = prefabInstance ? OverriddenRendererPaths(renderer, original.Length) : new string[0];
        var backup = Undo.AddComponent<SpiderWebBakeBackup>(renderer.gameObject);
        backup.wasPrefabInstance = prefabInstance;
        backup.prefabOverriddenPaths = overriddenBefore;
        backup.hideFlags |= HideFlags.DontSaveInBuild;   // ビルドに入れない（Editor/SpiderWebBakeBuildStrip.cs でも取り除く）
        backup.dataVersion = 1;
        backup.toolVersion = ToolVersion;
        backup.bakedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        backup.originalMaterials = (Material[])original.Clone();
        backup.snapshots = a.Slots.Select(p => SpiderWebMaterialSnapshotUtil.Capture(p.Source, p.Slot)).ToArray();
        backup.rendererSettings = new SpiderWebRendererSnapshot
        {
            shadowCastingMode = (int)renderer.shadowCastingMode,
            receiveShadows = renderer.receiveShadows,
            sortingLayerID = renderer.sortingLayerID,
            sortingOrder = renderer.sortingOrder,
            lightProbeUsage = (int)renderer.lightProbeUsage,
            reflectionProbeUsage = (int)renderer.reflectionProbeUsage,
            hadPropertyBlock = renderer.HasPropertyBlock(),
        };
        backup.bake = new SpiderWebBakeRecord
        {
            resolution = s.resolution, mode = s.mode.ToString(), cutoff = transparent ? 0f : s.cutoff,
            coverageThreshold = threshold, outputFolder = a.OutputFolder, slots = slotRecords.ToArray(),
        };
        backup.createdAssets = created.ToArray();
        backup.acceptedCritical = consent.Critical;
        backup.acceptedCaution = consent.Caution;
        backup.acceptedInfo = consent.Info;
        backup.consentHash = consent.AnalysisHash;

        Material[] next = (Material[])original.Clone();
        foreach (var kv in bakedMats) next[kv.Key] = kv.Value;
        backup.bakedMaterials = (Material[])next.Clone();
        Undo.RecordObject(renderer, "巣を lilToon に焼き込む");
        renderer.sharedMaterials = next;
        renderer.shadowCastingMode = ShadowCastingMode.Off;
        renderer.receiveShadows = false;
        if (PrefabUtility.IsPartOfPrefabInstance(renderer))
            PrefabUtility.RecordPrefabInstancePropertyModifications(renderer);
        EditorUtility.SetDirty(backup);
        EditorUtility.SetDirty(renderer);
        Undo.CollapseUndoOperations(group);
        return backup;
    }

    // 焼き込みと元に戻すで変える（変えうる）レンダラーの値の場所
    private static IEnumerable<string> TrackedRendererPaths(int materialCount)
    {
        yield return "m_Materials.Array.size";
        for (int i = 0; i < materialCount; i++) yield return "m_Materials.Array.data[" + i + "]";
        yield return "m_CastShadows";
        yield return "m_ReceiveShadows";
        yield return "m_SortingLayerID";
        yield return "m_SortingLayer";
        yield return "m_SortingOrder";
        yield return "m_LightProbeUsage";
        yield return "m_ReflectionProbeUsage";
    }

    private static string[] OverriddenRendererPaths(Renderer r, int materialCount)
    {
        var so = new SerializedObject(r);
        var list = new List<string>();
        foreach (string path in TrackedRendererPaths(materialCount))
        {
            SerializedProperty p = so.FindProperty(path);
            if (p != null && p.prefabOverride) list.Add(path);
        }
        return list.ToArray();
    }

    // ---- 1 スロットを焼いて PNG にし、取り込み設定をして、ミップの被覆率を測る ----
    private static Texture2D BakeTexture(Shader bakeShader, Mesh mesh, SpiderWebBakeSlotPlan plan, float threshold, string wantedPath, SpiderWebBakedSlot rec)
    {
        int w = plan.Width, h = plan.Height;
        Color32[] px = RenderPattern(bakeShader, mesh, plan, w, h);
        bool any = false;
        foreach (Color32 c in px) if (c.a > 0) { any = true; break; }
        if (!any) throw new InvalidOperationException("焼いた結果が空でした（糸が 1 本も描かれませんでした）。巣の不透明度や UV を確認してください。");
        rec.mipCoverageNaive = NaiveMipCoverage(px, w, h, threshold);
        Dilate(px, w, h);

        string path = AssetDatabase.GenerateUniqueAssetPath(wantedPath);
        var encode = new Texture2D(w, h, TextureFormat.RGBA32, false, false) { hideFlags = HideFlags.HideAndDontSave };
        try
        {
            encode.SetPixels32(px);
            File.WriteAllBytes(Path.GetFullPath(path), encode.EncodeToPNG());
        }
        finally { Object.DestroyImmediate(encode); }
        AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceSynchronousImport);
        var imp = AssetImporter.GetAtPath(path) as TextureImporter;
        if (imp == null) throw new InvalidOperationException("テクスチャの取り込みに失敗しました: " + path);
        imp.textureType = TextureImporterType.Default;
        imp.textureShape = TextureImporterShape.Texture2D;
        imp.sRGBTexture = true;                          // 色は sRGB で焼いてある
        imp.alphaSource = TextureImporterAlphaSource.FromInput;
        imp.alphaIsTransparency = true;                  // 透明な所の色を周りから広げる（にじみ止め。焼くときにも広げてある）
        imp.mipmapEnabled = true;
        imp.mipmapFilter = TextureImporterMipFilter.BoxFilter;
        imp.mipMapsPreserveCoverage = true;              // ★ しきい値を超える画素の割合を、各ミップ段で保つ
        imp.alphaTestReferenceValue = threshold;
        imp.borderMipmap = false;
        imp.fadeout = false;
        imp.streamingMipmaps = false;
        imp.wrapMode = TextureWrapMode.Clamp;
        imp.filterMode = FilterMode.Trilinear;
        imp.anisoLevel = 4;                              // 斜めから見る巣が多いので少し上げる
        imp.npotScale = TextureImporterNPOTScale.None;
        imp.isReadable = false;
        imp.maxTextureSize = Mathf.Max(w, h);
        imp.textureCompression = TextureImporterCompression.CompressedHQ;
        var pc = imp.GetPlatformTextureSettings("Standalone");
        pc.overridden = true;
        pc.maxTextureSize = Mathf.Max(w, h);
        pc.format = TextureImporterFormat.BC7;
        pc.textureCompression = TextureImporterCompression.CompressedHQ;
        pc.compressionQuality = 100;
        imp.SetPlatformTextureSettings(pc);
        imp.userData = "SpiderWebLilToonBaker " + ToolVersion + " threshold=" + threshold.ToString("R", CultureInfo.InvariantCulture) +
                       " uvRect=" + rec.uvRect.x.ToString("R", CultureInfo.InvariantCulture) + "," + rec.uvRect.y.ToString("R", CultureInfo.InvariantCulture) + "," +
                       rec.uvRect.z.ToString("R", CultureInfo.InvariantCulture) + "," + rec.uvRect.w.ToString("R", CultureInfo.InvariantCulture);
        imp.SaveAndReimport();
        var tex = AssetDatabase.LoadAssetAtPath<Texture2D>(path);
        if (tex == null) throw new InvalidOperationException("テクスチャを読み込めません: " + path);
        rec.texturePath = path;
        rec.mipCoverage = MeasureMipCoverage(bakeShader, tex, threshold);
        return tex;
    }

    /// <summary>巣のメッシュを UV の平面に広げて、焼き込み用シェーダーで描く。色は sRGB の 8bit。</summary>
    internal static Color32[] RenderPattern(Shader bakeShader, Mesh mesh, SpiderWebBakeSlotPlan plan, int w, int h)
    {
        Material bake = new Material(bakeShader) { hideFlags = HideFlags.HideAndDontSave };
        RenderTexture rt = null;
        Texture2D read = null;
        RenderTexture prev = RenderTexture.active;
        bool prevSRGB = GL.sRGBWrite;
        try
        {
            // 巣のマテリアルの値を、巣のシェーダーの Properties の型どおりに写す（動き・光の分はあとで 0 にする）。
            // 色の注意: 巣のシェーダーは Properties で「Color」と書いた値を、Unity が Linear に直して受け取る。
            //   焼き込み用シェーダーには Properties が無いので、Unity は直さない（2026-10-14 に実測。SetColor でも同じ）。
            //   そこで、ここで Linear に直した値を入れる（[Gamma] の付いた色は直さない）。
            //   ※ CopyPropertiesFromMaterial で写すと、Unity が直す印も一緒に写るので使わない（二重に直してしまう）
            Shader webShader = plan.Source.shader;
            bool linear = QualitySettings.activeColorSpace == ColorSpace.Linear;
            for (int i = 0; i < webShader.GetPropertyCount(); i++)
            {
                string name = webShader.GetPropertyName(i);
                switch (webShader.GetPropertyType(i))
                {
                    case ShaderPropertyType.Color:
                        Color c = plan.Source.GetColor(name);
                        bool gamma = (webShader.GetPropertyFlags(i) & ShaderPropertyFlags.Gamma) != 0;
                        bake.SetVector(name, linear && !gamma ? (Vector4)c.linear : (Vector4)c);
                        break;
                    case ShaderPropertyType.Vector:
                        bake.SetVector(name, plan.Source.GetVector(name));
                        break;
                    case ShaderPropertyType.Float:
                    case ShaderPropertyType.Range:
                        bake.SetFloat(name, plan.Source.GetFloat(name));
                        break;
                    case ShaderPropertyType.Int:
                        bake.SetInteger(name, plan.Source.GetInteger(name));
                        break;
                    case ShaderPropertyType.Texture:
                        bake.SetTexture(name, plan.Source.GetTexture(name));
                        bake.SetTextureScale(name, plan.Source.GetTextureScale(name));
                        bake.SetTextureOffset(name, plan.Source.GetTextureOffset(name));
                        break;
                }
            }
            foreach (string zero in new[] { "_SwayAnimEnable", "_PullEnable", "_PullCount", "_DrapeEnable", "_DrapeCount", "_LightInfluence" })
                bake.SetFloat(zero, 0f);
            bake.SetVector("_BakeUVRect", new Vector4(plan.UvMin.x, plan.UvMin.y, plan.UvSize.x, plan.UvSize.y));
            bake.SetVector("_BakeLightDir", plan.LightDir.sqrMagnitude > 1e-8f ? plan.LightDir.normalized : Vector3.up);
            bake.SetMatrix("_BakeObjectToWorld", plan.ObjectToWorld);
            bake.SetMatrix("_BakeWorldToObject", plan.ObjectToWorld.inverse);
            bake.SetFloat("_BakeTangentSign", plan.ObjectToWorld.determinant < 0f ? -1f : 1f);
            var desc = new RenderTextureDescriptor(w, h, RenderTextureFormat.ARGB32, 0) { sRGB = false, msaaSamples = 1, useMipMap = false, autoGenerateMips = false };
            rt = RenderTexture.GetTemporary(desc);
            RenderTexture.active = rt;
            GL.sRGBWrite = false;
            GL.Clear(true, true, new Color(0f, 0f, 0f, 0f));
            GL.PushMatrix();
            try
            {
                GL.LoadOrtho();
                if (!bake.SetPass(0)) throw new InvalidOperationException("焼き込み用シェーダーのパスを使えませんでした。");
                Graphics.DrawMeshNow(mesh, Matrix4x4.identity, plan.SubMesh);
            }
            finally { GL.PopMatrix(); }
            read = new Texture2D(w, h, TextureFormat.RGBA32, false, true) { hideFlags = HideFlags.HideAndDontSave };
            read.ReadPixels(new Rect(0, 0, w, h), 0, 0, false);
            return read.GetPixels32();
        }
        finally
        {
            RenderTexture.active = prev;
            GL.sRGBWrite = prevSRGB;
            if (rt != null) RenderTexture.ReleaseTemporary(rt);
            if (read != null) Object.DestroyImmediate(read);
            Object.DestroyImmediate(bake);
        }
    }

    /// <summary>
    /// 空き画素（不透明度 0）の色を、いちばん近い糸の色で埋める（ダイレーション）。不透明度は 0 のまま。
    /// ミップやテクスチャの補間で、透明な所の黒が糸の縁へにじむのを防ぐ。
    /// </summary>
    internal static void Dilate(Color32[] px, int w, int h)
    {
        int n = w * h;
        var filled = new bool[n];
        var queue = new int[n];
        int head = 0, tail = 0;
        for (int i = 0; i < n; i++)
            if (px[i].a > 0) { filled[i] = true; queue[tail++] = i; }
        if (tail == 0) return;
        while (head < tail)
        {
            int i = queue[head++];
            int x = i % w, y = i / w;
            Color32 c = px[i];
            for (int k = 0; k < 4; k++)
            {
                int nx = x + (k == 0 ? 1 : k == 1 ? -1 : 0);
                int ny = y + (k == 2 ? 1 : k == 3 ? -1 : 0);
                if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                int j = ny * w + nx;
                if (filled[j]) continue;
                filled[j] = true;
                px[j] = new Color32(c.r, c.g, c.b, 0);
                queue[tail++] = j;
            }
        }
    }

    /// <summary>参考: 被覆率を保たない単純な平均（2×2 の箱）のミップで、しきい値を超える画素の割合。</summary>
    internal static float[] NaiveMipCoverage(Color32[] px, int w, int h, float threshold)
    {
        var result = new List<float>();
        var a = new float[w * h];
        for (int i = 0; i < a.Length; i++) a[i] = px[i].a / 255f;
        while (true)
        {
            int over = 0;
            for (int i = 0; i < a.Length; i++) if (a[i] > threshold) over++;
            result.Add(over / (float)a.Length);
            if (w == 1 && h == 1) break;
            int nw = Mathf.Max(1, w / 2), nh = Mathf.Max(1, h / 2);
            var b = new float[nw * nh];
            for (int y = 0; y < nh; y++)
                for (int x = 0; x < nw; x++)
                {
                    float sum = 0f;
                    int cnt = 0;
                    for (int oy = 0; oy < 2; oy++)
                        for (int ox = 0; ox < 2; ox++)
                        {
                            int sx = Mathf.Min(x * 2 + ox, w - 1), sy = Mathf.Min(y * 2 + oy, h - 1);
                            sum += a[sy * w + sx];
                            cnt++;
                        }
                    b[y * nw + x] = sum / cnt;
                }
            a = b;
            w = nw;
            h = nh;
        }
        return result.ToArray();
    }

    /// <summary>取り込み（圧縮）後のテクスチャの、各ミップ段でしきい値を超える画素の割合を GPU で読んで数える。</summary>
    public static float[] MeasureMipCoverage(Shader bakeShader, Texture2D tex, float threshold)
    {
        var result = new List<float>();
        Material read = new Material(bakeShader) { hideFlags = HideFlags.HideAndDontSave };
        RenderTexture prev = RenderTexture.active;
        bool prevSRGB = GL.sRGBWrite;
        Texture2D cpu = null;
        try
        {
            GL.sRGBWrite = false;
            // Graphics.Blit は Properties の無いシェーダーだと _MainTex を結び付けないので、自分で渡す
            read.SetTexture("_MainTex", tex);
            for (int level = 0; level < tex.mipmapCount; level++)
            {
                int w = Mathf.Max(1, tex.width >> level), h = Mathf.Max(1, tex.height >> level);
                var desc = new RenderTextureDescriptor(w, h, RenderTextureFormat.ARGB32, 0) { sRGB = false, msaaSamples = 1 };
                RenderTexture rt = RenderTexture.GetTemporary(desc);
                try
                {
                    read.SetFloat("_BakeReadLod", level);
                    Graphics.Blit(tex, rt, read, 1);
                    RenderTexture.active = rt;
                    if (cpu == null || cpu.width != w || cpu.height != h)
                    {
                        if (cpu != null) Object.DestroyImmediate(cpu);
                        cpu = new Texture2D(w, h, TextureFormat.RGBA32, false, true) { hideFlags = HideFlags.HideAndDontSave };
                    }
                    cpu.ReadPixels(new Rect(0, 0, w, h), 0, 0, false);
                    Color32[] px = cpu.GetPixels32();
                    int over = 0;
                    foreach (Color32 c in px) if (c.a / 255f > threshold) over++;
                    result.Add(over / (float)px.Length);
                }
                finally
                {
                    RenderTexture.active = prev;
                    RenderTexture.ReleaseTemporary(rt);
                }
            }
        }
        finally
        {
            RenderTexture.active = prev;
            GL.sRGBWrite = prevSRGB;
            if (cpu != null) Object.DestroyImmediate(cpu);
            Object.DestroyImmediate(read);
        }
        return result.ToArray();
    }

    // ---- lilToon のマテリアル ----
    private static Material CreateLilToonMaterial(Material src, Texture2D tex, SpiderWebBakeSlotPlan plan, SpiderWebBakeSettings s)
    {
        bool transparent = s.mode == SpiderWebBakeMode.Transparent;
        var m = new Material(Shader.Find(transparent ? LilTransparentShaderName : LilCutoutShaderName)) { name = src.name + "_lilBaked" };
        try
        {
            SetupLilToon(m, transparent);
            string[] required = { "_MainTex", "_Color", "_Cutoff", "_Cull", "_ZWrite", "_AlphaToMask", "_TransparentMode", "_AsUnlit", "_LightMinLimit", "_LightMaxLimit" };
            string[] missing = required.Where(x => !m.HasProperty(x)).ToArray();
            if (missing.Length > 0)
                throw new InvalidOperationException("lilToon のシェーダーに想定したプロパティがありません: " + string.Join(", ", missing) + "（lilToon の版が想定（2.3.x）と違う可能性があります）");
            FillLilToonMaterial(m, src, tex, plan, s, transparent);
            return m;
        }
        catch
        {
            Object.DestroyImmediate(m);   // 作りかけのマテリアルは捨てる（アセットにはまだしていない）
            throw;
        }
    }

    private static void FillLilToonMaterial(Material m, Material src, Texture2D tex, SpiderWebBakeSlotPlan plan, SpiderWebBakeSettings s, bool transparent)
    {
        m.SetTexture("_MainTex", tex);
        // メッシュの UV → テクスチャの UV: (uv - 最小) / 大きさ
        m.SetTextureScale("_MainTex", new Vector2(1f / plan.UvSize.x, 1f / plan.UvSize.y));
        m.SetTextureOffset("_MainTex", new Vector2(-plan.UvMin.x / plan.UvSize.x, -plan.UvMin.y / plan.UvSize.y));
        m.SetColor("_Color", Color.white);
        // 両面描画。元の巣が裏面の糸を隠していたら、裏面を描かない
        m.SetFloat("_Cull", F(src, "_HideBackFibers") > 0.5f ? (float)CullMode.Back : (float)CullMode.Off);
        if (transparent)
        {
            m.SetFloat("_TransparentMode", 2f);
            m.SetFloat("_Cutoff", 0.001f);   // ほぼ透明な所だけ捨てる
            m.SetFloat("_ZWrite", 0f);       // 半透明は深度を書かない（lilToon の設定は 1 にするので戻す）
            m.SetFloat("_AlphaToMask", 0f);
            m.renderQueue = 3000;            // VRChat ワールドの半透明は 3000
        }
        else
        {
            m.SetFloat("_TransparentMode", 1f);
            m.SetFloat("_Cutoff", s.cutoff);
            m.SetFloat("_AlphaToMask", 1f);  // alpha to coverage（MSAA があれば縁がなめらか）
            m.renderQueue = 2450;
        }
        // 陰影・リム・艶はテクスチャに焼いてあるので、lilToon 側の同じ機能は切る
        foreach (string off in new[] { "_UseShadow", "_ShadowReceive", "_UseRim", "_UseMatCap", "_UseMatCap2nd", "_UseReflection", "_UseEmission", "_UseBacklight", "_UseOutline" })
            if (m.HasProperty(off)) m.SetFloat(off, 0f);
        // 明るさ: 元は「色 × lerp(1, 光, シーン光の反映度)」で、光は 0.25〜1.35 に収めていた。
        // lilToon は「色 × lerp(光, 1, _AsUnlit)」で、光を _LightMinLimit〜_LightMaxLimit に収める
        float influence = Mathf.Clamp01(F(src, "_LightInfluence", 0.35f));
        m.SetFloat("_AsUnlit", 1f - influence);
        m.SetFloat("_LightMinLimit", 0.25f);
        m.SetFloat("_LightMaxLimit", 1.35f);
    }

    // =========================================================================
    // 元に戻す
    // =========================================================================

    /// <summary>
    /// 元のマテリアルが焼いたあとで編集されていないかを調べる（何も変えない）。
    /// 戻り値: スロットごとの「控えの値との違い」（違いが無いスロット・元が無いスロットは入らない）
    /// </summary>
    public static Dictionary<int, List<string>> DiffOriginals(SpiderWebBakeBackup backup)
    {
        var result = new Dictionary<int, List<string>>();
        if (backup == null) return result;
        foreach (SpiderWebMaterialSnapshot snap in backup.snapshots)
        {
            Material orig = FindOriginal(backup, snap);
            if (orig == null) continue;
            List<string> diff = SpiderWebMaterialSnapshotUtil.Compare(snap, SpiderWebMaterialSnapshotUtil.Capture(orig, snap.slot));
            if (diff.Count > 0) result[snap.slot] = diff;
        }
        return result;
    }

    /// <summary>
    /// 元のマテリアル: 控えの参照。切れていたら、控えの GUID のアセット（Revert・DiffOriginals・控えのインスペクタで同じ判定を使う）。
    /// null なら、元に戻すときに控えの値から作り直す。
    /// </summary>
    internal static Material FindOriginal(SpiderWebBakeBackup backup, SpiderWebMaterialSnapshot snap)
    {
        if (snap.slot < 0 || snap.slot >= backup.originalMaterials.Length) return null;
        Material orig = backup.originalMaterials[snap.slot];
        if (orig == null && !string.IsNullOrEmpty(snap.assetGuid))
        {
            string p = AssetDatabase.GUIDToAssetPath(snap.assetGuid);
            if (!string.IsNullOrEmpty(p)) orig = AssetDatabase.LoadAssetAtPath<Material>(p);
        }
        return orig;
    }

    /// <summary>
    /// 控えから、焼く前のマテリアルとレンダラーの設定に戻し、控えのコンポーネントを外す（Undo 1 回分）。
    /// ・元のマテリアルが無ければ（mode が RecreateFromSnapshot なら、あっても）控えの値から作り直して
    ///   restoreFolder（空なら焼いたフォルダの Restored）に保存する。元がマテリアルバリアントでも、親の無い普通のマテリアルになる。
    ///   restoreFolder は Assets/ の下のフォルダ（.. を含まない）。違反なら何も変えずに ArgumentException で断る。
    /// ・元のマテリアルが焼いたあとで編集されていたら、その違いを結果に並べる（UseOriginal のときは今の値のまま使う）。
    /// ・prefab のインスタンスでは、焼く前に上書きでなかった値は、代入ではなく prefab の値へ戻す（上書きを残さない）。
    ///   ただし作り直したマテリアルのスロットは、上書きとして残す（prefab の値へ戻すと、作り直したマテリアルが使われない）。
    /// 焼いたアセットは消さない。
    /// </summary>
    public static SpiderWebRevertResult Revert(SpiderWebBakeBackup backup, string restoreFolder = "", SpiderWebRevertMode mode = SpiderWebRevertMode.UseOriginal)
    {
        if (backup == null) throw new ArgumentNullException(nameof(backup));
        if (EditorApplication.isPlayingOrWillChangePlaymode) throw new InvalidOperationException("Play 中は元に戻せません。Play を止めてから戻してください。");
        Renderer r = backup.GetComponent<Renderer>();
        if (r == null) throw new InvalidOperationException("控えと同じオブジェクトにレンダラーがありません。");
        var result = new SpiderWebRevertResult { Renderer = r };

        // 焼いたスロットだけ元に戻す。それ以外のスロット（焼いたあとで足した分も）は今のまま
        Material[] current = r.sharedMaterials;
        int count = Mathf.Max(backup.originalMaterials.Length, current.Length);
        var restored = new Material[count];
        for (int i = 0; i < count; i++)
            restored[i] = i < current.Length ? current[i] : backup.originalMaterials[i];
        string folder = string.IsNullOrEmpty(restoreFolder)
            ? (string.IsNullOrEmpty(backup.bake.outputFolder) ? DefaultRoot : backup.bake.outputFolder) + "/Restored"
            : restoreFolder.Replace('\\', '/').TrimEnd('/');
        // 指定された保存先は、焼くときの保存先と同じ条件で確かめる（Assets/ の下で、.. を含まない）。違反なら何も変えずに断る
        if (!string.IsNullOrEmpty(restoreFolder) && (!folder.StartsWith("Assets/", StringComparison.Ordinal) || folder.Contains("..")))
            throw new ArgumentException("作り直したマテリアルの保存先は Assets/ の下のフォルダにしてください: " + folder, nameof(restoreFolder));

        var recreatedSlots = new HashSet<int>();   // 控えの値から作り直したスロット（prefab の値へは戻さない）

        foreach (SpiderWebMaterialSnapshot snap in backup.snapshots)
        {
            if (snap.slot < 0 || snap.slot >= backup.originalMaterials.Length) continue;
            Material orig = FindOriginal(backup, snap);
            bool recreate = orig == null || mode == SpiderWebRevertMode.RecreateFromSnapshot;
            if (!recreate)
            {
                List<string> diff = SpiderWebMaterialSnapshotUtil.Compare(snap, SpiderWebMaterialSnapshotUtil.Capture(orig, snap.slot));
                if (diff.Count > 0)
                {
                    result.Messages.Add("スロット " + snap.slot + ": 元のマテリアル（" + orig.name + "）は焼いたあとで " + diff.Count +
                                        " か所変わっています。今の値のまま戻しました（控えの値に戻したいときは「控えの値で作り直す」を選んでください）:");
                    foreach (string d in diff.Take(20)) result.Messages.Add("    " + d);
                    if (diff.Count > 20) result.Messages.Add("    ほか " + (diff.Count - 20) + " か所");
                }
            }
            if (recreate)
            {
                bool missing = orig == null;
                orig = SpiderWebMaterialSnapshotUtil.Recreate(snap);
                SpiderShaderEditorUtility.EnsureFolder(folder);
                string path = AssetDatabase.GenerateUniqueAssetPath(folder + "/" + Sanitize(snap.name) + ".mat");
                AssetDatabase.CreateAsset(orig, path);
                result.Recreated.Add(path);
                recreatedSlots.Add(snap.slot);
                result.Messages.Add("スロット " + snap.slot + ": " + (missing ? "元のマテリアル（" + snap.name + "）が見つからないので、" : "") +
                                    "控えの値から作り直しました: " + path +
                                    (string.IsNullOrEmpty(snap.parentPath) ? "" : "（元はマテリアルバリアント。親 " + snap.parentPath + " とのつながりは作り直していません。親を持たない普通のマテリアルです）"));
            }
            else if (current.Length > snap.slot && backup.bakedMaterials.Length > snap.slot && current[snap.slot] != backup.bakedMaterials[snap.slot])
            {
                result.Messages.Add("スロット " + snap.slot + ": 焼いたあとで別のマテリアル（" + (current[snap.slot] != null ? current[snap.slot].name : "なし") + "）に変わっていましたが、元のマテリアルに戻しました。");
            }
            restored[snap.slot] = orig;
        }
        if (result.Recreated.Count > 0) AssetDatabase.SaveAssets();

        Undo.IncrementCurrentGroup();
        int group = Undo.GetCurrentGroup();
        Undo.SetCurrentGroupName("巣の焼き込みを元に戻す");
        Undo.RecordObject(r, "巣の焼き込みを元に戻す");
        SpiderWebRendererSnapshot rs = backup.rendererSettings;
        // 値が違うものだけ代入する（同じ値を代入して、prefab の上書きを増やさない）
        if (!r.sharedMaterials.SequenceEqual(restored)) r.sharedMaterials = restored;
        if (r.shadowCastingMode != (ShadowCastingMode)rs.shadowCastingMode) r.shadowCastingMode = (ShadowCastingMode)rs.shadowCastingMode;
        if (r.receiveShadows != rs.receiveShadows) r.receiveShadows = rs.receiveShadows;
        if (r.sortingLayerID != rs.sortingLayerID) r.sortingLayerID = rs.sortingLayerID;
        if (r.sortingOrder != rs.sortingOrder) r.sortingOrder = rs.sortingOrder;
        if (r.lightProbeUsage != (LightProbeUsage)rs.lightProbeUsage) r.lightProbeUsage = (LightProbeUsage)rs.lightProbeUsage;
        if (r.reflectionProbeUsage != (ReflectionProbeUsage)rs.reflectionProbeUsage) r.reflectionProbeUsage = (ReflectionProbeUsage)rs.reflectionProbeUsage;
        if (PrefabUtility.IsPartOfPrefabInstance(r))
        {
            PrefabUtility.RecordPrefabInstancePropertyModifications(r);
            if (backup.wasPrefabInstance)
            {
                // 焼く前に上書きでなかった値は、prefab の値へ戻す（上書きとして残さない）。
                // ・元のマテリアル（GUID で見つけ直したものも含む）を使ったスロットは、prefab の値が同じ元のマテリアルなので、戻しても見た目は同じ
                // ・作り直したスロットは戻さない（戻すと prefab の値になり、作り直したマテリアルが使われなくなる）。上書きとして残す
                var before = new HashSet<string>(backup.prefabOverriddenPaths ?? new string[0], StringComparer.Ordinal);
                var keep = new HashSet<string>(recreatedSlots.Select(s => "m_Materials.Array.data[" + s + "]"), StringComparer.Ordinal);
                var so = new SerializedObject(r);
                int reverted = 0, kept = 0;
                foreach (string path in TrackedRendererPaths(count))
                {
                    if (before.Contains(path)) continue;
                    SerializedProperty sp = so.FindProperty(path);
                    if (sp == null || !sp.prefabOverride) continue;
                    if (keep.Contains(path)) { kept++; continue; }
                    PrefabUtility.RevertPropertyOverride(sp, InteractionMode.UserAction);
                    reverted++;
                }
                if (reverted > 0) result.Messages.Add("prefab のインスタンス: 焼く前に上書きでなかったレンダラーの値 " + reverted + " か所を、prefab の値へ戻しました。");
                if (kept > 0) result.Messages.Add("prefab のインスタンス: 作り直したマテリアルのスロット " + kept + " か所は、prefab の上書きとして残しました（prefab の値へ戻すと、作り直したマテリアルが使われなくなるため）。");
            }
        }
        EditorUtility.SetDirty(r);
        Undo.DestroyObjectImmediate(backup);
        Undo.CollapseUndoOperations(group);
        result.Messages.Add("焼いたテクスチャとマテリアルは消していません（削除はご自身で）。");
        return result;
    }
}
