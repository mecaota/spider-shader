using UdonSharp;
using UnityEngine;

/// <summary>
/// くっついた巻き付き繭（mecaota/SpiderCocoonDepthDecal）を「同じ糸でまとめて巻かれた」
/// 見え方で描かせる（見た目のみ）。
///
/// ・decals の各繭を箱の内接円筒とみなす。円筒は体より大きめに作ってあるので、
///   半径に linkRadiusScale を掛けたものを「巻かれた手足の太さ」とみなし、その表面どうしが
///   linkDistance 以内（＝くっついた）の繭を同じグループにまとめる
///   （両手首を合わせる・手を胸に当てる・両足をそろえる等）
/// ・初回は最大の繭を代表にし、結合中は代表を保持する。
///   各部位の円筒と共有原点を渡し、代表だけが外殻と連続した巻き模様を描く。
///   外殻はワールド座標の円筒と橋から生成し、巻き方向は各部位の軸に滑らかに追従する。
///   分離には距離の余裕を設け、境界で結合・分離が往復するのを抑える。
/// ・followers（PlayerBoneConstraint など targetPlayerId を持つ追従器）を decals と同じ並びで
///   設定すると、装着中の繭だけを、同じプレイヤーの繭どうしでまとめる
///
/// 負荷対策（数百個の繭を登録しても重くならないように）:
/// ・全部の繭を調べ直す（新しく表示された繭を拾う）のは scanInterval 秒おきだけ
///   （新しく表示された繭は、最大 scanInterval 秒だけ単独で描かれてからまとまる）
/// ・それ以外のフレームは、表示中だった繭だけを測り直す（表示中が 2 つ未満なら何もしない）
/// ・距離の総当たりは表示中の繭どうしだけ
///
/// 注意:
/// ・円筒の式はシェーダーの SpiderCocoonDepthDecal（_RadiusFit / _HeightFit の内接円筒）と一致させる
/// ・追従器がボーン位置へ動かした後に読むため PostLateUpdate で動く
/// </summary>
[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class CocoonGroupLinker : UdonSharpBehaviour
{
    [Tooltip("まとめる候補の巻き付き繭（SpiderCocoonDepthDecal を使うレンダラー）")]
    public Renderer[] decals;

    [Tooltip("decals と同じ並びの追従器（targetPlayerId を持つ PlayerBoneConstraint 等）。設定すると装着中の繭だけを、同じプレイヤーどうしでまとめる。空なら表示中の繭すべてが対象")]
    public UdonSharpBehaviour[] followers;

    [Tooltip("巻かれた手足の表面どうしがこの距離(m)以内なら、くっついたとみなして 1 つの繭にまとめる")]
    public float linkDistance = 0.02f;

    [Tooltip("結合後はこの余裕(m)だけ離れてから分離する。境界でのちらつきを抑える")]
    public float unlinkHysteresis = 0.015f;

    [Tooltip("繭の円柱の半径のうち、巻かれた手足の太さとみなす割合（円柱は体より大きめのため）。1 で円柱そのものが触れたらまとめる")]
    public float linkRadiusScale = 0.5f;

    [Tooltip("代表の描画範囲（箱）を仲間の円筒より少し大きめに取る余白(m)")]
    public float wrapMargin = 0.02f;

    [Tooltip("全部の繭を調べ直して、新しく表示された繭を拾う間隔（秒）")]
    public float scanInterval = 1f;

    private MaterialPropertyBlock _mpb;
    private Vector3[] _center;
    private Vector3[] _axis;
    private float[] _hh;
    private float[] _radius;
    private float[] _volume;
    private int[] _player;
    private int[] _root;
    private int[] _groupSize;
    private int[] _previousGroup;
    private int[] _nextGroup;
    private Bounds[] _originalBounds;
    private int[] _role;
    private int[] _list;     // 表示中の繭の番号
    private Vector4[] _memA; // 代表へ渡す仲間の円筒（中心, 半径）
    private Vector4[] _memB; // 代表へ渡す仲間の円筒（軸 × 半分の高さ）
    private const int MaxMembers = 16;  // シェーダーの SCG_MAX_MEMBERS と一致させる
    private int _count;      // _list の有効な数
    private bool _inited;
    private float _nextScan;

    private void EnsureInit()
    {
        if (_inited) { return; }
        _inited = true;
        if (decals == null) { decals = new Renderer[0]; }
        int n = decals.Length;
        _mpb = new MaterialPropertyBlock();
        _center = new Vector3[n];
        _axis = new Vector3[n];
        _hh = new float[n];
        _radius = new float[n];
        _volume = new float[n];
        _player = new int[n];
        _root = new int[n];
        _groupSize = new int[n];
        _previousGroup = new int[n];
        _nextGroup = new int[n];
        for (int i = 0; i < n; i++) { _previousGroup[i] = -1; _nextGroup[i] = -1; }
        _originalBounds = new Bounds[n];
        for (int i = 0; i < n; i++)
            if (decals[i] != null) _originalBounds[i] = decals[i].localBounds;
        _role = new int[n];
        _list = new int[n];
        _memA = new Vector4[MaxMembers];
        _memB = new Vector4[MaxMembers];
    }

    public override void PostLateUpdate()
    {
        EnsureInit();
        int n = decals.Length;
        float now = Time.time;
        if (now >= _nextScan)
        {
            // 全部の繭を調べ直す（新しく表示された繭を拾う）
            _nextScan = now + Mathf.Max(0f, scanInterval);
            _count = 0;
            for (int i = 0; i < n; i++)
            {
                if (Measure(i)) { _list[_count] = i; _count++; }
                else if (_role[i] != 0) { ClearRole(i); }
            }
        }
        else
        {
            // それ以外のフレームは、表示中だった繭だけを測り直す
            if (_count < 2) { return; }
            int kept = 0;
            for (int k = 0; k < _count; k++)
            {
                int i = _list[k];
                if (Measure(i)) { _list[kept] = i; kept++; }
                else if (_role[i] != 0) { ClearRole(i); }
            }
            _count = kept;
        }

        // つなぐ相手を探す（表示中の繭どうしだけ）
        for (int a = 0; a < _count; a++) { _root[_list[a]] = _list[a]; _groupSize[_list[a]] = 1; }
        for (int a = 0; a < _count; a++)
        {
            int i = _list[a];
            for (int b = a + 1; b < _count; b++)
            {
                int j = _list[b];
                if (_player[i] != _player[j]) { continue; }
                bool wasLinked = _previousGroup[i] >= 0 && _previousGroup[i] == _previousGroup[j];
                float threshold = linkDistance + (wasLinked ? Mathf.Max(unlinkHysteresis, 0f) : 0f);
                if (Gap(i, j) < threshold) { Union(i, j); }
            }
        }

        for (int a = 0; a < _count; a++)
        {
            int i = _list[a];
            int ri = Find(i);
            int anchor = i;
            int members = 0;
            int previousLead = -1;
            for (int b = 0; b < _count; b++)
            {
                int j = _list[b];
                if (Find(j) != ri) { continue; }
                members++;
                if (_role[j] > 0 && (previousLead < 0 || j < previousLead)) previousLead = j;
                // 代表はグループで一番大きい繭。同点は番号の小さい方
                if (_volume[j] > _volume[anchor] || (_volume[j] == _volume[anchor] && j < anchor)) { anchor = j; }
            }
            // Keep the existing representative while it remains in this group.
            // Tiny scale/volume changes must not replace the winding coordinate frame.
            if (previousLead >= 0) anchor = previousLead;
            _nextGroup[i] = members >= 2 ? anchor : -1;
            int role = (members >= 2) ? ((anchor == i) ? 1 : -1) : 0;

            if (role == 0)
            {
                // 単独に戻った繭は一度だけ解除（毎フレーム書かない）
                if (_role[i] != 0) { ClearRole(i); }
                continue;
            }

            // 仲間のままなら書き直さない（仲間は _GroupRole だけで、毎フレーム書く値が無い）
            if (role < 0 && _role[i] < 0) { continue; }
            Renderer r = decals[i];
            // 代表から仲間に変わったら、代表のときに広げた描画範囲（箱）を戻す
            if (role < 0 && _role[i] > 0) { r.localBounds = _originalBounds[i]; }
            r.GetPropertyBlock(_mpb);
            _mpb.SetFloat("_GroupRole", role);
            if (role > 0) { WriteBundle(i); }
            r.SetPropertyBlock(_mpb);
            _role[i] = role;
        }
        for (int a = 0; a < _count; a++)
        {
            int i = _list[a];
            _previousGroup[i] = _nextGroup[i];
        }
    }

    private void OnDisable()
    {
        if (!_inited) return;
        for (int i = 0; i < decals.Length; i++)
            if (_role[i] != 0) ClearRole(i);
        _count = 0;
        _nextScan = 0f;
    }

    // まとめ描きを解除して、自分の円筒だけを巻く状態に戻す
    private void ClearRole(int i)
    {
        Renderer r = decals[i];
        if (r != null)
        {
            r.GetPropertyBlock(_mpb);
            r.localBounds = _originalBounds[i];
            _mpb.SetFloat("_GroupRole", 0f);
            r.SetPropertyBlock(_mpb);
        }
        _role[i] = 0;
        _previousGroup[i] = -1;
    }

    // 代表 lead に、仲間それぞれの円筒（描く範囲）と、グループ共通の巻き座標
    // （軸は代表の軸）と、全員を包む箱の大きさを _mpb で渡す
    private void WriteBundle(int lead)
    {
        int ri = Find(lead);
        Vector3 a = _axis[lead];
        // 軸の位置は「大きい繭ほど強く引き寄せる」重み付き平均（重み=体積の 2 乗）。
        // 同じ大きさどうし（両足）なら中間、胴＋両手なら胴の中を通る。
        // 単純平均だと胸の前の腕に引かれて軸が胴の表面近くを通り、軸の真上で
        // 巻きの角度が急変して帯が一点に潰れる（縦筋になる）
        Vector3 c0 = Vector3.zero;
        float wSum = 0f;
        for (int k = 0; k < _count; k++)
        {
            int j = _list[k];
            if (Find(j) != ri) { continue; }
            float w = _volume[j] * _volume[j] + 1e-12f;
            c0 += _center[j] * w;
            wSum += w;
        }
        c0 /= Mathf.Max(wSum, 1e-12f);
        // Unlike the bounding cylinder centre, this origin does not switch when
        // another member becomes the highest/lowest end of the bounding box.
        _mpb.SetVector("_GroupWrapOrigin", new Vector4(c0.x, c0.y, c0.z, 1f));

        float yMin = 1e9f;
        float yMax = -1e9f;
        float rad = 0f;
        for (int k = 0; k < _count; k++)
        {
            int j = _list[k];
            if (Find(j) != ri) { continue; }
            Vector3 d = _center[j] - c0;
            float y = Vector3.Dot(d, a);
            float radial = (d - a * y).magnitude;
            float cosT = Mathf.Abs(Vector3.Dot(_axis[j], a));
            float sinT = Mathf.Sqrt(Mathf.Max(0f, 1f - cosT * cosT));
            // 傾いた円筒が軸方向・径方向に占める範囲
            float axialExt = _hh[j] * cosT + _radius[j] * sinT;
            float radialExt = _hh[j] * sinT + _radius[j];
            yMin = Mathf.Min(yMin, y - axialExt);
            yMax = Mathf.Max(yMax, y + axialExt);
            rad = Mathf.Max(rad, radial + radialExt);
        }
        float half = (yMax - yMin) * 0.5f + wrapMargin;
        rad += wrapMargin;
        Vector3 center = c0 + a * ((yMin + yMax) * 0.5f);
        _mpb.SetVector("_GroupCylA", new Vector4(center.x, center.y, center.z, rad));
        _mpb.SetVector("_GroupCylB", new Vector4(a.x * half, a.y * half, a.z * half, 0f));

        // 描く範囲 = 仲間それぞれの円筒（単独のときと同じ範囲）
        int m = 0;
        for (int k = 0; k < _count && m < MaxMembers; k++)
        {
            int j = _list[k];
            if (Find(j) != ri) { continue; }
            Vector3 cj = _center[j];
            Vector3 hj = _axis[j] * _hh[j];
            if (j == lead) _mpb.SetFloat("_GroupLeadIndex", m);
            _memA[m] = new Vector4(cj.x, cj.y, cj.z, _radius[j]);
            _memB[m] = new Vector4(hj.x, hj.y, hj.z, 0f);
            m++;
        }
        _mpb.SetVectorArray("_GroupMemA", _memA);
        _mpb.SetVectorArray("_GroupMemB", _memB);
        _mpb.SetFloat("_GroupMemCount", m);
        // 橋の組は渡さない（0 = 代表から各部位へ放射状に橋を張る従来の形）
        _mpb.SetFloat("_GroupBridgeCount", 0f);

        // 代表の箱を、まとめた円筒を包む大きさへ（オブジェクト空間の半サイズ）
        Transform t = decals[lead].transform;
        Vector3 s = t.lossyScale;
        Vector3 lc = t.InverseTransformPoint(center);
        float margin = 0.05f;
        float hx = Mathf.Abs(lc.x) + (rad + margin) / Mathf.Max(Mathf.Abs(s.x), 1e-4f);
        float hy = Mathf.Abs(lc.y) + (half + margin) / Mathf.Max(Mathf.Abs(s.y), 1e-4f);
        float hz = Mathf.Abs(lc.z) + (rad + margin) / Mathf.Max(Mathf.Abs(s.z), 1e-4f);
        _mpb.SetVector("_GroupBoxHalf", new Vector4(Mathf.Max(hx, 0.5f), Mathf.Max(hy, 0.5f), Mathf.Max(hz, 0.5f), 0f));
        // Match the vertex-expanded box in CPU culling (otherwise shells pop at screen edges).
        Material material = decals[lead].sharedMaterial;
        float bulge = material.GetFloat("_GroupBulge");
        float padding = bulge > 0.0005f ? (Mathf.Max(material.GetFloat("_GlueThickness"), 0f) + bulge) * 1.3f : 0f;
        Vector3 halfBounds = new Vector3(Mathf.Max(hx, 0.5f) + padding / Mathf.Max(Mathf.Abs(s.x), 1e-4f),
                                        Mathf.Max(hy, 0.5f) + padding / Mathf.Max(Mathf.Abs(s.y), 1e-4f),
                                        Mathf.Max(hz, 0.5f) + padding / Mathf.Max(Mathf.Abs(s.z), 1e-4f));
        decals[lead].localBounds = new Bounds(Vector3.zero, halfBounds * 2f);
    }

    // 繭 i の円筒を測る。表示中（かつ装着中）なら true
    private bool Measure(int i)
    {
        _player[i] = -1;
        if (followers != null && i < followers.Length && followers[i] != null)
        {
            object v = followers[i].GetProgramVariable("targetPlayerId");
            int id = (v != null) ? (int)v : -1;
            if (id < 0) { return false; }
            _player[i] = id;
        }
        Renderer r = decals[i];
        if (r == null || !r.enabled || !r.gameObject.activeInHierarchy) { return false; }
        Material m = r.sharedMaterial;
        if (m == null) { return false; }
        Transform t = r.transform;
        Vector3 s = t.lossyScale;
        float rad = m.GetFloat("_RadiusFit") * Mathf.Max(Mathf.Abs(s.x), Mathf.Abs(s.z));
        float hh = m.GetFloat("_HeightFit") * Mathf.Abs(s.y);
        _center[i] = t.position;
        _axis[i] = t.up;
        _hh[i] = hh;
        _radius[i] = rad;
        _volume[i] = rad * rad * hh;
        return true;
    }

    // 巻かれた手足（円筒の半径 × linkRadiusScale の太さ）の表面どうしの距離（重なっていれば負）。
    // 円筒を包むカプセルで近似するので、端どうしが近いときはやや甘め（早めにつながる）に判定する
    private float Gap(int i, int j)
    {
        Vector3 hi = _axis[i] * _hh[i];
        Vector3 hj = _axis[j] * _hh[j];
        Vector3 p1 = _center[i] - hi;
        Vector3 d1 = hi * 2f;
        Vector3 p2 = _center[j] - hj;
        Vector3 d2 = hj * 2f;
        Vector3 rr = p1 - p2;
        float a = Vector3.Dot(d1, d1);
        float e = Vector3.Dot(d2, d2);
        float f = Vector3.Dot(d2, rr);
        float s = 0f;
        float t = 0f;
        if (a <= 1e-8f && e <= 1e-8f) { s = 0f; t = 0f; }
        else if (a <= 1e-8f) { s = 0f; t = Mathf.Clamp01(f / e); }
        else
        {
            float c = Vector3.Dot(d1, rr);
            if (e <= 1e-8f) { t = 0f; s = Mathf.Clamp01(-c / a); }
            else
            {
                float b = Vector3.Dot(d1, d2);
                float denom = a * e - b * b;
                s = (denom > 1e-8f) ? Mathf.Clamp01((b * f - c * e) / denom) : 0f;
                t = (b * s + f) / e;
                if (t < 0f) { t = 0f; s = Mathf.Clamp01(-c / a); }
                else if (t > 1f) { t = 1f; s = Mathf.Clamp01((b - c) / a); }
            }
        }
        Vector3 q1 = p1 + d1 * s;
        Vector3 q2 = p2 + d2 * t;
        return Vector3.Distance(q1, q2) - (_radius[i] + _radius[j]) * linkRadiusScale;
    }

    private int Find(int i)
    {
        while (_root[i] != i) { _root[i] = _root[_root[i]]; i = _root[i]; }
        return i;
    }

    private void Union(int i, int j)
    {
        int a = Find(i);
        int b = Find(j);
        // The shader has sixteen member slots. Keep additional parts in their own group.
        if (a != b && _groupSize[a] + _groupSize[b] <= MaxMembers)
        {
            _root[b] = a;
            _groupSize[a] += _groupSize[b];
        }
    }
}
