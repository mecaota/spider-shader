using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using UnityEditor;
using UnityEngine;

// =============================================================================
// SpiderSilkLookAutoSync — 質感の継承を「いつ」同期するかを決める係。
//
//  きっかけ（どれも「同期して」と依頼を積むだけ。実際の処理は 1 フレームに 1 回まとめて行う）:
//   ・インスペクタで値を変えた（ShaderGUI.ValidateMaterial）
//   ・Undo に記録される変更（ObjectChangeEvents。プリセット適用やスクリプトも含む）
//   ・Undo / Redo
//   ・.mat / シェーダーの取り込み（VCS 更新・外部編集・作成・削除）
//   ・エディタ起動直後・Play 終了後
//   ・見回り（2 秒ごと。Undo を通らないスクリプトの書き込み、蜘蛛糸の Variant の親の変更など）
//
//  同期しないとき: Play 中（CocoonMaterialTuner が実行時に .mat を書くため）・コンパイル中・
//  インポート中・質感プロパティの一致チェックに失敗している間。
//  自動の同期は SetDirty だけで、保存は Ctrl+S / Save Project のとき（明示操作とビルド前は保存する）。
//
//  安全装置: リンク（継承元）が、そのマテリアル自身で SetSource 以外の方法で外れたり変わったりした
//  （Revert all overrides・Reset・スクリプトの丸ごと上書きなど）ときは、値を書き換えずに止めて警告する。
//  止めたマテリアルは、継承元欄で選び直す（SetSource）か、リンクが元に戻る（その操作の Undo）まで止めたまま。
//  親から継承元を受け継いでいる子は、親（リンクの持ち主）の判定に従う。
// =============================================================================
[InitializeOnLoad]
internal static class SpiderSilkLookAutoSync
{
    const double PatrolInterval = 2.0;
    const string LinksKey = "SpiderSilkLook_LastLinks2";

    struct LinkRecord { public Vector4 Link; public bool Owned; }

    static bool   s_Pending = true;
    static bool   s_Running;
    static bool   s_TrustAll;     // Undo/Redo の直後は（止めていないマテリアルの）リンクの変化を正常とみなす
    static double s_NextPatrol;
    static readonly HashSet<string> s_ApiTrusted    = new HashSet<string>();   // SetSource 系で変えた GUID
    static readonly HashSet<string> s_ImportTrusted = new HashSet<string>();   // VCS 更新・外部編集で取り込まれた GUID
    static readonly HashSet<string> s_Held          = new HashSet<string>();   // 止めているマテリアルの GUID
    static readonly HashSet<string> s_Reported      = new HashSet<string>();   // 同じ問題を何度も出さない
    static Dictionary<string, LinkRecord> s_Last;

    static SpiderSilkLookAutoSync()
    {
        if (AssetDatabase.IsAssetImportWorkerProcess()) return;
        SpiderSilkLook.s_Notify = _ => Request();
        SpiderSilkLook.s_LinkSetByApi = ms => { foreach (var m in ms) s_ApiTrusted.Add(Guid(m)); Request(); };
        SpiderSilkLookAssetPostprocessor.s_AssetsChanged = paths =>
        {
            foreach (var p in paths) s_ImportTrusted.Add(AssetDatabase.AssetPathToGUID(p));
            Request();
        };
        Undo.undoRedoPerformed += () => { s_TrustAll = true; Request(); };
        ObjectChangeEvents.changesPublished += OnChanges;
        EditorApplication.playModeStateChanged += s => { if (s == PlayModeStateChange.EnteredEditMode) Request(); };
        EditorApplication.update += Tick;
    }

    public static void Request() { s_Pending = true; }

    /// <summary>安全装置で止めているマテリアルか（インスペクタの表示用）。</summary>
    internal static bool IsHeld(Material m) => m != null && s_Held.Contains(Guid(m));

    /// <summary>明示操作・ビルド前の同期でも、止めているマテリアルは書かない。</summary>
    internal static SpiderSilkLook.SyncOptions ExplicitOptions(bool save) =>
        new SpiderSilkLook.SyncOptions { Save = save, Hold = Hold, ReportHeld = true };

