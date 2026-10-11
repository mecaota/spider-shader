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
///   複数の巣にくっついても重ね掛けしない（くっついている巣のうち一番小さい倍率を 1 回だけ掛ける）。
///   くっついている巣が変わって倍率が変われば掛け直す
/// ・解除・掛け直しは「自分が設定した値のままのとき」だけ書き換える（他のギミックが後から速度を
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
    private float _myWalk, _myRun, _myStrafe;   // 最後に自分が書いた速度（他のギミックが変えたかの判定に使う）

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

    // ratio < 1 の間だけ移動速度を ratio 倍にする。ratio が変われば掛け直す
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
            // 今の速度＝元の速度なので、次の SetRatio で 3 つとも書き換わる
            _myWalk = _baseWalk; _myRun = _baseRun; _myStrafe = _baseStrafe;
            SetRatio(local, ratio);
            _slowed = true;
        }
        else if (want && Mathf.Abs(ratio - _slowRatio) > 1e-4f)
        {
            SetRatio(local, ratio);
        }
        else if (!want && _slowed)
        {
            RestoreSpeed();
        }
    }

    // 速度を「元の速度 × ratio」にする。自分が設定した値のままの速度だけ書き換える（後から他のギミックが変えた速度は触らない）
    private void SetRatio(VRCPlayerApi local, float ratio)
    {
        // 項目ごとに、最後に自分が書いた値のままのときだけ書き換える（書かなかった項目は、他のギミックが戻すのを待つ）
        if (Mathf.Abs(local.GetWalkSpeed() - _myWalk) < 0.001f) { _myWalk = _baseWalk * ratio; local.SetWalkSpeed(_myWalk); }
        if (Mathf.Abs(local.GetRunSpeed() - _myRun) < 0.001f) { _myRun = _baseRun * ratio; local.SetRunSpeed(_myRun); }
        if (Mathf.Abs(local.GetStrafeSpeed() - _myStrafe) < 0.001f) { _myStrafe = _baseStrafe * ratio; local.SetStrafeSpeed(_myStrafe); }
        _slowRatio = ratio;
    }

    private void RestoreSpeed()
    {
        if (!_slowed) { return; }
        _slowed = false;
        VRCPlayerApi local = Networking.LocalPlayer;
        if (!Utilities.IsValid(local)) { return; }
        SetRatio(local, 1f);
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
