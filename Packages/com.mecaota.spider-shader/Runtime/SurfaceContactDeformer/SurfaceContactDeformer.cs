using UdonSharp;
using UnityEngine;
using VRC.SDKBase;
using VRC.SDK3.UdonNetworkCalling;
using VRC.Udon;
using VRC.Udon.Common.Interfaces;

/// <summary>
/// 面（蜘蛛の巣・繭など。mecaota/SpiderWeb・mecaota/Cocoon シェーダー、_PullEnable ON）に
/// 手足が触れた場所をその手足に追従させて伸ばす／凹ませるギミック（見た目のみ）。
///
/// ・追従ボーンは bones 配列で任意本数。面（Plane/Sphere/Cylinder/TreeFan）から接触距離以内に
///   来たボーンをその場で「捕縛」し、触れた瞬間のローカル位置をスロットに記録する
/// ・複数プレイヤー同時対応。最大 MaxSlots 本のスロットを全員で先着共有する
/// ・全クライアントが毎フレーム Tick()（ボーン位置が確定した後）で各スロットの
///   プレイヤーのボーン位置を読み、MaterialPropertyBlock の配列でシェーダーへ
///   「捕縛点 _PullAnchors」「追従先 _PullTargets」「有効数 _PullCount」を渡す。
///   頂点の変形はシェーダー側で行うため、このスクリプトはメッシュに触らない
/// ・捕縛されたボーンには wrapByBone の GameObject（デカール繭の円柱など）を付け、
///   ボーン位置・向きへ毎フレーム追従させる（見た目の「糸が巻き付く」演出）
/// ・threadBySlot（任意）を与えると、くっついた場所（面の上）とボーンの間に太い粘液の糸
///   （LineRenderer）を張る。伸びるほど細り、千切れ（autoReleaseDistance）で消える
/// ・別のスクリプトは GetOccupiedSlotMask / GetSlotPlayerId / GetSlotHumanBone などで
///   「どのスロットに、誰の、どの部位が付いているか」を読める（読み取り専用。同期や捕縛は変えない）
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
/// くっつき方（固定設置の巣で使う設定）:
/// ・segmentContact: ボーンの点ではなく「ボーンの区間（そのボーン→子ボーン。すねなら膝→足首）」と
///   面の距離で判定する。手足の表面が触れた瞬間にくっつき、区間のどこが触れたか（割合）も記録して
///   その点に面を追従させる
/// ・pullOnly: くっついた後は「くっついた側へ引っ張る向き」と面に沿った向きにだけ追従し、
///   手足を面に近づけても面の奥へは凹ませない
///
/// くっついたときの通知（localStuckReceivers）:
/// ・ローカルプレイヤーがこの巣のどこか 1 か所でもくっついたら localStuckEvent、全部はがれたら localUnstuckEvent を、
///   localStuckReceivers の各 UdonBehaviour へ SendCustomEvent で送る（ローカルのみ。2 つは必ず交互に送る）
/// ・千切れ・リスポーンで解放を送った時点で「はがれた」とみなす（オーナーとの往復を待たない）。くっついている間に
///   巣やマネージャが無効になったときも「はがれた」を送り、有効に戻ってまだくっついていれば送り直す
/// ・restraint の PlayerMovementLock(窓口)に送れば「くっついている間の減速」になる（既定のイベント名は SubtractSpeed / AddSpeed。
///   対で送るので、何枚の巣から同じ窓口に送っても、全部はがれたら元に戻る）。イベント名で送るだけなので、
///   このパッケージは restraint が無くてもコンパイルできる（以前の slowLocalWhenStuck はこの形で restraint へ移した）
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
    // 外から読む API の占有スロットは int のビットマスク（bit i = スロット i）なので、MaxSlots は 32 以下に限る。
    // 33 以上にすると 0 での割り算になり、コンパイルエラーで止まる（1 << 32 は 1 に戻り、マスクが黙って壊れるため）
    private const int MaxSlotsFitsInMask = 1 / (MaxSlots <= 32 ? 1 : 0);

    [Header("対象")]
    [Tooltip("SpiderWeb / Cocoon マテリアル（_PullEnable ON）を付けた Renderer")]
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

    // TreeFan: 幹（ローカル Y 軸）の正面 +Z の高さ treeHubHeight にハブがあり、そこから
    // 幹を左右 treeWrapAngle 度まで回り込みつつ地面へ扇形に広がる巣。
    // 幹の周りの角度 α・幹表面からの距離 d として、外周（接地線）は
    // (α/A)²+(d/b)²=1 の楕円、高さは 地面 + ハブ高 × (1-s)(1-sag·s)（s = 楕円の正規化半径）。
    // TreeWebFanBuilder が同じ式でメッシュを作る（メッシュは実際の幹・地面に密着させてあるので
    // ここでの判定は数 cm の近似）
    [Header("木の幹に張り付く扇形（shape = TreeFan）")]
    [Tooltip("TreeFan: 幹の半径＋浮き（m）。ローカル Y 軸が幹の中心線、+Z が巣の正面")]
    public float treeTrunkRadius = 0.25f;
    [Tooltip("TreeFan: ハブ（中心結節点）の地面からの高さ（m）")]
    public float treeHubHeight = 1.75f;
    [Tooltip("TreeFan: 巣が幹を回り込む角度（片側・度）")]
    public float treeWrapAngle = 95f;
    [Tooltip("TreeFan: 正面で幹の表面から外周（接地線）までの距離（m）")]
    public float treeReach = 1.25f;
    [Tooltip("TreeFan: 縦糸のたわみ（0 で直線、大きいほど地面へなだらかに降りる）")]
    public float treeSag = 0.35f;
    [Tooltip("TreeFan: 地面の高さの近似平面 y = X*x + Y*z + Z（ローカル）")]
    public Vector3 treeGround = Vector3.zero;

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

    [Tooltip("Plane のみ: ボーンが面を通過して裏側（ローカル -Y 側）に入ってから捕縛する。面に近づいただけでは変形しない（FootTrapWeb 用）")]
    public bool captureOnlyBelowSurface = false;

    [Tooltip("単位サイズの WebPlane: マテリアルの扇形の範囲に捕縛を合わせる")]
    public bool matchFanShape = true;

    [Header("くっつき方")]
    [Tooltip("ON: ボーンの区間（そのボーン→子ボーン。すねなら膝→足首）と面の距離で接触を判定し、触れた位置に面を追従させる。OFF: ボーンの根元の点で判定（従来）")]
    public bool segmentContact = false;

    [Tooltip("ON: くっついた後は引っ張る向き（くっついた側）と面に沿った向きにだけ追従し、手足を面に近づけても面の奥へは凹ませない")]
    public bool pullOnly = false;

    [Header("くっついたときの通知（任意）")]
    [Tooltip("ローカルプレイヤーがこの巣にくっついた／全部はがれたときにイベントを送る UdonBehaviour（restraint の PlayerMovementLock の窓口で減速するなど）。空なら送らない")]
    public UdonBehaviour[] localStuckReceivers;

    [Tooltip("ローカルプレイヤーがどこか 1 か所でもくっついたときに送るイベント名")]
    public string localStuckEvent = "SubtractSpeed";

    [Tooltip("ローカルプレイヤーが全部はがれたときに送るイベント名（くっついている間にリスポーンしたときや、巣が無効になったときも送る）")]
    public string localUnstuckEvent = "AddSpeed";

    [Header("粘液の糸（任意）")]
    [Tooltip("くっついた場所（面）とボーンの間に張る太い粘液の糸（LineRenderer。SpiderSilk の粘液マテリアル）。スロット番号ごとに 1 本、最大 MaxSlots 本。空なら糸は描かない")]
    public LineRenderer[] threadBySlot;
    [Tooltip("糸の太さ（m。アバターの目の高さ 1.6m 基準で拡縮）")]
    public float threadWidth = 0.08f;
    [Tooltip("この長さ（m）までは太さそのまま。これより伸びると √(この長さ/長さ) 倍に細る（引き伸ばされた粘液）")]
    public float threadRestLength = 0.15f;
    [Tooltip("伸びたときの太さの下限（割合）")]
    public float threadMinWidth = 0.3f;
    [Tooltip("糸のたるみ（長さ 1m あたりの m）。シェーダーの重力たわみで曲げる")]
    public float threadSag = 0.06f;
    [Tooltip("ON: 糸の始点を「変形した巣の面」（くっついた点がシェーダーで動いた先）にする。_PullEnable の巣で凹み・伸びと糸を併用するとき用（落とし穴の巣）。OFF: 変形前の面の上の点（従来）")]
    public bool threadFromDeformedWeb = false;

    [Header("効果音（任意）")]
    [Tooltip("手足がくっついた瞬間に鳴らす AudioSource（くっついた場所へ移して clip を PlayOneShot）。同期済みのスロットから鳴らすので周りの人にも聞こえる。空なら鳴らさない")]
    public AudioSource contactAudio;
    [Tooltip("続けてくっついたとき（すね→もも→腰…）に鳴らす最短間隔（秒）")]
    public float contactAudioInterval = 0.4f;

    // ---- 同期状態（オーナーだけが書く）----
    // playerId（0 = 空き。VRChat の playerId は 1 以上）
    [UdonSynced] private int[] _slotPlayer = new int[MaxSlots];
    // bones 配列の index
    [UdonSynced] private int[] _slotBone = new int[MaxSlots];
    // 触れた瞬間のボーン位置（そのボーンの面のローカル座標）
    [UdonSynced] private Vector3[] _slotAnchor = new Vector3[MaxSlots];
    // 触れた位置がボーンの区間のどこか（0=ボーンの根元、1=子ボーン。segmentContact 用）
    [UdonSynced] private float[] _slotParam = new float[MaxSlots];

    // ---- ローカル ----
    private bool _inited = false;
    private MaterialPropertyBlock _mpb;
    private Vector4[] _anchorsV4;
    private Vector4[] _targetsV4;
    private float[] _pendingUntil;
    private float[] _cooldownUntil;
    private float[] _releaseUntil;               // 千切れの解放要求を送ってから同期待ちの間は再送しない
    private float _lastClaimSent = -999f;        // 最後に捕縛要求を送った時刻（応答の遅れたスロットもリスポーンで外すため）
    private bool _localInside = false;
    private Vector3 _tmpAnchor;
    private float _tmpParam;
    private const int SegmentSamples = 9; // 区間を調べる点の数（区間 40cm なら 5cm 刻み）
    private bool _decorsShown = false;
    private bool _registered = false;
    private int _lastActiveCount = -1;
    // wrap の現在の割り当て（ボーン index → playerId。0=非表示）
    private int[] _wrapPlayer;
    private bool _fanCapture;
    private Vector2 _fanHub;
    private float _fanRadius, _fanHalfAngle, _fanRotation;
    // TreeFanEval の副出力（U# は out 引数が使えないのでフィールドで返す）
    private float _tfY, _tfS, _tfGradX, _tfGradZ;
    // 粘液の糸（threadBySlot）
    private const int ThreadPoints = 9;          // 1 本の頂点数（シェーダーのたわみ用に分割）
    private MaterialPropertyBlock _threadMpb;
    private bool[] _threadOn;                    // 表示中か
    private bool[] _threadDrawn;                 // 今フレーム描いたか
    private Vector3[] _threadPts;
    // 効果音: 前回見たスロットの持ち主（新しくくっついたスロットを見つける）
    private int[] _seenPlayer;
    private int[] _seenBone;
    private float _nextContactSound;
    private bool _gotFirstSync;                  // 途中入室: 入室直後の最初の同期で届いた既存の捕縛は鳴らさない
    private float _initTime;
    // threadFromDeformedWeb: シェーダーの SC_PullTerm と同じ重みを出すためのマテリアル値
    private float _webStrength = 1f, _webMaxStretch, _webTearFade = 1e-3f, _webRadius = .45f, _webFalloff = 1.5f;
    private bool _webPullEnabled, _externalCaptureUsed, _externalCaptureActive;
    private float _nextExternalClaim, _nextExternalRelease;
    private const float ExternalCleanupWait = 2f; // 外部捕縛の解除後、遅れて届く claim を待つ秒数（再送待ちの 1 秒の後）
    private Vector3[] _threadEnds;
    private int[] _threadPullIndices;
    private Vector3[] _pullAnchors3, _pullDeltas3;   // threadFromDeformedWeb: 今フレームの接点と変位（WebFollow 用）
    // 外部 claim の再送は初回と同じ捕縛点を使い、遅延で二重到着しても巣を飛ばさない。
    // 木の巣など外部 claim を使わない利用者には確保しない。
    private bool[] _externalAnchorSet;
    private Vector3[] _externalAnchors;
    private float[] _externalParams;
    // 誰かが付いているスロット（bit i = スロット i）と、その数。外から読む API と登録制の判定が使う。
    // スロットを書き換えた所（ClaimSlotCore・ClearSlot）でその 1 bit だけ直し、同期を受け取ったときは
    // RefreshOccupiedSlots() で作り直す。毎フレームは数え直さない
    private int _occupiedMask = 0;
    private int _occupiedCount = 0;
    // 占有スロットが変わるたびに 1 増える番号（外から「前に読んだときから変わったか」を確かめる用）
    private int _slotVersion = 0;
    // GameObject が有効で、この巣が動いている間だけ true。無効の間は同期も退室の掃除も届かず
    // スロットが古いまま残るので、外から読む API は「誰も付いていない」を返す
    private bool _live = false;
    // localStuckReceivers へ最後に知らせた「ローカルプレイヤーがくっついているか」
    private bool _localStuckNotified = false;

    private void EnsureInit()
    {
        if (_inited) { return; }
        _inited = true;
        if (targetRenderer == null) { targetRenderer = GetComponent<Renderer>(); }
        if (_slotPlayer == null || _slotPlayer.Length != MaxSlots) { _slotPlayer = new int[MaxSlots]; }
        if (_slotBone == null || _slotBone.Length != MaxSlots) { _slotBone = new int[MaxSlots]; }
        if (_slotAnchor == null || _slotAnchor.Length != MaxSlots) { _slotAnchor = new Vector3[MaxSlots]; }
        if (_slotParam == null || _slotParam.Length != MaxSlots) { _slotParam = new float[MaxSlots]; }
        if (bones == null) { bones = new TrackBone[0]; }
        _pendingUntil = new float[bones.Length];
        _cooldownUntil = new float[bones.Length];
        _releaseUntil = new float[bones.Length];
        _wrapPlayer = new int[bones.Length];
        for (int i = 0; i < bones.Length; i++) { _pendingUntil[i] = -999f; _cooldownUntil[i] = -999f; _releaseUntil[i] = -999f; _wrapPlayer[i] = 0; }
        _mpb = new MaterialPropertyBlock();
        _anchorsV4 = new Vector4[MaxSlots];
        _targetsV4 = new Vector4[MaxSlots];
        _threadMpb = new MaterialPropertyBlock();
        _threadOn = new bool[MaxSlots];
        // シーンで有効のまま置かれた糸も、使うまで消しておく
        if (threadBySlot != null)
        {
            for (int i = 0; i < threadBySlot.Length; i++) { if (threadBySlot[i] != null) { threadBySlot[i].enabled = false; } }
        }
        _threadDrawn = new bool[MaxSlots];
        _threadPts = new Vector3[ThreadPoints];
        _threadEnds = new Vector3[MaxSlots];
        _threadPullIndices = new int[MaxSlots];
        _pullAnchors3 = new Vector3[MaxSlots];
        _pullDeltas3 = new Vector3[MaxSlots];
        _seenPlayer = new int[MaxSlots];
        _seenBone = new int[MaxSlots];
        _initTime = Time.time;
        RefreshOccupiedSlots();
        RefreshFanShape();
    }

    // threadFromDeformedWeb 用: 巣のマテリアルの引っ張りの強さ・千切れの値を読む
    private void RefreshPullWeights()
    {
        if (!threadFromDeformedWeb || targetRenderer == null) { return; }
        Material mat = targetRenderer.sharedMaterial;
        if (mat == null) { return; }
        _webPullEnabled = mat.HasProperty("_PullEnable") && mat.GetFloat("_PullEnable") > .5f;
        if (mat.HasProperty("_PullRadius")) { _webRadius = Mathf.Max(mat.GetFloat("_PullRadius"), .001f); }
        if (mat.HasProperty("_PullFalloff")) { _webFalloff = mat.GetFloat("_PullFalloff"); }
        if (mat.HasProperty("_PullStrength")) { _webStrength = mat.GetFloat("_PullStrength"); }
        if (mat.HasProperty("_PullMaxStretch")) { _webMaxStretch = mat.GetFloat("_PullMaxStretch"); }
        if (mat.HasProperty("_PullTearFade")) { _webTearFade = Mathf.Max(mat.GetFloat("_PullTearFade"), 1e-3f); }
    }

    // SpiderWeb.shader の SC_PullOffset と同じ全接点の合成。近い手足の影響と正規化も含める。
    // Udon では演算 1 つずつが外部呼び出しで重いので、影響半径の外の接点は距離だけ見て飛ばす
    // （2 人で 16 接点なら 16 本 × 16 接点を毎フレーム回すため）。
    private Vector3 WebFollow(Vector3 point, int count)
    {
        if (!_webPullEnabled) { return point; }
        Vector3 sum = Vector3.zero;
        float weights = 0f;
        for (int i = 0; i < count; i++)
        {
            Vector3 anchor = _pullAnchors3[i];
            float distance = Vector3.Distance(point, anchor);
            if (distance >= _webRadius) { continue; }
            Vector3 delta = _pullDeltas3[i];
            float t = 1f - Mathf.SmoothStep(0f, 1f, distance / _webRadius);
            float w = t > 0f ? _webStrength * Mathf.Pow(t, _webFalloff) : 0f;
            if (_webMaxStretch > 0f) { w *= Mathf.Clamp01(1f - (delta.magnitude - _webMaxStretch) / _webTearFade); }
            sum += delta * w; weights += w;
        }
        return point + sum / Mathf.Max(1f, weights);
    }

    // マテリアルを実行中に切り替える場合は、このイベントで範囲を更新する。
    public void RefreshFanShape()
    {
        RefreshPullWeights();
        _fanCapture = false;
        if (!matchFanShape || targetRenderer == null) { return; }
        Material mat = targetRenderer.sharedMaterial;
        if (mat == null || !mat.HasProperty("_FanEnable") || mat.GetFloat("_FanEnable") < 0.5f) { return; }
        _fanCapture = true;
        _fanHub = new Vector2(Mathf.Clamp(mat.GetFloat("_HubOffsetX"), -0.999f, 0.999f),
                              Mathf.Clamp(mat.GetFloat("_HubOffsetY"), -0.999f, 0.999f)) * 0.5f;
        // シェーダーの扇形は横糸をメッシュ端まで並べ、巣の半径はその上限（縦糸の延長に関係なく
        // 扇の中＝メッシュ端と半径の内側だけが巣）
        _fanRadius = Mathf.Max(mat.GetFloat("_WebRadius"), 0.001f);
        _fanHalfAngle = Mathf.Clamp(mat.GetFloat("_FanAngle"), 15f, 330f) * 0.5f;
        _fanRotation = mat.GetFloat("_FanRotation");
    }

    void Start()
    {
        EnsureInit();
        ApplyPull(); // 初期状態（変形なし）を1回押す
        UpdateRegistration();
    }

    // 無効から戻ったとき: 無効の間に退室した人のスロットをオーナーが掃除し、登録を戻す
    // （初回は Start より先に呼ばれる。そのときは掃除するものが無い）
    private void OnEnable()
    {
        EnsureInit();
        _live = true;
        _slotVersion++;
        if (Utilities.IsValid(Networking.LocalPlayer)) { PurgeInvalidSlots(); } // 入室直後（ネットワークの準備前）は掃除しない
        UpdateRegistration();
    }

    // 無効にされたとき: マネージャから外し（無効の巣を Tick し続けないように）、外から読む API を空にする
    private void OnDisable()
    {
        _live = false;
        _slotVersion++;
        // 無効の間はトリガーの出入りが届かないので、外にいる扱いに戻す（中にいれば、有効に戻ったときに入った通知が来る）
        _localInside = false;
        NotifyLocalStuck(false);
        if (_registered)
        {
            _registered = false;
            if (manager != null) { manager.Unregister(this); }
        }
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
        NotifyLocalStuck(IsLocalHeld()); // スロットが変わると必ずここを通るので、登録を外す前にくっつき状態を見る
        bool want = _live && (_localInside || _occupiedCount > 0);
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
        // 千切れで解放を送った瞬間や、解放の同期待ちが切れたときは、スロットが変わらなくても状態が変わるので毎フレーム見る
        NotifyLocalStuck(IsLocalHeld());

        // トリガー外＆全スロット解放になったら登録を外す
        if (!_localInside && _occupiedCount == 0) { UpdateRegistration(); }
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
        float now = Time.time;
        // 外部捕縛の解除後しばらくは、遅れて届いた claim を取り除くだけにする。通常の木の巣ではこの分岐へ入らない。
        // 最後の解除から約 3 秒、自分のスロットが無ければ自動の接触判定に戻す
        if (_externalCaptureUsed && !_externalCaptureActive)
        {
            if (now < _nextExternalRelease) { return; }
            if (HasSlotOf(localId))
            {
                _nextExternalRelease = now + 1f;
                SendReleasePlayer(localId);
                return;
            }
            if (now < _nextExternalRelease + ExternalCleanupWait) { return; }
            _externalCaptureUsed = false;
        }
        bool canCapture = !requireTrigger || _localInside;
        int sends = 0; // 1フレームの送信数上限（レート制限対策）

        for (int b = 0; b < bones.Length; b++)
        {
            if (sends >= 2) { break; }
            int slot = FindSlot(localId, b);
            if (slot >= 0)
            {
                // 捕縛中: 千切れ判定
                if (autoReleaseDistance <= 0f) { continue; }
                Vector3 bp = BoneSegPoint(local, b, _slotParam[slot]);
                if (bp == Vector3.zero) { continue; }
                Vector3 a = AnchorSurfaceWorld(b, _slotAnchor[slot]);
                Vector3 t = bp - OffsetWorld(b, _slotAnchor[slot]);
                if (Vector3.Distance(a, t) > autoReleaseDistance)
                {
                    if (now < _releaseUntil[b]) { continue; } // 送った解放の同期待ち。再送しない
                    SendRelease(localId, b);
                    _releaseUntil[b] = now + pendingTimeout;
                    if (_externalAnchorSet != null) { _externalAnchorSet[b] = false; }
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
                SendClaim(localId, b, _tmpAnchor, _tmpParam);
                _pendingUntil[b] = now + pendingTimeout;
                _releaseUntil[b] = -999f;
                sends++;
            }
        }
    }

    // 外部スクリプト（落とし穴の罠など）が、ローカルプレイヤーのボーン boneIndex を、自分で決めた
    // 捕縛点 anchorLocal（面のローカル座標。面から離れた分も含む）で捕縛させる。自動の接触判定は通らない。
    // オーナーへの送信は ClaimSlot のレート制限（20/秒）に従うので、何本も送るときは呼び出し側で間隔を空ける
    public void ClaimLocalBone(int boneIndex, Vector3 anchorLocal, float param)
    {
        EnsureInit();
        VRCPlayerApi local = Networking.LocalPlayer;
        if (local == null || !local.IsValid() || boneIndex < 0 || boneIndex >= bones.Length) { return; }
        _externalCaptureUsed = true; _externalCaptureActive = true;
        float now = Time.time;
        if (FindSlot(local.playerId, boneIndex) >= 0 || now < _pendingUntil[boneIndex]
            || now < _cooldownUntil[boneIndex] || now < _nextExternalClaim) { return; }
        if (_externalAnchorSet == null)
        {
            _externalAnchorSet = new bool[bones.Length];
            _externalAnchors = new Vector3[bones.Length];
            _externalParams = new float[bones.Length];
        }
        if (!_externalAnchorSet[boneIndex])
        {
            _externalAnchorSet[boneIndex] = true;
            _externalAnchors[boneIndex] = anchorLocal;
            _externalParams[boneIndex] = param;
        }
        _nextExternalClaim = now + .05f;
        _pendingUntil[boneIndex] = now + Mathf.Max(pendingTimeout, .05f);
        _releaseUntil[boneIndex] = -999f;
        SendClaim(local.playerId, boneIndex, _externalAnchors[boneIndex], _externalParams[boneIndex]);
    }

    // ================= オーナー処理（NetworkCallable）=================
    // スクリプト内からは *Core を直接呼ぶ。入口（ClaimSlot など）を通すと、他のネットワークイベントの
    // 処理中に呼ばれたとき、送信者がその外側のイベントの送り主のままなので弾かれる
    private void SendClaim(int playerId, int boneIndex, Vector3 anchorLocal, float param)
    {
        _lastClaimSent = Time.time;
        if (Networking.IsOwner(gameObject)) { ClaimSlotCore(playerId, boneIndex, anchorLocal, param); }
        else { SendCustomNetworkEvent(NetworkEventTarget.Owner, nameof(ClaimSlot), playerId, boneIndex, anchorLocal, param); }
    }

    private void SendRelease(int playerId, int boneIndex)
    {
        if (Networking.IsOwner(gameObject)) { ReleaseSlotCore(playerId, boneIndex); }
        else { SendCustomNetworkEvent(NetworkEventTarget.Owner, nameof(ReleaseSlot), playerId, boneIndex); }
    }

    private void SendReleasePlayer(int playerId)
    {
        if (Networking.IsOwner(gameObject)) { ReleasePlayerCore(playerId); }
        else { SendCustomNetworkEvent(NetworkEventTarget.Owner, nameof(ReleasePlayer), playerId); }
    }

    // ネットワークの入口。送信者が自分の分を送ったときだけ通す（改造クライアントが他人のボーンを付け外しできないように）。
    // ネットワーク外からの直接呼び出しは送信者が無いのでそのまま通る
    [NetworkCallable(20)]
    public void ClaimSlot(int playerId, int boneIndex, Vector3 anchorLocal, float param)
    {
        VRCPlayerApi caller = NetworkCalling.CallingPlayer;
        if (Utilities.IsValid(caller) && caller.playerId != playerId) { return; }
        ClaimSlotCore(playerId, boneIndex, anchorLocal, param);
    }

    // 解放の要求に当てはまるスロットが無いときは、要求した人の手元に古いスロットが残っている（巣が無効の間に同期を
    // 取りこぼしたなど）ので、今の状態を配り直す。配らないと、その人の手元ではくっついたままに見え続ける
    [NetworkCallable(20)]
    public void ReleaseSlot(int playerId, int boneIndex)
    {
        VRCPlayerApi caller = NetworkCalling.CallingPlayer;
        if (Utilities.IsValid(caller) && caller.playerId != playerId) { return; }
        if (!ReleaseSlotCore(playerId, boneIndex) && Networking.IsOwner(gameObject)) { RequestSerialization(); }
    }

    [NetworkCallable]
    public void ReleasePlayer(int playerId)
    {
        VRCPlayerApi caller = NetworkCalling.CallingPlayer;
        if (Utilities.IsValid(caller) && caller.playerId != playerId) { return; }
        if (!ReleasePlayerCore(playerId) && Networking.IsOwner(gameObject)) { RequestSerialization(); }
    }

    // 以下は実処理（オーナーのみ）。private なのでネットワークからは呼べない
    private void ClaimSlotCore(int playerId, int boneIndex, Vector3 anchorLocal, float param)
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
            _occupiedMask |= 1 << slot; // 新しく埋まったスロットだけ足す（既存スロットの更新では数え直さない）
            _occupiedCount++;
            _slotVersion++;
        }
        _slotAnchor[slot] = anchorLocal; // 既存なら捕縛点だけ更新（冪等）
        _slotParam[slot] = Mathf.Clamp01(param);
        CommitSlots();
    }

    // スロットを外したら true
    private bool ReleaseSlotCore(int playerId, int boneIndex)
    {
        EnsureInit();
        if (!Networking.IsOwner(gameObject)) { return false; }
        int slot = FindSlot(playerId, boneIndex);
        if (slot < 0) { return false; }
        ClearSlot(slot);
        CommitSlots();
        return true;
    }

    // スロットを 1 つでも外したら true
    private bool ReleasePlayerCore(int playerId)
    {
        EnsureInit();
        if (!Networking.IsOwner(gameObject)) { return false; }
        bool changed = false;
        for (int i = 0; i < MaxSlots; i++)
        {
            if (_slotPlayer[i] == playerId) { ClearSlot(i); changed = true; }
        }
        if (changed) { CommitSlots(); }
        return changed;
    }

    // スロットを書き換えた後（オーナーのみ）: 全員へ配り、登録を更新する。
    // オーナーは OnDeserialization を受けないので、自分の分はここで反映する
    private void CommitSlots()
    {
        RequestSerialization();
        UpdateRegistration();
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
        if (changed) { CommitSlots(); }
    }

    // ================= 同期・退室・リスポーン =================
    public override void OnDeserialization()
    {
        EnsureInit();
        RefreshOccupiedSlots(); // 届いた同期配列から占有スロットを作り直す（オーナーは ClaimSlotCore・ClearSlot で直す）
        if (!_gotFirstSync)
        {
            _gotFirstSync = true;
            // 入室直後に届いた同期＝前からいる人の捕縛。その分は鳴らさない（入室後しばらく経ってからの
            // 最初の同期は本当に今くっついたものなので鳴らす）
            if (Time.time < _initTime + 10f)
            {
                for (int i = 0; i < MaxSlots; i++) { _seenPlayer[i] = _slotPlayer[i]; _seenBone[i] = _slotBone[i]; }
            }
        }
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
        if (Networking.IsOwner(gameObject)) { ReleasePlayerCore(player.playerId); }
    }

    public override void OnPlayerRespawn(VRCPlayerApi player)
    {
        if (player == null || !player.isLocal) { return; }
        _ReleaseLocalBones();
        NotifyLocalStuck(IsLocalHeld()); // 解放を送ったので「はがれた」になる（同期が届くのを待たない）
    }

    // 外部捕縛が終了したとき（無効化、席の解除を含む）。リスポーンの通常経路でも共有する。
    // 「_」始まりなのでネットワークからは呼べない（他人が全員の捕縛を外せないように）
    public void _ReleaseLocalBones()
    {
        EnsureInit();
        VRCPlayerApi player = Networking.LocalPlayer;
        if (player == null || !player.IsValid()) { return; }
        float now = Time.time;
        // くっついている・要求の応答待ち・外部捕縛中の巣だけ送る（リスポーンで全部の巣が送らないように）
        // 応答待ちが切れた後に同期が届くこともあるので、最近捕縛要求を送った巣も送る
        bool send = _externalCaptureActive || HasSlotOf(player.playerId) || now < _lastClaimSent + 5f;
        for (int b = 0; b < bones.Length && !send; b++) { if (now < _pendingUntil[b]) { send = true; } }
        _externalCaptureActive = false;
        _nextExternalRelease = now + 1f;
        if (send) { SendReleasePlayer(player.playerId); }
        for (int b = 0; b < bones.Length; b++)
        {
            _cooldownUntil[b] = now + recaptureCooldown; _pendingUntil[b] = -999f;
            _releaseUntil[b] = send ? now + pendingTimeout : -999f; // 送った解放の同期待ちに ReleaseSlot を重ねない
            if (_externalAnchorSet != null) { _externalAnchorSet[b] = false; }
        }
    }

    // ================= シェーダーへ渡す＋wrap更新 =================
    private void ApplyPull()
    {
        if (targetRenderer == null) { return; }
        int n = 0;
        for (int i = 0; i < MaxSlots; i++) { _threadDrawn[i] = false; _threadPullIndices[i] = -1; }
        // wrap を今フレームの割り当てで塗り替えるため、まず前回分をクリア候補にする
        for (int i = 0; i < MaxSlots; i++)
        {
            int pid = _slotPlayer[i];
            if (pid <= 0) { continue; }
            VRCPlayerApi p = VRCPlayerApi.GetPlayerById(pid);
            if (p == null || !p.IsValid()) { continue; }
            int b = _slotBone[i];
            if (b < 0 || b >= bones.Length) { continue; }
            Vector3 bp = BoneSegPoint(p, b, _slotParam[i]);
            if (bp == Vector3.zero) { continue; }

            Vector3 a = AnchorSurfaceWorld(b, _slotAnchor[i]);
            Vector3 t = PullTarget(b, _slotAnchor[i], a, bp - OffsetWorld(b, _slotAnchor[i]));
            // 各巣は単一面レンダラーなので .w=1（有効フラグ）で足りる
            _anchorsV4[n] = new Vector4(a.x, a.y, a.z, 1f);
            _targetsV4[n] = new Vector4(t.x, t.y, t.z, 0f);
            if (threadFromDeformedWeb) { _threadPullIndices[i] = n; _threadEnds[i] = bp; _pullAnchors3[n] = a; _pullDeltas3[n] = t - a; }
            else { DrawThread(i, p, a, bp); }
            n++;
            if (_seenPlayer[i] != pid || _seenBone[i] != b)
            {
                _seenPlayer[i] = pid; _seenBone[i] = b;
                PlayContactSound(a, p);
            }
        }
        for (int i = n; i < MaxSlots; i++) { _anchorsV4[i] = Vector4.zero; _targetsV4[i] = Vector4.zero; }
        for (int i = 0; i < MaxSlots; i++) { if (_slotPlayer[i] <= 0) { _seenPlayer[i] = 0; } }
        // 全接点を詰めてから糸の始点を計算する（未更新の後続接点を混ぜない）。
        if (threadFromDeformedWeb)
        {
            for (int i = 0; i < MaxSlots; i++)
            {
                int index = _threadPullIndices[i];
                if (index < 0) { continue; }
                DrawThread(i, VRCPlayerApi.GetPlayerById(_slotPlayer[i]), WebFollow(_pullAnchors3[index], n), _threadEnds[i]);
            }
        }
        HideUnusedThreads();

        // 配列 uniform は最初の長さで固定されるため、常に MaxSlots 要素を渡す
        targetRenderer.GetPropertyBlock(_mpb);
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

    // 新しくくっついたスロットを見つけたら、くっついた場所で効果音を鳴らす。
    // 全クライアントが同期済みのスロットから同じ判断をするので、周りの人にも同じ場所で聞こえる。
    // すね・もも・腰…と続けてくっつくので contactAudioInterval 秒に 1 回まで
    // くっついたのが自分なら、音と一緒に両手のコントローラーを最大強度(振幅 1、320 Hz)で振動させる(ユーザー指示 2026-10-08)。
    // 振動はローカルなので、全クライアントが同じ判断をしても本人のコントローラーだけが震える。
    private void PlayContactSound(Vector3 worldPos, VRCPlayerApi player)
    {
        if (contactAudio == null || contactAudio.clip == null) { return; }
        float now = Time.time;
        if (now < _nextContactSound) { return; }
        _nextContactSound = now + contactAudioInterval;
        contactAudio.transform.position = worldPos;
        contactAudio.PlayOneShot(contactAudio.clip);
        if (player != null && player.isLocal)
        {
            player.PlayHapticEventInHand(VRC_Pickup.PickupHand.Left, .5f, 1f, 320f);
            player.PlayHapticEventInHand(VRC_Pickup.PickupHand.Right, .5f, 1f, 320f);
        }
    }

    // くっついた場所 a（面の上）とボーン上の点 bp の間に粘液の糸を張る。スロット単位なので
    // 同期済みのスロットから全クライアントで同じ糸になる（追加の通信なし）。長く伸びるほど細り、
    // autoReleaseDistance を超えるとスロットごと千切れて消える
    private void DrawThread(int slot, VRCPlayerApi player, Vector3 a, Vector3 bp)
    {
        if (threadBySlot == null || slot >= threadBySlot.Length) { return; }
        LineRenderer line = threadBySlot[slot];
        if (line == null) { return; }
        _threadDrawn[slot] = true;
        float length = Vector3.Distance(a, bp);
        float scale = Mathf.Clamp(player.GetAvatarEyeHeightAsMeters() / 1.6f, 0.5f, 2f);
        float thin = (length > threadRestLength && length > 1e-4f) ? Mathf.Sqrt(threadRestLength / length) : 1f;
        line.widthMultiplier = threadWidth * scale * Mathf.Max(thin, threadMinWidth);
        for (int k = 0; k < ThreadPoints; k++) { _threadPts[k] = Vector3.Lerp(a, bp, k / (float)(ThreadPoints - 1)); }
        line.positionCount = ThreadPoints;
        line.SetPositions(_threadPts);
        line.GetPropertyBlock(_threadMpb);
        _threadMpb.SetFloat("_GravityUseUV", 1f);
        _threadMpb.SetFloat("_GravityLineLength", length);
        _threadMpb.SetFloat("_GravitySag", threadSag * length);
        line.SetPropertyBlock(_threadMpb);
        if (!_threadOn[slot]) { _threadOn[slot] = true; line.enabled = true; }
    }

    private void HideUnusedThreads()
    {
        if (threadBySlot == null) { return; }
        for (int i = 0; i < MaxSlots && i < threadBySlot.Length; i++)
        {
            if (_threadDrawn[i] || !_threadOn[i]) { continue; }
            _threadOn[i] = false;
            if (threadBySlot[i] != null) { threadBySlot[i].enabled = false; }
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
            float param = 0f;
            for (int i = 0; i < MaxSlots; i++)
            {
                if (_slotPlayer[i] > 0 && _slotBone[i] == b) { pid = _slotPlayer[i]; param = _slotParam[i]; break; }
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
            Vector3 bp = BoneSegPoint(p, b, param); // くっついた位置に巻き付く
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
        if (shape == SurfaceShape.TreeFan)
        {
            // 面の法線方向へ 1 歩戻してから、その位置の面の高さに載せる（ほぼ最近点）
            float y = TreeFanEval(l);
            float nrm = 1f / Mathf.Sqrt(1f + _tfGradX * _tfGradX + _tfGradZ * _tfGradZ);
            float dn = (l.y - y) * nrm;
            Vector3 p = new Vector3(l.x + _tfGradX * nrm * dn, 0f, l.z + _tfGradZ * nrm * dn);
            float pr = Mathf.Sqrt(p.x * p.x + p.z * p.z);
            if (pr < treeTrunkRadius && pr > 1e-5f) { p = p * (treeTrunkRadius / pr); } // 幹の中へは入れない
            p.y = TreeFanEval(p);
            return p;
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
        if (shape == SurfaceShape.Plane)
        {
            if (_fanCapture)
            {
                if (Mathf.Abs(l.x) > 0.5f || Mathf.Abs(l.z) > 0.5f) { return false; }
                Vector2 p = new Vector2(l.x, l.z) - _fanHub;
                if (p.magnitude > _fanRadius) { return false; }
                float angle = Mathf.Atan2(p.y, p.x) * Mathf.Rad2Deg;
                return Mathf.Abs(Mathf.DeltaAngle(_fanRotation, angle)) <= _fanHalfAngle;
            }
            return new Vector2(l.x, l.z).magnitude <= captureRadiusLocal;
        }
        if (shape == SurfaceShape.Cylinder) { return Mathf.Abs(l.y) <= surfaceHalfHeightLocal; }
        if (shape == SurfaceShape.TreeFan)
        {
            // 高さと傾きも求めておく（直後の TryContact が _tfY / _tfGrad* を使う）
            _tfY = TreeFanEval(l);
            return _tfS <= 1.02f;
        }
        return true;
    }

    // TreeFan の面の高さ（ローカル y）。副出力: _tfS（楕円の正規化半径。1 が接地線）、
    // _tfGradX / _tfGradZ（高さの x・z 方向の傾き＝法線を作る材料）
    private float TreeFanEval(Vector3 l)
    {
        float x = l.x, z = l.z;
        float rho = Mathf.Sqrt(x * x + z * z);
        float wrap = Mathf.Max(treeWrapAngle, 1f) * Mathf.Deg2Rad;
        float reach = Mathf.Max(treeReach, 0.01f);
        float alpha = Mathf.Atan2(x, z);                  // 幹の周りの角度（0 = 正面 +Z）
        float d = rho - treeTrunkRadius;                  // 幹の表面からの距離
        bool onTrunk = d < 0f;
        if (onTrunk) { d = 0f; }
        float qa = alpha / wrap, qd = d / reach;
        float s = Mathf.Sqrt(qa * qa + qd * qd);
        _tfS = s;
        float k = treeSag;
        float f = 0f, fp = 0f;                            // 高さの形 (1-s)(1-k·s) とその s 微分
        if (s < 1f) { f = (1f - s) * (1f - k * s); fp = -1f - k + 2f * k * s; }
        float gx = treeGround.x, gz = treeGround.y;
        if (s > 1e-4f && rho > 1e-4f && s < 1f)
        {
            float dsda = qa / (wrap * s);
            float dsdd = onTrunk ? 0f : qd / (reach * s);
            float r2 = rho * rho;
            gx += treeHubHeight * fp * (dsda * (z / r2) + dsdd * (x / rho));
            gz += treeHubHeight * fp * (dsda * (-x / r2) + dsdd * (z / rho));
        }
        _tfGradX = gx; _tfGradZ = gz;
        return treeGround.x * x + treeGround.y * z + treeGround.z + treeHubHeight * f;
    }

    private Vector3 AnchorSurfaceWorld(int b, Vector3 anchorLocal)
    {
        return Face(b).TransformPoint(ProjectLocal(anchorLocal));
    }

    private Vector3 OffsetWorld(int b, Vector3 anchorLocal)
    {
        return Face(b).TransformVector(anchorLocal - ProjectLocal(anchorLocal));
    }

    // 捕縛点での面の法線（ワールド）を、捕縛したときにボーンがあった側へ向けたもの
    private Vector3 CaptureSideNormal(int b, Vector3 anchorLocal)
    {
        Vector3 pr = ProjectLocal(anchorLocal);
        Vector3 nl = Vector3.up;                                            // Plane
        if (shape == SurfaceShape.Sphere) { nl = pr; }
        else if (shape == SurfaceShape.Cylinder) { nl = new Vector3(pr.x, 0f, pr.z); }
        else if (shape == SurfaceShape.TreeFan) { TreeFanEval(pr); nl = new Vector3(-_tfGradX, 1f, -_tfGradZ); }
        Vector3 n = Face(b).TransformDirection(nl);
        if (n.sqrMagnitude < 1e-10f) { n = Face(b).up; }
        n = n.normalized;
        return (Vector3.Dot(OffsetWorld(b, anchorLocal), n) < 0f) ? -n : n;
    }

    // pullOnly: 追従先のうち「面の奥へ押し込む向き」の成分を消す（近づけても凹まない）
    private Vector3 PullTarget(int b, Vector3 anchorLocal, Vector3 a, Vector3 t)
    {
        if (!pullOnly) { return t; }
        Vector3 n = CaptureSideNormal(b, anchorLocal);
        float dn = Vector3.Dot(t - a, n);
        return (dn < 0f) ? t - n * dn : t;
    }

    private float ContactDistanceOf(int b)
    {
        if (contactDistanceByBone != null && b < contactDistanceByBone.Length && contactDistanceByBone[b] > 0f)
        {
            return contactDistanceByBone[b];
        }
        return contactDistance;
    }

    // スロット b のボーンが面に触れていれば _tmpAnchor / _tmpParam に記録して true。
    // segmentContact なら、ボーンの区間（ボーン→子ボーン）を SegmentSamples 点で調べ、
    // 面に一番近い点で判定する（すねなら膝〜足首のどこが触れても捕縛）
    private bool TryContact(VRCPlayerApi player, int b)
    {
        Vector3 bp = BonePos(player, b);
        if (bp == Vector3.zero) { return false; } // そのボーンが無いアバター
        Vector3 cp = segmentContact ? ChildPos(player, b) : Vector3.zero;
        int samples = (cp == Vector3.zero) ? 1 : SegmentSamples;
        Transform f = Face(b);
        // Plane では面からの高さが区間に沿って直線的に変わる。両端が面の同じ側にあり、
        // 近い方の端も接触距離より遠ければ、どの点も届かないので調べない
        if (samples > 1 && shape == SurfaceShape.Plane)
        {
            float yb = f.InverseTransformPoint(bp).y;
            float yc = f.InverseTransformPoint(cp).y;
            float unit = f.TransformVector(Vector3.up).magnitude;
            if (yb * yc > 0f && Mathf.Min(Mathf.Abs(yb), Mathf.Abs(yc)) * unit > ContactDistanceOf(b)) { return false; }
        }
        float best = float.MaxValue;
        for (int k = 0; k < samples; k++)
        {
            float sk = (samples > 1) ? (float)k / (samples - 1) : 0f;
            Vector3 l = f.InverseTransformPoint((samples > 1) ? Vector3.Lerp(bp, cp, sk) : bp);
            if (!InCaptureRange(l)) { continue; }
            if (captureOnlyBelowSurface && shape == SurfaceShape.Plane && l.y > 0f) { continue; } // 面を通過するまで待つ
            float distM;
            if (shape == SurfaceShape.TreeFan)
            {
                // InCaptureRange が求めた面の高さと傾きから、面の法線方向の距離を出す（軽い近似）
                float dn = (l.y - _tfY) / Mathf.Sqrt(1f + _tfGradX * _tfGradX + _tfGradZ * _tfGradZ);
                distM = f.TransformVector(new Vector3(0f, dn, 0f)).magnitude;
            }
            else
            {
                distM = f.TransformVector(l - ProjectLocal(l)).magnitude;
            }
            if (distM < best) { best = distM; _tmpAnchor = l; _tmpParam = sk; }
        }
        return best <= ContactDistanceOf(b);
    }

    // ボーン b の区間上の点（0=ボーンの根元、1=子ボーン）。子ボーンが無ければ根元
    private Vector3 BoneSegPoint(VRCPlayerApi player, int b, float param)
    {
        Vector3 bp = BonePos(player, b);
        if (bp == Vector3.zero || param <= 0f) { return bp; }
        Vector3 cp = ChildPos(player, b);
        return (cp == Vector3.zero) ? bp : Vector3.Lerp(bp, cp, param);
    }

    // 子ボーンの位置（子が無い・取れないなら Vector3.zero）
    private Vector3 ChildPos(VRCPlayerApi player, int b)
    {
        HumanBodyBones self = (HumanBodyBones)(int)bones[b];
        HumanBodyBones child = ChildOf(self);
        if (child == self) { return Vector3.zero; }
        Vector3 v = player.GetBonePosition(child);
        return (v.sqrMagnitude < 1e-8f) ? Vector3.zero : v;
    }

    // ローカルプレイヤーがこの面にくっついているか
    public bool IsLocalStuck()
    {
        VRCPlayerApi local = Networking.LocalPlayer;
        if (local == null) { return false; }
        return HasSlotOf(local.playerId);
    }

    // 「くっついたときの通知」の判定: 自分のスロットがあり、そのボーンの解放を送って同期を待っている最中でない。
    // 千切れ・リスポーンで解放を送った時点で「はがれた」とみなすので、オーナーとの往復を待たずに減速が戻る。
    // 同期待ち（pendingTimeout 秒）が切れてもスロットが残っていれば、くっついている扱いに戻る
    private bool IsLocalHeld()
    {
        if (!_live) { return false; }
        VRCPlayerApi local = Networking.LocalPlayer;
        if (local == null) { return false; }
        int id = local.playerId;
        float now = Time.time;
        for (int i = 0; i < MaxSlots; i++)
        {
            if (_slotPlayer[i] != id) { continue; }
            int b = _slotBone[i];
            if (b >= 0 && b < _releaseUntil.Length && now < _releaseUntil[b]) { continue; }
            return true;
        }
        return false;
    }

    // マネージャが無効になったとき（Tick が止まり、はがれたことに気付けなくなる）: 「はがれた」を送っておく。
    // マネージャが有効に戻れば、次の Tick でまだくっついていれば送り直す
    public void _OnManagerDisabled()
    {
        NotifyLocalStuck(false);
    }

    // くっついているかが変わったときだけ、localStuckReceivers へ知らせる（ローカルのみ）
    private void NotifyLocalStuck(bool stuck)
    {
        if (stuck == _localStuckNotified) { return; }
        _localStuckNotified = stuck;
        string eventName = stuck ? localStuckEvent : localUnstuckEvent;
        if (localStuckReceivers == null || eventName == null || eventName.Length == 0) { return; }
        for (int i = 0; i < localStuckReceivers.Length; i++)
        {
            if (localStuckReceivers[i] != null) { localStuckReceivers[i].SendCustomEvent(eventName); }
        }
    }

    private bool HasSlotOf(int playerId)
    {
        for (int i = 0; i < MaxSlots; i++)
        {
            if (_slotPlayer[i] == playerId) { return true; }
        }
        return false;
    }

    // ================= スロットの状態を外から読む（読み取り専用）=================
    // 別の UdonBehaviour（捕まった部位から全身の繭を組み立てるスクリプトなど）が
    // 「どのスロットに、誰の、どの部位が付いているか」を読むための入口。
    // 値は同期済みのスロット（オーナーが書いて全員に配ったもの）なので、全クライアントで同じになる。
    // どれも読むだけで、同期・捕縛の状態は変えない。多数の巣を調べるときは、全部の巣ではなく
    // SurfaceContactDeformerManager の GetActiveCount / GetActive で「動いている巣」だけを回り、
    // 先に GetOccupiedSlotMask() が 0 かどうかを見て、誰も付いていない巣を 1 回の呼び出しで飛ばす。
    // GameObject が無効の巣は、無効の間スロットが古いまま残るので「誰も付いていない」を返す

    // スロットの総数（= MaxSlots。空きも含む）。UdonSharp からは定数 SurfaceContactDeformer.MaxSlots を
    // 直接使うほうが、別の UdonBehaviour を呼ぶ手間が無い分だけ軽い（このメソッドは互換のため残している）
    public int GetSlotCount()
    {
        return MaxSlots;
    }

    // 誰かが付いているスロットのビットマスク（スロット i に付いていれば bit i が 1。0 なら誰も付いていない）。
    // スロットが変わったときに作っておいた値を返すだけなので、毎フレーム呼んでも軽い。無効の巣は 0
    public int GetOccupiedSlotMask()
    {
        return _live ? _occupiedMask : 0;
    }

    // 誰かが付いているスロットの数（0〜MaxSlots）。無効の巣は 0
    public int GetOccupiedSlotCount()
    {
        return _live ? _occupiedCount : 0;
    }

    // 占有スロットが変わるたびに増える番号。前に読んだ値と同じなら、マスク・playerId・ボーンは前のまま
    // （捕縛点の位置の更新では増えない）。巣の有効・無効が切り替わったときも増える
    public int GetSlotVersion()
    {
        return _slotVersion;
    }

    // スロット slot に付いているプレイヤーの playerId。空きは 0、範囲外の slot は -1。
    // 退室した人のスロットはオーナーが掃除するまで少し残ることがあるので、使う側で GetPlayerById の結果を確かめる
    public int GetSlotPlayerId(int slot)
    {
        if (slot < 0 || slot >= MaxSlots) { return -1; }
        if (!_live) { return 0; }
        int pid = _slotPlayer[slot];
        return (pid > 0) ? pid : 0;
    }

    // スロット slot に付いているボーンの bones 配列での番号（ClaimLocalBone の boneIndex と同じ）。空き・範囲外は -1
    public int GetSlotBoneIndex(int slot)
    {
        if (slot < 0 || slot >= MaxSlots || !_live || _slotPlayer[slot] <= 0) { return -1; }
        int b = _slotBone[slot];
        if (bones == null || b < 0 || b >= bones.Length) { return -1; }
        return b;
    }

    // スロット slot に付いているボーンの種類。TrackBone は HumanBodyBones と同じ整数なので、
    // 受け取った値は (HumanBodyBones)値 でそのまま変換できる。空き・範囲外は -1
    public int GetSlotHumanBone(int slot)
    {
        int b = GetSlotBoneIndex(slot);
        if (b < 0) { return -1; }
        return (int)bones[b];
    }

    // 占有スロットのキャッシュ（_occupiedMask / _occupiedCount）を同期配列から作り直す。
    // 同期配列を受け取った後（OnDeserialization）と初期化で呼ぶ。オーナーの書き換えは ClaimSlotCore・ClearSlot が 1 bit ずつ直す。
    // 同じマスクのまま別の人が入れ替わることもあるので、受け取るたびに番号を進める（変わっていなくても進むことがある）
    private void RefreshOccupiedSlots()
    {
        _slotVersion++;
        int mask = 0, count = 0;
        for (int i = 0; i < MaxSlots; i++)
        {
            if (_slotPlayer[i] > 0) { mask |= 1 << i; count++; }
        }
        _occupiedMask = mask;
        _occupiedCount = count;
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
        if (_slotPlayer[i] > 0)
        {
            _occupiedMask &= ~(1 << i);
            _occupiedCount--;
            _slotVersion++;
        }
        _slotPlayer[i] = 0;
        _slotBone[i] = 0;
        _slotAnchor[i] = Vector3.zero;
        _slotParam[i] = 0f;
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
