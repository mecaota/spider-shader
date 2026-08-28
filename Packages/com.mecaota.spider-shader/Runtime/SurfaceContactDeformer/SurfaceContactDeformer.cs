using UdonSharp;
using UnityEngine;
using VRC.SDKBase;
using VRC.SDK3.UdonNetworkCalling;
using VRC.Udon.Common.Interfaces;

/// <summary>
/// 面（蜘蛛の巣・繭など。mecaota/SpiderWeb・mecaota/SpiderCocoon シェーダー、_PullEnable ON）に
/// 手足が触れた場所をその手足に追従させて伸ばす／凹ませるギミック（見た目のみ）。
///
/// ・追従ボーンは bones 配列で任意本数。面（Plane/Sphere/Cylinder）から接触距離以内に
///   来たボーンをその場で「捕縛」し、触れた瞬間のローカル位置をスロットに記録する
/// ・複数プレイヤー同時対応。最大 MaxSlots 本のスロットを全員で先着共有する
/// ・全クライアントが毎フレーム Tick()（ボーン位置が確定した後）で各スロットの
///   プレイヤーのボーン位置を読み、MaterialPropertyBlock の配列でシェーダーへ
///   「捕縛点 _PullAnchors」「追従先 _PullTargets」「有効数 _PullCount」を渡す。
///   頂点の変形はシェーダー側で行うため、このスクリプトはメッシュに触らない
/// ・捕縛されたボーンには wrapByBone の GameObject（デカール繭の円柱など）を付け、
///   ボーン位置・向きへ毎フレーム追従させる（見た目の「糸が巻き付く」演出）
///
/// 負荷対策（マネージャ登録制）:
/// ・PostLateUpdate は持たず public Tick() を SurfaceContactDeformerManager が駆動する。
///   「捕縛が有効 or ローカルがトリガー内」のときだけ manager へ Register し、
///   外れたら Unregister する。全ての巣が毎フレーム走るのを避ける
///
/// ネットワーク（オーナー集約方式）:
/// ・同期配列（Manual）はオーナーだけが書く。各クライアントは自分のローカルプレイヤーの
///   ボーンだけ接触・千切れを判定し、[NetworkCallable] の ClaimSlot/ReleaseSlot をオーナーへ送る
///   （自分がオーナーなら直接呼ぶ）。書き手が常に 1 人なので更新の取りこぼしが起きない
/// ・オーナーは退室者のスロットを OnPlayerLeft／OnOwnershipTransferred で掃除する
/// ・移動は拘束しない。手足が捕縛点から autoReleaseDistance 以上離れたら「千切れ」て解放
///
/// 面ごとの座標（boneSurfaces）:
/// ・boneSurfaces[b] を与えると、ボーン b の接触判定・捕縛点ローカル座標・投影を
///   その Transform 基準にする（1つのレンダラーに複数の平面を焼き込んだ結合メッシュ用）。
///   null／要素 null は自身の transform にフォールバック
///
/// 注意:
/// ・VRCShader.PropertyToID は _Udon 接頭辞のプロパティしか扱えないため、文字列版の API を使う
/// ・配列 uniform は最初に渡した長さで固定されるので、常に MaxSlots 要素の配列を渡す
/// ・トリガーコライダー（isTrigger）と同じ GameObject に付ける（requireTrigger 用）
/// </summary>
[UdonBehaviourSyncMode(BehaviourSyncMode.Manual)]
public class SurfaceContactDeformer : UdonSharpBehaviour
{
    public const int MaxSlots = 16; // シェーダーの SC_PULL_MAX と一致させる

    [Header("対象")]
    [Tooltip("SpiderWeb / SpiderCocoon マテリアル（_PullEnable ON）を付けた Renderer")]
    public Renderer targetRenderer;

    [Tooltip("多数の Deformer を1つの PostLateUpdate で駆動する管理役（シーンに1個）")]
    public SurfaceContactDeformerManager manager;

