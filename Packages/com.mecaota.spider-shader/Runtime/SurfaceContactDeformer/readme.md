# SurfaceContactDeformer

## 概要

蜘蛛の巣や繭（`mecaota/SpiderWeb`／`mecaota/SpiderCocoon`シェーダー、`_PullEnable`ON）に手足が触れた場所を、その手足に追従させて伸ばしたり凹ませたりするギミックです。見た目だけで、プレイヤーの移動は拘束しません。

`Bones`配列に指定したボーンが面から`Contact Distance`以内に来るとその場で捕縛され、触れた点をスロットに記録します。以後は全クライアントが毎フレーム各スロットのボーン位置を読み、`MaterialPropertyBlock`の配列でシェーダーへ「捕縛点（`_PullAnchors`）」「追従先（`_PullTargets`）」「有効数（`_PullCount`）」を渡します。触れた瞬間は変位ゼロで、手足を上げれば伸び、押し込めば凹みます（`Pull Only` ON なら凹まず、引っ張る向きにだけ追従します）。捕縛点から一定距離離れたスロットは「千切れた」として個別に解放します。

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

`Plane`（ローカルXZ平面・法線+Y）／`Sphere`（原点中心）／`Cylinder`（Y軸）／`TreeFan`（木の幹＝ローカルY軸に張り付き、+Z側の地面へ扇形に広がる曲面。`Tree*` の項目で形を指定し、`TreeWebFanBuilder` が木ごとに書き込む）。

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

`bones` と並行の接触距離配列。`Segment Contact` がOFFのときは、足首・手首など末端より1つ根側のボーン（すね・前腕）は面から離れるので、ボーンごとに広げられます。null／長さ不一致なら共通の `Contact Distance` を使います。

### くっつき方

#### Segment Contact

ONのとき、ボーンの「点」ではなく「区間」（そのボーン→子ボーン。すねなら膝→足首、前腕なら肘→手首）と面の距離で判定します。区間を9点で調べ、面に一番近い点が接触距離以内になった瞬間（手足の表面が初めて触れた瞬間）にくっつきます。区間のどこが触れたか（0〜1の割合）も同期し、以後はその点に面を追従させ、巻き付き円柱（Wrap）もその点に付けます。接触距離は「区間の中心線から面まで」なので、手足の太さ＋少しの余裕にします。

#### Pull Only

ONのとき、くっついた後は「くっついた側へ引っ張る向き」と面に沿った向きにだけ追従します。手足を面に近づけても面の奥へは凹みません（追従先から「面の奥へ押し込む向き」の成分を取り除きます）。手足を離す向きへ動かすと伸び、`Auto Release Distance` を超えると千切れます。

#### Slow Local When Stuck／Stuck Speed Ratio

ONのとき、ローカルプレイヤーがどこか1か所でもくっついている間、歩き・走り・横歩きの速度を `Stuck Speed Ratio` 倍（既定 1/3）にします。どのボーンがくっついていても同じです。適用と解除は `SurfaceContactDeformerManager` がまとめて行うので、`Manager` の設定が必要です。複数の巣にくっついても重ね掛けせず、くっついている巣のうち一番小さい倍率を1回だけ掛けます。くっついている巣が変われば掛け直します。解除と掛け直しは「自分が設定した値のままのとき」だけ行います（他のギミックが後から変えた速度は上書きしません）。

### 粘液の糸

#### Thread By Slot

くっついた場所（面）とボーンの間に張る粘液の糸（`LineRenderer`、任意）。スロットごとに1本、最大16本です。同期済みのスロットから描くので、追加の通信はありません。伸びるほど細り、千切れると消えます。

LineRenderer は次のように設定します。

- `Texture Mode` は `Stretch`。uv.x が糸全体で0〜1になる前提です。`Tile` だとたわみが先頭1mにしか掛かりません。
- `Use World Space` は ON。頂点をワールド座標で渡します。
- 初期状態は無効で構いません。使うときにスクリプトが有効にします。
- マテリアルは `SpiderThreadTrail` の粘液マテリアルです。`_GravityUseUV` などはスクリプトが設定します。

#### Thread From Deformed Web

ONのとき、糸の始点を変形後の巣の面にします。凹み・伸びと糸を併用する巣（落とし穴の巣など）で使います。

#### ClaimLocalBone（スクリプトから呼ぶ）

外部スクリプト（落とし穴の罠など）が、ローカルプレイヤーのボーンを指定の捕縛点で捕縛させます。引数はボーン番号（`Bones` の順）、捕縛点（面のローカル座標）、区間上の位置（0〜1）です。自動の接触判定は通りません。送信は1秒20回までなので、何本も送るときは間隔を空けます。

終わったら `_ReleaseLocalBones` を呼びます。解除後の約3秒は、遅れて届いた捕縛を取り除きます。その後は自動の接触判定に戻ります。

#### RefreshFanShape（スクリプトから呼ぶ）

実行中に巣のマテリアルを切り替えたときに呼びます。捕縛範囲（扇形）と `Thread From Deformed Web` 用の値を読み直します。

### 効果音

#### Contact Audio／Contact Audio Interval

手足がくっついた瞬間に鳴らす `AudioSource`（任意）。くっついた場所へ移して `clip` を `PlayOneShot` します。同期済みのスロットが増えたのを各クライアントが見て鳴らすので、周りの人にも同じ場所で聞こえます（本人はオーナーへの捕縛要求が往復するぶん少し遅れて鳴ります）。すね→もも→腰…と続けてくっつくので、`Contact Audio Interval` 秒（既定 0.4）に1回までにしています。途中入室した人には、入室直後に届いた既存の捕縛ぶんは鳴らしません。木のステーション（TreeWebStation.prefab）は子の `StickySE`（`audios/sticky.wav`、3D）を指定しています。

### 固定設置の巣の共通設定

全ての固定設置の巣（木のステーション・Web/WebPlane・Nest/WebPlane・Web/WebSphere・フォトコーナーの足元/手の巣）は次の設定で揃えています（`Tools/SpiderPhoto` の Unit9／10／11 も同じ設定で生成します）。飛ばした網（StickyNet）はこの対象外です。

| 項目 | 値 |
|---|---|
| Bones | 左右のすね（LowerLeg）・もも（UpperLeg）・前腕（LowerArm）・上腕（UpperArm）、腰（Hips）、首（Neck） |
| Contact Distance By Bone | すね 0.09 / もも 0.12 / 前腕 0.07 / 上腕 0.08 / 腰 0.15 / 首 0.08（m、区間の中心線から） |
| Segment Contact / Pull Only / Slow Local When Stuck | ON / ON / ON（速度 1/3） |
| Capture Only Below Surface | OFF（初めて触れた時にくっつく） |

## 注意

- 配列uniformは最初に渡した長さで固定されるため、常に16要素の配列を渡しています。シェーダー側の`SC_PULL_MAX`と`MaxSlots`を揃えてください。
- 非アクティブなUdonBehaviourではイベントが走りません。面を隠すときは`SetActive(false)`ではなく`Renderer.enabled`を使ってください。
- ClientSimではネットワークイベントのリモート経路とボーン情報が不完全なため、複数人の同時捕縛は実機（Build & Test）で確認してください。