    static void OnChanges(ref ObjectChangeEventStream stream)
    {
        for (int i = 0; i < stream.length; i++)
        {
            switch (stream.GetEventType(i))
            {
                case ObjectChangeKind.ChangeAssetObjectProperties:
                {
                    stream.GetChangeAssetObjectPropertiesEvent(i, out var e);
                    if (!(EditorUtility.InstanceIDToObject(e.instanceId) is Material m)) break;
                    bool spider = SpiderSilkLook.GetRole(m.shader) != SpiderSilkLook.Role.None;
                    // シェーダーを切り替えて役割が変わったら一覧を作り直す
                    if (spider != SpiderSilkLookIndex.Contains(m)) SpiderSilkLookIndex.Invalidate();
                    if (spider || SpiderSilkLookIndex.Contains(m)) Request();
                    break;
                }
                case ObjectChangeKind.CreateAssetObject:
                {
                    stream.GetCreateAssetObjectEvent(i, out var e);
                    if (IsMat(e.guid)) { SpiderSilkLookIndex.Invalidate(); Request(); }
                    break;
                }
                case ObjectChangeKind.DestroyAssetObject:
                {
                    stream.GetDestroyAssetObjectEvent(i, out var e);
                    if (IsMat(e.guid)) { SpiderSilkLookIndex.Invalidate(); Request(); }
                    break;
                }
            }
        }
    }

    static bool IsMat(GUID guid)
    {
        var path = AssetDatabase.GUIDToAssetPath(guid);
        return string.IsNullOrEmpty(path) || path.EndsWith(".mat", StringComparison.OrdinalIgnoreCase);
    }

    static void Tick()
    {
        if (s_Running || EditorApplication.isPlayingOrWillChangePlaymode || EditorApplication.isCompiling || EditorApplication.isUpdating) return;
        double now = EditorApplication.timeSinceStartup;
        if (!s_Pending && now < s_NextPatrol) return;
        s_Pending = false;
        s_NextPatrol = now + PatrolInterval;

        s_Running = true;
        try
        {
            var inheritors = SpiderSilkLookIndex.Inheritors;
            if (inheritors.Count == 0) return;
            var report = SpiderSilkLook.SyncAll(new SpiderSilkLook.SyncOptions { Hold = Hold });
            Remember(inheritors);
            foreach (var p in report.Problems)
                if (s_Reported.Add(p)) Debug.LogWarning("[蜘蛛糸の質感] " + p);
        }
        catch (Exception ex) { Debug.LogException(ex); }
        finally
        {
            s_Running = false;
            s_TrustAll = false;
            s_ApiTrusted.Clear();
            s_ImportTrusted.Clear();
            SpiderSilkLookAssetWatcher.s_SavedByEditor.Clear();
        }
    }

