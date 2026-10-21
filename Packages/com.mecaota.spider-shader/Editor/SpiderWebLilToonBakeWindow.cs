// このファイルは C# の null 許容の注釈（nullable）を使わない書き方をしている。利用側のプロジェクトが
// 追加のコンパイラ引数（csc.rsp の -nullable:enable など）で注釈を有効にしても警告が出ないよう、明示的に無効にする。
#nullable disable
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using UnityEditor;
using UnityEngine;

// =============================================================================
// SpiderWebLilToonBakeWindow.cs — 巣を lilToon に焼き込む前の確認画面（同意画面）
//
//  開き方:
//    ・メニュー Tools/SpiderShader/SpiderWeb を lilToon に焼き込む…（選んでいるオブジェクトのレンダラー）
//    ・MeshRenderer の右上の「⋮」メニュー → SpiderWeb を lilToon に焼き込む…
//    ・巣のマテリアルのインスペクターの「lilToon に焼き込む」欄のボタン
//  このレンダラーで失われる機能と注意事項を「重大・注意・参考」に分けて一覧にし、
//  「上記を理解し、焼き込みに同意します」にチェックを入れたときだけ「焼き込む」を押せる。
//  設定や対象を変えると、確認内容が変わるのでチェックは外れる。
// =============================================================================
public sealed class SpiderWebLilToonBakeWindow : EditorWindow
{
    private const string MenuPath = "Tools/SpiderShader/SpiderWeb を lilToon に焼き込む…";
    private const string ContextPath = "CONTEXT/MeshRenderer/SpiderWeb を lilToon に焼き込む…";

    [SerializeField] private Renderer target;
    [SerializeField] private SpiderWebBakeSettings settings = new SpiderWebBakeSettings();
    [SerializeField] private bool agreed;
    [SerializeField] private string agreedHash = "";
    [SerializeField] private bool showReferences;

    private SpiderWebBakeAnalysis analysis;
    private string analysisError = "";
    // 設定を変えたときの見直しは、少し遅らせてまとめる（参照の走査は覚えてあるが、テクスチャの見積もりなども毎回やり直すため）
    [NonSerialized] private double pendingReanalyzeAt = -1;
    private const double ReanalyzeDelay = 0.4;
    private Vector2 scroll;
    private string lastResult = "";

    [MenuItem(MenuPath, false, 2100)]
    private static void OpenFromMenu()
    {
        Renderer r = Selection.activeGameObject != null ? Selection.activeGameObject.GetComponent<Renderer>() : null;
        Open(r);
    }

    [MenuItem(ContextPath)]
    private static void OpenFromContext(MenuCommand command)
    {
        Open(command.context as Renderer);
    }

    /// <summary>確認画面を開く（焼き込みはしない）。</summary>
    public static SpiderWebLilToonBakeWindow Open(Renderer renderer)
    {
        var w = GetWindow<SpiderWebLilToonBakeWindow>(false, "巣を lilToon に焼き込む", true);
        w.minSize = new Vector2(460f, 520f);
        w.target = renderer;
        w.agreed = false;
        w.agreedHash = "";
        w.lastResult = "";
        w.Reanalyze();
        w.Show();
        return w;
    }

    private void OnEnable()
    {
        EditorApplication.update -= OnEditorUpdate;
        EditorApplication.update += OnEditorUpdate;
        Reanalyze();
    }

    private void OnDisable()
    {
        EditorApplication.update -= OnEditorUpdate;
    }

    private void OnEditorUpdate()
    {
        if (pendingReanalyzeAt > 0 && EditorApplication.timeSinceStartup >= pendingReanalyzeAt)
        {
            pendingReanalyzeAt = -1;
            Reanalyze();
        }
    }

    // 設定を変えたとき: 同意はすぐ外し、見直しは少しあとにまとめて 1 回
    private void ScheduleReanalyze()
    {
        agreed = false;
        agreedHash = "";
        pendingReanalyzeAt = EditorApplication.timeSinceStartup + ReanalyzeDelay;
        Repaint();
    }

