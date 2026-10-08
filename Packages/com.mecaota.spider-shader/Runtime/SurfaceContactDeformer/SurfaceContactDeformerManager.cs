using UdonSharp;
using UnityEngine;
using VRC.SDKBase;

/// <summary>
/// 多数の <see cref="SurfaceContactDeformer"/> を1つの PostLateUpdate から駆動する管理役。
///
/// 巣を全ての木の麓に置くと100個以上になり、各自が PostLateUpdate を回すと
/// アイドル時でも毎フレーム重い（1個数µs×100個）。そこで各 Deformer は
/// PostLateUpdate を持たず、「捕縛が有効になった or ローカルがトリガー内に入った」
/// ときだけこのマネージャへ Register し、外れたら Unregister する。
/// マネージャはアクティブな Deformer（通常0〜数個）だけ Tick() する。
///
/// PostLateUpdate を持つ UdonBehaviour はこの1個だけなので、アイドル時のコストは
/// マネージャ1個分に収まる。シーンに1個だけ置くこと。
///
/// くっついている間の減速:
/// ・slowLocalWhenStuck が ON の Deformer のどれかにローカルプレイヤーがくっついている間、
///   歩き・走り・横歩きの速度を stuckSpeedRatio 倍にする（どのボーンがくっついていても同じ）。
///   複数の巣にくっついても重ね掛けしない（一番小さい倍率を 1 回だけ掛ける）
/// ・解除は「自分が設定した値のままのとき」だけ元に戻す（他のギミックが後から速度を
///   変えていたら上書きしない。BossStickyNetManager と同じ作法）
/// </summary>
[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class SurfaceContactDeformerManager : UdonSharpBehaviour
{
    private const int Capacity = 256;

    private SurfaceContactDeformer[] _active = new SurfaceContactDeformer[Capacity];
    private int _count = 0;

    // くっついている間の減速（ローカルのみ）
    private bool _slowed = false;
    private float _slowRatio = 1f;
    private float _baseWalk, _baseRun, _baseStrafe;

    // 既に登録済みなら何もしない
    public void Register(SurfaceContactDeformer d)
    {
        if (d == null) { return; }
        for (int i = 0; i < _count; i++)
        {
            if (_active[i] == d) { return; }
        }
        if (_count >= Capacity) { return; }
        _active[_count] = d;
        _count++;
    }

    public void Unregister(SurfaceContactDeformer d)
    {
        for (int i = 0; i < _count; i++)
        {
            if (_active[i] == d)
            {
                _count--;
                _active[i] = _active[_count]; // 末尾を詰める
                _active[_count] = null;
                return;
            }
        }
    }

    public override void PostLateUpdate()
    {
        // Tick 中に Unregister されると詰めで同じ index に別要素が来るので、
        // 末尾から回して安全に走査する
        float ratio = 1f;
        for (int i = _count - 1; i >= 0; i--)
        {
            var d = _active[i];
            if (d == null) { continue; }
            d.Tick();
            // くっついている巣は必ず登録中なので、ここで見るだけで漏れない
            if (d.slowLocalWhenStuck && d.IsLocalStuck())
            {
                ratio = Mathf.Min(ratio, Mathf.Clamp01(d.stuckSpeedRatio));
            }
        }
        UpdateSlow(ratio);
    }

    // ratio < 1 の間だけ移動速度を ratio 倍にする
    private void UpdateSlow(float ratio)
    {
        VRCPlayerApi local = Networking.LocalPlayer;
        if (!Utilities.IsValid(local)) { return; }
        bool want = ratio < 0.999f;
        if (want && !_slowed)
        {
            _baseWalk = local.GetWalkSpeed();
            _baseRun = local.GetRunSpeed();
            _baseStrafe = local.GetStrafeSpeed();
            _slowRatio = ratio;
            local.SetWalkSpeed(_baseWalk * _slowRatio);
            local.SetRunSpeed(_baseRun * _slowRatio);
            local.SetStrafeSpeed(_baseStrafe * _slowRatio);
            _slowed = true;
        }
        else if (!want && _slowed)
        {
            RestoreSpeed();
        }
    }

    // 自分が設定した値のままのときだけ元に戻す（後から他のギミックが変えた速度は触らない）
    private void RestoreSpeed()
    {
        if (!_slowed) { return; }
        _slowed = false;
        VRCPlayerApi local = Networking.LocalPlayer;
        if (!Utilities.IsValid(local)) { return; }
        if (Mathf.Abs(local.GetWalkSpeed() - _baseWalk * _slowRatio) < 0.001f) { local.SetWalkSpeed(_baseWalk); }
        if (Mathf.Abs(local.GetRunSpeed() - _baseRun * _slowRatio) < 0.001f) { local.SetRunSpeed(_baseRun); }
        if (Mathf.Abs(local.GetStrafeSpeed() - _baseStrafe * _slowRatio) < 0.001f) { local.SetStrafeSpeed(_baseStrafe); }
    }

    public override void OnPlayerRespawn(VRCPlayerApi player)
    {
        if (Utilities.IsValid(player) && player.isLocal) { RestoreSpeed(); }
    }

    private void OnDisable()
    {
        RestoreSpeed();
    }
}