    // リンクが想定外の方法で外れた・変わったマテリアルは書かない（true = 止める）
    static bool Hold(Material m, SpiderSilkLook.LinkInfo link)
    {
        LoadLinks();
        string guid = Guid(m);
        if (string.IsNullOrEmpty(guid)) return false;
        var now  = m.GetVector(SpiderSilkLook.LinkProperty);
        bool owns = m.parent == null || m.IsPropertyOverriden(SpiderSilkLook.LinkProperty);
        bool api  = s_ApiTrusted.Contains(guid);
        s_Last.TryGetValue(guid, out var rec);
        bool known = s_Last.ContainsKey(guid);

        // 止めているもの: 継承元欄で選び直すか、リンクが元に戻ったときだけ再開する
        if (s_Held.Contains(guid))
        {
            if (api || (known && now == rec.Link && owns == rec.Owned)) { Release(m, guid); return false; }
            // 親（リンクの持ち主）に従って止めていた子は、親が再開したら再開する
            if (known && !rec.Owned && !owns)
            {
                var o = Owner(m);
                if (o != null && !s_Held.Contains(Guid(o))) { Release(m, guid); return false; }
            }
            return true;
        }
        if (api || !known) return false;                       // 正常な変更 / 初めて見るマテリアル
        if (now == rec.Link && owns == rec.Owned) return false; // 変化なし

        // 親から受け継いだリンクのまま変わった → 変えたのは親（リンクの持ち主）。親の判定に従う
        if (!owns && !rec.Owned)
        {
            var owner = Owner(m);
            if (owner != null && s_Held.Contains(Guid(owner))) { s_Held.Add(guid); return true; }
            return false;
        }
        // このマテリアル自身で変わった
        if (s_TrustAll || s_ImportTrusted.Contains(guid)) return false;   // Undo/Redo・VCS 更新
        if (rec.Owned && owns && rec.Link.w == 0f) return false;          // 継承元なし → ツールがリンクを書いた

        s_Held.Add(guid);
        string msg = AssetDatabase.GetAssetPath(m) + ": 継承元の記録がインスペクタの継承元欄以外の方法で" +
                     (now.w == 0f ? "外れました" : "変わりました") +
                     "（Revert all overrides・Reset・スクリプトの丸ごと上書きなど）。質感の同期を止め、今の値を保っています。" +
                     "意図した変更なら、インスペクタの「継承元の蜘蛛糸」で選び直してください（なしにするなら ▼ → なし）。元に戻すなら Ctrl+Z。";
        Debug.LogWarning("[蜘蛛糸の質感] " + msg, m);
        return true;
    }

    // リンクの持ち主（自分でリンクを上書きしている一番近い親。どこも上書きしていなければ一番上の親）
    static Material Owner(Material m)
    {
        var o = m.parent;
        while (o != null && o.parent != null && !o.IsPropertyOverriden(SpiderSilkLook.LinkProperty)) o = o.parent;
        return o;
    }

    static void Release(Material m, string guid)
    {
        s_Held.Remove(guid);
        // 同じことがまた起きたら、もう一度警告を出せるようにする
        string path = AssetDatabase.GetAssetPath(m);
        s_Reported.RemoveWhere(s => s.StartsWith(path, StringComparison.Ordinal));
    }

    static void LoadLinks()
    {
        if (s_Last != null) return;
        s_Last = new Dictionary<string, LinkRecord>();
        var c = CultureInfo.InvariantCulture;
        foreach (var entry in SessionState.GetString(LinksKey, "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = entry.Split('=');
            if (kv.Length != 2) continue;
            var f = kv[1].Split(',');
            if (f.Length != 5) continue;
            s_Last[kv[0]] = new LinkRecord
            {
                Link  = new Vector4(float.Parse(f[0], c), float.Parse(f[1], c), float.Parse(f[2], c), float.Parse(f[3], c)),
                Owned = f[4] == "1",
            };
        }
    }

    static void Remember(IReadOnlyList<Material> inheritors)
    {
        LoadLinks();
        var c = CultureInfo.InvariantCulture;
        var sb = new StringBuilder();
        foreach (var m in inheritors)
        {
            string guid = Guid(m);
            if (string.IsNullOrEmpty(guid)) continue;
            // 止めているマテリアルは「最後の正常なリンク」を覚えたままにする
            if (!s_Held.Contains(guid))
                s_Last[guid] = new LinkRecord
                {
                    Link  = m.GetVector(SpiderSilkLook.LinkProperty),
                    Owned = m.parent == null || m.IsPropertyOverriden(SpiderSilkLook.LinkProperty),
                };
            if (!s_Last.TryGetValue(guid, out var r)) continue;
            sb.Append(guid).Append('=').Append(r.Link.x.ToString("R", c)).Append(',').Append(r.Link.y.ToString("R", c)).Append(',')
              .Append(r.Link.z.ToString("R", c)).Append(',').Append(r.Link.w.ToString("R", c)).Append(',').Append(r.Owned ? "1" : "0").Append(';');
        }
        SessionState.SetString(LinksKey, sb.ToString());
    }

    static string Guid(Material m) => m == null ? null : AssetDatabase.AssetPathToGUID(AssetDatabase.GetAssetPath(m));
}
