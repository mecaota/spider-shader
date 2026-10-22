# SurfaceContactDeformer

蜘蛛の巣・繭・蜘蛛の巣ドレープ（`mecaota/SpiderWeb`・`mecaota/Cocoon`・`mecaota/SpiderWebDrape`。マテリアルの「接触追従の変形」を ON）に手足が触れた場所を、その手足に追従させて伸ばしたり凹ませたりする Udon ギミックです。見た目だけの表現で、プレイヤーの移動は拘束しません。

| スクリプト | 役割 |
|---|---|
| `SurfaceContactDeformer.cs` | 面ごとに付ける本体。捕縛の判定・同期と、シェーダーへの値の受け渡し |
| `SurfaceContactDeformerManager.cs` | 多数の面をまとめて動かす管理役（シーンに 1 つ・任意） |
| `TrackBone.cs` | 追従するボーンの種類の定義 |

セットアップ手順・全設定項目・注意点は、GitHub のドキュメントを参照してください。

- [Udon ギミック > 接触追従の変形（SurfaceContactDeformer）](https://github.com/mecaota/spider-shader/blob/main/docs/UdonGimmicks.md#接触追従の変形surfacecontactdeformer)
- [Udon ギミック > スロットの状態を外から読む](https://github.com/mecaota/spider-shader/blob/main/docs/UdonGimmicks.md#スロットの状態を外から読む) — 別のスクリプトから「どのスロットに、誰の、どの部位が付いているか」を読む方法