    [Tooltip("追従するボーン（任意本数。面に触れたものから順に捕縛される）")]
    public TrackBone[] bones = new TrackBone[] {
        TrackBone.LeftLowerLeg, TrackBone.RightLowerLeg };

    [Tooltip("ボーンごとの接触面（結合メッシュ用。null／要素 null は自身の transform）")]
    public Transform[] boneSurfaces;

    [Tooltip("捕縛されたボーンに付ける GameObject（デカール繭の円柱など。bones と並行・任意）")]
    public GameObject[] wrapByBone;

    [Tooltip("wrap のスケール（bones と並行。円柱=直径×高さ×直径）")]
    public Vector3[] wrapScaleByBone;

    [Tooltip("捕縛中だけ表示する装飾（任意。誰か 1 人でも捕縛中なら表示）")]
    public GameObject[] decors;

    [Header("面の形")]
    [Tooltip("接触判定に使う面の形（オブジェクトのローカル空間）")]
    public SurfaceShape shape = SurfaceShape.Plane;

    [Tooltip("Plane: 面の中心からこの半径（ローカル単位）内だけ捕縛。SpiderWeb の _WebRadius に合わせる")]
    public float captureRadiusLocal = 0.45f;

    [Tooltip("Sphere / Cylinder: 半径（ローカル単位。標準メッシュは 0.5）")]
    public float surfaceRadiusLocal = 0.5f;

    [Tooltip("Cylinder: 半高（ローカル単位。標準 Cylinder は 1）")]
    public float surfaceHalfHeightLocal = 1f;

    [Header("捕縛")]
    [Tooltip("面からこの距離（m）以内に来たボーンを捕縛する（どちら側でも）。ボーン別指定が無いとき共通値")]
    public float contactDistance = 0.2f;

    [Tooltip("ボーンごとの接触距離（bones と並行。null／長さ不一致なら contactDistance を使う）")]
    public float[] contactDistanceByBone;

    [Tooltip("手足が捕縛点からこの距離（m）以上離れたら千切れて解放。0 で無効")]
    public float autoReleaseDistance = 0.8f;

    [Tooltip("千切れ／解放してからこの秒数は同じボーンを再捕縛しない")]
    public float recaptureCooldown = 1.0f;

    [Tooltip("捕縛要求を送ってから同期が届くまで再送しない秒数")]
    public float pendingTimeout = 1.0f;

    [Tooltip("ON: トリガー内にいる間だけ新しい接触を捕縛する（通りすがりの誤爆防止）")]
    public bool requireTrigger = true;

    // ---- 同期状態（オーナーだけが書く）----
    // playerId（0 = 空き。VRChat の playerId は 1 以上）
    [UdonSynced] private int[] _slotPlayer = new int[MaxSlots];
    // bones 配列の index
    [UdonSynced] private int[] _slotBone = new int[MaxSlots];
    // 触れた瞬間のボーン位置（そのボーンの面のローカル座標）
    [UdonSynced] private Vector3[] _slotAnchor = new Vector3[MaxSlots];

    // ---- ローカル ----
    private bool _inited = false;
    private MaterialPropertyBlock _mpb;
    private Vector4[] _anchorsV4;
    private Vector4[] _targetsV4;
    private float[] _pendingUntil;
    private float[] _cooldownUntil;
    private bool _localInside = false;
    private Vector3 _tmpAnchor;
    private bool _decorsShown = false;
    private bool _registered = false;
    private int _lastActiveCount = -1;
    // wrap の現在の割り当て（ボーン index → playerId。0=非表示）
    private int[] _wrapPlayer;

    private void EnsureInit()
    {
        if (_inited) { return; }
        _inited = true;
        if (_slotPlayer == null || _slotPlayer.Length != MaxSlots) { _slotPlayer = new int[MaxSlots]; }
        if (_slotBone == null || _slotBone.Length != MaxSlots) { _slotBone = new int[MaxSlots]; }
        if (_slotAnchor == null || _slotAnchor.Length != MaxSlots) { _slotAnchor = new Vector3[MaxSlots]; }
        if (bones == null) { bones = new TrackBone[0]; }
        _pendingUntil = new float[bones.Length];
        _cooldownUntil = new float[bones.Length];
        _wrapPlayer = new int[bones.Length];
        for (int i = 0; i < bones.Length; i++) { _pendingUntil[i] = -999f; _cooldownUntil[i] = -999f; _wrapPlayer[i] = 0; }
        _mpb = new MaterialPropertyBlock();
        _anchorsV4 = new Vector4[MaxSlots];
        _targetsV4 = new Vector4[MaxSlots];
    }

