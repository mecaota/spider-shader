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
/// ・繭を付ける部位（頭・胸・腰・左右の上腕・左右の前腕と手・左右のもも・左右のすねと足）を選べる。
///   部位の判定に使う首・肩・肘・股関節・膝の位置も毎フレーム渡す（_JointNeck など）。
///
/// 使い方（別の UdonSharp スクリプトから。どれも呼んだクライアントの見た目だけを変える）:
/// ・SetOwner(playerId)  この人のアバターにだけ繭を描かせる
/// ・ClearOwner()        やめる（Projector を無効にする）
/// ・SetParts(mask)      繭を付ける部位をまとめて選ぶ（ビットの並びは PartHead 〜 PartShinRight の定数）
/// ・SetPart(part, on)   部位を 1 つだけ ON / OFF する
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

    [Tooltip("手に持つ物・帽子・靴など骨の下に付いた物の原点が、頭・胸・両手・両足からこの距離以内なら本人の物とみなす。0 で使わない")]
    public float attachmentRadius = 0.25f;

    [Header("繭を付ける部位（OFF の部位には繭が出ない）")]
    public bool head = true;
    public bool chest = true;
    [Tooltip("腰（股関節の高さから胸の骨の高さまで。骨盤とお尻を含む）")]
    public bool waist = true;
    public bool upperArmLeft = true;
    [Tooltip("左の前腕と手")]
    public bool forearmLeft = true;
    public bool upperArmRight = true;
    [Tooltip("右の前腕と手")]
    public bool forearmRight = true;
    public bool thighLeft = true;
    [Tooltip("左のすねと足")]
    public bool shinLeft = true;
    public bool thighRight = true;
    [Tooltip("右のすねと足")]
    public bool shinRight = true;

    // SetParts / SetPart / GetParts のビット（PartAll = 全部）
    public const int PartHead = 0, PartChest = 1, PartWaist = 2;
    public const int PartUpperArmLeft = 3, PartForearmLeft = 4, PartUpperArmRight = 5, PartForearmRight = 6;
    public const int PartThighLeft = 7, PartShinLeft = 8, PartThighRight = 9, PartShinRight = 10;
    public const int PartAll = 2047;

    // マスクのシェーダーの _OwnerPt0〜5 の順（頭・胸・左手・右手・左足・右足）
    private int[] _pointBones;
    private string[] _pointNames;
    // 部位の判定に使う関節（首・左肩・左肘・右肩・右肘・左股関節・左膝・右股関節・右膝）
    private int[] _jointBones;
    private string[] _jointNames;
    // 部位の ON / OFF を渡すプロパティ（ビットの順）
    private string[] _partNames;
    private int _partsWritten = -1;   // マテリアルに書いた部位のビット（-1 = まだ書いていない）
    private bool _inited = false;
    private int _ownerId = 0;
    private bool _projectorOn = true;

    private void EnsureInit()
    {
        if (_inited) { return; }
        _inited = true;
        _pointBones = new int[] { (int)HumanBodyBones.Head, (int)HumanBodyBones.Chest,
                                  (int)HumanBodyBones.LeftHand, (int)HumanBodyBones.RightHand,
                                  (int)HumanBodyBones.LeftFoot, (int)HumanBodyBones.RightFoot };
        _pointNames = new string[] { "_OwnerPt0", "_OwnerPt1", "_OwnerPt2", "_OwnerPt3", "_OwnerPt4", "_OwnerPt5" };
        _jointBones = new int[] { (int)HumanBodyBones.Neck,
                                  (int)HumanBodyBones.LeftUpperArm, (int)HumanBodyBones.LeftLowerArm,
                                  (int)HumanBodyBones.RightUpperArm, (int)HumanBodyBones.RightLowerArm,
                                  (int)HumanBodyBones.LeftUpperLeg, (int)HumanBodyBones.LeftLowerLeg,
                                  (int)HumanBodyBones.RightUpperLeg, (int)HumanBodyBones.RightLowerLeg };
        _jointNames = new string[] { "_JointNeck", "_JointUpperArmL", "_JointLowerArmL", "_JointUpperArmR", "_JointLowerArmR",
                                     "_JointUpperLegL", "_JointLowerLegL", "_JointUpperLegR", "_JointLowerLegR" };
        _partNames = new string[] { "_PartHead", "_PartChest", "_PartWaist",
                                    "_PartUpperArmL", "_PartForearmL", "_PartUpperArmR", "_PartForearmR",
                                    "_PartThighL", "_PartShinL", "_PartThighR", "_PartShinR" };
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
            for (int i = 0; i < _jointNames.Length; i++) { maskMaterial.SetVector(_jointNames[i], none); }
        }
        SetProjector(false);
    }

    // 今の対象の playerId（いなければ 0）
    public int GetOwnerId()
    {
        return _ownerId;
    }

    // 繭を付ける部位をまとめて選ぶ。mask のビット = PartHead 〜 PartShinRight（例: 腰と両腕 =
    // (1 << PartWaist) | (1 << PartUpperArmLeft) | (1 << PartForearmLeft) | (1 << PartUpperArmRight) | (1 << PartForearmRight)）
    public void SetParts(int mask)
    {
        head = (mask & (1 << PartHead)) != 0;
        chest = (mask & (1 << PartChest)) != 0;
        waist = (mask & (1 << PartWaist)) != 0;
        upperArmLeft = (mask & (1 << PartUpperArmLeft)) != 0;
        forearmLeft = (mask & (1 << PartForearmLeft)) != 0;
        upperArmRight = (mask & (1 << PartUpperArmRight)) != 0;
        forearmRight = (mask & (1 << PartForearmRight)) != 0;
        thighLeft = (mask & (1 << PartThighLeft)) != 0;
        shinLeft = (mask & (1 << PartShinLeft)) != 0;
        thighRight = (mask & (1 << PartThighRight)) != 0;
        shinRight = (mask & (1 << PartShinRight)) != 0;
        WriteParts();
    }

    // 部位を 1 つだけ ON / OFF する（part = PartHead 〜 PartShinRight）
    public void SetPart(int part, bool on)
    {
        if (part < 0 || part > PartShinRight) { return; }
        int mask = GetParts();
        if (on) { mask |= 1 << part; } else { mask &= ~(1 << part); }
        SetParts(mask);
    }

    // 今の部位のビット
    public int GetParts()
    {
        int m = 0;
        if (head) { m |= 1 << PartHead; }
        if (chest) { m |= 1 << PartChest; }
        if (waist) { m |= 1 << PartWaist; }
        if (upperArmLeft) { m |= 1 << PartUpperArmLeft; }
        if (forearmLeft) { m |= 1 << PartForearmLeft; }
        if (upperArmRight) { m |= 1 << PartUpperArmRight; }
        if (forearmRight) { m |= 1 << PartForearmRight; }
        if (thighLeft) { m |= 1 << PartThighLeft; }
        if (shinLeft) { m |= 1 << PartShinLeft; }
        if (thighRight) { m |= 1 << PartThighRight; }
        if (shinRight) { m |= 1 << PartShinRight; }
        return m;
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

        WriteParts();
        Vector3 root = p.GetPosition();
        maskMaterial.SetVector("_OwnerRoot", new Vector4(root.x, root.y, root.z, rootRadius));
        maskMaterial.SetVector("_OwnerHips", BonePoint(p, (int)HumanBodyBones.Hips, hipsRadius));
        for (int i = 0; i < _pointBones.Length; i++)
        {
            maskMaterial.SetVector(_pointNames[i], BonePoint(p, _pointBones[i], attachmentRadius));
        }
        // 胸の骨が無いアバターは背骨で代わりにする（部位の判定で腰と胸の境目に使う）
        if (p.GetBonePosition(HumanBodyBones.Chest).sqrMagnitude < 1e-8f)
        {
            maskMaterial.SetVector(_pointNames[1], BonePoint(p, (int)HumanBodyBones.Spine, attachmentRadius));
        }
        for (int i = 0; i < _jointBones.Length; i++)
        {
            maskMaterial.SetVector(_jointNames[i], BonePoint(p, _jointBones[i], 0f));
        }
        // 首の骨が無いアバターは、胸（無ければ背骨）と頭の間で代わりにする
        if (p.GetBonePosition(HumanBodyBones.Neck).sqrMagnitude < 1e-8f)
        {
            Vector3 c = p.GetBonePosition(HumanBodyBones.Chest);
            if (c.sqrMagnitude < 1e-8f) { c = p.GetBonePosition(HumanBodyBones.Spine); }
            Vector3 h = p.GetBonePosition(HumanBodyBones.Head);
            if (c.sqrMagnitude > 1e-8f && h.sqrMagnitude > 1e-8f)
            {
                Vector3 n = Vector3.Lerp(c, h, 0.6f);
                maskMaterial.SetVector(_jointNames[0], new Vector4(n.x, n.y, n.z, 0f));
            }
        }

        if (projectorTransform != null)
        {
            // 頭の上から真下へ向ける。Projector の上方向（画面の縦）は本人の正面にそろえる
            Vector3 headPos = p.GetBonePosition(HumanBodyBones.Head);
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

    // 骨の位置と許容半径。骨が無ければ無効（y = -9999、w = 0）。
    // radius <= 0 でも位置は渡す（w = 0 なら所有者の判定には使われず、部位の判定にだけ使われる）
    private Vector4 BonePoint(VRCPlayerApi p, int bone, float radius)
    {
        Vector3 v = p.GetBonePosition((HumanBodyBones)bone);
        if (v.sqrMagnitude < 1e-8f) { return new Vector4(0f, -9999f, 0f, 0f); }
        return new Vector4(v.x, v.y, v.z, radius > 0f ? radius : 0f);
    }

    // 部位の ON / OFF をマスクのマテリアルに書く（変わったときだけ）
    private void WriteParts()
    {
        EnsureInit();
        if (maskMaterial == null) { return; }
        int mask = GetParts();
        if (mask == _partsWritten) { return; }
        _partsWritten = mask;
        for (int i = 0; i < _partNames.Length; i++)
        {
            maskMaterial.SetFloat(_partNames[i], (mask & (1 << i)) != 0 ? 1f : 0f);
        }
    }

    private void SetProjector(bool on)
    {
        if (projectorTransform == null || on == _projectorOn) { return; }
        _projectorOn = on;
        projectorTransform.gameObject.SetActive(on);
    }
}
