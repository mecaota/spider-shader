# Spider Shaders

蜘蛛の巣や繭に捕らわれる「疑似拘束」を演出するための、VRChat ワールド向けシェーダー集です。蜘蛛が吐いた糸、張られた巣、体に巻きつく繭、体にかぶさる粘液のネットを、画像素材を用意しなくてもシェーダーの計算だけで描きます。

> **Unity Built-in Render Pipeline 専用**です。URP / HDRP のプロジェクトでは動きません（マテリアルがピンクになります）。

## シェーダー一覧

名前をクリックすると、使い方とすべての設定項目の説明が開きます。

| シェーダー | 何を描くか | 何に貼るか | 補足 |
|---|---|---|---|
| [吐いた糸（SpiderThreadTrail）](docs/SpiderThreadTrail.md) | 蜘蛛が吐いた糸。乾いた細い糸か、粘液の束 | Trail Renderer・Particle System の Trails・LineRenderer | 巣・繭などの色やツヤを決める「継承元」にもなる |
| [蜘蛛の巣（SpiderWeb）](docs/SpiderWeb.md) | 縦糸と横糸の蜘蛛の巣。扇形・曲面にも対応 | 平面・球のメッシュ（巣用の平面メッシュを生成できる） | |
| [繭（SpiderCocoon）](docs/SpiderCocoon.md) | 糸がぐるぐる巻いた繭。中に入ると内壁に包まれる | 円柱メッシュ | |
| [体に張り付く繭（SpiderCocoonDepthDecal）](docs/SpiderCocoonDepthDecal.md) | プレイヤーの体の表面に沿って巻きつく繭 | 体を包む Cube | **PC 専用**。影付きのリアルタイムライトが必要 |
| [ねばねばネット（SpiderGooSilkSheet）](docs/SpiderGooSilkSheet.md) | 体にかぶさる粘液のシート（最大 8 層） | 平面などのメッシュ | **PC 専用**。使う前に模様の「焼き込み」が必要 |
| [受け手マスク（SpiderCocoonProjectorMask）](docs/SpiderCocoonProjectorMask.md) | 体に張り付く繭を、捕まった人のアバターにだけ描くための目印 | Projector コンポーネント | 試験実装。**PC 専用**。駆動する Udon は同梱していない |

複数のシェーダーで共通の機能:

- [共通機能](docs/CommonFeatures.md) — インスペクタの見方、質感の継承、プリセット、Editor のメニュー
- [Udon ギミック](docs/UdonGimmicks.md) — 触れた手足に巣が貼り付いて伸びる（SurfaceContactDeformer）、くっついた繭をまとめて描く（CocoonGroupLinker）、投げた網が体にかぶさる

### このパッケージでよく出てくる言葉