    void Start()
    {
        EnsureInit();
        ApplyPull(); // 初期状態（変形なし）を1回押す
        UpdateRegistration();
    }

    // ================= トリガー =================
    public override void OnPlayerTriggerEnter(VRCPlayerApi player)
    {
        if (player != null && player.isLocal) { _localInside = true; UpdateRegistration(); }
    }

    public override void OnPlayerTriggerExit(VRCPlayerApi player)
    {
        if (player != null && player.isLocal) { _localInside = false; UpdateRegistration(); }
    }

    // ================= 登録制 =================
    // 「有効スロット>0 or ローカルがトリガー内」なら manager に登録、そうでなければ解除
    private void UpdateRegistration()
    {
        EnsureInit();
        bool want = _localInside || ActiveSlotCount() > 0;
        if (want == _registered) { return; }
        _registered = want;
        if (manager != null)
        {
            if (want) { manager.Register(this); }
            else { manager.Unregister(this); ApplyPull(); } // 解除時に変形をゼロへ戻す1回
        }
        else if (!want)
        {
            ApplyPull();
        }
    }

    private int ActiveSlotCount()
    {
        int n = 0;
        for (int i = 0; i < MaxSlots; i++) { if (_slotPlayer[i] > 0) { n++; } }
        return n;
    }

    // ================= 毎フレーム（マネージャから駆動）=================
    public void Tick()
    {
        EnsureInit();
        if (targetRenderer == null) { return; }

        VRCPlayerApi local = Networking.LocalPlayer;
        if (local != null && local.IsValid())
        {
            UpdateLocalContacts(local);
        }
        ApplyPull();

        // トリガー外＆全スロット解放になったら登録を外す
        if (!_localInside && ActiveSlotCount() == 0) { UpdateRegistration(); }
    }

    // manager 無しの構成でも動くよう PostLateUpdate も一応持つ（登録済みなら二重駆動を避ける）
    public override void PostLateUpdate()
    {
        if (manager != null) { return; }
        Tick();
    }

    // 自分のボーンだけ接触・千切れを判定し、オーナーへ要求を送る
    private void UpdateLocalContacts(VRCPlayerApi local)
    {
        int localId = local.playerId;
        bool canCapture = !requireTrigger || _localInside;
        float now = Time.time;
        int sends = 0; // 1フレームの送信数上限（レート制限対策）

        for (int b = 0; b < bones.Length; b++)
        {
            if (sends >= 2) { break; }
            int slot = FindSlot(localId, b);
            if (slot >= 0)
            {
                // 捕縛中: 千切れ判定
                if (autoReleaseDistance <= 0f) { continue; }
                Vector3 bp = BonePos(local, b);
                if (bp == Vector3.zero) { continue; }
                Vector3 a = AnchorSurfaceWorld(b, _slotAnchor[slot]);
                Vector3 t = bp - OffsetWorld(b, _slotAnchor[slot]);
                if (Vector3.Distance(a, t) > autoReleaseDistance)
                {
                    SendRelease(localId, b);
                    _cooldownUntil[b] = now + recaptureCooldown;
                    sends++;
                }
            }
            else
            {
                // 未捕縛: 接触したら捕縛要求
                if (!canCapture) { continue; }
                if (now < _cooldownUntil[b] || now < _pendingUntil[b]) { continue; }
                if (!TryContact(local, b)) { continue; }
                SendClaim(localId, b, _tmpAnchor);
                _pendingUntil[b] = now + pendingTimeout;
                sends++;
            }
        }
    }

