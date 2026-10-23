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
/// ・繭を付ける部位を、SurfaceContactDeformer と同じ TrackBone の配列（bones）で選べる（空なら全身）。
///   部位の判定に使う背骨・首・肩・肘・股関節・膝・つま先の位置も毎フレーム渡す（_JointSpine など）。
///
/// 使い方（別の UdonSharp スクリプトから。どれも呼んだクライアントの見た目だけを変える）:
/// ・SetOwner(playerId)   この人のアバターにだけ繭を描かせる
/// ・ClearOwner()         やめる（Projector を無効にする）
/// ・SetBones(bones)      繭を付ける骨をまとめて選ぶ（空の配列 = 全身）
/// ・SetBone(bone, on)    骨を 1 つだけ ON / OFF する（全部 OFF にすると何も付かない。SetBones / SetWholeBody で戻る）
/// ・SetWholeBody()       全身に戻す
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

    [Header("繭を付ける部位")]
    [Tooltip("繭を付ける骨。空なら全身（衣装の付属品まで丸ごと）。各骨の部位は「その骨から次の骨まで」（Hips は骨盤から背骨の骨まで、Hand は手首から指先まで、Foot はかかとからつま先まで）。UpperChest・LeftShoulder・RightShoulder は Chest、LeftToes・RightToes は Foot として扱う")]
    public TrackBone[] bones = new TrackBone[0];

    private const int PartCount = 17;
    private const int PartAll = (1 << PartCount) - 1;

    // マスクのシェーダーの _OwnerPt0〜5 の順（頭・胸・左手・右手・左足・右足）
    private int[] _pointBones;
    private string[] _pointNames;
    // 部位の判定に使う骨（背骨・首・左肩・左肘・右肩・右肘・左股関節・左膝・右股関節・右膝・左つま先・右つま先）
    private int[] _jointBones;
    private string[] _jointNames;
    // シェーダーの部位（_PartHips 〜 _PartRightFoot）と、その部位を代表する骨（ビットの順）
    private string[] _partNames;
    private TrackBone[] _partBones;
    private int[] _partOfBone;        // HumanBodyBones の値 → 部位の番号（-1 = 部位なし）
    private int _partsWritten = -1;   // マテリアルに書いた部位のビット（-1 = まだ書いていない）
    private bool _noParts = false;    // SetBone で全部 OFF にした（空の bones は全身なので、別に覚える）
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
        _jointBones = new int[] { (int)HumanBodyBones.Spine, (int)HumanBodyBones.Neck,
                                  (int)HumanBodyBones.LeftUpperArm, (int)HumanBodyBones.LeftLowerArm,
                                  (int)HumanBodyBones.RightUpperArm, (int)HumanBodyBones.RightLowerArm,
                                  (int)HumanBodyBones.LeftUpperLeg, (int)HumanBodyBones.LeftLowerLeg,
                                  (int)HumanBodyBones.RightUpperLeg, (int)HumanBodyBones.RightLowerLeg,
                                  (int)HumanBodyBones.LeftToes, (int)HumanBodyBones.RightToes };
        _jointNames = new string[] { "_JointSpine", "_JointNeck",
                                     "_JointLeftUpperArm", "_JointLeftLowerArm", "_JointRightUpperArm", "_JointRightLowerArm",
                                     "_JointLeftUpperLeg", "_JointLeftLowerLeg", "_JointRightUpperLeg", "_JointRightLowerLeg",
                                     "_JointLeftToes", "_JointRightToes" };
        _partBones = new TrackBone[] { TrackBone.Hips, TrackBone.Spine, TrackBone.Chest, TrackBone.Neck, TrackBone.Head,
                                       TrackBone.LeftUpperArm, TrackBone.LeftLowerArm, TrackBone.LeftHand,
                                       TrackBone.RightUpperArm, TrackBone.RightLowerArm, TrackBone.RightHand,
                                       TrackBone.LeftUpperLeg, TrackBone.LeftLowerLeg, TrackBone.LeftFoot,
                                       TrackBone.RightUpperLeg, TrackBone.RightLowerLeg, TrackBone.RightFoot };
        // U# では自作 enum が int として扱われ ToString() が数字になるので、名前は手で並べる
        _partNames = new string[] { "_PartHips", "_PartSpine", "_PartChest", "_PartNeck", "_PartHead",
                                    "_PartLeftUpperArm", "_PartLeftLowerArm", "_PartLeftHand",
                                    "_PartRightUpperArm", "_PartRightLowerArm", "_PartRightHand",
                                    "_PartLeftUpperLeg", "_PartLeftLowerLeg", "_PartLeftFoot",
                                    "_PartRightUpperLeg", "_PartRightLowerLeg", "_PartRightFoot" };
        _partOfBone = new int[(int)HumanBodyBones.LastBone];
        for (int i = 0; i < _partOfBone.Length; i++) { _partOfBone[i] = -1; }
        for (int i = 0; i < PartCount; i++) { _partOfBone[(int)_partBones[i]] = i; }
        // 部位を持たない骨は、その骨を含む部位に寄せる（肩の上と上胸は胸の円柱、つま先は足の円柱に入る）
        _partOfBone[(int)TrackBone.UpperChest] = 2;
        _partOfBone[(int)TrackBone.LeftShoulder] = 2;
        _partOfBone[(int)TrackBone.RightShoulder] = 2;
        _partOfBone[(int)TrackBone.LeftToes] = 13;
        _partOfBone[(int)TrackBone.RightToes] = 16;
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

    // 繭を付ける骨をまとめて選ぶ。空の配列（または null）なら全身
    public void SetBones(TrackBone[] newBones)
    {
        bones = newBones != null ? newBones : new TrackBone[0];
        _noParts = false;
        WriteParts();
    }

    // 骨を 1 つだけ ON / OFF する。その骨を含む部位ごと切り替わる（例: UpperChest を OFF にすると Chest が OFF）
    public void SetBone(TrackBone bone, bool on)
    {
        EnsureInit();
        int part = PartOf((int)bone);
        if (part < 0) { return; }
        int mask = GetPartMask();
        if (on) { mask |= 1 << part; } else { mask &= ~(1 << part); }
        bones = BonesFromMask(mask);
        _noParts = mask == 0;
        WriteParts();
    }

    // 全身に戻す
    public void SetWholeBody()
    {
        SetBones(new TrackBone[0]);
    }

    // 骨（を含む部位）に繭を付けるか
    public bool HasBone(TrackBone bone)
    {
        EnsureInit();
        int part = PartOf((int)bone);
        return part >= 0 && (GetPartMask() & (1 << part)) != 0;
    }

    // 今の骨の配列（空 = 全身）
    public TrackBone[] GetBones()
    {
        return bones;
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
        for (int i = 0; i < _jointBones.Length; i++)
        {
            maskMaterial.SetVector(_jointNames[i], BonePoint(p, _jointBones[i], 0f));
        }
        // 胸・首の骨が無いアバターは、背骨と頭の間で代わりにする（部位の判定で背骨・胸・首の境目に使う）
        Vector3 spinePos = p.GetBonePosition(HumanBodyBones.Spine);
        Vector3 chestPos = p.GetBonePosition(HumanBodyBones.Chest);
        Vector3 headBone = p.GetBonePosition(HumanBodyBones.Head);
        bool canGuess = spinePos.sqrMagnitude > 1e-8f && headBone.sqrMagnitude > 1e-8f;
        if (chestPos.sqrMagnitude < 1e-8f && canGuess)
        {
            chestPos = Vector3.Lerp(spinePos, headBone, 0.3f);
            maskMaterial.SetVector(_pointNames[1], new Vector4(chestPos.x, chestPos.y, chestPos.z, attachmentRadius > 0f ? attachmentRadius : 0f));
        }
        if (p.GetBonePosition(HumanBodyBones.Neck).sqrMagnitude < 1e-8f && canGuess)
        {
            Vector3 n = Vector3.Lerp(chestPos, headBone, 0.6f);
            maskMaterial.SetVector(_jointNames[1], new Vector4(n.x, n.y, n.z, 0f));
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

    // HumanBodyBones の値 → シェーダーの部位の番号（-1 = 部位なし）
    private int PartOf(int bone)
    {
        if (bone < 0 || bone >= _partOfBone.Length) { return -1; }
        return _partOfBone[bone];
    }

    // bones から、ON の部位のビット（空 = 全部）
    private int GetPartMask()
    {
        if (_noParts) { return 0; }
        if (bones == null || bones.Length == 0) { return PartAll; }
        int m = 0;
        for (int i = 0; i < bones.Length; i++)
        {
            int part = PartOf((int)bones[i]);
            if (part >= 0) { m |= 1 << part; }
        }
        return m;
    }

    // 部位のビットから骨の配列を作る（全部 ON・全部 OFF なら空）
    private TrackBone[] BonesFromMask(int mask)
    {
        if ((mask & PartAll) == PartAll || mask == 0) { return new TrackBone[0]; }
        int n = 0;
        for (int i = 0; i < PartCount; i++) { if ((mask & (1 << i)) != 0) { n++; } }
        TrackBone[] result = new TrackBone[n];
        n = 0;
        for (int i = 0; i < PartCount; i++)
        {
            if ((mask & (1 << i)) != 0) { result[n] = _partBones[i]; n++; }
        }
        return result;
    }

    // 部位の ON / OFF をマスクのマテリアルに書く（変わったときだけ）
    private void WriteParts()
    {
        EnsureInit();
        if (maskMaterial == null) { return; }
        int mask = GetPartMask();
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
