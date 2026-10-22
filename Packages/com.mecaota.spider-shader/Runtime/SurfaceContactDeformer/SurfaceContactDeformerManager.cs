using UdonSharp;
using UnityEngine;

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
/// くっついている間の減速は、以前はここで行っていたが restraint の PlayerSpeedLimiter へ移した
/// （各 Deformer の localStuckReceivers から「くっついた」「全部はがれた」を送る）
/// </summary>
[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class SurfaceContactDeformerManager : UdonSharpBehaviour
{
    private const int Capacity = 256;

    private SurfaceContactDeformer[] _active = new SurfaceContactDeformer[Capacity];
    private int _count = 0;

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

    // 外から読む用: いま登録されている（捕縛中、またはローカルがトリガーの中にいる）巣の数と、その i 番目。
    // 誰かが付いている巣は必ずこの中にいるので、スロットを調べるスクリプトは全部の巣ではなくここだけを回ればよい。
    // 並びは登録・解除で入れ替わるので、番号を次のフレームまで持ち越さない
    public int GetActiveCount()
    {
        return _count;
    }

    public SurfaceContactDeformer GetActive(int i)
    {
        if (i < 0 || i >= _count) { return null; }
        return _active[i];
    }

    public override void PostLateUpdate()
    {
        // Tick 中に Unregister されると詰めで同じ index に別要素が来るので、
        // 末尾から回して安全に走査する
        for (int i = _count - 1; i >= 0; i--)
        {
            var d = _active[i];
            if (d == null) { continue; }
            d.Tick();
        }
    }
}