    // ================= オーナー処理（NetworkCallable）=================
    private void SendClaim(int playerId, int boneIndex, Vector3 anchorLocal)
    {
        if (Networking.IsOwner(gameObject)) { ClaimSlot(playerId, boneIndex, anchorLocal); }
        else { SendCustomNetworkEvent(NetworkEventTarget.Owner, nameof(ClaimSlot), playerId, boneIndex, anchorLocal); }
    }

    private void SendRelease(int playerId, int boneIndex)
    {
        if (Networking.IsOwner(gameObject)) { ReleaseSlot(playerId, boneIndex); }
        else { SendCustomNetworkEvent(NetworkEventTarget.Owner, nameof(ReleaseSlot), playerId, boneIndex); }
    }

    private void SendReleasePlayer(int playerId)
    {
        if (Networking.IsOwner(gameObject)) { ReleasePlayer(playerId); }
        else { SendCustomNetworkEvent(NetworkEventTarget.Owner, nameof(ReleasePlayer), playerId); }
    }

    [NetworkCallable(20)]
    public void ClaimSlot(int playerId, int boneIndex, Vector3 anchorLocal)
    {
        EnsureInit();
        if (!Networking.IsOwner(gameObject)) { return; }
        if (playerId <= 0 || boneIndex < 0 || boneIndex >= bones.Length) { return; }
        VRCPlayerApi p = VRCPlayerApi.GetPlayerById(playerId);
        if (p == null || !p.IsValid()) { return; }

        int slot = FindSlot(playerId, boneIndex);
        if (slot < 0)
        {
            slot = FindFreeSlot();
            if (slot < 0) { return; } // 満員
            _slotPlayer[slot] = playerId;
            _slotBone[slot] = boneIndex;
        }
        _slotAnchor[slot] = anchorLocal; // 既存なら捕縛点だけ更新（冪等）
        RequestSerialization();
        UpdateRegistration(); // オーナーは OnDeserialization を受けないので自分で反映
    }

    [NetworkCallable(20)]
    public void ReleaseSlot(int playerId, int boneIndex)
    {
        EnsureInit();
        if (!Networking.IsOwner(gameObject)) { return; }
        int slot = FindSlot(playerId, boneIndex);
        if (slot < 0) { return; }
        ClearSlot(slot);
        RequestSerialization();
        UpdateRegistration();
    }

    [NetworkCallable]
    public void ReleasePlayer(int playerId)
    {
        EnsureInit();
        if (!Networking.IsOwner(gameObject)) { return; }
        bool changed = false;
        for (int i = 0; i < MaxSlots; i++)
        {
            if (_slotPlayer[i] == playerId) { ClearSlot(i); changed = true; }
        }
        if (changed) { RequestSerialization(); UpdateRegistration(); }
    }

    // 退室済み・無効なプレイヤーのスロットを掃除（オーナーのみ）
    private void PurgeInvalidSlots()
    {
        if (!Networking.IsOwner(gameObject)) { return; }
        bool changed = false;
        for (int i = 0; i < MaxSlots; i++)
        {
            if (_slotPlayer[i] <= 0) { continue; }
            VRCPlayerApi p = VRCPlayerApi.GetPlayerById(_slotPlayer[i]);
            if (p == null || !p.IsValid()) { ClearSlot(i); changed = true; }
        }
        if (changed) { RequestSerialization(); UpdateRegistration(); }
    }

    // ================= 同期・退室・リスポーン =================
    public override void OnDeserialization()
    {
        EnsureInit();
        VRCPlayerApi local = Networking.LocalPlayer;
        if (local != null)
        {
            for (int i = 0; i < MaxSlots; i++)
            {
                if (_slotPlayer[i] == local.playerId && _slotBone[i] >= 0 && _slotBone[i] < _pendingUntil.Length)
                {
                    _pendingUntil[_slotBone[i]] = -999f; // 自分の捕縛要求が反映されたら pending 解除
                }
            }
        }
        UpdateRegistration();
    }

    public override void OnOwnershipTransferred(VRCPlayerApi player)
    {
        EnsureInit();
        PurgeInvalidSlots();
    }