    private void OnFocus()
    {
        // 他の画面でマテリアルなどを変えたかもしれないので、見直す（内容が変わればチェックは外れる）
        Reanalyze();
    }

    private void Reanalyze()
    {
        analysisError = "";
        try { analysis = SpiderWebLilToonBaker.Analyze(target, settings); }
        catch (Exception e) { analysis = null; analysisError = e.Message; }
        if (analysis == null || analysis.Hash != agreedHash) { agreed = false; agreedHash = ""; }
        pendingReanalyzeAt = -1;
        Repaint();
    }

    private void OnGUI()
    {
        scroll = EditorGUILayout.BeginScrollView(scroll);
        EditorGUILayout.HelpBox("巣の模様をテクスチャに焼き、このレンダラーのマテリアルを lilToon に差し替えます。" +
                                "画素ごとの計算が無くなるので描画は軽くなりますが、下に挙げる機能は失われます。\n" +
                                "焼いたあとは、レンダラーに付く控えのコンポーネント（SpiderWebBakeBackup）の「元に戻す」で、いつでも元に戻せます。", MessageType.Info);

        bool lilOk = SpiderWebLilToonBaker.IsLilToonAvailable(out string lilReason);
        if (!lilOk) EditorGUILayout.HelpBox(lilReason, MessageType.Error);

        EditorGUI.BeginChangeCheck();
        target = (Renderer)EditorGUILayout.ObjectField("対象のレンダラー", target, typeof(Renderer), true);
        if (EditorGUI.EndChangeCheck()) Reanalyze();

        // ---- 設定 ----
        EditorGUILayout.Space(4);
        EditorGUILayout.LabelField("設定", EditorStyles.boldLabel);
        EditorGUI.BeginChangeCheck();
        settings.resolution = EditorGUILayout.IntPopup("解像度（長い辺）", settings.resolution,
            SpiderWebLilToonBaker.Resolutions.Select(x => x.ToString(CultureInfo.InvariantCulture)).ToArray(), SpiderWebLilToonBaker.Resolutions);
        settings.mode = (SpiderWebBakeMode)EditorGUILayout.Popup("モード", (int)settings.mode,
            new[] { "Cutout ＋ alpha to coverage（既定）", "Transparent（半透明）" });
        if (settings.mode == SpiderWebBakeMode.Cutout)
            settings.cutoff = EditorGUILayout.Slider("Cutout のしきい値", settings.cutoff, 0.05f, 0.95f);
        else
            EditorGUILayout.LabelField("被覆率を保つしきい値", SpiderWebLilToonBaker.TransparentCoverageThreshold.ToString("0.00", CultureInfo.InvariantCulture) + "（巣の深度パスと同じ）");
        settings.outputFolder = EditorGUILayout.TextField(new GUIContent("保存先（空なら自動）", "空なら Assets/mecaota/BakedWebs/<シーン名>"), settings.outputFolder);
        if (EditorGUI.EndChangeCheck()) ScheduleReanalyze();
        bool pending = pendingReanalyzeAt > 0;
        if (pending) EditorGUILayout.HelpBox("設定が変わったので、確認し直しています…", MessageType.None);

        if (!string.IsNullOrEmpty(analysisError)) EditorGUILayout.HelpBox(analysisError, MessageType.Error);
        if (analysis != null)
        {
            foreach (string b in analysis.Blockers) EditorGUILayout.HelpBox("焼けません: " + b, MessageType.Error);

            if (analysis.Slots.Count > 0)
            {
                EditorGUILayout.Space(4);
                EditorGUILayout.LabelField("焼くスロット", EditorStyles.boldLabel);
                foreach (SpiderWebBakeSlotPlan p in analysis.Slots)
                {
                    using (new EditorGUI.DisabledScope(true))
                        EditorGUILayout.ObjectField("スロット " + p.Slot + "（サブメッシュ " + p.SubMesh + "）", p.Source, typeof(Material), false);
                    EditorGUILayout.LabelField("　テクスチャ", p.Width + "×" + p.Height + "、糸 1 本 約 " + p.ThreadTexels.ToString("0.0", CultureInfo.InvariantCulture) +
                                                                " テクセル、" + (p.Bytes / (1024.0 * 1024.0)).ToString("0.0", CultureInfo.InvariantCulture) + " MiB");
                }
                EditorGUILayout.LabelField("保存先", analysis.OutputFolder);
            }

            DrawItems("失われる機能", analysis.Lost);
            DrawItems("注意事項", analysis.Notes);

            if (analysis.References.Count > 0)
            {
                showReferences = EditorGUILayout.Foldout(showReferences, "このレンダラーを参照しているもの（" + analysis.References.Count + "）", true);
                if (showReferences)
                    foreach (string x in analysis.References) EditorGUILayout.LabelField("・" + x, EditorStyles.wordWrappedMiniLabel);
            }
            if (GUILayout.Button("もう一度調べる")) Reanalyze();

            // ---- 同意 ----
            EditorGUILayout.Space(8);
            using (new EditorGUI.DisabledScope(!analysis.CanBake || !lilOk || pending))
            {
                EditorGUI.BeginChangeCheck();
                bool next = EditorGUILayout.ToggleLeft("上記を理解し、焼き込みに同意します", agreed, EditorStyles.boldLabel);
                if (EditorGUI.EndChangeCheck())
                {
                    agreed = next;
                    agreedHash = next ? analysis.Hash : "";
                }
            }
            bool busy = EditorApplication.isPlayingOrWillChangePlaymode || EditorApplication.isCompiling;
            if (busy) EditorGUILayout.HelpBox("Play 中・コンパイル中は焼けません。", MessageType.Warning);
            bool ready = lilOk && analysis.CanBake && agreed && agreedHash == analysis.Hash && !busy && !pending;
            using (new EditorGUI.DisabledScope(!ready))
            {
                if (GUILayout.Button("焼き込む", GUILayout.Height(30f)))
                {
                    string error = DoBake();
                    if (error != null) EditorUtility.DisplayDialog("巣を lilToon に焼き込む", error, "OK");
                    GUIUtility.ExitGUI();
                }
            }
        }
        if (!string.IsNullOrEmpty(lastResult)) EditorGUILayout.HelpBox(lastResult, MessageType.Info);
        EditorGUILayout.EndScrollView();
    }

