# Spider Shaders

蜘蛛の巣・繭で捕らわれる「疑似拘束」を表現するための、VRChat ワールド向けシェーダー集です。蜘蛛が吐いた糸、張られた巣、体に巻きつく繭、体にかぶさる粘液のネットを、テクスチャなしの計算で描きます。

**Unity Built-in Render Pipeline 専用**です（URP / HDRP には対応していません）。

## シェーダー一覧

名前をクリックすると、使い方とすべての設定項目の説明が開きます。

| シェーダー | 何を描くか | 何に貼るか | 環境 |
|---|---|---|---|
| [吐いた糸（SpiderThreadTrail）](docs/SpiderThreadTrail.md) | 蜘蛛が吐いた糸。乾いた細い糸か、粘液の束 | Trail Renderer・Particle System の Trails・LineRenderer | PC（Quest は未検証） |
| [蜘蛛の巣（SpiderWeb）](docs/SpiderWeb.md) | 縦糸と横糸の蜘蛛の巣。扇形・曲面にも対応 | 平面・球のメッシュ（専用の分割平面を生成可） | PC（Quest は未検証） |
| [繭（SpiderCocoon）](docs/SpiderCocoon.md) | 糸がぐるぐる巻いた繭。中に入ると内壁に包まれる | 円柱メッシュ | PC（Quest は未検証） |
| [体に張り付く繭（SpiderCocoonDepthDecal）](docs/SpiderCocoonDepthDecal.md) | プレイヤーの体の表面に沿って巻きつく繭 | 体を包む Cube | **PC 専用**・影付きライト必須 |
| [ねばねばネット（SpiderGooSilkSheet）](docs/SpiderGooSilkSheet.md) | 体にかぶさる粘液のシート（最大 8 層） | 平面などのメッシュ（模様の焼き込みが必要） | **PC 専用** |
| [地面転写（SpiderWebGroundProjector）](docs/SpiderWebGroundProjector.md) | 床に投影する蜘蛛の巣の画像 | Projector コンポーネント | 試験実装 |

複数のシェーダーで共通の機能:

- [共通機能](docs/CommonFeatures.md) — インスペクタの見方、**質感の継承**（吐いた糸の色・ツヤを巣や繭に受け継ぐ仕組み）、プリセット、Editor のメニュー
- [Udon ギミック](docs/UdonGimmicks.md) — 触れた手足に巣が貼り付いて伸びる（SurfaceContactDeformer）、くっついた繭をまとめて描く（CocoonGroupLinker）、投げた網が体にかぶさる

## 動作環境

- Unity 2022.3
- Built-in Render Pipeline
- VRChat Worlds SDK 3.8.1 以上（UdonSharp を含む）。同梱の Udon スクリプトが参照しているため、シェーダーだけを使う場合も必要です。
- PC 向けワールドを想定しています。Quest（Android）では、PC 専用と書いたもの以外も動作を確認していません。

## インストール

### VCC（VRChat Creator Companion）/ ALCOM から