- **質感の継承** — 巣・繭・ねばねばネットの色やツヤは、それぞれのマテリアルでは決めず、「吐いた糸」のマテリアルから受け取ります。受け取る元のマテリアルを**継承元**と呼びます。1 つの継承元を変えるだけで、それを使う巣や繭の色がまとめて変わります（[詳しく](docs/CommonFeatures.md#質感の継承)）。
- **焼き込み** — ねばねばネットの模様を、あらかじめ画像として書き出しておく処理です。形を変えたら焼き直します（[詳しく](docs/SpiderGooSilkSheet.md#焼き込み)）。
- **視界ジャック** — 繭の中にカメラが入ったとき、周りを繭の内壁で囲んで「包まれた」視界にする演出です（[詳しく](docs/SpiderCocoon.md#視界ジャック包まれ演出のしくみ)）。

## 動作環境

- Unity 2022.3（Built-in Render Pipeline）
- VRChat Worlds SDK 3.8.1 以上（UdonSharp を含む）。同梱の Udon スクリプトが参照しているため、シェーダーだけを使う場合も必要です。
- PC 向けワールドを想定しています。Quest（Android）では、どのシェーダーも動作を確認していません。

## インストール

### VCC（VRChat Creator Companion）/ ALCOM から

1. [配布ページ](https://github.pito.run/spider-shader/)を開き、上部の「Add to VCC」ボタンを押してリポジトリを追加します。
   - ボタンが反応しない場合は、VCC の `Settings` → `Packages` → `Add Repository` に `https://github.pito.run/spider-shader/index.json` を貼り付けます。
2. プロジェクトの「Manage Project」から「Spider Shaders」を追加します。

### 手動インストール

[Releases](https://github.com/mecaota/spider-shader/releases) から `com.mecaota.spider-shader-x.y.z.zip` をダウンロードし、Unity プロジェクトの `Packages/com.mecaota.spider-shader/` に展開してください（`.unitypackage` 版もあります）。

## はじめての使い方

### 1. 巣を 1 枚置いてみる

マテリアルを 1 つ作るだけで、標準の見た目の巣が表示されます。

1. メニュー **Tools > SpiderShader > Generate WebPlane Mesh...** を開き、**Generate** を押します。巣を貼るための平面メッシュ `Assets/mecaota/models/WebPlane.asset` ができます。
2. 空の GameObject を作り、**MeshFilter** を追加して Mesh に `WebPlane` を入れ、**MeshRenderer** も追加します。
   - 平面は床に置いた向き（表が真上 = +Y）で作られます。壁に貼るときは Transform の Rotation の X を 90 にします。
3. Project ウィンドウで **Create > Material** を作り、Shader を `mecaota/SpiderWeb` にして、MeshRenderer に入れます。
4. マテリアルのインスペクタ先頭にある緑の「プリセット」欄で **「蜘蛛の住処の巣」** を押すと、巣が表示されます。

### 2. 巣の色やツヤを変える

巣の色やツヤは、巣のマテリアルでは変えられません。[質感の継承](#このパッケージでよく出てくる言葉)の仕組みで、継承元（吐いた糸のマテリアル）を作ってそちらで変えます。

1. 巣のマテリアルの紫の「蜘蛛糸の質感（継承）」欄で **「今の質感から新しい継承元を作る…」** を押し、保存先を選びます。今の見た目のまま、吐いた糸（`mecaota/SpiderThreadTrail`）のマテリアルが作られ、継承元に設定されます。
2. 同じ欄の **「継承元を開く」** を押すと、継承元のマテリアルが別ウィンドウで開きます。
3. そこで「明部の色」を変えると、巣の色も一緒に変わります。

すでに吐いた糸のマテリアルがあるときは、「継承元の蜘蛛糸」欄にそれを入れるだけでも構いません。継承するのは色・陰影・ツヤ・トゥーン・リムなどの質感だけで、巣の形や糸の本数などは巣のマテリアルで変えます。

## 困ったとき

| 症状 | 原因と対処 |
|---|---|
| マテリアルがピンクになる | Built-in Render Pipeline 以外（URP / HDRP）のプロジェクトでは動きません。 |
| 巣・繭の色やツヤの項目が灰色で変えられない | 色やツヤは継承元の吐いた糸マテリアルで決まるため、巣・繭の側では変えられません。紫の欄の「継承元を開く」で継承元を開いて変えるか、「今の質感から新しい継承元を作る…」でその巣専用の継承元を作ります（[質感の継承](docs/CommonFeatures.md#質感の継承)）。 |
| 体に張り付く繭が何も表示されない | ワールドに**影付きのリアルタイム Directional Light**（Shadow Type が Soft Shadows か Hard Shadows）が必要です。影を描くために Unity が作る奥行きの情報（深度）を使って、体の表面の位置を求めているためです。Cube が体を包んでいるか（位置・向き・スケール）も確認してください（[確認チェックリスト](docs/SpiderCocoonDepthDecal.md#確認チェックリスト)）。 |
| ねばねばネットが何も表示されない | 模様を焼き込むまでは表示されません。インスペクタ下部の黄緑の「焼き込みの状態」欄で **「焼き直す」** を押します。帯の幅などの形を変えたときも押し直します（[焼き込み](docs/SpiderGooSilkSheet.md#焼き込み)）。 |
| 網が体にかぶさらない | 体に覆いかぶさる変形には、体の形と網の位置を毎フレーム渡す Udon が必要です。この Udon はパッケージに含まれていません（[詳しく](docs/UdonGimmicks.md#体に覆いかぶさる変形drape)）。 |
| 足に貼り付いて持ち上がった巣の一部が、画面の端で消える | GameObject の Static のうち **Batching Static を OFF** にしてください。頂点を動かす変形は Unity の「画面に映っているか」の判定範囲（バウンズ）に反映されないため、WebPlane は判定範囲を広げて作ってあります。Batching Static が ON だとメッシュが結合され、この広げた範囲が失われます。2 m 以上持ち上げる場合は、WebPlane の生成画面で **Bounds Up** を上げて作り直します（[詳しく](docs/UdonGimmicks.md#注意制約)）。 |
| 繭の中で、背を向けると内壁が丸ごと消える | 視界ジャックの判定範囲（「内側判定の半径」「内側判定の高さ」）が、繭のメッシュの外にはみ出しています。Unity はメッシュが画面外だと描画ごと省くので、判定範囲をメッシュの内側に収めてください（[詳しく](docs/SpiderCocoon.md#視界ジャック包まれ演出のしくみ)）。 |
| 吐いた糸が重力でたわまない | パーティクルの糸をたわませるには、マテリアルにプリセット「粘液の吐き糸」か「乾いた糸＋重力のたゆみ」を当てたうえで、Particle System 側に 3 つの設定（Trails の Texture Mode を Tile・Custom Vertex Streams・Color over Trail の青チャンネルのグラデーション）が必要です（[詳しく](docs/SpiderThreadTrail.md#重力のたゆみ)）。 |

## 開発者向け

シェーダーと共通コードの構成、変更するときの約束、リリース手順、作者のワールドでの使用例などは [開発者向けノート（CONTRIBUTING.md）](CONTRIBUTING.md) にまとめています。

## ライセンス

[MIT License](LICENSE)
