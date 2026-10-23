# Udon ギミック（変形・まとめ描き）

[← README に戻る](../README.md)

シェーダーだけではできない「プレイヤーの手足に合わせて動く」表現を、Udon（UdonSharp）と組み合わせて作るためのページです。

| ギミック | 同梱 | 対応シェーダー | 何ができるか |
|---|---|---|---|
| [接触追従の変形](#接触追従の変形surfacecontactdeformer) | ○ `SurfaceContactDeformer` | 蜘蛛の巣・繭・蜘蛛の巣ドレープ | 手足が触れた所が貼り付き、上げると伸び、押すと凹む |
| [繭のまとめ描き](#繭のまとめ描きcocoongrouplinker) | ○ `CocoonGroupLinker` | 体に張り付く繭 | くっついた複数の繭を、同じ糸でまとめて巻いたように描く |
| [体に覆いかぶさる変形](#体に覆いかぶさる変形drape) | ○ `SpiderWebDrapeDriver` | 蜘蛛の巣・蜘蛛の巣ドレープ | 投げた網が体の形に沿ってかぶさる |
| [繭プロジェクターの駆動](CocoonProjector.md#駆動スクリプトspidercocoonprojectormaskdriver) | ○ `SpiderCocoonProjectorMaskDriver` | 繭プロジェクター（体に張り付く繭と組む） | 体に張り付く繭を、捕まった人のアバターにだけ描く |

**前提**: VRChat Worlds SDK 3.8.1 以上（UdonSharp を含む）が入ったプロジェクトが必要です。

### しくみの共通点（初心者向け）

シェーダーは GPU で動くので、「プレイヤーの足がどこにあるか」を自分では知りません。そこで Udon が毎フレームボーンの位置を読み、**MaterialPropertyBlock**（Renderer ごとにマテリアルの値を上書きできる入れ物）でシェーダーへ渡します。Web でいえば、JavaScript が DOM 要素の `style` に CSS 変数を毎フレーム書き込み、CSS 側がその変数で見た目を変えるイメージです。

MaterialPropertyBlock で渡す値は .mat に保存されず、インスペクタにも出ません（「Udonが設定」と書かれた項目はその目印です）。

---

## 接触追従の変形（SurfaceContactDeformer）

地面に張った蜘蛛の巣に足を踏み入れると足が捕らわれ、**足を上げると巣がその部分だけ伸びる**表現です。巣の端（地面への係留）は動きません。見た目だけの表現で、プレイヤーの移動は拘束しません（[くっついている間だけ遅くする](#くっついたときの通知local-stuck-receivers)こともできます）。手足が捕まった点から一定距離離れると「千切れて」元に戻ります。

### なぜ PhysBone ではないのか

ワールド側の PhysBone は、アバターのコライダーに押しのけられるだけで、足に付着・追従しません。そこで「Udon が足のボーンの位置を読み、シェーダーが頂点を動かす」方式にしています。

### しくみ

1. `SurfaceContactDeformer` は、指定したボーンが面に一定距離まで近づくと、その場所を**捕縛点**として記録し、全員に同期します（スロットは最大 16 本を全員で先着共有）。
2. 以後は全員のクライアントが毎フレーム、各スロットのボーンの現在位置（**追従先**）を読み、MaterialPropertyBlock の配列でシェーダーへ渡します。
3. シェーダーの頂点処理が、捕縛点から「引っ張り半径」以内の頂点に、「捕縛点 → 追従先」のずれを距離に応じて弱めながら足します。面から離せば伸び、押し込めば凹みます。半径の外はまったく動かないので、メッシュの端は固定されたままです。
4. 糸の模様は UV で決まるので、頂点が動いても糸は面に貼りついたまま伸びます。陰影も、動いた後の面の傾きから計算し直します。

### セットアップ

1. 面のメッシュを用意します。平面の巣は **Tools > SpiderShader > Generate WebPlane Mesh...** で作った WebPlane を使います（Unity 標準の Plane は分割が粗すぎます）。球・円柱は標準メッシュでも動きますが、細かく変形させるには細かく分割したメッシュが必要です。
2. MeshRenderer に、蜘蛛の巣・繭・蜘蛛の巣ドレープのマテリアルを入れ、「接触追従の変形 有効」を ON にします。
3. マテリアルの **Enable GPU Instancing を OFF**、GameObject の **Static（Batching Static）を OFF** にします。
4. 同じ GameObject に**トリガーコライダー**（Is Trigger を ON）を付けます。範囲は面とその上の手足が入るくらいにします。
5. 同じ GameObject に `SurfaceContactDeformer` を追加し、**Target Renderer** にその Renderer、**Bones** に追従させたいボーンを設定します（同期モードは自動で Manual になります）。
6. 巣を多数置くときは、シーンに 1 つ `SurfaceContactDeformerManager` を置き、各 Deformer の **Manager** に設定します。

### シェーダー側の設定（接触追従の変形）

蜘蛛の巣・繭・蜘蛛の巣ドレープのインスペクタの「接触追従の変形（固有）」にある項目です。

| 表示名 | 内部名 | 既定値 | 説明 |
|---|---|---|---|
| 接触追従の変形 有効 | `_PullEnable` | OFF | ON で変形する。OFF なら頂点はまったく動かない |
| 引っ張り半径 m | `_PullRadius` | 巣 0.5 / 繭 0.3 / 蜘蛛の巣ドレープ 0.5 | 捕縛点からこの距離以内の頂点が引かれる。外は動かない |
| 減衰の鋭さ | `_PullFalloff` | 1.5 | 大きいほど捕縛点の近くだけが鋭く持ち上がる |
| 引っ張り強さ | `_PullStrength` | 1 | 1 で捕縛点が手足に完全に追従する |
| 千切れ開始距離 m 0で無効 | `_PullMaxStretch` | 0 | 伸びがこの距離を超えると糸が千切れて戻り始める |
| 千切れフェード幅 m | `_PullTearFade` | 0.3 | 千切れて戻り切るまでの距離の幅 |
| 有効スロット数 Udonが設定 | `_PullCount` | 0 | Udon が設定する値。手で触らない（プリセットにも保存されない） |

Udon が MaterialPropertyBlock で渡す配列（インスペクタには出ません）:

| 名前 | 内容 |
|---|---|
| `_PullAnchors[16]` | 捕縛点（ワールド座標 xyz）。w が 1 のスロットだけ有効 |
| `_PullTargets[16]` | 追従先＝手足の今の位置（ワールド座標 xyz） |

> 「千切れ開始距離＋フェード幅」と、Deformer の **Auto Release Distance** をそろえると、糸が戻る見た目とスロットの解放のタイミングが一致します（例: 0.7 ＋ 0.15 ＝ 0.85 m）。

### SurfaceContactDeformer の設定項目

インスペクタの見出しごとに載せています。「`Bones` と並行」と書いた配列は、`Bones` と同じ順番・同じ長さで並べます。

#### 対象

| 項目 | 既定値 | 説明 |
|---|---|---|
| Target Renderer | （自分の Renderer） | 「接触追従の変形」を ON にしたマテリアルを付けた Renderer |
| Manager | なし | `SurfaceContactDeformerManager`。多数の巣を置くときに設定（下の「Manager」） |
| Bones | 左右のすね | 追従するボーンの配列（任意の本数）。面に触れたものから順に捕縛される |
| Bone Surfaces | なし | `Bones` と並行。1 つの Renderer に複数の面をまとめたメッシュで、ボーンごとに別の面を基準にしたいとき指定。空なら自分の Transform |
| Wrap By Bone | なし | `Bones` と並行。捕縛されたボーンに付ける GameObject（[繭デカール](CocoonDecal.md)の Cube など）。捕縛中はそのボーンの位置・向きへ毎フレーム追従し、解放で非表示になる。UdonBehaviour の無い普通の GameObject で構わない |
| Wrap Scale By Bone | なし | `Bones` と並行。Wrap のスケール（円柱なら 直径×高さ×直径）。0 なら変えない |
| Decors | なし | 誰か 1 人でも捕縛中のときだけ表示する装飾 |

#### 面の形

| 項目 | 既定値 | 説明 |
|---|---|---|
| Shape | Plane | 接触判定に使う面の形（ローカル空間）。Plane（XZ 平面・上が +Y）／Sphere（原点中心）／Cylinder（Y 軸）／TreeFan（木の幹に張り付く扇形） |
| Capture Radius Local | 0.45 | Plane のとき、面の中心からこの半径（ローカル単位）内だけ捕縛する。巣の「巣の半径」に合わせる（標準プリセットは 0.5） |
| Surface Radius Local | 0.5 | Sphere / Cylinder の半径 |
| Surface Half Height Local | 1 | Cylinder の半分の高さ |

#### 木の幹に張り付く扇形（Shape = TreeFan）

幹（ローカル Y 軸）に張り付き、+Z 側の地面へ扇形に広がる曲面の形です。メッシュと同じ値にそろえます。

> 幹に沿う曲面のメッシュを作るツールは、このパッケージに含まれていません。自分で用意したメッシュの寸法に合わせて、下の値を入れます（メッシュの条件は [蜘蛛の巣の「曲面の巣」](SpiderWeb.md#曲面の巣木の幹に張り付く扇形など)）。

| 項目 | 既定値 | 説明 |
|---|---|---|
| Tree Trunk Radius | 0.25 | 幹の半径＋浮き（m） |
| Tree Hub Height | 1.75 | ハブ（中心結節点）の地面からの高さ（m） |
| Tree Wrap Angle | 95 | 巣が幹を回り込む角度（片側・度） |
| Tree Reach | 1.25 | 正面で、幹の表面から外周（接地線）までの距離（m） |
| Tree Sag | 0.35 | 縦糸のたわみ（0 で直線） |
| Tree Ground | (0,0,0) | 地面の高さの近似平面 y = X·x + Y·z + Z（ローカル） |

#### 捕縛

| 項目 | 既定値 | 説明 |
|---|---|---|
| Contact Distance | 0.2 | 面からこの距離（m）以内に来たボーンを捕縛する（面のどちら側でも） |
| Contact Distance By Bone | なし | ボーンごとの接触距離。`Bones` と同じ順に 1 本ずつ入れる（`Bones` の 1 番目に対応するのは 1 番目の値）。値が無いボーンや 0 以下のボーンは、共通の Contact Distance を使う |
| Auto Release Distance | 0.8 | 手足が捕縛点からこの距離（m）以上離れたら千切れて解放する。0 で無効 |
| Recapture Cooldown | 1 | 解放してからこの秒数は同じボーンを捕縛しない |
| Pending Timeout | 1 | 捕縛の要求を送ってから同期が届くまで、再送しない秒数 |
| Require Trigger | ON | トリガーの中にいる間だけ新しく捕縛する（通りすがりの誤爆防止） |
| Capture Only Below Surface | OFF | Plane のみ。ボーンが面を通り抜けて裏側（-Y 側）に入ってから捕縛する（落とし穴のような巣用） |
| Match Fan Shape | ON | マテリアルが扇形の巣なら、扇の範囲（角度・巣の半径・メッシュの端）の外では捕縛しない。1 m 四方・XZ 平面・UV 0〜1 の WebPlane 用 |

#### くっつき方

| 項目 | 既定値 | 説明 |
|---|---|---|
| Segment Contact | OFF | ON で、ボーンの「点」ではなく「区間」（そのボーン → 子ボーン。すねなら膝 → 足首）と面の距離で判定する。区間を 9 点で調べ、手足の表面が初めて触れた瞬間にくっつき、触れた位置（区間上の割合）も同期する。接触距離は「区間の中心線から面まで」なので、手足の太さ＋少しの余裕にする |
| Pull Only | OFF | ON で、くっついた後は引っ張る向きと面に沿った向きにだけ追従する。手足を面に近づけても面の奥へは凹まない。面のほぼ上（1 cm 未満）でくっついてどちら側か決められないときは効かない |

#### くっついたときの通知（Local Stuck Receivers）

自分がこの巣にくっついた瞬間と、全部はがれた瞬間に、指定した UdonBehaviour へイベントを送ります（任意）。[vrc-restraint-scripts](https://github.com/mecaota/vrc-restraint-scripts) の `PlayerMovementLock` に送ると、**くっついている間だけ歩く・走る・横歩きの速さを落とせます**（0 で動けない、0.5 で半分の速さ）。

`PlayerMovementLock` は、オブジェクト名が `PlayerMovementLock` のものが「まとめ役」（元の速さの保存と復元を受け持つ。1 ワールドに 1 つ）、それ以外の場所に置いたものが「窓口」（イベントを受けて、まとめ役に減速を頼む）になります。巣につなぐのは窓口です。

| 項目 | 既定値 | 説明 |
|---|---|---|
| Local Stuck Receivers | なし | イベントを送る UdonBehaviour（`PlayerMovementLock` の窓口など）。空なら送らない |
| Local Stuck Event | SubtractSpeed | どこか 1 か所でもくっついたときに送るイベント名 |
| Local Unstuck Event | AddSpeed | 全部はがれたときに送るイベント名。くっついている間にリスポーンしたときや、巣・Manager の GameObject が無効になったときも送る |

- イベントは自分のクライアントだけで、自分がくっついた／はがれたときだけ送ります（ほかの人がくっついても送りません）。速さはローカル専用の設定なので、同期は要りません。
- 2 つのイベントは必ず交互に送ります（「くっついた」の次は必ず「はがれた」）。千切れたときやリスポーンしたときは、解放を送った時点で「はがれた」を送るので、通信の往復を待たずに速さが戻ります。
- このパッケージは送るだけで、速さには触りません。イベント名で呼ぶだけなので、restraint が入っていないプロジェクトでもコンパイルできます。Web でいえば、巣は `dispatchEvent` するだけで、聞き手（`PlayerMovementLock` の窓口）がいれば反応する、という関係です。
- 窓口は、速さを `SetSpeed`（決めた倍率にする）・`AddSpeed` / `SubtractSpeed`（決めた量だけ増減）・`ResetSpeed`（元の速さに戻す）で変えます。巣は既定で、くっついたら `SubtractSpeed`、はがれたら `AddSpeed` を対で送ります。
- 何枚の巣から同じ窓口に送っても構いません。増減は範囲の外に出た分も覚えているので、全部はがれたときに必ず元の速さに戻ります。
  - 何枚くっついても 1/3 にしたい（重ねて遅くしない）: 窓口の「Step Ratio」0.6667・「Min Ratio」0.3333
  - くっついた巣が増えるほど遅くしたい: 「Step Ratio」を小さく（例: 0.3 なら 1 枚で 0.7 倍、2 枚で 0.4 倍）
  - 巣ごとに遅さを変えたいときは、遅さごとに窓口を分けます
- 巣につなぐ窓口は巣専用にしてください。RestraintCore やボタンから `SetSpeed` / `ResetSpeed` が届く窓口と共有すると、巣が減らした分がリセットで消え、その後の「はがれた」で元より上の値が残って、次にくっついても遅くならなくなります。
- 窓口は常に有効な場所に置き、実行中に「Local Stuck Receivers」やイベント名を差し替えないでください。無効の間に届いたイベントは捨てられるので、「くっついた」と「はがれた」の片方だけが届いて数がずれます。
- 元の速さの保存と復元は、`PlayerMovementLock` のまとめ役が受け持ちます。ほかのギミックの減速と重なっても、解除の順番に関係なく正しく戻ります。

> 0.12.0 より前の「Slow Local When Stuck」「Stuck Speed Ratio」は、この形に置き換えました。上げると巣にくっついても遅くならなくなるので、`PlayerMovementLock` の窓口を置いて「Local Stuck Receivers」につないでください。以前と同じ動き（何枚くっついても「Stuck Speed Ratio」の倍率。既定は 1/3）にするには、「Min Ratio」に以前の倍率、「Step Ratio」に 1 − 以前の倍率を入れます（1/3 なら 0.3333 と 0.6667）。

#### 粘液の糸（Thread By Slot）

くっついた場所とボーンの間に張る粘液の糸です（任意）。

| 項目 | 既定値 | 説明 |
|---|---|---|
| Thread By Slot | なし | スロットごとの LineRenderer（最大 16 本）。空なら糸は描かない |
| Thread Width | 0.08 | 糸の太さ（m。目の高さ 1.6 m のアバターを基準に拡大縮小） |
| Thread Rest Length | 0.15 | この長さ（m）までは太さそのまま。これより伸びると細くなる |
| Thread Min Width | 0.3 | 伸びたときの太さの下限（割合） |
| Thread Sag | 0.06 | 糸のたるみ（長さ 1 m あたりの m） |
| Thread From Deformed Web | OFF | ON で、糸の始点を変形した後の面にする（凹み・伸びと糸を一緒に使う巣用）。Web Max Bulge が 0 より大きいときは OFF でも ON と同じ |
| Web Max Bulge | 0 | 面が膨らむ上限（m）。手足がこれより離れた分は面を引っ張らず、糸が受け持つ。0 で上限なし（従来どおり）。Auto Release Distance より十分小さくする。下の「膨らみの上限と糸」 |
| Thread Fade Length | 0.03 | Web Max Bulge を使うとき、面の先が手足に届かない長さがこの値（m）になるまで糸を細くしておく。0 で細くしない |

##### 膨らみの上限と糸（Web Max Bulge）

巣にくっついた手足を離していくと、巣は上限の長さまで手足の方へ膨らみ、それより離れた分は粘液の糸が巣と手足をつなぎます。ゴムのように伸び切った巣から、糸が引き出されて見えます。

- 上限が効くのは、くっついた側（手足がいた側）へ引っ張る向きの量だけです。面に沿った向きのずれは、今までどおり面が追従します。
- 手足を面へ押し込む向きでは、上限は効かず、面だけが凹みます。このとき糸は出ません（`pullOnly` が ON なら凹みもしません）。
- 糸は、変形した面の先が手足に届かなかった分だけ出ます。上限で止めた分のほか、引っ張りの弱い巣（`_PullStrength` が 1 未満）、`_PullMaxStretch` で千切れて戻った巣、`_PullEnable` が OFF の巣、近くの別の接点と平均されて届かない分も、糸がつなぎます。
- 糸は、届かない長さが「Thread Fade Length」になるまで細く描き、上限の前後でぱっと現れたり消えたりしないようにします。
- 手足が面のほぼ上（1 cm 未満）でくっつき、どちら側か決められないときは、引いた向きに上限をかけます（このときは押し込んでも糸が出ることがあります）。`pullOnly` もこのときは効かず、面はどちらの向きにも追従します。Capture Only Below Surface の巣は、いつも裏側として扱います。
- 糸の始点は、膨らんだ巣の先（変形した後の面）になります。Thread From Deformed Web が OFF でも同じです。
- 千切れ（Auto Release Distance）は、今までどおり捕縛点から手足までの距離で決まります（面に沿ったずれも含む）。まっすぐ引いたとき、上限を超えてから千切れるまでに手足が離れられるのは、おおよそ「Auto Release Distance − Web Max Bulge」です。描かれる糸は、捕まえたときのボーンと面の距離（最大で Contact Distance）のぶんだけこれより長くなります。Web Max Bulge が Auto Release Distance に近いと、糸が出る前に千切れます。
- 糸を描くには Thread By Slot が要ります。空のときは、巣が上限で止まるだけになります。

LineRenderer の設定:

- マテリアルは [蜘蛛糸](SpiderSilk.md) の粘液モードのマテリアルを使います。たるみの値はスクリプトが MaterialPropertyBlock で設定します。
- **Texture Mode は Stretch**（糸全体で uv.x が 0〜1 になる前提）。Tile だとたるみが先頭 1 m にしかかかりません。
- **Use World Space は ON**。
- 初期状態は無効で構いません。使うときにスクリプトが有効にします。
- 同期済みのスロットから描くので、追加の通信はありません。伸びるほど細り、千切れると消えます。

#### 効果音

| 項目 | 既定値 | 説明 |
|---|---|---|
| Contact Audio | なし | 手足がくっついた瞬間に鳴らす AudioSource。くっついた場所へ移して clip を鳴らす（周りの人にも同じ場所で聞こえる） |
| Contact Audio Interval | 0.4 | 続けてくっついたとき（すね → もも → 腰…）に鳴らす最短の間隔（秒） |

- くっついたのが自分なら、音と一緒に両手のコントローラーが 0.5 秒振動します（Contact Audio を設定したときだけ）。
- 本人は捕縛の要求がオーナーと往復する分、少し遅れて聞こえます。
- 途中から入室した人には、入室直後に届いた既存の捕縛の分は鳴らしません。

### スクリプトから呼ぶメソッド

| メソッド | 内容 |
|---|---|
| `ClaimLocalBone(int boneIndex, Vector3 anchorLocal, float param)` | 外部のスクリプト（落とし穴の罠など）から、自分のボーンを指定の捕縛点で捕縛させる。引数はボーン番号（`Bones` の順）、捕縛点（面のローカル座標）、区間上の位置（0〜1）。自動の接触判定は通らない。送信は 1 秒 20 回までなので、何本も送るときは間隔を空ける |
| `_ReleaseLocalBones()` | `ClaimLocalBone` で捕縛した自分のボーンを解放する。解放後の約 3 秒は、遅れて届いた捕縛を取り除く |
| `RefreshFanShape()` | 実行中に巣のマテリアルや扇形の形を変えたときに呼ぶ。捕縛範囲（扇形）を読み直す |

### スロットの状態を外から読む

別の UdonSharp スクリプトから、この巣の「どのスロットに、誰の、どの部位（ボーン）が付いているか」を読めます。たとえば、ワールドにある全部の巣を調べて、捕まっている部位から全身の繭（[外殻の部位](#外殻の部位を自分で渡すとき)）を組み立てる、といった使い方です。どのメソッドも読むだけで、同期や捕縛の状態は変えません。

| メソッド | 返す値 |
|---|---|
| `GetSlotCount()` | スロットの総数（`MaxSlots` = 16。空きも含む）。UdonSharp からは定数 `SurfaceContactDeformer.MaxSlots` を直接使うほうが軽い |
| `GetOccupiedSlotMask()` | 誰かが付いているスロットのビットマスク。スロット i に付いていれば bit i が 1。0 なら誰も付いていない |
| `GetOccupiedSlotCount()` | 誰かが付いているスロットの数（0〜16） |
| `GetSlotVersion()` | スロットの中身が変わるたびに増える番号。前に読んだ値と同じなら、マスク・playerId・ボーンは前のまま（変わっていなくても増えることはある） |
| `GetSlotPlayerId(int slot)` | そのスロットに付いている人の `playerId`。空きは 0、範囲外の slot は -1 |
| `GetSlotBoneIndex(int slot)` | 付いているボーンの `Bones` での番号（`ClaimLocalBone` の boneIndex と同じ）。空き・範囲外は -1 |
| `GetSlotHumanBone(int slot)` | 付いているボーンの種類。[TrackBone](#trackboneボーンの指定) は `HumanBodyBones` と同じ整数なので、`(HumanBodyBones)値` でそのまま変換できる。空き・範囲外は -1 |

GameObject が無効になっている巣は、無効の間スロットが古いまま残る（同期も退室の掃除も届かない）ため、上のメソッドは「誰も付いていない」（マスク 0・playerId 0・ボーン -1）を返します。有効に戻ると、オーナーが退室した人のスロットを掃除してから、また本当の値を返します。

マネージャ（`SurfaceContactDeformerManager`）にも、いま動いている巣を読むメソッドがあります。

| メソッド | 返す値 |
|---|---|
| `GetActiveCount()` | いま登録されている巣の数（誰かが付いている巣と、自分がトリガーの中にいる巣） |
| `GetActive(int i)` | その i 番目の巣（範囲外は null）。並びは登録・解除で入れ替わるので、番号を次のフレームまで持ち越さない |

**考え方**: スロットの中身は全員で同じ値になる同期配列ですが、巣が 100 個以上あるワールドで、毎フレームすべての巣の 16 スロットを調べると無駄が大きくなります。そこで 2 段階で絞ります。

1. 誰かが付いている巣は、必ずマネージャに登録されています（登録制は [負荷対策](#surfacecontactdeformermanager) のための仕組みで、各自のクライアントで同期を受け取ったときに登録されます）。だから全部の巣ではなく、マネージャの一覧（ふだんは 0〜数個）だけを回れば足ります。
2. 巣の側で「誰かが付いているスロット」を 1 つの整数（ビットマスク）にまとめておき、スロットが変わったときだけ直します。読む側は `GetOccupiedSlotMask()` が 0 の巣を 1 回の呼び出しで飛ばせます。

Web でいえば、全件を毎回 `filter` するのではなく、サーバーが「更新のあった項目の一覧」と「未読フラグ」を持っておき、画面はそれだけを読むイメージです。

巣を調べる例（UdonSharp）:

```csharp
using UdonSharp;
using UnityEngine;
using VRC.SDKBase;

[UdonBehaviourSyncMode(BehaviourSyncMode.None)]
public class WebSlotScanner : UdonSharpBehaviour
{
    public SurfaceContactDeformerManager manager; // シーンの SurfaceContactDeformerManager

    void Update()
    {
        if (manager == null) { return; }
        int n = manager.GetActiveCount();
        for (int k = 0; k < n; k++)
        {
            SurfaceContactDeformer d = manager.GetActive(k);
            if (d == null) { continue; }
            int mask = d.GetOccupiedSlotMask();
            if (mask == 0) { continue; }           // 自分がトリガーに入っているだけの巣はここで終わり
            for (int s = 0; s < SurfaceContactDeformer.MaxSlots; s++)
            {
                if ((mask & (1 << s)) == 0) { continue; }
                int playerId = d.GetSlotPlayerId(s);
                int bone = d.GetSlotHumanBone(s);
                if (playerId <= 0 || bone < 0) { continue; }
                VRCPlayerApi p = VRCPlayerApi.GetPlayerById(playerId);
                if (!Utilities.IsValid(p)) { continue; } // 退室した直後
                HumanBodyBones part = (HumanBodyBones)bone;
                // ここで「p の part に糸が付いている」を記録する
            }
        }
    }
}
```

- 値は同期済みのスロットなので、全員のクライアントで同じになります（スクリプトは各自のクライアントで読むだけでよく、同期は要りません）。自分が触れた直後は、捕縛の要求がオーナーとやり取りされるまでの間（通信の遅れの分）、まだ入っていません。
- 退室した人のスロットは、オーナーが掃除するまで少しの間残ることがあります。`VRCPlayerApi.GetPlayerById` の結果を `Utilities.IsValid` で確かめてください。
- `GetOccupiedSlotCount()` は、ボーンを引けないスロット（実行中に `Bones` を短くしたときなど、`GetSlotHumanBone` が -1 のスロット）も数えます。部位の数が要るときは、上の例のように 1 つずつ確かめて数えてください。
- 毎フレーム組み立て直すのが重いときは、巣ごとに `GetSlotVersion()` を覚えておき、変わった巣だけ読み直します。
- マネージャを置かない構成では、調べる巣の配列を自分で持って回ります。そのときは GameObject が無効の巣を飛ばしてください（一度も有効になっていない巣は、呼んでも値が返らないことがあります）。

### 推奨設定の例（地面・木などに固定した巣）

作者のワールドで、固定設置の巣にそろえて使っている設定です。投げ網など飛んでくる網には当てはまりません。

| 項目 | 値 |
|---|---|
| Bones | 次の 10 本をこの順に: LeftLowerLeg・RightLowerLeg（すね）、LeftUpperLeg・RightUpperLeg（もも）、LeftLowerArm・RightLowerArm（前腕）、LeftUpperArm・RightUpperArm（上腕）、Hips（腰）、Neck（首） |
| Contact Distance By Bone | Bones と同じ順に 10 個: 0.09・0.09・0.12・0.12・0.07・0.07・0.08・0.08・0.15・0.08（m、区間の中心線から。すね 0.09 / もも 0.12 / 前腕 0.07 / 上腕 0.08 / 腰 0.15 / 首 0.08） |
| Segment Contact / Pull Only | ON / ON |
| Local Stuck Receivers | 「Step Ratio」0.6667・「Min Ratio」0.3333（何枚くっついても速さ 1/3）の `PlayerMovementLock` の窓口（restraint） |
| Capture Only Below Surface | OFF（初めて触れたときにくっつく） |

### SurfaceContactDeformerManager

多数の巣を置くとき、各 Deformer が毎フレーム処理を回すと重くなります。シーンに 1 つ Manager を置き、各 Deformer の **Manager** に設定すると、Deformer は「誰かが捕縛中」か「自分がトリガーの中にいる」ときだけ Manager に登録され、そのときだけ処理されます（何もない間は Manager 1 つ分の負荷）。

- 設定項目はありません。登録できる Deformer は最大 256 個です。
- Manager を使う場合、Deformer はトリガーに入った時に登録されるので、**Require Trigger を OFF にしてもトリガーコライダーは必要**です。
- Manager を設定しなくても、各 Deformer が自分で毎フレーム動きます（少数なら問題ありません）。

### TrackBone（ボーンの指定）

`Bones` で選ぶボーンの種類です。Unity の `HumanBodyBones` と同じ値で、Hips〜RightToes と UpperChest を選べます。「Segment Contact」が ON のとき、次のボーンは子ボーンまでの区間で判定し、それ以外は点で判定します。

- UpperLeg → LowerLeg → Foot
- Shoulder → UpperArm → LowerArm → Hand
- Hips → Spine → Chest → Neck → Head

### 同期のしくみ

- 同期は「オーナーがまとめて書く」方式です。各クライアントは自分のボーンだけ判定し、捕縛・解放の要求（`[NetworkCallable]` の `ClaimSlot` / `ReleaseSlot`）をオーナーへ送ります。オーナーだけが同期配列を書くので、更新の取りこぼしが起きません。
- 同期するのは「どのスロットに誰のどのボーンが、どこで捕まったか」だけです。追従先（ボーンの今の位置）は各クライアントが自分で読むので、通信は増えません。
- 途中から入室した人にも、捕縛の状態が復元されます。

### 注意・制約

- **Batching Static は OFF** にしてください。頂点を動かしても Renderer の描画範囲（バウンズ）は広がらないため、WebPlane はあらかじめバウンズを広げて保存しています。静的バッチングで結合されるとこのバウンズが失われ、足を上げた部分が画面の端で消えます。
- **GPU Instancing は OFF** にしてください。捕縛点は MaterialPropertyBlock で Renderer ごとに渡します。
- 足を 2 m 以上持ち上げる、または引っ張り半径を大きくする場合は、WebPlane の生成ツールで Bounds Up / Bounds Lateral を上げて作り直してください。
- 糸の太さは UV 基準なので、引き伸ばした方向に太く見えます。
- 指定したボーンを持たないアバターでは、そのボーンは捕縛されません。
- 1 枚の面で同時に捕縛できるのは最大 16 か所です（その場にいる全員で先着順に分け合います）。上限を変えるには、シェーダーとスクリプトの両方を直す必要があります（[開発者向けノート](../CONTRIBUTING.md#変更するときの約束)）。
- 面を隠すときは GameObject の `SetActive(false)` ではなく `Renderer.enabled` を使ってください。非アクティブな UdonBehaviour ではイベントが動きません。
- ClientSim ではボーンの情報とネットワークイベントの一部が再現されないので、足の持ち上げや複数人の同時捕縛は実機（Build & Test）で確認してください。

### 確認チェックリスト

1. 巣に踏み込む・手をつくとその場所が捕縛され、上げると追従して伸び、押し込むと凹むこと。一定距離離れると千切れて戻ること。
2. 複数人が同時に触れても、それぞれの手足に追従すること。
3. 実機 2 台で、片方が足を上げるともう片方の画面でも同じ場所が持ち上がること。途中入室者にも復元されること。ミラーの中でも変形して見えること。
4. 巣の端の外からカメラを向けても、持ち上げた部分が画面の端で消えないこと。

> Udon を使わずに見た目だけ確かめたいときは、Editor スクリプトから `MaterialPropertyBlock.SetVectorArray` で `_PullAnchors` の 0 番に `(x, y, z, 1)`、`_PullTargets` の 0 番に `(x, y + 0.4, z, 0)` を入れ（どちらも 16 要素の配列で渡す）、同じブロックで `_PullCount` を 1 にして Renderer に `SetPropertyBlock` します。巣が円錐状に持ち上がれば成功です。

---

## 繭のまとめ描き（CocoonGroupLinker）

両手首を合わせた・手を胸に当てた・両足をそろえた、などのときに、くっついた[繭デカール](CocoonDecal.md)を「同じ糸でまとめて巻かれた」1 つの繭として描きます。見た目だけで、同期はしません。

### しくみ

- シェーダーは自分の箱のことしか知らないので、「近くに別の繭があるか」は Udon（`CocoonGroupLinker`）が調べて、MaterialPropertyBlock で各繭に伝えます。
- 円筒は体より太めなので、半径に「Link Radius Scale」（既定 0.5）を掛けたものを「巻かれた手足の太さ」とみなします。その表面どうしが「Link Distance」（既定 0.02 m）以内の繭を 1 グループにまとめます。腕を下ろして手首が太ももの横にあるだけ・両足が並んでいるだけでは、まとまりません。
- グループの中で一番大きい繭を**代表**にします（一度まとまった後は、離れるまで同じ代表を保ちます）。代表は仲間全員の円筒の範囲を、共通の向きの帯で巻きます。代表以外は描きません。描く箱が 1 つなので、継ぎ目や二重描きが出ません。
- 巻く軸は「大きい繭ほど強く引き寄せる」重み付きの位置に置き、部位ごとの軸にも沿わせます（強さは繭のマテリアルの「部位の軸に沿う強さ」）。
- 繭のマテリアルの「まとめ描きの膨らみ」が 0 より大きいと、仲間の円筒から計算した厚い外殻として描き、近い部位の間も外皮でつなぎます（[設定](CocoonDecal.md#繭まとめ描きのボリューム固有)）。

### セットアップ

1. 空の GameObject に `CocoonGroupLinker` を追加します。
2. **Decals** に、まとめたい体に張り付く繭の Renderer を並べます。
3. 繭がプレイヤーのボーンに追従するなら、その追従スクリプトを **Followers** に**同じ並び**で設定します。同じプレイヤーの、装着中の繭どうしだけをまとめるためです。空なら「表示中（GameObject が有効）の繭すべて」が対象です。
   - 追従スクリプトの条件: UdonSharpBehaviour で、`int` 型の変数 `targetPlayerId`（追従先プレイヤーの ID）を持ち、装着していないときは負の値にしていること。
   - `targetPlayerId` が負、または変数が無い追従スクリプトの繭はまとめません。

### 設定項目

| 項目 | 既定値 | 説明 |
|---|---|---|
| Decals | なし | まとめる候補の体に張り付く繭の Renderer |
| Followers | なし | `Decals` と同じ並びの追従スクリプト（上の条件を満たすもの） |
| Link Distance | 0.02 | 巻かれた手足の表面どうしがこの距離（m）以内ならまとめる |
| Unlink Hysteresis | 0.015 | まとまった後は、この距離（m）だけ余分に離れてから分ける（境目でまとまったり離れたりを繰り返さないため） |
| Link Radius Scale | 0.5 | 円筒の半径のうち「巻かれた手足の太さ」とみなす割合。1 で円筒そのものが触れたらまとめる |
| Wrap Margin | 0.02 | 代表の描画範囲（箱）を仲間の円筒より少し大きめに取る余白（m） |
| Scan Interval | 1 | すべての繭を調べ直して、新しく表示された繭を拾う間隔（秒）。それ以外のフレームは表示中の繭だけを測り直すので、数百個登録しても軽い |

### まとめ描きの注意

- 新しく表示された繭は、最大「Scan Interval」秒だけ単独で描かれてからまとまります。
- Followers を空にすると、くっついた別のプレイヤーの繭どうしもまとまることがあります。
- まとめ描き中は代表のマテリアルの設定で全員を巻きます（グループ内の見た目は代表にそろいます）。
- 1 グループは最大 16 個です。超えた分は別のグループになります。
- 代表の描画範囲（バウンズ）を広げ、解除時に元に戻します。
- 円筒の半径・高さ・膨らみ・糸の厚みは、各繭の共有マテリアルから読みます。MaterialPropertyBlock で上書きしても反映されません。
- 繭の位置をボーンからずらしたいとき（太ももの繭を股関節から太ももの途中へ、など）は、追従スクリプト側でずらしてください。

### 外殻の部位を自分で渡すとき

全身を 1 つの外殻で包むなど、`CocoonGroupLinker` を使わずに部位を自分で決めるときは、代表にする繭の Renderer に次の値を MaterialPropertyBlock で渡します（駆動スクリプトは同梱していません）。どの部位に巣が付いているかは、SurfaceContactDeformer の [スロットの状態を外から読む](#スロットの状態を外から読む) メソッドで調べられます。

| 名前 | 内容 |
|---|---|
| `_GroupRole` | 1＝代表（まとめて描く）、0＝単独、-1＝代表に任せて描かない |
| `_GroupCylA` / `_GroupCylB` | 巻き模様の軸。A の xyz＝軸が通る点、w＝全体を包む半径（m）。B の xyz＝軸の向き × 半分の高さ |
| `_GroupWrapOrigin` | xyz＝巻き模様の高さを測る原点、w＝1 で有効（0 なら `_GroupCylA` の点） |
| `_GroupBoxHalf` | 代表の箱を広げた半サイズ（オブジェクト空間。全部位を包む大きさ） |
| `_GroupMemA[16]` | 部位ごとの円筒。xyz＝中心（ワールド）、w＝半径（m） |
| `_GroupMemB[16]` | 部位ごとの軸。xyz＝軸の向き × 半分の高さ、w＝端の丸め（0＝平らな端、1＝カプセル） |
| `_GroupMemCount` / `_GroupLeadIndex` | 有効な部位の数（最大 16）／代表の部位の番号 |
| `_GroupBridgePairs[16]` | 繭同士の接続部位（2 つの部位のあいだを繭で埋めてつなぐ部分）を作る部位の組。x・y＝部位の番号、z＝つなぐ距離の倍率（0 で既定）、w＝接続部位の形の絞り（0 で絞らない） |
| `_GroupBridgeCount` | 有効な組の数。0 なら代表から各部位へ放射状に接続部位を作る（`CocoonGroupLinker` と同じ） |

名前の `Bridge` は繭同士の接続部位のことです（互換のため名前はそのままにしています）。

代表の描画範囲（Renderer の `localBounds`）も、部位全体を包む大きさに広げてください。値の作り方は `CocoonGroupLinker.cs` の `WriteBundle` が参考になります。

---

## 体に覆いかぶさる変形（Drape）

投げつけた網が、当たった人の体の形に沿ってかぶさる表現です。[蜘蛛の巣](SpiderWeb.md)と[蜘蛛の巣ドレープ](SpiderWebDrape.md)が対応しています。

体の形（ボーンから作ったカプセル）と網の位置・向きを、Udon が MaterialPropertyBlock で毎フレーム渡します。パッケージには、そのための汎用の駆動スクリプト [SpiderWebDrapeDriver](#駆動スクリプトspiderwebdrapedriver) が入っています。値が渡されない間は、変形は何も起きません。作者のワールドでは、網の飛行や着弾の同期まで含めた独自の `CaptureNetDrape` で駆動しています（[開発者向けノート](../CONTRIBUTING.md#作者のワールドwebbedworldでの使用例と経緯)）。

### しくみ

- 網の頂点の位置は **UV だけ**から決まります（Transform は描画範囲を決めるだけ）。そのため WebPlane のような 1 枚の平面メッシュ専用です。
- 体はボーンから作ったカプセル（最大 20 本）で近似します。
- **横から投げた網**: 網を「飛んできた方向に垂直な円盤」とみなし、各頂点から飛んできた方向へ光線を伸ばして、体に当たった所に頂点を置きます。体の輪郭からはみ出した部分は、背中側へ回り込み、余りは重力で垂れます。床より下には行きません。
- **巻きつき**（「体に巻きつく最大の周回数」が 0 より大きいとき）: 網が体の周りを螺旋状に巻きます。
- **姿勢追従**（スクリプトが有効にしたとき）: かぶさった後に体が動いても、網が体に沿って動きます。
- **上から降る網**（スクリプトが有効にしたとき）: 頭の上から網をかぶせ、縦のひだを作り、床では外へ広げます。
- 法線（面の向き）は、隣の点を同じ計算に通した差から求め直します。
- 接触追従の変形と両方 ON のときは、こちらが優先されます。

### シェーダー側の設定（体に覆いかぶさる変形）

| 表示名 | 内部名 | 既定値 | 説明 |
|---|---|---|---|
| 体に覆いかぶさる変形 有効 | `_DrapeEnable` | OFF | ON で変形する（スクリプトが値を渡している間だけ） |
| 体からの浮き m | `_DrapeGap` | 0.025 | 体の表面から浮かせる距離 |
| 部位間のなじみ幅 m | `_DrapeSmooth` | 0.06 | 腕と胴など、部位のつなぎ目をなめらかにする幅 |
| 背中側へ巻き込む量 | `_DrapeWrap` | 1 | 輪郭からはみ出した部分を背中側へ回り込ませる量 |
| 同じ高さの部位に巻きつく強さ | `_DrapeCling` | 3 | 同じ高さにある部位を優先して巻きつく強さ |
| 巻き込んだ余りの伸び | `_DrapeTail` | 0.3 | 回り込んだ余りが伸びる量 |
| 余りの重力たるみ | `_DrapeSag` | 0.2 | 余りが重力で垂れる量 |
| 体に巻きつく最大の周回数 0で従来 | `_DrapeTurns` | 0 | 0 より大きいと螺旋状に巻きつく（最大 3 周） |
| 1周ごとの重なりの厚み m | `_DrapeLayer` | 0.012 | 巻きつくとき、1 周ごとに重なる厚み |
| 巻ききれない余りのふくらみ m/m | `_DrapeBunch` | 0.03 | 巻ききれない余りのふくらみ |
| 伸びすぎた所を薄くする倍率 | `_DrapeStretchFade` | 3 | 大きく引き伸ばされた所を透明にする（巻きつき時だけ） |
| 姿勢追従: 部位の境目のなじみ幅 m | `_DrapeFollowBlend` | 0.05 | 姿勢追従で、部位の境目をなじませる幅 |
| 姿勢追従: 体へのめり込みを押し戻す | `_DrapeFollowPush` | 1 | 体にめり込んだ所を外へ押し戻す強さ |
| 姿勢追従: 体から離れた余りを重力で垂らす | `_DrapeFollowHang` | 1 | 体から離れた余りを重力で垂らす強さ |
| 姿勢追従: 重力で垂れきる体からの距離 m | `_DrapeFollowHangDist` | 0.25 | この距離まで離れると完全に垂れる |
| 有効カプセル数 Udonが設定 | `_DrapeCount` | 0 | スクリプトが設定する値。手で触らない |

### 駆動スクリプト（SpiderWebDrapeDriver）

`Runtime/WebDrape/SpiderWebDrapeDriver.cs`。網を 1 枚、指定したプレイヤーにかぶせ、毎フレーム体に合わせて値を渡します。網を飛ばす動き・当たり判定・全員への同期は含みません。それらは呼び出す側（投げ網のギミックなど）が受け持ち、当たったと決まったら全員のクライアントでこのスクリプトのメソッドを呼びます。

**しくみ**: 頭・首・胸・背骨・骨盤・両腕（上腕・前腕・手）・両脚（腿・すね・足）の 17 本のカプセルを、骨の位置と目の高さから作ります（太さは目の高さに対する割合）。姿勢追従が ON なら、かぶせた瞬間のカプセルを「基準」として残し、骨ごとに「基準 → 今」の回転と移動（剛体変換）を毎フレーム渡します。シェーダーはこれを使って、網の各点を近くの部位と一緒に動かします（アバターのメッシュがボーンについて動くのと同じ考え方）。

**セットアップ**:

1. 網の GameObject を作り、MeshFilter に WebPlane（**Tools > SpiderShader > Generate WebPlane Mesh...** で生成）、MeshRenderer に蜘蛛の巣か蜘蛛の巣ドレープのマテリアルを入れます。マテリアルの「体に覆いかぶさる変形 有効」を ON にします（蜘蛛の巣ならプリセット「覆いかぶさる捕獲網」）。
2. 同じ GameObject（または別の GameObject）に `SpiderWebDrapeDriver` を付け、Target Renderer に 1 の MeshRenderer を入れます。
3. 網の GameObject の Static はすべて OFF、マテリアルの GPU Instancing も OFF にします。
4. 別の UdonSharp スクリプトから `DrapeThrown` か `DrapeFromAbove` を呼びます。試すだけなら、ボタンなどから `SendCustomEvent("DrapeLocalPlayerFromFront")` で自分にかぶせられます。

| 設定項目 | 既定値 | 説明 |
|---|---|---|
| Target Renderer | （空なら同じ GameObject の Renderer） | 網の Renderer |
| Move Renderer To Body | ON | 網の Transform を毎フレーム腰の位置へ動かす。網の形は Transform と関係なく決まるが、画面に映っているかの判定範囲（バウンズ）を体に付いてこさせるため |
| Hide When Released | ON | かぶせていない間は Renderer を非表示にする |
| Net Radius | 1 | 網の半径 m（WebPlane の中心から辺まで）。1 m 四方の WebPlane なら 0.5、2 倍に広げて使うなら 1 |
| Cover Time | 0.35 | 平らな網が体に沿うまでの秒数 |
| Sag Wobble | 1 | たるみの揺れの倍率 |
| Body Radius Scale | 1 | 体のカプセルの太さの倍率。網が体にめり込むときは上げる |
| Follow Pose | ON | 横から投げた網の姿勢追従。OFF だと毎フレーム今の姿勢へかぶせ直す（体を動かすと網が滑る） |
| Anchor Distance | 0 | 壁などに貼り付いた網。体からこの距離 m より離れた所は動かない（姿勢追従のときだけ） |
| Fall Height / Fall Time | 1.2 / 0.5 | 上から降る網が落ち始める高さ m と、落ちきるまでの秒数 |
| Fall Hang | 0.6 | 上から降る網の垂れ下がり。0 で体に貼りつき、1 で一番張り出した所から真下へ |
| Fall Edge Lift | 0.15 | 落下中にふちが持ち上がる高さ m |
| Floor Layers | Nothing（＝Default と Environment） | 床として Raycast するレイヤー |
| Floor Probe | 3 | 腰から下へ床を探す距離 m。見つからなければ床なし |

| メソッド | 内容 |
|---|---|
| `DrapeThrown(int playerId, Vector3 direction)` | 横から投げた網をかぶせる。direction は網が進む向き（投げた人 → 当たった人） |
| `DrapeFromAbove(int playerId)` | 頭の上から降ってくる網をかぶせる |
| `SetAnchorDistance(float m)` | 壁などに貼り付いた網にする（0 で解除） |
| `Release()` | 網を外す |
| `GetDrapedPlayerId()` | 今かぶせている人の playerId（いなければ 0） |
| `DrapeLocalPlayerFromFront()` / `DrapeLocalPlayerFromAbove()` | 引数なし。自分にかぶせる（動作確認・UI ボタン用。`SendCustomEvent` で呼べる） |

- かぶせた人が退室すると自動で外れます。
- このスクリプトは同期しません。全員に同じ網を見せたいときは、同期している側（捕獲の判定など）から、全員のクライアントで同じメソッドを呼びます（たとえば `SendCustomNetworkEvent` で全員に「この人に当たった」を伝え、受け取った各クライアントが `DrapeThrown` を呼ぶ）。
- 網 1 枚につき 1 つ付けます。同じ網を 2 人に同時にはかぶせられません。

### スクリプトが渡す値（駆動スクリプトを自作する人向け）

変形は `_DrapeEnable` が ON、`_DrapeCount` が 1 以上、`_DrapeCenter.w`（網の半径）が 0 より大きいときだけ動きます。

| 名前 | 内容 |
|---|---|
| `_DrapeCenter` | xyz＝網の中心（ワールド）、w＝網の半径（m） |
| `_DrapeDir` | xyz＝網が飛んできた方向、w＝かぶさり具合（0〜1） |
| `_DrapeUp` | xyz＝上方向の基準、w＝たるみの揺れの倍率 |
| `_DrapeFloor` | xyz＝床の法線、w＝床までの距離（法線が 0 なら床なし） |
| `_DrapeCapA[20]` / `_DrapeCapB[20]` | 体のカプセルの両端（ワールド）。`_DrapeCapA` の w＝カプセルの半径 |
| `_DrapeCount` | 有効なカプセルの数 |
| `_DrapeFollow` | 1 で姿勢追従 |
| `_DrapeCurA[20]` / `_DrapeCurB[20]` | 姿勢追従: 今のカプセルの両端 |
| `_DrapeSkinX[20]` / `_DrapeSkinY[20]` / `_DrapeSkinZ[20]` | 姿勢追従: かぶさった時の姿勢 → 今の姿勢への変換行列（3×4 の各行） |
| `_DrapeFall` | x＝1 で上から降る網、y＝垂れ具合（0〜1）、z＝ふちの持ち上がり（m）、w＝落下の高さ（m） |
| `_DrapeAnchor` | 壁などに貼り付いた網。x＝体からこの距離（m）より離れた所は動かない世界に残る（0 で従来どおり体に追従） |

実装は `Runtime/CGINC/SpiderWeb_Drape.cginc` です。

### Drape の注意

- **Batching Static と GPU Instancing は OFF** にしてください（接触追従の変形と同じ理由）。
- 頂点 1 つごとに最大 20 本のカプセルとの計算を行うので、網の頂点数が多いと重くなります。軽くしたいときは、WebPlane の生成画面（**Tools > SpiderShader > Generate WebPlane Mesh...**）で Segments を下げたメッシュを作って使います（既定の 64 で 65×65 頂点、32 で 33×33 頂点）。
- 蜘蛛の巣の標準プリセット「覆いかぶさる捕獲網」は、巻きつき・姿勢追従の値を含みません（今の値が残ります）。
