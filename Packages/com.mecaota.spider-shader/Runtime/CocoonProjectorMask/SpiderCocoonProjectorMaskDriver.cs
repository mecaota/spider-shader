using UdonSharp;
using UnityEngine;
using VRC.SDKBase;

/// <summary>
/// 受け手マスク（mecaota/SpiderCocoonProjectorMask）を動かす役。体に張り付く繭（SpiderCocoonDepthDecal）を、
/// 捕まった人のアバターにだけ描かせる（床・壁・隣に立つ人には繭が出ない）。
///
/// しくみ:
/// ・Projector は「投影範囲に入ったアバターを、マスクのマテリアルでもう一度描く」部品。マスクのシェーダーは
///   描き直す相手が捕まった本人かどうかを、相手のメッシュの原点と本人の骨の位置を比べて決める。
/// ・このスクリプトは毎フレーム、本人の足元・腰・頭・胸・両手・両足の位置をマスクのマテリアルに渡し
///   （_OwnerRoot / _OwnerHips / _OwnerPt0〜5）、Projector を本人の頭の上へ動かして真下へ向ける。
/// ・誰も捕まっていない間は Projector の GameObject を無効にする（描き直しの負荷をなくす）。
///
/// 使い方（別の UdonSharp スクリプトから。どれも呼んだクライアントの見た目だけを変える）:
/// ・SetOwner(playerId)  この人のアバターにだけ繭を描かせる
/// ・ClearOwner()        やめる（Projector を無効にする）
/// 全員に同じ見え方をさせたいときは、捕獲を同期しているスクリプトから全員のクライアントで呼ぶ。
///
/// 注意:
/// ・Projector コンポーネントの設定（Orthographic・大きさ・Ignore Layers）は Udon から変えられないので、
///   シーンで設定しておく（docs/SpiderCocoonProjectorMask.md の「セットアップ」）
/// ・マスクのマテリアルは Projector 1 つにつき 1 つ（共有すると全員が同じ人として扱われる）
/// </summary>
[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class SpiderCocoonProjectorMaskDriver : UdonSharpBehaviour
{
    [Header("対象")]
    [Tooltip("Projector コンポーネントを付けた GameObject の Transform。頭の上へ動かして真下へ向ける。誰もいない間は GameObject ごと無効にするので、このスクリプトとは別の GameObject にする")]
    public Transform projectorTransform;

    [Tooltip("Projector に入れたマスクのマテリアル（mecaota/SpiderCocoonProjectorMask）。Projector ごとに別のマテリアルにする")]
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

    // マスクのシェーダーの _OwnerPt0〜5 の順（頭・胸・左手・右手・左足・右足）
    private int[] _pointBones;
    private string[] _pointNames;
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
        maskMaterial.SetVector("_OwnerHips", BonePoint(p, (int)HumanBodyBones.Hips, hipsRadius));
        for (int i = 0; i < _pointBones.Length; i++)
        {
            maskMaterial.SetVector(_pointNames[i], BonePoint(p, _pointBones[i], attachmentRadius));
        }

        if (projectorTransform != null)
        {
            // 頭の上から真下へ向ける。Projector の上方向（画面の縦）は本人の正面にそろえる
            Vector3 head = p.GetBonePosition(HumanBodyBones.Head);
            if (head.sqrMagnitude < 1e-8f) { head = root + Vector3.up * p.GetAvatarEyeHeightAsMeters(); }
            Vector3 fwd = p.GetRotation() * Vector3.forward;
            fwd.y = 0f;
            if (fwd.sqrMagnitude < 1e-6f) { fwd = Vector3.forward; }
            projectorTransform.SetPositionAndRotation(head + Vector3.up * heightAboveHead,
                                                      Quaternion.LookRotation(Vector3.down, fwd.normalized));
        }
    }

    public override void OnPlayerLeft(VRCPlayerApi player)
    {
        if (player != null && _ownerId != 0 && player.playerId == _ownerId) { ClearOwner(); }
    }

    // ================= 内部 =================

    // 骨の位置と許容半径。骨が無ければ無効（y = -9999、w = 0）
    private Vector4 BonePoint(VRCPlayerApi p, int bone, float radius)
    {
        Vector3 v = p.GetBonePosition((HumanBodyBones)bone);
        if (v.sqrMagnitude < 1e-8f || radius <= 0f) { return new Vector4(0f, -9999f, 0f, 0f); }
        return new Vector4(v.x, v.y, v.z, radius);
    }

    private void SetProjector(bool on)
    {
        if (projectorTransform == null || on == _projectorOn) { return; }
        _projectorOn = on;
        projectorTransform.gameObject.SetActive(on);
    }
}
