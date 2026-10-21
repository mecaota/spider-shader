# SurfaceContactDeformer

蜘蛛の巣・繭・ねばねばネット（`mecaota/SpiderWeb`・`mecaota/SpiderCocoon`・`mecaota/SpiderGooSilkSheet`。マテリアルの「接触追従の変形」を ON）に手足が触れた場所を、その手足に追従させて伸ばしたり凹ませたりする Udon ギミックです。見た目だけの表現で、プレイヤーの移動は拘束しません。

| スクリプト | 役割 |
|---|---|
| `SurfaceContactDeformer.cs` | 面ごとに付ける本体。捕縛の判定・同期と、シェーダーへの値の受け渡し |
| `SurfaceContactDeformerManager.cs` | 多数の面をまとめて動かす管理役（シーンに 1 つ・任意） |
| `TrackBone.cs` | 追従するボーンの種類の定義 |

セットアップ手順・全設定項目・注意点は、GitHub のドキュメントを参照してください。

- [Udon ギミック > 接触追従の変形（SurfaceContactDeformer）](https://github.com/mecaota/spider-shader/blob/main/docs/UdonGimmicks.md#接触追従の変形surfacecontactdeformer)

## スロットの状態を外から読む

別の UdonSharp スクリプトから「どのスロットに、誰の、どの部位が付いているか」を読めます（読み取り専用。同期や捕縛の状態は変えません）。

| メソッド | 返す値 |
|---|---|
| `GetSlotCount()` | スロットの総数（16） |
| `GetOccupiedSlotMask()` | 誰かが付いているスロットのビットマスク（bit i = スロット i。0 なら誰も付いていない） |
| `GetOccupiedSlotCount()` | 誰かが付いているスロットの数 |
| `GetSlotPlayerId(int slot)` | 付いている人の `playerId`（空き 0、範囲外 -1） |
| `GetSlotBoneIndex(int slot)` | 付いているボーンの `Bones` での番号（空き・範囲外 -1） |
| `GetSlotHumanBone(int slot)` | 付いているボーンの `HumanBodyBones` の値（空き・範囲外 -1） |

```csharp
int mask = deformer.GetOccupiedSlotMask();   // 0 なら誰も付いていないので、すぐ次の巣へ
if (mask != 0)
{
    int slots = deformer.GetSlotCount();
    for (int s = 0; s < slots; s++)
    {
        if ((mask & (1 << s)) == 0) { continue; }
        int playerId = deformer.GetSlotPlayerId(s);
        int bone = deformer.GetSlotHumanBone(s);
        if (playerId <= 0 || bone < 0) { continue; }
        HumanBodyBones part = (HumanBodyBones)bone; // playerId の人の part に糸が付いている
    }
}
```

ビットマスクはスロットが変わったとき（同期を受け取ったとき・オーナーが書き換えたとき）だけ作り直すので、多数の巣を毎フレーム少しずつ調べても軽く済みます。詳しい説明と注意点は [スロットの状態を外から読む](https://github.com/mecaota/spider-shader/blob/main/docs/UdonGimmicks.md#スロットの状態を外から読む) を参照してください。