    public override void OnPlayerLeft(VRCPlayerApi player)
    {
        EnsureInit();
        if (player == null) { return; }
        if (Networking.IsOwner(gameObject)) { ReleasePlayer(player.playerId); }
    }

    public override void OnPlayerRespawn(VRCPlayerApi player)
    {
        if (player == null || !player.isLocal) { return; }
        EnsureInit();
        SendReleasePlayer(player.playerId);
        float now = Time.time;
        for (int b = 0; b < bones.Length; b++) { _cooldownUntil[b] = now + recaptureCooldown; _pendingUntil[b] = -999f; }
    }

    // ================= シェーダーへ渡す＋wrap更新 =================
    private void ApplyPull()
    {
        int n = 0;
        // wrap を今フレームの割り当てで塗り替えるため、まず前回分をクリア候補にする
        for (int i = 0; i < MaxSlots; i++)
        {
            int pid = _slotPlayer[i];
            if (pid <= 0) { continue; }
            VRCPlayerApi p = VRCPlayerApi.GetPlayerById(pid);
            if (p == null || !p.IsValid()) { continue; }
            int b = _slotBone[i];
            if (b < 0 || b >= bones.Length) { continue; }
            Vector3 bp = BonePos(p, b);
            if (bp == Vector3.zero) { continue; }

            Vector3 a = AnchorSurfaceWorld(b, _slotAnchor[i]);
            Vector3 t = bp - OffsetWorld(b, _slotAnchor[i]);
            // 各巣は単一面レンダラーなので .w=1（有効フラグ）で足りる
            _anchorsV4[n] = new Vector4(a.x, a.y, a.z, 1f);
            _targetsV4[n] = new Vector4(t.x, t.y, t.z, 0f);
            n++;
        }
        for (int i = n; i < MaxSlots; i++) { _anchorsV4[i] = Vector4.zero; _targetsV4[i] = Vector4.zero; }

        // 配列 uniform は最初の長さで固定されるため、常に MaxSlots 要素を渡す
        _mpb.SetVectorArray("_PullAnchors", _anchorsV4);
        _mpb.SetVectorArray("_PullTargets", _targetsV4);
        _mpb.SetFloat("_PullCount", n);
        targetRenderer.SetPropertyBlock(_mpb);

        UpdateWraps();

        bool show = n > 0;
        if (show != _decorsShown)
        {
            _decorsShown = show;
            if (decors != null)
            {
                for (int i = 0; i < decors.Length; i++)
                {
                    if (decors[i] != null) { decors[i].SetActive(show); }
                }
            }
        }
    }

    // 捕縛されたボーンに wrap（デカール繭の円柱）を追従させる。
    // ボーン index 単位で「最小スロットの人」を表示（決定的）
    private void UpdateWraps()
    {
        if (wrapByBone == null) { return; }
        for (int b = 0; b < bones.Length; b++)
        {
            if (b >= wrapByBone.Length || wrapByBone[b] == null) { continue; }

            // このボーンを持つ最小スロットの playerId を探す
            int pid = 0;
            for (int i = 0; i < MaxSlots; i++)
            {
                if (_slotPlayer[i] > 0 && _slotBone[i] == b) { pid = _slotPlayer[i]; break; }
            }

            var wrap = wrapByBone[b];
            if (pid <= 0)
            {
                if (_wrapPlayer[b] != 0) { _wrapPlayer[b] = 0; wrap.SetActive(false); }
                continue;
            }
            VRCPlayerApi p = VRCPlayerApi.GetPlayerById(pid);
            if (p == null || !p.IsValid())
            {
                if (_wrapPlayer[b] != 0) { _wrapPlayer[b] = 0; wrap.SetActive(false); }
                continue;
            }
            Vector3 bp = BonePos(p, b);
            if (bp == Vector3.zero) { continue; }

            if (_wrapPlayer[b] != pid)
            {
                _wrapPlayer[b] = pid;
                wrap.SetActive(true);
                if (wrapScaleByBone != null && b < wrapScaleByBone.Length && wrapScaleByBone[b] != Vector3.zero)
                {
                    wrap.transform.localScale = wrapScaleByBone[b];
                }
            }
            // 位置＝ボーン、向き＝ボーンの節方向（親→子）に円柱軸(+Y)を合わせる
            Vector3 dir = BoneDir(p, b);
            Quaternion rot = (dir.sqrMagnitude > 1e-6f)
                ? Quaternion.FromToRotation(Vector3.up, dir.normalized) : wrap.transform.rotation;
            wrap.transform.SetPositionAndRotation(bp, rot);
        }
    }

