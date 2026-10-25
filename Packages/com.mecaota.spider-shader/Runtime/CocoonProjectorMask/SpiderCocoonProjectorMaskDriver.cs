using UdonSharp;
using UnityEngine;
using VRC.SDKBase;

/// <summary>
/// 繭プロジェクター（mecaota/CocoonProjector）を動かす役。繭デカール（CocoonDecal）を、
/// 捕まった人のアバターにだけ描かせる（床・壁・隣に立つ人には繭が出ない）。
///
/// しくみ:
/// ・Projector は「投影範囲に入ったアバターを、マスクのマテリアルでもう一度描く」部品。マスクのシェーダーは
///   描き直す相手が捕まった本人かどうかを、相手のメッシュの原点と本人の骨の位置を比べて決める。
/// ・このスクリプトは毎フレーム、本人の足元・腰・頭・胸・両手・両足の位置をマスクのマテリアルに渡し
///   （_OwnerRoot / _OwnerHips / _OwnerPt0〜5）、Projector を本人の頭の上へ動かして真下へ向ける。
/// ・誰も捕まっていない間は Projector の GameObject を無効にする（描き直しの負荷をなくす）。
/// ・繭はいつも体全体に付ける。部位を選ぶ機能（bones・SetBones など）は 2026-10-25 に外した
///   （手足は大きく動くので、骨から作る部位の範囲から外れて、繭が切れたりはみ出したりするため）。
/// ・繭デカールの「太さをそろえる」（_EvenGirth）と組むとき（2026-10-25）: cocoonRenderer に繭デカールの箱を入れると、
///   骨から「体の一番太い所の太さの筒」（体の軸に沿った下端・上端と、軸から一番遠くまで張り出した所までの半径）を
///   毎フレーム計算し、その Renderer の MaterialPropertyBlock に渡す（_EvenGirthA / _EvenGirthB）。
///   腕を下ろして立っていれば、一番太い所は腕の外側になる。衣装のふくらみは骨からは分からないので、
///   繭デカールの「そろえた繭の太さの足し引き」で調整する。
///
/// 使い方（別の UdonSharp スクリプトから。どれも呼んだクライアントの見た目だけを変える）:
/// ・SetOwner(playerId)  この人のアバターにだけ繭を描かせる
/// ・ClearOwner()        やめる（Projector を無効にする）
/// 全員に同じ見え方をさせたいときは、捕獲を同期しているスクリプトから全員のクライアントで呼ぶ。
///
/// 注意:
/// ・Projector コンポーネントの設定（Orthographic・大きさ・Ignore Layers）は Udon から変えられないので、
///   シーンで設定しておく（docs/CocoonProjector.md の「セットアップ」）
/// ・マスクのマテリアルは Projector 1 つにつき 1 つ（共有すると全員が同じ人として扱われる）
/// </summary>
[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class SpiderCocoonProjectorMaskDriver : UdonSharpBehaviour
{
    [Header("対象")]
    [Tooltip("Projector コンポーネントを付けた GameObject の Transform。頭の上へ動かして真下へ向ける。誰もいない間は GameObject ごと無効にするので、このスクリプトとは別の GameObject にする")]
    public Transform projectorTransform;

    [Tooltip("Projector に入れたマスクのマテリアル（mecaota/CocoonProjector）。Projector ごとに別のマテリアルにする")]
    public Material maskMaterial;

    [Tooltip("ON: SetOwner を呼ばなくても、自分（ローカルプレイヤー）を対象にする（動作確認用）")]
    public bool followLocalPlayer = false;

    [Header("Projector の置き方")]
    [Tooltip("頭からどれだけ上に Projector を置くか m。Projector の Near Clip より大きく、Far Clip は「この値 + 背の高さ + 余裕」にする")]
    public float heightAboveHead = 0.5f;

    [Header("本人かどうかの判定（許容半径 m）")]
    [Tooltip("アバターのメッシュの原点が、足元（GetPosition）からこの距離以内なら本人とみなす")]
    public float rootRadius = 0.35f;

    [Tooltip("原点が腰の骨からこの距離以内なら本人とみなす（SkinnedMeshRenderer の rootBone が腰のアバター向け）")]
    public float hipsRadius = 0.35f;

    [Tooltip("手に持つ物・帽子・靴・衣装の付属品など骨の下に付いた物の原点が、頭・胸・両手・両足からこの距離以内なら本人の物とみなす。0 で使わない。広げすぎると、すぐ隣に立つ人の物まで本人の物とみなす")]
    public float attachmentRadius = 0.5f;

    [Header("太さをそろえる（繭デカールの _EvenGirth と組む）")]
    [Tooltip("繭デカール（mecaota/CocoonDecal）の箱の Renderer（任意）。入れると、骨から「体の一番太い所の太さの筒」を毎フレーム計算して、この Renderer に MaterialPropertyBlock で渡す。繭デカールのマテリアルの「太さをそろえる」を 0 より大きくすると、その太さのそろった繭になる。空なら渡さない（繭プロジェクターと組む繭デカールは、筒を描かない）")]
    public Renderer cocoonRenderer;
    // 最後に渡した筒（ワールド。girthRadius が 0 なら渡していない）。半径は体の一番太い所までで、繭デカールが足す
    // 足し引き・糸の厚みは含まない。繭デカールの箱を筒が入る大きさに広げるスクリプトが読む
    [HideInInspector] public Vector3 girthBottom;
    [HideInInspector] public Vector3 girthTop;
    [HideInInspector] public float girthRadius;

    // マスクのシェーダーの _OwnerPt0〜5 の順（頭・胸・左手・右手・左足・右足）
    private int[] _pointBones;
    private string[] _pointNames;
    private Vector3[] _pointPos;      // そのフレームに読んだ位置（読み直さない）
    private bool _inited = false;
    private int _ownerId = 0;
    private bool _projectorOn = true;
    // 太さをそろえる筒（WriteGirth）。軸の原点（腰）と向き、軸に沿った下端・上端、軸から一番遠い所までの距離
    private MaterialPropertyBlock _girthBlock;
    private Vector3 _gOrigin;
    private Vector3 _gUp;
    private float _gMinAlong;
    private float _gMaxAlong;
    private float _gMaxRadial;
    private bool _gAny;

    private void EnsureInit()
    {
        if (_inited) { return; }
        _inited = true;
        _pointBones = new int[] { (int)HumanBodyBones.Head, (int)HumanBodyBones.Chest,
                                  (int)HumanBodyBones.LeftHand, (int)HumanBodyBones.RightHand,
                                  (int)HumanBodyBones.LeftFoot, (int)HumanBodyBones.RightFoot };
        _pointNames = new string[] { "_OwnerPt0", "_OwnerPt1", "_OwnerPt2", "_OwnerPt3", "_OwnerPt4", "_OwnerPt5" };
        _pointPos = new Vector3[_pointBones.Length];
    }

    void Start()
    {
        EnsureInit();
        if (_ownerId == 0 && !followLocalPlayer) { ClearOwner(); }
    }

    // ================= 外から呼ぶ =================

    // playerId の人のアバターにだけ繭を描かせる
    public void SetOwner(int playerId)
    {
        EnsureInit();
        _ownerId = playerId;
        SetProjector(playerId > 0);
    }

    // やめる。マスクの値を「誰でもない」に戻し、Projector を無効にする
    public void ClearOwner()
    {
        EnsureInit();
        _ownerId = 0;
        if (maskMaterial != null)
        {
            Vector4 none = new Vector4(0f, -9999f, 0f, 0f);
            maskMaterial.SetVector("_OwnerRoot", none);
            maskMaterial.SetVector("_OwnerHips", none);
            for (int i = 0; i < _pointNames.Length; i++) { maskMaterial.SetVector(_pointNames[i], none); }
        }
        // 太さをそろえる筒も「渡していない」に戻す（繭デカールの箱を次の人に使い回すとき、前の人の筒が残らないように）
        WriteGirthNone();
        SetProjector(false);
    }

    // 今の対象の playerId（いなければ 0）
    public int GetOwnerId()
    {
        return _ownerId;
    }

    // ================= 毎フレーム =================
    // アバターの骨がそのフレームの位置に動いた後に読むため PostLateUpdate で動く
    public override void PostLateUpdate()
    {
        int id = _ownerId;
        if (id == 0 && followLocalPlayer)
        {
            VRCPlayerApi local = Networking.LocalPlayer;
            if (Utilities.IsValid(local)) { id = local.playerId; SetProjector(true); }
        }
        if (id == 0) { return; }
        VRCPlayerApi p = VRCPlayerApi.GetPlayerById(id);
        if (!Utilities.IsValid(p)) { ClearOwner(); return; }
        if (maskMaterial == null) { return; }

        Vector3 root = p.GetPosition();
        maskMaterial.SetVector("_OwnerRoot", new Vector4(root.x, root.y, root.z, rootRadius));
        maskMaterial.SetVector("_OwnerHips", Point(p.GetBonePosition(HumanBodyBones.Hips), hipsRadius));
        for (int i = 0; i < _pointBones.Length; i++)
        {
            _pointPos[i] = p.GetBonePosition((HumanBodyBones)_pointBones[i]);
            maskMaterial.SetVector(_pointNames[i], Point(_pointPos[i], attachmentRadius));
        }
        // 繭デカールの「太さをそろえる」の筒（繭デカールの Renderer を入れたときだけ）
        if (cocoonRenderer != null) { WriteGirth(p); }

        if (projectorTransform != null)
        {
            // 頭の上から真下へ向ける。Projector の上方向（画面の縦）は本人の正面にそろえる
            Vector3 headPos = _pointPos[0];
            if (headPos.sqrMagnitude < 1e-8f) { headPos = root + Vector3.up * p.GetAvatarEyeHeightAsMeters(); }
            Vector3 fwd = p.GetRotation() * Vector3.forward;
            fwd.y = 0f;
            if (fwd.sqrMagnitude < 1e-6f) { fwd = Vector3.forward; }
            projectorTransform.position = headPos + Vector3.up * heightAboveHead;
            projectorTransform.rotation = Quaternion.LookRotation(Vector3.down, fwd.normalized);
        }
    }

    public override void OnPlayerLeft(VRCPlayerApi player)
    {
        if (player != null && _ownerId != 0 && player.playerId == _ownerId) { ClearOwner(); }
    }

    // ================= 内部 =================

    // 骨の位置と許容半径。骨が無い（GetBonePosition がゼロ）か半径が 0 以下なら無効（y = -9999、w = 0）
    private Vector4 Point(Vector3 v, float radius)
    {
        if (v.sqrMagnitude < 1e-8f || radius <= 0f) { return new Vector4(0f, -9999f, 0f, 0f); }
        return new Vector4(v.x, v.y, v.z, radius);
    }

    // ---- 太さをそろえる筒（繭デカールの _EvenGirthA / _EvenGirthB） ----
    // 体を骨と骨を結ぶ円柱（大人の体の目安の太さ）の集まりと考え、体の軸（腰 → 頭）に沿って一番下の骨から一番上の骨まで、
    // 軸から一番遠くまで張り出した所（骨 + 円柱の太さ）までを含む筒を作る。
    // 上下の端は骨の位置で止める（太さを足さない）。上端は頭のてっぺん、下端は足の裏。
    // 円柱の太さは大人の体（腰〜首 0.45 m）の目安を、その人の腰〜首の長さで伸び縮みさせる。
    // 筒の端の丸みと糸の厚みは繭デカールが足す。骨が足りず筒が作れないときは「渡していない」にする（繭デカールは筒を描かない）
    private void WriteGirth(VRCPlayerApi p)
    {
        Vector3 hips = p.GetBonePosition(HumanBodyBones.Hips);
        if (hips.sqrMagnitude < 1e-8f) { WriteGirthNone(); return; }
        Vector3 head = _pointPos[0];
        Vector3 chest = _pointPos[1];
        Vector3 handL = _pointPos[2];
        Vector3 handR = _pointPos[3];
        Vector3 footL = _pointPos[4];
        Vector3 footR = _pointPos[5];
        Vector3 spine = p.GetBonePosition(HumanBodyBones.Spine);
        Vector3 neck = p.GetBonePosition(HumanBodyBones.Neck);
        Vector3 shoulderL = p.GetBonePosition(HumanBodyBones.LeftUpperArm);
        Vector3 elbowL = p.GetBonePosition(HumanBodyBones.LeftLowerArm);
        Vector3 shoulderR = p.GetBonePosition(HumanBodyBones.RightUpperArm);
        Vector3 elbowR = p.GetBonePosition(HumanBodyBones.RightLowerArm);
        Vector3 hipL = p.GetBonePosition(HumanBodyBones.LeftUpperLeg);
        Vector3 kneeL = p.GetBonePosition(HumanBodyBones.LeftLowerLeg);
        Vector3 hipR = p.GetBonePosition(HumanBodyBones.RightUpperLeg);
        Vector3 kneeR = p.GetBonePosition(HumanBodyBones.RightLowerLeg);
        Vector3 toesL = p.GetBonePosition(HumanBodyBones.LeftToes);
        Vector3 toesR = p.GetBonePosition(HumanBodyBones.RightToes);
        Vector3 fingersL = p.GetBonePosition(HumanBodyBones.LeftMiddleProximal);
        Vector3 fingersR = p.GetBonePosition(HumanBodyBones.RightMiddleProximal);
        // 胸・首の骨が無いアバターは、背骨と頭の間で代わりにする
        if (!Valid(chest) && Valid(spine) && Valid(head)) { chest = Vector3.Lerp(spine, head, 0.3f); }
        if (!Valid(neck) && Valid(chest) && Valid(head)) { neck = Vector3.Lerp(chest, head, 0.6f); }

        // 体の軸: 腰 → 頭（頭が無ければ首・胸。どれも無ければ真上）
        Vector3 top = Valid(head) ? head : (Valid(neck) ? neck : chest);
        Vector3 up = Valid(top) ? top - hips : Vector3.up;
        up = up.sqrMagnitude > 1e-4f ? up.normalized : Vector3.up;
        // 体の大きさ（大人の腰〜首 0.45 m、腰〜頭 0.55 m を 1 とする）
        float size = 1f;
        if (Valid(neck)) { size = Vector3.Distance(hips, neck) / 0.45f; }
        else if (Valid(head)) { size = Vector3.Distance(hips, head) / 0.55f; }
        float s = Mathf.Clamp(size, 0.2f, 5f);

        // 骨の無い端（頭のてっぺん・指先・骨盤の下）をのばす
        Vector3 headTop = Valid(head) ? head + up * (0.15f * s) : Vector3.zero;   // 頭のてっぺん（筒の上端はここで止める）
        Vector3 pelvis = Valid(chest) ? Extend(hips, chest, 0.4f) : (Valid(spine) ? Extend(hips, spine, 0.8f) : hips);
        Vector3 handTipL = Valid(fingersL) ? Extend(fingersL, handL, 1f) : Extend(handL, elbowL, 0.7f);
        Vector3 handTipR = Valid(fingersR) ? Extend(fingersR, handR, 1f) : Extend(handR, elbowR, 0.7f);

        _gOrigin = hips;
        _gUp = up;
        _gMinAlong = 1e9f;
        _gMaxAlong = -1e9f;
        _gMaxRadial = 0f;
        _gAny = false;
        GirthSeg(pelvis, spine, 0.15f * s);
        GirthSeg(spine, chest, 0.15f * s);
        GirthSeg(chest, neck, 0.15f * s);
        GirthSeg(neck, head, 0.06f * s);
        GirthSeg(head, headTop, 0.10f * s);
        GirthSeg(shoulderL, elbowL, 0.050f * s);
        GirthSeg(elbowL, handL, 0.045f * s);
        GirthSeg(handL, handTipL, 0.060f * s);
        GirthSeg(shoulderR, elbowR, 0.050f * s);
        GirthSeg(elbowR, handR, 0.045f * s);
        GirthSeg(handR, handTipR, 0.060f * s);
        GirthSeg(hipL, kneeL, 0.080f * s);
        GirthSeg(kneeL, footL, 0.055f * s);
        GirthFoot(footL, kneeL, toesL, s);
        GirthSeg(hipR, kneeR, 0.080f * s);
        GirthSeg(kneeR, footR, 0.055f * s);
        GirthFoot(footR, kneeR, toesR, s);
        if (!_gAny || _gMaxAlong <= _gMinAlong) { WriteGirthNone(); return; }

        Vector3 lo = _gOrigin + _gUp * _gMinAlong;
        Vector3 hi = _gOrigin + _gUp * _gMaxAlong;
        if (_girthBlock == null) { _girthBlock = new MaterialPropertyBlock(); }
        // 繭デカールの箱には別のスクリプト（巻きアニメなど）も値を渡すので、今の値を読んでから書き足す
        cocoonRenderer.GetPropertyBlock(_girthBlock);
        _girthBlock.SetVector("_EvenGirthA", new Vector4(lo.x, lo.y, lo.z, 0f));
        _girthBlock.SetVector("_EvenGirthB", new Vector4(hi.x, hi.y, hi.z, _gMaxRadial));
        cocoonRenderer.SetPropertyBlock(_girthBlock);
        girthBottom = lo;
        girthTop = hi;
        girthRadius = _gMaxRadial;
    }

    // 筒を「渡していない」にする（w = 0。繭プロジェクターと組む繭デカールは筒を描かない）
    private void WriteGirthNone()
    {
        girthRadius = 0f;
        if (cocoonRenderer == null) { return; }
        if (_girthBlock == null) { _girthBlock = new MaterialPropertyBlock(); }
        cocoonRenderer.GetPropertyBlock(_girthBlock);
        _girthBlock.SetVector("_EvenGirthB", Vector4.zero);
        cocoonRenderer.SetPropertyBlock(_girthBlock);
    }

    // 骨 a〜b を結ぶ半径 r の円柱を筒に入れる（軸に沿った端は骨の位置まで、軸からの遠さは骨 + r まで広げる）。
    // どちらかの骨が無ければ使わない
    private void GirthSeg(Vector3 a, Vector3 b, float r)
    {
        if (!Valid(a) || !Valid(b)) { return; }
        GirthPoint(a, r);
        GirthPoint(b, r);
        _gAny = true;
    }

    private void GirthPoint(Vector3 v, float r)
    {
        Vector3 d = v - _gOrigin;
        float along = Vector3.Dot(d, _gUp);
        float radial = (d - _gUp * along).magnitude;
        _gMinAlong = Mathf.Min(_gMinAlong, along);
        _gMaxAlong = Mathf.Max(_gMaxAlong, along);
        _gMaxRadial = Mathf.Max(_gMaxRadial, radial + r);
    }

    // 足（足首から先）。つま先の骨があれば、かかとからつま先の先まで。無ければ足首から真下（すねの向き）へ。
    // 足の裏は足首の骨より下にあるので、下端を足首の骨から 0.1 m（大人の目安）下まで広げる
    private void GirthFoot(Vector3 foot, Vector3 knee, Vector3 toes, float s)
    {
        if (!Valid(foot)) { return; }
        if (Valid(toes))
        {
            GirthSeg(Extend(foot, toes, 0.35f), Extend(toes, foot, 0.3f), 0.050f * s);
        }
        else
        {
            Vector3 sole = Valid(knee) ? Extend(foot, knee, 0.15f) : foot - Vector3.up * (0.08f * s);
            GirthSeg(foot, sole, 0.055f * s);
        }
        _gMinAlong = Mathf.Min(_gMinAlong, Vector3.Dot(foot - _gOrigin, _gUp) - 0.10f * s);
    }

    // 骨の位置が取れているか（GetBonePosition は骨が無いとゼロを返す）
    private bool Valid(Vector3 v)
    {
        return v.sqrMagnitude >= 1e-8f;
    }

    // 点 a から「b → a の向き」に、a と b の距離の k 倍だけ先へのばした点。どちらかの骨が無ければゼロ（骨が無い扱い）
    private Vector3 Extend(Vector3 a, Vector3 b, float k)
    {
        if (!Valid(a) || !Valid(b)) { return Vector3.zero; }
        return a + (a - b) * k;
    }

    private void SetProjector(bool on)
    {
        if (projectorTransform == null || on == _projectorOn) { return; }
        _projectorOn = on;
        projectorTransform.gameObject.SetActive(on);
    }
}
