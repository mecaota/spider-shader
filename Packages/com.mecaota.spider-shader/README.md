# Spider Shaders（com.mecaota.spider-shader）

蜘蛛の巣・繭で捕らわれる「疑似拘束」を表現するための、VRChat ワールド向けシェーダー集です。**Unity Built-in Render Pipeline 専用**（URP / HDRP 非対応）。

使い方とすべての設定項目の説明は、GitHub のドキュメントにまとめています。

- [README（概要・インストール・はじめての使い方・困ったとき）](https://github.com/mecaota/spider-shader#readme)

## シェーダー

| シェーダー | 何を描くか | ドキュメント |
|---|---|---|
| `mecaota/SpiderThreadTrail` | 蜘蛛が吐いた糸（Trail / Particle Trails / LineRenderer） | [吐いた糸](https://github.com/mecaota/spider-shader/blob/main/docs/SpiderThreadTrail.md) |
| `mecaota/SpiderWeb` | 蜘蛛の巣（平面・球・扇形・曲面） | [蜘蛛の巣](https://github.com/mecaota/spider-shader/blob/main/docs/SpiderWeb.md) |
| `mecaota/SpiderCocoon` | 円柱の繭（中に入ると内壁に包まれる） | [繭](https://github.com/mecaota/spider-shader/blob/main/docs/SpiderCocoon.md) |
| `mecaota/SpiderCocoonDepthDecal` | 体の表面に張り付く繭（PC 専用・影付きライト必須） | [体に張り付く繭](https://github.com/mecaota/spider-shader/blob/main/docs/SpiderCocoonDepthDecal.md) |
| `mecaota/SpiderGooSilkSheet` | 体にかぶさる粘液のシート（PC 専用・焼き込みが必要） | [ねばねばネット](https://github.com/mecaota/spider-shader/blob/main/docs/SpiderGooSilkSheet.md) |
| `mecaota/SpiderCocoonProjectorMask` | 体に張り付く繭をアバターにだけ描くための目印（試験実装・PC 専用。駆動は `Runtime/CocoonProjectorMask`） | [受け手マスク](https://github.com/mecaota/spider-shader/blob/main/docs/SpiderCocoonProjectorMask.md) |

## 共通機能・Udon ギミック

- [共通機能](https://github.com/mecaota/spider-shader/blob/main/docs/CommonFeatures.md) — インスペクタの見方・質感の継承・プリセット・Editor のメニュー
- [Udon ギミック](https://github.com/mecaota/spider-shader/blob/main/docs/UdonGimmicks.md) — 接触追従の変形（`Runtime/SurfaceContactDeformer`）・繭のまとめ描き（`Runtime/CocoonGroupLinker`）・体に覆いかぶさる変形（`Runtime/WebDrape`）
  - 接触追従の変形は、どのスロットに誰のどの部位が付いているかを別のスクリプトから読めます（[スロットの状態を外から読む](https://github.com/mecaota/spider-shader/blob/main/docs/UdonGimmicks.md#スロットの状態を外から読む)）

## 動作環境

- Unity 2022.3 / Built-in Render Pipeline
- VRChat Worlds SDK 3.8.1 以上（UdonSharp を含む）

## ライセンス

MIT License（同梱の `LICENSE`）