    // ================= 面の幾何 =================
    private Transform Face(int b)
    {
        if (boneSurfaces != null && b >= 0 && b < boneSurfaces.Length && boneSurfaces[b] != null)
        {
            return boneSurfaces[b];
        }
        return transform;
    }

    private Vector3 ProjectLocal(Vector3 l)
    {
        if (shape == SurfaceShape.Sphere)
        {
            float m = l.magnitude;
            return (m < 1e-6f) ? new Vector3(0f, surfaceRadiusLocal, 0f) : l * (surfaceRadiusLocal / m);
        }
        if (shape == SurfaceShape.Cylinder)
        {
            Vector2 xz = new Vector2(l.x, l.z);
            float m = xz.magnitude;
            if (m < 1e-6f) { xz = new Vector2(surfaceRadiusLocal, 0f); }
            else { xz = xz * (surfaceRadiusLocal / m); }
            return new Vector3(xz.x, Mathf.Clamp(l.y, -surfaceHalfHeightLocal, surfaceHalfHeightLocal), xz.y);
        }
        return new Vector3(l.x, 0f, l.z); // Plane
    }

    private bool InCaptureRange(Vector3 l)
    {
        if (shape == SurfaceShape.Plane) { return new Vector2(l.x, l.z).magnitude <= captureRadiusLocal; }
        if (shape == SurfaceShape.Cylinder) { return Mathf.Abs(l.y) <= surfaceHalfHeightLocal; }
        return true;
    }

    private Vector3 AnchorSurfaceWorld(int b, Vector3 anchorLocal)
    {
        return Face(b).TransformPoint(ProjectLocal(anchorLocal));
    }

    private Vector3 OffsetWorld(int b, Vector3 anchorLocal)
    {
        return Face(b).TransformVector(anchorLocal - ProjectLocal(anchorLocal));
    }

    private float ContactDistanceOf(int b)
    {
        if (contactDistanceByBone != null && b < contactDistanceByBone.Length && contactDistanceByBone[b] > 0f)
        {
            return contactDistanceByBone[b];
        }
        return contactDistance;
    }

    // スロット b のボーンが面に触れていれば _tmpAnchor に記録して true
    private bool TryContact(VRCPlayerApi player, int b)
    {
        Vector3 bp = BonePos(player, b);
        if (bp == Vector3.zero) { return false; } // そのボーンが無いアバター
        Transform f = Face(b);
        Vector3 l = f.InverseTransformPoint(bp);
        if (!InCaptureRange(l)) { return false; }
        float distM = f.TransformVector(l - ProjectLocal(l)).magnitude;
        if (distM > ContactDistanceOf(b)) { return false; }
        _tmpAnchor = l;
        return true;
    }

    // ================= スロット操作 =================
    private int FindSlot(int playerId, int boneIndex)
    {
        for (int i = 0; i < MaxSlots; i++)
        {
            if (_slotPlayer[i] == playerId && _slotBone[i] == boneIndex) { return i; }
        }
        return -1;
    }

    private int FindFreeSlot()
    {
        for (int i = 0; i < MaxSlots; i++)
        {
            if (_slotPlayer[i] <= 0) { return i; }
        }
        return -1;
    }

    private void ClearSlot(int i)
    {
        _slotPlayer[i] = 0;
        _slotBone[i] = 0;
        _slotAnchor[i] = Vector3.zero;
    }