    private static void DrawItems(string title, List<SpiderWebBakeItem> items)
    {
        if (items.Count == 0) return;
        EditorGUILayout.Space(4);
        EditorGUILayout.LabelField(title + "（" + items.Count + "）", EditorStyles.boldLabel);
        foreach (SpiderWebBakeItem i in items.OrderBy(x => (int)x.Severity))
        {
            MessageType type = i.Severity == SpiderWebBakeSeverity.Critical ? MessageType.Error
                             : i.Severity == SpiderWebBakeSeverity.Caution ? MessageType.Warning : MessageType.Info;
            EditorGUILayout.HelpBox(i.Label + i.Title + "\n" + i.Detail, type);
        }
    }

    // 同意したときだけ焼く（ボタンは同意のチェックと確認内容の一致が条件。ここでも確かめる）。
    // 戻り値: 失敗の理由（成功なら null）
    internal string DoBake()
    {
        if (analysis == null || !agreed || agreedHash != analysis.Hash)
            return "同意のチェックが入っていないか、確認したあとで内容が変わりました。";
        try
        {
            SpiderWebBakeConsent consent = SpiderWebLilToonBaker.CreateConsent(analysis);
            SpiderWebBakeBackup backup = SpiderWebLilToonBaker.Bake(target, settings, consent);
            lastResult = "焼き込みました。元に戻すときは、" + backup.gameObject.name + " の SpiderWebBakeBackup の「元に戻す」を押してください。\n作ったアセット: " +
                         string.Join(", ", backup.createdAssets);
            Selection.activeObject = backup.gameObject;
            EditorGUIUtility.PingObject(backup);
            return null;
        }
        catch (Exception e)
        {
            lastResult = "";
            Debug.LogException(e);
            return e.Message;
        }
        finally
        {
            agreed = false;
            agreedHash = "";
            Reanalyze();
        }
    }
}
