using UdonSharp;
using UnityEngine;
using VRC.SDKBase;

/// <summary>
/// 網（mecaota/SpiderWeb・mecaota/SpiderWebDrape。マテリアルの「体に覆いかぶさる変形」を ON）を
/// プレイヤーの体にかぶせる駆動役（見た目のみ。プレイヤーの移動は拘束しない）。
///
/// シェーダー（CGINC/SpiderWeb_Drape.cginc）は「体の形」と「網の位置・向き」を受け取って頂点を動かすだけなので、
/// このスクリプトが毎フレーム次の値を MaterialPropertyBlock で渡す:
/// ・体の形: 骨の位置から作ったカプセル（線分＋半径）最大 17 本（_DrapeCapA / _DrapeCapB / _DrapeCount）
/// ・網: 中心と半径（_DrapeCenter）、飛んできた向きとかぶさり具合（_DrapeDir）、上の基準（_DrapeUp）
/// ・床: 腰から真下へ Raycast した面（_DrapeFloor）
/// ・姿勢追従（followPose）: かぶさった瞬間のカプセルを基準に残し、今のカプセル（_DrapeCurA/B）と
///   基準 → 今 の剛体変換（_DrapeSkinX/Y/Z）を渡す。網は体と一緒に動き、滑らない
/// ・上から降る網: _DrapeFall で落下の高さ・垂れ具合を渡す
///
/// 使い方（別の UdonSharp スクリプトから。どれも呼んだクライアントの見た目だけを変える）:
/// ・DrapeThrown(playerId, direction)  横から投げた網。direction は網が進む向き（体へ向かう向き）
/// ・DrapeFromAbove(playerId)          頭の上から降ってくる網
/// ・SetAnchorDistance(m)              壁などに貼り付いた網（体からこの距離より離れた所は動かない）。0 で解除
/// ・Release()                         網を外す
/// 全員に同じ網を見せたいときは、同期しているスクリプト（捕獲の判定など）から全員のクライアントで呼ぶ。
///
/// 注意:
/// ・網の頂点の位置は UV だけから決まる（Transform は描画範囲を決めるだけ）。WebPlane など 1 枚の平面メッシュ専用
/// ・網の Renderer は Batching Static と GPU Instancing を OFF にする
/// ・配列 uniform は最初に渡した長さで固定されるので、常に MaxCapsules 要素の配列を渡す
/// </summary>
[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class SpiderWebDrapeDriver : UdonSharpBehaviour
{
    public const int MaxCapsules = 20; // シェーダーの SW_DRAPE_MAX と一致させる
    private const int CapsuleKinds = 17;

    [Header("対象")]
    [Tooltip("網の Renderer（マテリアルの「体に覆いかぶさる変形」を ON）。WebPlane など 1 枚の平面メッシュ")]
    public Renderer targetRenderer;

    [Tooltip("ON: 網の Transform を毎フレーム腰の位置へ動かす（網は Transform と関係なく体に沿うが、画面に映っているかの判定範囲が付いてくるように）")]
    public bool moveRendererToBody = true;

    [Tooltip("ON: かぶせていない間は Renderer を非表示にする")]
    public bool hideWhenReleased = true;

    [Header("網")]
    [Tooltip("網の半径 m（WebPlane の中心から辺までの長さ。1 m 四方の WebPlane を 2 倍に広げて使うなら 1）")]
    public float netRadius = 1f;

    [Tooltip("網が平らな状態から体に沿うまでの時間（秒）")]
    public float coverTime = 0.35f;

    [Tooltip("たるみの揺れの倍率（_DrapeUp.w）")]
    public float sagWobble = 1f;

    [Tooltip("体のカプセルの太さの倍率。網が体にめり込むときは上げる")]
    public float bodyRadiusScale = 1f;

    [Header("横から投げた網")]
    [Tooltip("ON: かぶさった後に体が動いても、網が体に沿って動く（姿勢追従）。OFF: 毎フレーム今の姿勢へかぶせ直す（体を動かすと網が滑る）")]
    public bool followPose = true;

    [Tooltip("壁などに貼り付いた網: 体からこの距離 m より離れた所は動かない世界に残る。0 で従来どおり全体が体に追従（姿勢追従のときだけ効く）")]
    public float anchorDistance = 0f;

    [Header("上から降る網")]
    [Tooltip("網が落ち始める、体のてっぺんからの高さ m")]
    public float fallHeight = 1.2f;

    [Tooltip("落ちきるまでの時間（秒）")]
    public float fallTime = 0.5f;

    [Tooltip("垂れ下がり 0（体に貼りつく）〜1（一番張り出した所から真下へ）")]
    [Range(0f, 1f)] public float fallHang = 0.6f;

    [Tooltip("落下中にふちが持ち上がる高さ m")]
    public float fallEdgeLift = 0.15f;

    [Header("床")]
    [Tooltip("床として Raycast するレイヤー。Nothing なら Default と Environment")]
    public LayerMask floorLayers;

    [Tooltip("腰から下へ床を探す距離 m。見つからなければ床なし")]
    public float floorProbe = 3f;

    // ---- カプセルの定義（骨の番号は HumanBodyBones の整数値） ----
    // _kindA → _kindB の線分。_kindB が -1 なら _kindA から（_kindA − _kindExtFrom）の向きへ伸ばす（頭・手）。
    // 半径と伸ばす長さは目の高さに対する割合。_kindRot は姿勢追従で回転を取る骨
    private int[] _kindA, _kindB, _kindExtFrom, _kindRot;
    private float[] _kindRadius, _kindExtLen;

    private bool _inited = false;
    private MaterialPropertyBlock _mpb;
    private int _playerId = 0;
    private int _mode = 0;          // 0 = なし、1 = 横から投げた網、2 = 上から降る網
    private float _startTime;
    private bool _follow;

    private int _count = 0;         // 有効なカプセルの数
    private int[] _map;             // カプセル i の種類（かぶせた瞬間に骨があったものだけを詰める）
    private Vector4[] _capA, _capB; // 基準（姿勢追従）または今のカプセル
    private Vector4[] _curA, _curB; // 今のカプセル（姿勢追従）
    private Vector4[] _skinX, _skinY, _skinZ;
    private Vector3[] _baseA;       // 基準の端点 A（剛体変換の支点）
    private Quaternion[] _baseRot;  // 基準の骨の回転

    private Vector3 _center;        // 網の中心（横から投げた網: 基準の姿勢での位置）
    private Vector3 _centerOffset;  // 腰から網の中心まで（姿勢追従しないとき、毎フレーム腰に足す）
    private Vector3 _dir;           // 網が進む向き
    private Vector3 _fallAxis;      // 上から降る網の水平の基準軸

    // BuildCapsule の結果（UdonSharp は out 引数を使えないので、フィールドで受け渡す）
    private Vector3 _tmpA, _tmpB;
    private float _tmpR;
    private Quaternion _tmpRot;

    private void EnsureInit()
    {
        if (_inited) { return; }
        _inited = true;
        if (targetRenderer == null) { targetRenderer = GetComponent<Renderer>(); }
        _mpb = new MaterialPropertyBlock();
        //            頭   首  胸  背骨 骨盤 左上腕 右上腕 左前腕 右前腕 左手 右手 左腿 右腿 左すね 右すね 左足 右足
        _kindA       = new int[]   { 10,  9,  8,  0,  1, 13, 14, 15, 16, 17, 18,  1,  2,  3,  4,  5,  6 };
        _kindB       = new int[]   { -1, 10,  9,  8,  2, 15, 16, 17, 18, -1, -1,  3,  4,  5,  6, 19, 20 };
        _kindExtFrom = new int[]   {  9, -1, -1, -1, -1, -1, -1, -1, -1, 15, 16, -1, -1, -1, -1, -1, -1 };
        _kindRot     = new int[]   { 10,  9,  8,  0,  0, 13, 14, 15, 16, 17, 18,  1,  2,  3,  4,  5,  6 };
        _kindRadius  = new float[] { 0.07f, 0.04f, 0.10f, 0.095f, 0.085f, 0.04f, 0.04f, 0.033f, 0.033f, 0.03f, 0.03f,
                                     0.06f, 0.06f, 0.045f, 0.045f, 0.035f, 0.035f };
        _kindExtLen  = new float[] { 0.10f, 0, 0, 0, 0, 0, 0, 0, 0, 0.06f, 0.06f, 0, 0, 0, 0, 0, 0 };
        _map = new int[MaxCapsules];
        _capA = new Vector4[MaxCapsules];
        _capB = new Vector4[MaxCapsules];
        _curA = new Vector4[MaxCapsules];
        _curB = new Vector4[MaxCapsules];
        _skinX = new Vector4[MaxCapsules];
        _skinY = new Vector4[MaxCapsules];
        _skinZ = new Vector4[MaxCapsules];
        _baseA = new Vector3[MaxCapsules];
        _baseRot = new Quaternion[MaxCapsules];
        for (int i = 0; i < MaxCapsules; i++)
        {
            _skinX[i] = new Vector4(1, 0, 0, 0);
            _skinY[i] = new Vector4(0, 1, 0, 0);
            _skinZ[i] = new Vector4(0, 0, 1, 0);
            _baseRot[i] = Quaternion.identity;
        }
    }

    void Start()
    {
        EnsureInit();
        if (hideWhenReleased && targetRenderer != null && _mode == 0) { targetRenderer.enabled = false; }
    }

    // ================= 外から呼ぶ =================

    // 横から投げた網を playerId の人にかぶせる。direction は網が進む向き（投げた人 → 当たった人）
    public void DrapeThrown(int playerId, Vector3 direction)
    {
        EnsureInit();
        VRCPlayerApi p = VRCPlayerApi.GetPlayerById(playerId);
        if (!Utilities.IsValid(p)) { return; }
        if (!CaptureBody(p)) { return; }
        _playerId = playerId;
        _mode = 1;
        _follow = followPose;
        _startTime = Time.time;
        _dir = (direction.sqrMagnitude > 1e-6f) ? direction.normalized : -(p.GetRotation() * Vector3.forward);
        // 網の中心は胴の中ほど（腰と胸の中点）
        Vector3 hips = BonePos(p, 0);
        Vector3 chest = BonePos(p, 8);
        if (chest == Vector3.zero) { chest = hips + Vector3.up * 0.3f; }
        _center = (hips + chest) * 0.5f;
        _centerOffset = _center - hips;
        Show();
        Apply(p);
    }

    // 頭の上から降ってくる網を playerId の人にかぶせる
    public void DrapeFromAbove(int playerId)
    {
        EnsureInit();
        VRCPlayerApi p = VRCPlayerApi.GetPlayerById(playerId);
        if (!Utilities.IsValid(p)) { return; }
        if (!CaptureBody(p)) { return; }
        _playerId = playerId;
        _mode = 2;
        _follow = false; // 上から降る網は毎フレーム今の姿勢で形を決める（シェーダーが姿勢追従に対応していない）
        _startTime = Time.time;
        Vector3 f = p.GetRotation() * Vector3.forward;
        f.y = 0f;
        _fallAxis = (f.sqrMagnitude > 1e-6f) ? f.normalized : Vector3.forward;
        Show();
        Apply(p);
    }

    // 自分（ローカルプレイヤー）に、前から投げた網をかぶせる（UI のボタンや動作確認用。SendCustomEvent で呼べる）
    public void DrapeLocalPlayerFromFront()
    {
        VRCPlayerApi local = Networking.LocalPlayer;
        if (!Utilities.IsValid(local)) { return; }
        DrapeThrown(local.playerId, -(local.GetRotation() * Vector3.forward));
    }

    // 自分（ローカルプレイヤー）に、上から降る網をかぶせる（動作確認用）
    public void DrapeLocalPlayerFromAbove()
    {
        VRCPlayerApi local = Networking.LocalPlayer;
        if (!Utilities.IsValid(local)) { return; }
        DrapeFromAbove(local.playerId);
    }

    // 壁などに貼り付いた網にする。体からこの距離 m より離れた所は動かない（0 で解除）
    public void SetAnchorDistance(float distance)
    {
        anchorDistance = Mathf.Max(distance, 0f);
    }

    // 網を外す
    public void Release()
    {
        EnsureInit();
        _mode = 0;
        _playerId = 0;
        _count = 0;
        if (targetRenderer == null) { return; }
        targetRenderer.GetPropertyBlock(_mpb);
        _mpb.SetVector("_DrapeCenter", Vector4.zero); // 半径 0 でシェーダーの変形が止まる
        _mpb.SetFloat("_DrapeCount", 0f);
        _mpb.SetFloat("_DrapeFollow", 0f);
        _mpb.SetVector("_DrapeFall", Vector4.zero);
        _mpb.SetVector("_DrapeAnchor", Vector4.zero);
        targetRenderer.SetPropertyBlock(_mpb);
        if (hideWhenReleased) { targetRenderer.enabled = false; }
    }

    // 今かぶせている人の playerId（かぶせていなければ 0）
    public int GetDrapedPlayerId()
    {
        return _playerId;
    }

    // ================= 毎フレーム =================
    public override void PostLateUpdate()
    {
        if (_mode == 0) { return; }
        VRCPlayerApi p = VRCPlayerApi.GetPlayerById(_playerId);
        if (!Utilities.IsValid(p)) { Release(); return; }
        Apply(p);
    }

    public override void OnPlayerLeft(VRCPlayerApi player)
    {
        if (_mode != 0 && player != null && player.playerId == _playerId) { Release(); }
    }

    // ================= 内部 =================

    private void Show()
    {
        if (targetRenderer != null) { targetRenderer.enabled = true; }
    }

    // かぶせた瞬間の体を基準として保存する。骨が 1 本も取れなければ false
    private bool CaptureBody(VRCPlayerApi p)
    {
        float h = EyeHeight(p);
        int n = 0;
        for (int k = 0; k < CapsuleKinds && n < MaxCapsules; k++)
        {
            if (!BuildCapsule(p, k, h)) { continue; } // このアバターに無い骨のカプセルは使わない
            _map[n] = k;
            _capA[n] = new Vector4(_tmpA.x, _tmpA.y, _tmpA.z, _tmpR);
            _capB[n] = new Vector4(_tmpB.x, _tmpB.y, _tmpB.z, 0f);
            _curA[n] = _capA[n];
            _curB[n] = _capB[n];
            _baseA[n] = _tmpA;
            _baseRot[n] = _tmpRot;
            _skinX[n] = new Vector4(1, 0, 0, 0);
            _skinY[n] = new Vector4(0, 1, 0, 0);
            _skinZ[n] = new Vector4(0, 0, 1, 0);
            n++;
        }
        _count = n;
        return n > 0;
    }

    // 種類 k のカプセルを今の姿勢から作り、_tmpA / _tmpB / _tmpR / _tmpRot に入れる。骨が無ければ false
    private bool BuildCapsule(VRCPlayerApi p, int k, float h)
    {
        Vector3 a = BonePos(p, _kindA[k]);
        if (a == Vector3.zero) { return false; }
        Vector3 b;
        if (_kindB[k] >= 0)
        {
            b = BonePos(p, _kindB[k]);
            if (b == Vector3.zero) { b = a; } // つま先が無い足などは球にする
        }
        else
        {
            Vector3 from = BonePos(p, _kindExtFrom[k]);
            Vector3 d = (from == Vector3.zero) ? Vector3.up : (a - from);
            d = (d.sqrMagnitude > 1e-8f) ? d.normalized : Vector3.up;
            b = a + d * (_kindExtLen[k] * h);
        }
        _tmpA = a;
        _tmpB = b;
        _tmpR = _kindRadius[k] * h * Mathf.Max(bodyRadiusScale, 0.01f);
        _tmpRot = p.GetBoneRotation((HumanBodyBones)_kindRot[k]);
        return true;
    }

    // 今の姿勢と経過時間から値を作ってシェーダーへ渡す
    private void Apply(VRCPlayerApi p)
    {
        if (targetRenderer == null) { return; }
        float h = EyeHeight(p);
        float t = Time.time - _startTime;
        Vector3 hips = BonePos(p, 0);
        if (hips == Vector3.zero) { hips = p.GetPosition() + Vector3.up * (0.55f * h); }

        // 今のカプセル（骨が一時的に取れないフレームは前の値のまま）
        for (int i = 0; i < _count; i++)
        {
            if (!BuildCapsule(p, _map[i], h)) { continue; }
            _curA[i] = new Vector4(_tmpA.x, _tmpA.y, _tmpA.z, _tmpR);
            _curB[i] = new Vector4(_tmpB.x, _tmpB.y, _tmpB.z, 0f);
            if (_follow)
            {
                // 基準 → 今 の剛体変換: 点 x を  今の A + R (x − 基準の A)  へ。R = 今の回転 × 基準の回転の逆
                Quaternion r = _tmpRot * Quaternion.Inverse(_baseRot[i]);
                Vector3 c0 = r * Vector3.right, c1 = r * Vector3.up, c2 = r * Vector3.forward;
                Vector3 tr = _tmpA - r * _baseA[i];
                _skinX[i] = new Vector4(c0.x, c1.x, c2.x, tr.x);
                _skinY[i] = new Vector4(c0.y, c1.y, c2.y, tr.y);
                _skinZ[i] = new Vector4(c0.z, c1.z, c2.z, tr.z);
            }
            else
            {
                _capA[i] = _curA[i];
                _capB[i] = _curB[i];
            }
        }

        targetRenderer.GetPropertyBlock(_mpb);
        float radius = Mathf.Max(netRadius, 0.01f);
        if (_mode == 1)
        {
            float amount = (coverTime > 0.001f) ? Mathf.Clamp01(t / coverTime) : 1f;
            Vector3 c = _follow ? _center : hips + _centerOffset;
            _mpb.SetVector("_DrapeCenter", new Vector4(c.x, c.y, c.z, radius));
            _mpb.SetVector("_DrapeDir", new Vector4(_dir.x, _dir.y, _dir.z, amount));
            _mpb.SetVector("_DrapeUp", new Vector4(0f, 1f, 0f, sagWobble));
            _mpb.SetVector("_DrapeFall", Vector4.zero);
            _mpb.SetFloat("_DrapeFollow", _follow ? 1f : 0f);
            _mpb.SetVector("_DrapeAnchor", new Vector4(_follow ? Mathf.Max(anchorDistance, 0f) : 0f, 0f, 0f, 0f));
        }
        else
        {
            // 落ちる間は高さを減らし（だんだん速く）、着地してから中心からふちへかぶさる
            float ft = Mathf.Max(fallTime, 0.001f);
            float drop = Mathf.Clamp01(t / ft);
            float height = Mathf.Max(fallHeight, 0f) * (1f - drop * drop);
            float amount = (drop < 1f) ? 0f : ((coverTime > 0.001f) ? Mathf.Clamp01((t - ft) / coverTime) : 1f);
            _mpb.SetVector("_DrapeCenter", new Vector4(hips.x, hips.y, hips.z, radius)); // xz が体の軸
            _mpb.SetVector("_DrapeDir", new Vector4(0f, -1f, 0f, amount));
            _mpb.SetVector("_DrapeUp", new Vector4(_fallAxis.x, 0f, _fallAxis.z, sagWobble));
            _mpb.SetVector("_DrapeFall", new Vector4(1f, Mathf.Clamp01(fallHang), Mathf.Max(fallEdgeLift, 0f), height));
            _mpb.SetFloat("_DrapeFollow", 0f);
            _mpb.SetVector("_DrapeAnchor", Vector4.zero);
        }
        _mpb.SetVector("_DrapeFloor", FindFloor(hips));
        _mpb.SetVectorArray("_DrapeCapA", _capA);
        _mpb.SetVectorArray("_DrapeCapB", _capB);
        _mpb.SetVectorArray("_DrapeCurA", _curA);
        _mpb.SetVectorArray("_DrapeCurB", _curB);
        _mpb.SetVectorArray("_DrapeSkinX", _skinX);
        _mpb.SetVectorArray("_DrapeSkinY", _skinY);
        _mpb.SetVectorArray("_DrapeSkinZ", _skinZ);
        _mpb.SetFloat("_DrapeCount", _count);
        targetRenderer.SetPropertyBlock(_mpb);

        if (moveRendererToBody) { targetRenderer.transform.position = hips; }
    }

    // 腰から真下の床の平面（xyz = 法線、w = 距離。dot(法線, 点) + w = 0 が床）。見つからなければ 0（床なし）
    private Vector4 FindFloor(Vector3 from)
    {
        int mask = floorLayers.value != 0 ? floorLayers.value : ((1 << 0) | (1 << 11));
        RaycastHit hit;
        if (Physics.Raycast(from, Vector3.down, out hit, Mathf.Max(floorProbe, 0.1f), mask, QueryTriggerInteraction.Ignore))
        {
            Vector3 n = hit.normal;
            return new Vector4(n.x, n.y, n.z, -Vector3.Dot(n, hit.point));
        }
        return Vector4.zero;
    }

    // ボーンが無いアバターは Vector3.zero
    private Vector3 BonePos(VRCPlayerApi p, int bone)
    {
        Vector3 v = p.GetBonePosition((HumanBodyBones)bone);
        return (v.sqrMagnitude < 1e-8f) ? Vector3.zero : v;
    }

    private float EyeHeight(VRCPlayerApi p)
    {
        float h = p.GetAvatarEyeHeightAsMeters();
        return (h > 0.1f) ? h : 1.5f;
    }
}
