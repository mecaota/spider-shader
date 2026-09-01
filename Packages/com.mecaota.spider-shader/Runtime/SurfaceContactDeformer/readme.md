# SurfaceContactDeformer

## 概要

蜘蛛の巣や繭（`mecaota/SpiderWeb`／`mecaota/SpiderCocoon`シェーダー、`_PullEnable`ON）に手足が触れた場所を、その手足に追従させて伸ばしたり凹ませたりするギミックです。見た目だけで、プレイヤーの移動は拘束しません。

`Bones`配列に指定したボーンが面から`Contact Distance`以内に来るとその場で捕縛され、触れた点をスロットに記録します。以後は全クライアントが毎フレーム各スロットのボーン位置を読み、`MaterialPropertyBlock`の配列でシェーダーへ「捕縛点（`_PullAnchors`）」「追従先（`_PullTargets`）」「有効数（`_PullCount`）」を渡します。触れた瞬間は変位ゼロで、手足を上げれば伸び、押し込めば凹みます。捕縛点から一定距離離れたスロットは「千切れた」として個別に解放します。

複数プレイヤーが同時に触れられます（スロットは最大16本を全員で先着共有）。同期はオーナー集約方式で、各クライアントは自分のボーンだけ判定し、`[NetworkCallable]`の`ClaimSlot`／`ReleaseSlot`をオーナーへ送ります。オーナーだけが同期配列を書くので、更新の取りこぼしが起きません。

## セットアップ

1. 平面の巣は`Tools/SpiderShader/Generate WebPlane Mesh...`で細分化平面メッシュ（`WebPlane.asset`）を生成して使います（Unity標準のPlaneは粗すぎます）。球・円柱は標準メッシュでも動きますが、細かい変形には細分化したメッシュが必要です。
2. `MeshRenderer`にSpiderWeb／SpiderCocoonマテリアル（`_PullEnable`ON、GPU Instancing OFF）を割り当てます。
3. 同じGameObjectにトリガーコライダー（`Is Trigger`ON）と本コンポーネントを付け、`Target Renderer`にそのRendererを設定します。同期モードはManualです。
4. GameObjectの`Batching Static`はOFFにしてください（結合メッシュになると拡張バウンズが失われます）。

## 設定項目

### 対象

#### Target Renderer

SpiderWeb／SpiderCocoonマテリアルを付けたRendererです。

#### Bones

追従するボーンの配列（任意本数）。面に触れたものから順に捕縛されます。そのボーンが無いアバターではそのスロットは捕縛されません。

#### Decors

誰か1人でも捕縛中のときだけ表示する装飾（任意）。

### 面の形

#### Shape

`Plane`（ローカルXZ平面・法線+Y）／`Sphere`（原点中心）／`Cylinder`（Y軸）。

#### Capture Radius Local

Planeのとき、面の中心からこの半径（ローカル単位）内だけ捕縛します。SpiderWebの`_WebRadius`に合わせます。

#### Surface Radius Local／Surface Half Height Local

Sphere／Cylinderの半径と、Cylinderの半高（ローカル単位。標準メッシュは半径0.5・半高1）。

### 捕縛

#### Contact Distance

面からこの距離（m）以内に来たボーンを捕縛します（面のどちら側でも）。

#### Auto Release Distance

手足が捕縛点からこの距離（m）以上離れたら千切れてそのスロットを解放します。0で無効。シェーダーの`_PullMaxStretch`＋`_PullTearFade`と揃えると、糸が戻る演出と解放が一致します。

#### Recapture Cooldown

千切れ・解放してからこの秒数は同じボーンを再捕縛しません。

#### Pending Timeout

捕縛要求をオーナーへ送ってから、同期が届くまで再送しない秒数。

#### Require Trigger

ONのとき、トリガー内にいる間だけ新しい接触を捕縛します（通りすがりの誤爆防止）。手の巣のように体のカプセルから離れた面ではOFFにします。

#### Manager

多数の巣を置くとき、各 Deformer が毎フレーム PostLateUpdate を回すと重いので、シーンに1個 `SurfaceContactDeformerManager` を置き、各 Deformer の `Manager` に設定します。Deformer は「捕縛が有効 or ローカルがトリガー内」のときだけマネージャーに登録され、そのときだけ Tick されます（アイドル時はマネージャー1個分のコスト）。未設定でも各自 PostLateUpdate で動きます（少数向け）。

#### Bone Surfaces

`bones` と並行の Transform 配列。1つのレンダラーに複数の面を焼き込んだ結合メッシュで、ボーンごとに別の面を接触判定・投影の基準にしたいとき指定します。null／要素 null は自身の transform を使います。

#### Wrap By Bone／Wrap Scale By Bone

捕縛されたボーンに付ける GameObject（デカール繭の円柱など）を `bones` と並行で指定します。捕縛中はそのボーンの位置・節方向へ毎フレーム追従し、解放で非表示になります。UdonBehaviour を持たない素の GameObject で構いません（このスクリプトが直接 Transform を動かします）。

#### Contact Distance By Bone

`bones` と並行の接触距離配列。足首・手首など末端より1つ根側のボーン（すね・前腕）は面から離れるので、ボーンごとに広げられます。null／長さ不一致なら共通の `Contact Distance` を使います。

## 注意

- 配列uniformは最初に渡した長さで固定されるため、常に16要素の配列を渡しています。シェーダー側の`SC_PULL_MAX`と`MaxSlots`を揃えてください。
- 非アクティブなUdonBehaviourではイベントが走りません。面を隠すときは`SetActive(false)`ではなく`Renderer.enabled`を使ってください。
- ClientSimではネットワークイベントのリモート経路とボーン情報が不完全なため、複数人の同時捕縛は実機（Build & Test）で確認してください。