1. [配布ページ](https://github.pito.run/spider-shader/)を開き、上部の「Add to VCC」ボタンを押してリポジトリを追加します。
   - ボタンが反応しない場合は、VCC の `Settings` → `Packages` → `Add Repository` に `https://github.pito.run/spider-shader/index.json` を貼り付けます。
2. プロジェクトの「Manage Project」から「Spider Shaders」を追加します。

### 手動インストール

[Releases](https://github.com/mecaota/spider-shader/releases) から `com.mecaota.spider-shader-x.y.z.zip` をダウンロードし、Unity プロジェクトの `Packages/com.mecaota.spider-shader/` に展開してください（`.unitypackage` 版もあります）。

## はじめての使い方（巣を 1 枚置いてみる）

1. メニュー **Tools > SpiderShader > Generate WebPlane Mesh...** を開き、**Generate** を押します。蜘蛛の巣用の平面メッシュ `Assets/mecaota/models/WebPlane.asset` ができます。
2. 空の GameObject を作り、**MeshFilter** に `WebPlane` を入れ、**MeshRenderer** を追加します。平面は床向き（上が +Y）なので、壁に貼るときは X を 90° 回転させます。
3. Project ウィンドウで **Create > Material** を 2 つ作ります。
   - 1 つ目: Shader を `mecaota/SpiderWeb` にして MeshRenderer に入れ、インスペクタ先頭の緑の「プリセット」欄で **「蜘蛛の住処の巣」** を押します。これで巣が表示されます。
   - 2 つ目: Shader を `mecaota/SpiderThreadTrail` にして、プリセット **「粘液の吐き糸」** を押します。これが巣の色・ツヤを決める「継承元」になります。
4. 巣のマテリアルの紫の「蜘蛛糸の質感（継承）」欄で、「継承元の蜘蛛糸」に 2 つ目のマテリアルを入れます。
5. 2 つ目のマテリアルの「明部の色」を変えると、巣の色も一緒に変わります。

巣・繭・ねばねばネットの色やツヤは、このように**吐いた糸のマテリアルでまとめて決める**仕組みです（[質感の継承](docs/CommonFeatures.md#質感の継承)）。巣のマテリアル側では編集できないので注意してください。

## 困ったとき

| 症状 | 原因と対処 |
|---|---|
| マテリアルがピンクになる | Built-in Render Pipeline 以外のプロジェクトでは動きません。また、以前の版にあった別のねばねばネット系シェーダーは撤去済みです（[ねばねばネット](docs/SpiderGooSilkSheet.md)に置き換えてください）。 |
| 巣・繭の色やツヤの項目が灰色で変えられない | 継承先のマテリアルでは質感は読み取り専用です。継承元の吐いた糸マテリアルで変えます（[質感の継承](docs/CommonFeatures.md#質感の継承)）。 |
| 体に張り付く繭が何も表示されない | ワールドに**影付きのリアルタイム Directional Light** が必要です。Cube が体を包んでいるか（位置・向き・スケール）も確認してください（[詳しく](docs/SpiderCocoonDepthDecal.md#確認チェックリスト)）。 |
| ねばねばネットが何も表示されない | 模様を焼き込むまでは表示されません。インスペクタ下部の「焼き込みの状態」で **「焼き直す」** を押します（[詳しく](docs/SpiderGooSilkSheet.md#焼き込み)）。 |
| 網が体にかぶさらない | 体に覆いかぶさる変形は、値を渡す Udon（パッケージ外）が必要です（[詳しく](docs/UdonGimmicks.md#体に覆いかぶさる変形drape)）。 |
| 足を上げた巣の一部が画面の端で消える | GameObject の Batching Static を OFF にしてください。持ち上げる高さが大きい場合は WebPlane のバウンズを広げて作り直します（[詳しく](docs/UdonGimmicks.md#注意制約)）。 |
| 繭の中で、背を向けると内壁が丸ごと消える | 視界ジャックの判定範囲がメッシュの外にはみ出しています（[詳しく](docs/SpiderCocoon.md#視界ジャック包まれ演出のしくみ)）。 |
| 吐いた糸が重力でたわまない | たわみには、パーティクル側の設定（Tile・Vertex Streams・Color over Trail の青）が必要です（[詳しく](docs/SpiderThreadTrail.md#重力のたゆみ)）。 |

## ライセンス

[MIT License](LICENSE)

---

## 開発者向けノート

ここから下は、このリポジトリを改造・保守する人向けの情報です。

### リポジトリ構成

[vrchat-community/template-package](https://github.com/vrchat-community/template-package) に準拠した VPM パッケージのリポジトリです。

```text
Packages/com.mecaota.spider-shader/   パッケージ本体（VCC で配布される範囲）
  package.json                        VPM パッケージの定義（バージョンはここで上げる）
  README.md                           パッケージ内の入口（docs/ へのリンクのみ）
  Runtime/                            シェーダー（*.shader）と共通コード（CGINC/*.cginc）
    CocoonGroupLinker/                繭のまとめ描きの Udon
    SurfaceContactDeformer/           接触追従の変形の Udon
  Editor/                             インスペクタ・質感の継承・プリセット・焼き込み・メッシュ生成（Editor 専用）
    Shaders/, CGINC/                  ねばねばネットの焼き込み用シェーダー（Editor 専用）
  Presets/                            標準プリセット（SpiderShaderPreset アセット）
docs/                                 利用者向けドキュメント（シェーダーごと＋共通機能＋Udon ギミック）
Website/                              配布ページのテンプレート
.github/workflows/                    リリースと VPM リスティングの自動生成
.github/scripts/                      リスティング（index.json）と配布ページの生成スクリプト
```

- `Editor/` のスクリプトは `includePlatforms: Editor` の asmdef で分けてあり、ワールドのビルドには含まれません。VRChat SDK（`com.vrchat.base`）があるときだけ `SPIDER_SHADER_VRCSDK` が定義され、Build & Upload 直前の質感の同期が有効になります。
- `Runtime/` の asmdef は `VRC.Udon`・`UdonSharp.Runtime` を参照しています。

### シェーダーと共通コード（CGINC）の関係

各シェーダーは同じ `Runtime/` 内の `CGINC/` を相対パスで include しています。フォルダ構造を変えないでください。

| CGINC | 役割 | 使うシェーダー |
|---|---|---|
| `SpiderSilk_Look.cginc` | 質感 21 項目の uniform 宣言（**宣言はここだけ**） | 全シェーダー（`SpiderCocoon_Common` / `SpiderGoo_Shading` 経由） |
| `SpiderGoo_Shading.cginc` | 粘液の塗り（丸い断面・トゥーン・ハイライト・輪郭線・透け） | 糸・巣・繭・デカール・ねばねばネット |
| `SpiderCocoon_Common` / `_Noise` / `_Thread` / `_Lighting.cginc` | 共通の uniform・ノイズ・糸の位相・リムライト・揺れ | 糸・巣・繭・デカール・ねばねばネット |
| `SpiderCocoon_Compose.cginc` | 乾いた糸のレイヤー合成（`SC_CompositeLayers`） | 吐いた糸（乾いた糸モード）。繭・デカールは include のみ |
| `SpiderThread_Goo.cginc` | 粘液の束・膜の距離場（`STG_GooField`） | 吐いた糸、ねばねばネットの焼き込み |
| `SpiderCocoon_Goo.cginc` | 繭の粘液の帯・巻きアニメ（`SC_CompositeGoo`） | 繭・デカール |
| `SpiderCocoon_VisionJack.cginc` | 視界ジャック（包まれ演出） | 繭・デカール |
| `SpiderCocoon_Group.cginc` / `_GroupShell.cginc` | くっついた繭のまとめ描き・外殻 | デカール |
| `SpiderCocoon_Pull.cginc` | 接触追従の変形（`SC_PULL_MAX = 16`） | 巣・繭・ねばねばネット |
| `SpiderWeb_Drape.cginc` | 体に覆いかぶさる変形（`SW_DRAPE_MAX = 20`） | 巣・ねばねばネット |
| `SpiderSilk_Motion.cginc` | 揺れ・重力たゆみの波形 | 糸・巣 |
| `SpiderGooSheet_BakedPattern.cginc` | 焼き込んだ模様の読み取り | ねばねばネット |

インスペクタは全シェーダー共通の `Editor/SpiderCocoonShaderGUI.cs`（地面転写を除く）が描きます。

### 変更するときの約束

- **質感 21 項目**は、名前・型・範囲・既定値・属性を全 5 シェーダーで完全に一致させます。足す・消すときは `Runtime/CGINC/SpiderSilk_Look.cginc`・`Editor/SpiderSilkLook.cs`（`Props`）・5 つの `.shader` の Properties を一緒に直します。メニュー **Tools > SpiderShader > 質感プロパティの一致チェック**（取り込み時にも自動実行）で確かめられ、一致しない間は自動同期が止まります。
- **新しいプロパティ**は `SpiderCocoonShaderGUI.cs` の `Categories` 表に登録します。未登録だと「その他（未分類）」に出ます。プリセットでの扱い（`Part` = Look / Shape / Gimmick、`Hidden`）もここで決まります。Udon が実行時に渡す値は `RuntimeOnlyProps` に入れてプリセットから除外します。
- ShaderLab の属性の引数（`[Header(...)]` など）は ASCII のみです（日本語を書くとパースエラー）。表示名の日本語は問題ありません。
- **ステンシルのビット**: 繭の視界ジャック 128（`_StencilRef`）、吐いた糸の芯 64（`_SilkStencilBit`）、デカールが塗らない画素 192（`_StencilSkipMask` = 128 + 64）。どれかを変えたら合計をそろえます。
- **描画順**: 吐いた糸は `Transparent-10`、それ以外は `Transparent`。理由は [吐いた糸の「描画順とステンシル」](docs/SpiderThreadTrail.md#描画順とステンシル)。
- **上限値の対応**: `SC_PULL_MAX` = `SurfaceContactDeformer.MaxSlots`（16）、まとめ描きの仲間 `SCG_MAX_MEMBERS`（8）と `CocoonGroupLinker` のグループ上限。
- 繭・デカールはオブジェクト空間を使う判定があるため `DisableBatching` タグを付けています。

### ドキュメントの方針

- 利用者向けの説明は `docs/` が正本です。パッケージ内の `README.md` と `Runtime/SurfaceContactDeformer/readme.md` は、docs へのリンクだけを置く入口です（VCC で入れた人向け）。
- プロパティを追加・変更したら、対応する docs の表（表示名・内部名・既定値）も更新します。表はインスペクタの並び順にそろえています。
- このルート README は、配布ページ（GitHub Pages）にも埋め込まれます（`.github/scripts/build.mjs`）。先頭の `# 見出し` は削られ、相対リンクは `main` ブランチの GitHub の URL に書き換わります。利用者向けの内容を上に、開発者向けの内容を下に置いてください。

### リリース手順（メンテナ向け）

1. GitHub リポジトリの「Settings > Secrets and variables > Actions」で、リポジトリ変数 `PACKAGE_NAME` に `com.mecaota.spider-shader` を設定（初回のみ）
2. 「Settings > Pages > Source」を「GitHub Actions」に設定（初回のみ）
3. `Packages/com.mecaota.spider-shader/package.json` の `version` を、公開済みの最新より上げてコミット
4. Actions タブから「Build Release」workflow を手動実行 → zip / unitypackage 付きの Release が作成され、続けて「Build Repo Listing」が GitHub Pages のリスティングと配布ページを更新
5. README.md や Website/ の変更を main に push した場合も「Build Repo Listing」が自動実行され、配布ページが更新される（GitHub 上で手動作成・編集した Release を反映するには「Build Repo Listing」を手動実行）

### 作者のワールド（WebbedWorld）での使用例と経緯

作者のワールド（WebbedWorld、このリポジトリには含まれない）での使い方と、設計判断の経緯のメモです。ここに出てくるアセット・メニュー・スクリプトは**パッケージには入っていません**。

**蜘蛛の巣**

- 縦糸の粘液感 `_SpokeGoo` の使い分け: 飛ばした巣（Web / BossWebContact / StickyNet / ScatterNet / WebContactParticle）は 1、固定設置の巣（WebContact / WebContactStation / HomeWeb / TreeGimmickWebArea / WebFan）は 0。Web.mat はパーティクル（ThreadParticle）用なので 1 で、固定設置のバリアントが 0 を上書きしている。フォトコーナーの WebOrbAmbient は 1 にしたバリアント WebContactParticle.mat を使う。
- `Assets/mecaota/materials/WebFan.mat`: 中心 (-0.94, -0.94)・開き 90°・向き 45°・半径 0.94 の扇形。
- 木の根元の巣 `TreeWebStations`（131 個）: 幹の正面・地面から 1.75 m にハブがあり、両端の縦糸は幹を左右 95° まで回り込んで根元へ降り、外周は地面に接地する曲面の扇形。メッシュは木ごとに `Tools/SpiderPhoto/Unit11b Fit Tree Web Fans`（`Assets/Editor/SpiderPhotoGimmick/TreeWebFanBuilder.cs`）が幹の太さと地形の高さを測って作り、`Assets/mecaota/models/TreeWebFanMeshes.asset` にまとめて保存する。UV は曲面の展開図（UV の半径＝ハブから曲面に沿った長さ、1 UV = 2.4 m）で、共通マテリアル `WebContactStation.mat` の開き角度 117° に合わせてある。SurfaceContactDeformer の `Shape = TreeFan` はメッシュ生成と同じ式で面の高さと傾きを求め、木ごとの値はツールが `Tree*` 項目に書き込む。
- 縦横の質感の比較用に `Assets/mecaota/WebAppearanceTests` に 4 種類（横のみ・縦のみ・両方・両方なし）の材質と比較 Prefab を置いている（EditorOnly でアップロードしない）。

**吐いた糸・質感の継承**

- 継承元はすべて `SpiderThreadGoo.mat` の Material Variant。
- 捕獲後の接続糸（Chaise・Stationary）は 33 点に分割し、MaterialPropertyBlock で長さとたわみを渡している。蜘蛛自身の降下ロープはたわみの対象外。
- 旧式の射出糸には `SpiderThreadGravity.mat` を用意し、吊り下げなどが共有する `SpiderThread.mat` の設定は変えていない。射出パーティクルの Min Vertex Distance は 0.08 m。

**繭・デカール**

- 吊り下げギミックの `HangingWrap.mat` は `_WrapFacing` = 0.2。
- 繭をボーンに追従させる `PlayerBoneConstraint` / `PlayerBoneDirectionConstraint` はワールド側の実装。`alongBone`（骨の長さに対する割合）で位置をずらし、吊り下げギミックの太ももの繭は 0.35。
- 巻きアニメの `_WindProgress` はワールド側の `BossSpiderController` が MaterialPropertyBlock で渡す。

**接触追従の変形**

- 固定設置の巣（木のステーション・Web/WebPlane・Nest/WebPlane・Web/WebSphere・フォトコーナーの足元/手の巣）は [推奨設定の例](docs/UdonGimmicks.md#推奨設定の例地面木などに固定した巣) の値でそろえ、`Tools/SpiderPhoto` の Unit9／10／11 も同じ設定で生成する。飛ばした網（StickyNet）は対象外。
- 木のステーション（TreeWebStation.prefab）の効果音は子の `StickySE`（`audios/sticky.wav`、3D）。
- `Capture Only Below Surface` は落とし穴の巣（FootTrapWeb）用。
- 以前あった「ボーンへの粘着追従」（`_PullAdhesion`・`_PullContactSize`・`_PullContactThicken`・`_PullEdgePin`）は描画に使っていなかったため撤去した。

**ねばねばネット**

- 2026-10-08 に採用。それまで試したねばねばネット系（四角の網 `SpiderGooQuadNet` / `Decal`、絡みつきデカール `SpiderGooWrapDecal`、水玉の巣 `SpiderGooDotWeb`、重ね巣 `SpiderGooLayeredWeb`、焼き込み重ね巣 `SpiderGooLayeredWebBaked` と「蜘蛛の巣から作る」機能、蜘蛛糸の格子 `SpiderGooSilkGridBaked`）は、評価が圧倒的によかったこのシェーダーに置き換えて同じ日に撤去した（いずれもこのリポジトリには入っていない）。経緯と比較画像は WebbedWorld の `WorkLogs/2026-10-08-silk-grid/` と `WorkLogs/2026-10-08-goo-sheet/`。
- 見本は `Tools/Spider Dungeon/WebbedWorld/Build Goo Sheet Samples` で `Assets/mecaota/GooNet/` に作る（2 層・3 模様・圧縮、質感は `SilkLook_CaptureNet` を継承）。
  - `GooSilkSheetCapture.mat`: 投げ網用（`CaptureDrape.mat` から Drape・Pull・外形の半径を写す）
  - `GooSilkSheetSample.mat`: 板・球・円柱に貼る見本（外形の半径 0.71）
  - `GooSilkSheetFloor.mat`: 覆いかぶせるゾーンの床の円
  - `GooNetWrapZone.prefab`: 床の円に立った人へ粘液シートを頭の上から落として全身にかぶせる見本（最大 4 人）。落とす向きは円に入った本人が決めてネットワークイベントで全員へ伝える。中身は `GooNetWrapZone`（Udon、NoVariableSync）と 1 人 1 枚の `CaptureNetDrape`（投げ網と同じ `Drop` → `Land`）。
- 投げ網 `CaptureNetDrape` では WebPlane（1 m 四方）を約 1.95 倍に広げるので、帯の幅 0.12 は約 23 cm になる。
- 軽量化（2026-10-08）: 深度を一番内側の層だけ書く（16 パス → 9 パス）、投げ網は 33×33 頂点の専用メッシュ `GooSheetPlane33.asset`（WebbedWorld のビルダーが作る）。
- 体に被せた投げ網 1 枚の追加時間（Unity Editor・1080p・RX 9070 XT、網を出した時と消した時を交互に測った差。比べられるのは同じ回の中だけ）:

| | 寄り | 全身 2.6 m | 遠く 8 m |
|---|---:|---:|---:|
| 2 層・軽量化前（16 パス・65×65） | +0.49 ms | +0.20 ms | +0.11 ms |
| 2 層・軽量化後（9 パス・33×33） | +0.28 ms | +0.13 ms | +0.10 ms |
| 3 層・軽量化前 | +0.61 ms | +0.26 ms | +0.21 ms |
| 3 層・軽量化後 | +0.33 ms | +0.15 ms | +0.09 ms |

焼き込みの解像度（1024 → 512）や使わない層のパスを削っても速さは変わらなかった（512 はメモリが 12 → 3 MiB）。

### 既知の課題

- シェーダー・C# のコメントに古い記述が残っている（「4 シェーダー」の表記、撤去したシェーダー名、`SpiderWeb.shader` 冒頭の「縦糸を別に描いて横糸を重ねる」説明、`SpiderThreadTrail.shader` 冒頭の「繭と同じ共通実装」など）。実装は docs の説明のとおり。
- 蜘蛛の巣の標準プリセットは、後から追加された項目（体に覆いかぶさる変形の巻きつき・姿勢追従、近接表示）の値を持っていない。
- Quest（Android）での動作は未確認。
