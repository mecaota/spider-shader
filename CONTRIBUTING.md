# 開発者向けノート

このリポジトリを改造・保守する人向けの情報です。シェーダーを使うだけなら、[README](README.md) と [docs/](docs/) を見てください。

## リポジトリ構成

[vrchat-community/template-package](https://github.com/vrchat-community/template-package) に準拠した VPM パッケージのリポジトリです。

```text
README.md                             利用者向けの入口（配布ページにも埋め込まれる）
CONTRIBUTING.md                       このファイル（開発者向けノート）
Packages/com.mecaota.spider-shader/   パッケージ本体（VCC で配布される範囲）
  package.json                        VPM パッケージの定義（バージョンはここで上げる）
  README.md                           パッケージ内の入口（docs/ へのリンクのみ）
  Runtime/                            シェーダー（*.shader）と共通コード（CGINC/*.cginc）
    CocoonGroupLinker/                繭のまとめ描きの Udon
    SurfaceContactDeformer/           接触追従の変形の Udon
    WebBake/                          巣の lilToon 焼き込みの控え（エディター専用のコンポーネント）
  Editor/                             インスペクタ・質感の継承・プリセット・焼き込み・メッシュ生成（Editor 専用）
    SpiderWeb*Bake*.cs                巣の lilToon 焼き込み（確認画面・控えのインスペクタ・ビルド時の除去。SpiderWebMaterialSnapshotUtil.cs も）
    Shaders/, CGINC/                  焼き込み用シェーダー（Editor 専用。ねばねばネット用と、巣の lilToon 焼き込み用の SpiderWebBake.shader）
  Presets/                            標準プリセット（SpiderShaderPreset アセット）
docs/                                 利用者向けドキュメント（シェーダーごと＋共通機能＋Udon ギミック）
Website/                              配布ページのテンプレート
.github/workflows/                    リリースと VPM リスティングの自動生成
.github/scripts/                      リスティング（index.json）と配布ページの生成スクリプト
```

- `Editor/` のスクリプトは `includePlatforms: Editor` の asmdef で分けてあり、ワールドのビルドには含まれません。VRChat SDK（`com.vrchat.base`）があるときだけ `SPIDER_SHADER_VRCSDK` が定義され、Build & Upload 直前の質感の同期が有効になります。
- `Runtime/` の asmdef は `VRC.Udon`・`UdonSharp.Runtime` を参照しています。
- `Editor/` の asmdef は、巣の焼き込みの控え（`Runtime/WebBake/SpiderWebBakeBackup.cs`）を使うため、`Runtime/` の asmdef（`com.mecaota.spider-shader`）を参照しています。lilToon は参照せず、`Shader.Find` とリフレクションで探します（lilToon の無いプロジェクトでもコンパイルが通る）。

## シェーダーと共通コード（CGINC）の関係

各シェーダーは同じ `Runtime/` 内の `CGINC/` を相対パスで include しています。フォルダ構造を変えないでください。

| CGINC | 役割 | 使うシェーダー |
|---|---|---|
| `SpiderSilk_Look.cginc` | 質感 21 項目の uniform 宣言（**宣言はここだけ**） | 受け手マスクを除く 5 シェーダー（`SpiderCocoon_Common` / `SpiderGoo_Shading` 経由） |
| `SpiderGoo_Shading.cginc` | 粘液の塗り（丸い断面・トゥーン・ハイライト・輪郭線・透け） | 糸・巣・繭・デカール・ねばねばネット |
| `SpiderCocoon_Common.cginc` / `SpiderCocoon_Noise.cginc` / `SpiderCocoon_Thread.cginc` / `SpiderCocoon_Lighting.cginc` | 共通の uniform・ノイズ・糸の位相・リムライト・揺れ | 糸・巣・繭・デカール・ねばねばネット |
| `SpiderCocoon_Compose.cginc` | 乾いた糸のレイヤー合成（`SC_CompositeLayers`） | 吐いた糸（乾いた糸モード）。繭・デカールは include のみ |
| `SpiderThread_Goo.cginc` | 粘液の束・膜の距離場（`STG_GooField`） | 吐いた糸、ねばねばネットの焼き込み |
| `SpiderCocoon_Goo.cginc` | 繭の粘液の帯・巻きアニメ（`SC_CompositeGoo`） | 繭・デカール |
| `SpiderCocoon_VisionJack.cginc` | 視界ジャック（包まれ演出） | 繭・デカール |
| `SpiderCocoon_Group.cginc` / `_GroupShell.cginc` | くっついた繭のまとめ描き・外殻 | デカール |
| `SpiderCocoon_Sheet.cginc` | 表面の模様「ねばねばネット風」（`_SurfaceStyle`） | デカール |
| `SpiderWeb_Core.cginc` | 巣の頂点・フラグメントの処理（`SpiderWeb.shader` の本体）。`SW_BAKE` を定義して include すると視線と光の向きが焼き込み用に置き換わり、巣の lilToon 焼き込み用の `Editor/Shaders/SpiderWebBake.shader` と同じ式を共有する | 巣、巣の lilToon 焼き込み |
| `SpiderCocoon_Pull.cginc` | 接触追従の変形（`SC_PULL_MAX = 16`） | 巣・繭・ねばねばネット |
| `SpiderWeb_Drape.cginc` | 体に覆いかぶさる変形（`SW_DRAPE_MAX = 20`） | 巣・ねばねばネット |
| `SpiderSilk_Motion.cginc` | 揺れ・重力たゆみの波形 | 糸・巣 |
| `SpiderGooSheet_BakedPattern.cginc` | 焼き込んだ模様の読み取り | ねばねばネット |

インスペクタは全シェーダー共通の `Editor/SpiderCocoonShaderGUI.cs`（受け手マスクを除く）が描きます。

## 変更するときの約束

- **質感 21 項目**は、名前・型・範囲・既定値・属性を全 5 シェーダーで完全に一致させます。足す・消すときは `Runtime/CGINC/SpiderSilk_Look.cginc`・`Editor/SpiderSilkLook.cs`（`Props`）・5 つの `.shader` の Properties を一緒に直します。メニュー **Tools > SpiderShader > 質感プロパティの一致チェック**（取り込み時にも自動実行）で確かめられ、一致しない間は自動同期が止まります。
- **新しいプロパティ**は `SpiderCocoonShaderGUI.cs` の `Categories` 表に登録します。未登録だと「その他（未分類）」に出ます。プリセットでの扱い（`Part` = Look / Shape / Gimmick、`Hidden`）もここで決まります。Udon が実行時に渡す値は `RuntimeOnlyProps` に入れてプリセットから除外します。
- ShaderLab の属性の引数（`[Header(...)]` など）は ASCII のみです（日本語を書くとパースエラー）。表示名の日本語は問題ありません。
- **ステンシルのビット**: 繭の視界ジャック 128（`_StencilRef`）、吐いた糸の芯 64（`_SilkStencilBit`）、受け手マスク 32（`_StencilReceiverBit`）、蜘蛛の体 16（ワールド側のシェーダーが立てる）。デカールの体表 glue は `_GlueStencilRef` / `_GlueStencilReadMask`（既定 0 / 208 = 128 + 64 + 16、受け手マスクと組むときは 32 / 240）。どれかを変えたら合計をそろえます。
- **描画順**: 吐いた糸は `Transparent-10`、それ以外は `Transparent`。理由は [吐いた糸の「描画順とステンシル」](docs/SpiderThreadTrail.md#描画順とステンシル)。
- **上限値の対応**: `SC_PULL_MAX` = `SurfaceContactDeformer.MaxSlots`（16）、まとめ描きの仲間 `SCG_MAX_MEMBERS`（16）と `CocoonGroupLinker` の `MaxMembers`（16）。
- 繭・デカールはオブジェクト空間を使う判定があるため `DisableBatching` タグを付けています。
- 巣の lilToon 焼き込み（`Editor/SpiderWebLilToonBaker.cs`）の焼き方（座標・色・ミップ・lilToon の設定）を変えたら `ToolVersion` を上げます。`SpiderWeb_Core.cginc` を変えると焼き込みの色も変わりますが、焼いた巣には自動では反映されません（焼き直しが必要）。

## ドキュメントの方針

- 利用者向けの説明は `docs/` が正本です。パッケージ内の `README.md` と `Runtime/SurfaceContactDeformer/readme.md` は、docs へのリンクだけを置く入口です（VCC で入れた人向け）。
- プロパティを追加・変更したら、対応する docs の表（表示名・内部名・既定値）も更新します。表はインスペクタの並び順にそろえています。
- ルートの `README.md` は、配布ページ（GitHub Pages）にも埋め込まれます（`.github/scripts/build.mjs`）。先頭の `# 見出し` は削られ、相対リンクは `main` ブランチの GitHub の URL に書き換わります。そのため README には利用者向けの内容だけを書き、開発者向けの内容（このファイル）は分けています。

## リリース手順（メンテナ向け）

1. GitHub リポジトリの「Settings > Secrets and variables > Actions」で、リポジトリ変数 `PACKAGE_NAME` に `com.mecaota.spider-shader` を設定（初回のみ）
2. 「Settings > Pages > Source」を「GitHub Actions」に設定（初回のみ）
3. `Packages/com.mecaota.spider-shader/package.json` の `version` を、公開済みの最新より上げてコミット
4. Actions タブから「Build Release」workflow を手動実行 → zip / unitypackage 付きの Release が作成され、続けて「Build Repo Listing」が GitHub Pages のリスティングと配布ページを更新
5. README.md や Website/ の変更を main に push した場合も「Build Repo Listing」が自動実行され、配布ページが更新される（GitHub 上で手動作成・編集した Release を反映するには「Build Repo Listing」を手動実行）

## 作者のワールド（WebbedWorld）での使用例と経緯

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

**巣の lilToon 焼き込み**

- 2026-10-14 に追加。ワールド固有のスクリプトの個別の説明（空中の巣の壁 `AerialWebWall`・ハンモックの巣 `HammockWebTrap`・`BossStickyNetManager`・`PitfallWebTrap`）と、焼けない網（`CaptureNetDrape`・`SpiderSilkShooter`）は、パッケージ 0.9.0 で名前を外した。ワールドの Editor コードから `SpiderWebLilToonBaker.RegisterKnownScript` で登録する（`AerialWebWall` は表示する距離 `cullOnDistance` / `cullOffDistance` を読んで説明に入れる）。登録しないと一般の【注意】になり、捕獲網でもマテリアルの `_DrapeEnable` が OFF なら焼けてしまう（SkinnedMeshRenderer・パーティクルの網は登録しなくても断る）。
- `SpiderWeb_Core.cginc` を `SpiderWeb.shader` から切り出す前後で、巣の描画は 19 構図で画素が一致し、D3D11 のバイトコードも 16 バリアントすべてで一致した。
- 巣だけの描画時間（巣を消した画面との差。2026-10-14、Unity Editor、1080p 全画面、RX 9070 XT、MSAA なし）:

| 巣 | 元 | 焼いたあと |
|---|---:|---:|
| WebPlane の巣 | 0.72 ms | 0.22 ms |
| 木の扇の巣 | 0.96 ms | 0.34 ms |
| 空中の巣の板 | 0.67 ms | 0.06 ms |

MSAA 4x でも 62〜77% 減った。画面に巣が小さく写るときは差も小さくなる。実機の VRChat（VR・鏡・多人数）では未計測。

- 被覆率を保つミップの実測: 空中の巣の板は 2048 段 24.55% → 32 段 24.81%（ふつうの平均なら 32 段で 1.27% まで減る）。木の扇の巣は 34.66% → 36.72%（+2.06 ポイント）。1×1〜16×16 の段は画素が少ないので割合が粗くなる。

## 既知の課題

- シェーダー・C# のコメントに古い記述が残っている（「4 シェーダー」の表記、撤去したシェーダー名、`SpiderWeb.shader` 冒頭の「縦糸を別に描いて横糸を重ねる」説明、`SpiderThreadTrail.shader` 冒頭の「繭と同じ共通実装」など）。実装は docs の説明のとおり。
- 蜘蛛の巣の標準プリセットは、後から追加された項目（体に覆いかぶさる変形の巻きつき・姿勢追従、近接表示）の値を持っていない。
- Quest（Android）での動作は未確認。
