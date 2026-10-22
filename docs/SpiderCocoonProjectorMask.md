# 受け手マスク（SpiderCocoonProjectorMask）

シェーダー名: `mecaota/SpiderCocoonProjectorMask`

> **試験実装です。** 実機の VRChat（VR の両目・ミラー・多人数）での確認は済んでいません。駆動する Udon は [`SpiderCocoonProjectorMaskDriver`](#駆動スクリプトspidercocoonprojectormaskdriver) として同梱しています。

## ひとことで

[体に張り付く繭](SpiderCocoonDepthDecal.md)を、**捕まった人のアバターにだけ**描くための目印を付けるシェーダーです。色は一切塗りません。

- 体に張り付く繭は「深度テクスチャに写っている、円筒の中の面」ならどこにでも繭を描くので、円筒に入った床・木・壁や、隣に立つ別の人にも繭が乗ることがあります。
- このシェーダーを Projector で使うと、捕まった人のアバターの見えている画素にだけ、ステンシルの目印（ビット 32）が立ちます。繭のマテリアルを「目印のある画素にだけ描く」設定にすると、床・壁・隣の人には繭が出なくなります。
- 対応環境: **PC 専用**（体に張り付く繭と同じ）。Unity Built-in Render Pipeline。

## しくみ（シェーダー初心者向け）

- **ステンシル**は、画面の画素ごとに持てる 8 ビットの小さなメモです。このパッケージでは 128 ＝ 視界ジャックの内壁、64 ＝ 吐いた糸の芯、**32 ＝ 受け手（繭を描いてよいアバター）**、16 ＝ 蜘蛛の体（ワールド側のシェーダーが立てる）に使います。
- Unity の **Projector** は「投影範囲に入ったレンダラーを、Projector のマテリアルでもう一度描く」部品です。Projector の Ignore Layers で `Player`・`PlayerLocal`・`MirrorReflection` 以外をすべて無視すると、アバターのメッシュだけがこのシェーダーで描き直されます。
- このシェーダーは、描き直された相手が捕まった本人かどうかを、相手のメッシュの原点（足元か腰）と、スクリプトが渡す本人の骨の位置で判定します。本人でなければ何も描きません。本人なら、見えている画素（手前の柱・壁・他人には負ける）に目印のビットを立てます。
- 体に張り付く繭は輪郭の少し外（糸の厚みの分）にも糸を盛るので、このシェーダーも頂点を同じ幅だけ外へ膨らませます。

## セットアップ

1. **マテリアル**: `mecaota/SpiderCocoonProjectorMask` のマテリアルを、**Projector 1 つにつき 1 つ**作ります（共有すると全員が同じ人として扱われます）。「輪郭の外への膨張」は繭のマテリアルの「糸の厚み」（`_GlueThickness`）と同じ値にします。
2. **Projector**: 空の GameObject に Projector を付けます。
   - Orthographic を ON。Orthographic Size は 1.2 前後（両腕を広げた幅の半分より少し大きく）。Near Clip Plane は 0.1、Far Clip Plane は 3（頭の上 0.5 m から足元まで届く長さ）。
   - 向きと位置は駆動スクリプトが毎フレーム決めます（捕まった人の頭の上から真下へ）。
   - Ignore Layers ＝ `Player`・`PlayerLocal`・`MirrorReflection` **以外すべて**。
   - GameObject 自身のレイヤーは Default（ミラーに映るレイヤー。ミラーの中でも目印が立ちます）。
   - Material ＝ 1 のマテリアル。
3. **繭のマテリアル**: 体に張り付く繭のマテリアルを `_GlueStencilRef` 32 / `_GlueStencilReadMask` 240 にします（[レンダーステート](SpiderCocoonDepthDecal.md#レンダーステート固有)）。
4. **駆動スクリプト**: 別の GameObject に [`SpiderCocoonProjectorMaskDriver`](#駆動スクリプトspidercocoonprojectormaskdriver) を付け、Projector Transform に 2 の GameObject、Mask Material に 1 のマテリアルを入れます。捕まった人が決まったら、捕獲を扱うスクリプトから `SetOwner(playerId)` を呼びます。

## 駆動スクリプト（SpiderCocoonProjectorMaskDriver）

`Runtime/CocoonProjectorMask/SpiderCocoonProjectorMaskDriver.cs`。毎フレーム、マスクのマテリアルに `_OwnerRoot`（足元）・`_OwnerHips`（腰）・`_OwnerPt0`〜`_OwnerPt5`（頭・胸・左手・右手・左足・右足）を `Material.SetVector` で渡し（xyz ＝ 位置、w ＝ 許容半径 m）、Projector を捕まった人の頭の上へ動かして真下へ向けます。誰も捕まっていない間は、Projector の GameObject を無効にして、描き直しの負荷をなくします。

| 設定項目 | 既定値 | 説明 |
|---|---|---|
| Projector Transform | （必須） | Projector を付けた GameObject。誰もいない間は GameObject ごと無効にするので、**このスクリプトとは別の GameObject** にする |
| Mask Material | （必須） | Projector に入れたマスクのマテリアル |
| Follow Local Player | OFF | ON で、`SetOwner` を呼ばなくても自分を対象にする（動作確認用。デバッグ表示と組み合わせると、自分の体に緑が乗るのを確かめられる） |
| Height Above Head | 0.5 | 頭からどれだけ上に Projector を置くか m |
| Root Radius | 0.35 | アバターのメッシュの原点が足元からこの距離以内なら本人とみなす |
| Hips Radius | 0.35 | 原点が腰の骨からこの距離以内なら本人とみなす |
| Attachment Radius | 0.25 | 手に持つ物・帽子・靴など骨の下の物の原点が、頭・胸・両手・両足からこの距離以内なら本人の物とみなす。0 で使わない |

| メソッド | 内容 |
|---|---|
| `SetOwner(int playerId)` | この人のアバターにだけ繭を描かせる |
| `ClearOwner()` | やめる（Projector を無効にする） |
| `GetOwnerId()` | 今の対象の playerId（いなければ 0） |

- 対象の人が退室すると自動で `ClearOwner` します。
- このスクリプトは同期しません。全員に同じ見え方をさせたいときは、捕獲を同期しているスクリプトから、全員のクライアントで `SetOwner` を呼びます。
- 同時に何人もの繭を描き分けるときは、人数分の「Projector ＋ マスクのマテリアル ＋ 駆動スクリプト」を用意します。

## インスペクタの項目

Unity 標準のインスペクタで表示されます（このパッケージの専用インスペクタ・プリセット・質感の継承には対応していません）。

| 表示名 | 内部名 | 既定値 | 説明 |
|---|---|---|---|
| 受け手ビット | `_StencilReceiverBit` | 32 | 立てるビット。繭のマテリアルの `_GlueStencilRef` と同じ値にする（64・128 は使えない） |
| 輪郭の外への膨張 m | `_Inflate` | 0.06 | 繭のマテリアルの「糸の厚み」と同じ値にする |
| 対象 | `_OwnerMode` | 所有者のみ | 0 ＝ 投影範囲の全員、1 ＝ 所有者（捕まった人）だけ |
| 所有者のルート / 腰 | `_OwnerRoot` / `_OwnerHips` | (0,-9999,0,0) | xyz ＝ 位置、w ＝ 許容半径 m。スクリプトが毎フレーム設定 |
| 所有者の頭・胸・両手・両足 | `_OwnerPt0`〜`_OwnerPt5` | (0,-9999,0,0) | 手に持つ物・帽子・靴など骨の下の物の原点がここに近ければ、本人の物として受け入れる。w ≤ 0 で無効 |
| 視錐台の外を切る | `_FrustumClip` | OFF | 全員モードで範囲を絞るときだけ ON |
| デバッグ表示 | `_DebugView` | Off | On で目印が立つ範囲を緑で塗る（確認用） |

## 描画について

- 描画順は `Transparent-100`（2900）です。アバター（不透明 2000、カットアウト 2450、lilToon の半透明 2460 など）の後、吐いた糸（2990）と繭（3000）の前に描きます。
- Frame Debugger で、アバター → このマスク → 吐いた糸の `DEPTHSOLID` → 体に張り付く繭のパス 2、の順に並んでいることを確かめてください。

## 注意・制約

- `IgnoreProjector` が ON のアバターのマテリアル（Standard の Fade / Transparent など）には目印が立たず、その部位には繭が出ません。
- マスク（2900）より後でステンシルを書き換える（Replace する）アバターの部位では目印が消え、その部位には繭が出ません。
- Default レイヤーを映さないミラー（低画質のミラーなど）の中では繭が出ません。
- VR のシングルパスインスタンシングでは、Projector が片目にしか描かれない Unity の既知の問題があります。
- 実機の VRChat（VR の両目・ミラー・多人数）での確認は済んでいません。

## 関連ファイル

| ファイル | 内容 |
|---|---|
| `Runtime/SpiderCocoonProjectorMask.shader` | シェーダー本体（先頭のコメントにセットアップの要点あり） |
| `Runtime/CocoonProjectorMask/SpiderCocoonProjectorMaskDriver.cs` | 駆動スクリプト |