    // ボーンが無いアバターは Vector3.zero（捕縛の対象外）
    private Vector3 BonePos(VRCPlayerApi player, int b)
    {
        Vector3 v = player.GetBonePosition((HumanBodyBones)(int)bones[b]);
        return (v.sqrMagnitude < 1e-8f) ? Vector3.zero : v;
    }

    // ボーンの節方向（そのボーン→子ボーン）。子が無ければ親→自分
    private Vector3 BoneDir(VRCPlayerApi player, int b)
    {
        HumanBodyBones self = (HumanBodyBones)(int)bones[b];
        HumanBodyBones child = ChildOf(self);
        HumanBodyBones parent = ParentOf(self);
        Vector3 sp = player.GetBonePosition(self);
        Vector3 cp = (child != self) ? player.GetBonePosition(child) : Vector3.zero;
        if (cp != Vector3.zero && sp != Vector3.zero) { return cp - sp; }
        Vector3 pp = (parent != self) ? player.GetBonePosition(parent) : Vector3.zero;
        if (sp != Vector3.zero && pp != Vector3.zero) { return sp - pp; }
        return Vector3.up;
    }

    private HumanBodyBones ChildOf(HumanBodyBones b)
    {
        if (b == HumanBodyBones.LeftUpperLeg) { return HumanBodyBones.LeftLowerLeg; }
        if (b == HumanBodyBones.RightUpperLeg) { return HumanBodyBones.RightLowerLeg; }
        if (b == HumanBodyBones.LeftLowerLeg) { return HumanBodyBones.LeftFoot; }
        if (b == HumanBodyBones.RightLowerLeg) { return HumanBodyBones.RightFoot; }
        if (b == HumanBodyBones.LeftShoulder) { return HumanBodyBones.LeftUpperArm; }
        if (b == HumanBodyBones.RightShoulder) { return HumanBodyBones.RightUpperArm; }
        if (b == HumanBodyBones.LeftUpperArm) { return HumanBodyBones.LeftLowerArm; }
        if (b == HumanBodyBones.RightUpperArm) { return HumanBodyBones.RightLowerArm; }
        if (b == HumanBodyBones.LeftLowerArm) { return HumanBodyBones.LeftHand; }
        if (b == HumanBodyBones.RightLowerArm) { return HumanBodyBones.RightHand; }
        if (b == HumanBodyBones.Hips) { return HumanBodyBones.Spine; }
        if (b == HumanBodyBones.Spine) { return HumanBodyBones.Chest; }
        if (b == HumanBodyBones.Chest) { return HumanBodyBones.Neck; }
        if (b == HumanBodyBones.Neck) { return HumanBodyBones.Head; }
        return b;
    }

    private HumanBodyBones ParentOf(HumanBodyBones b)
    {
        if (b == HumanBodyBones.LeftLowerLeg) { return HumanBodyBones.LeftUpperLeg; }
        if (b == HumanBodyBones.RightLowerLeg) { return HumanBodyBones.RightUpperLeg; }
        if (b == HumanBodyBones.LeftFoot) { return HumanBodyBones.LeftLowerLeg; }
        if (b == HumanBodyBones.RightFoot) { return HumanBodyBones.RightLowerLeg; }
        if (b == HumanBodyBones.LeftUpperArm) { return HumanBodyBones.LeftShoulder; }
        if (b == HumanBodyBones.RightUpperArm) { return HumanBodyBones.RightShoulder; }
        if (b == HumanBodyBones.LeftLowerArm) { return HumanBodyBones.LeftUpperArm; }
        if (b == HumanBodyBones.RightLowerArm) { return HumanBodyBones.RightUpperArm; }
        if (b == HumanBodyBones.LeftHand) { return HumanBodyBones.LeftLowerArm; }
        if (b == HumanBodyBones.RightHand) { return HumanBodyBones.RightLowerArm; }
        if (b == HumanBodyBones.Head) { return HumanBodyBones.Neck; }
        if (b == HumanBodyBones.Neck) { return HumanBodyBones.Chest; }
        return b;
    }
}
