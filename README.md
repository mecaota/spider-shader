# Spider Cocoon Shaders

蜘蛛の巣・繭による拘束表現を行うVRChatワールド向けシェーダー集です。**Unity Built-in Render Pipeline専用**（URP/HDRP非対応）。

- 繭本体（`mecaota/SpiderCocoon`）: 円柱メッシュに手続き的な糸を巻き、内側に入ると「包まれ演出」（視界ジャック）
- 深度デカール（`mecaota/SpiderCocoonDepthDecal`）: 第三者視点でプレイヤーの体表に繭を張り付ける
- 蜘蛛の巣（`mecaota/SpiderWeb`）: 断裂・立体感付きの蜘蛛の巣
- 糸トレイル（`mecaota/SpiderThreadTrail`）: Trail Renderer / Particle System用の吐き糸
- 地面転写（`mecaota/SpiderWebGroundProjector`）: 蜘蛛の巣の転写プロジェクター

シェーダーの詳細な解説・パラメーター一覧は[パッケージ内のREADME](Packages/com.mecaota.spider-cocoon/README.md)を参照してください。

## インストール

### VCC（VRChat Creator Companion）/ ALCOMから

1. リポジトリリスティング`https://mecaota.github.io/spider-shader/index.json`をVCCに追加（または<https://mecaota.github.io/spider-shader/>の「Add to VCC」ボタン）
2. プロジェクトに「Spider Cocoon Shaders」を追加

### 手動インストール

[Releases](https://github.com/mecaota/spider-shader/releases)から`com.mecaota.spider-cocoon-x.y.z.zip`をダウンロードし、Unityプロジェクトの`Packages/com.mecaota.spider-cocoon/`に展開してください（`.unitypackage`版もあります）。

## リポジトリ構成

[vrchat-community/template-package](https://github.com/vrchat-community/template-package)準拠のVPMパッケージリポジトリです。

```text
Packages/com.mecaota.spider-cocoon/   パッケージ本体
  package.json                        VPMパッケージ定義
  Runtime/                            シェーダー本体（*.shader, CGINC/*.cginc）
  Editor/                             カスタムインスペクタ（Editor専用・ビルド非含有）
.github/workflows/                    リリース＆VPMリスティング自動生成
Website/                              リスティングのランディングページ（GitHub Pages）
```

### リリース手順（メンテナ向け）

1. GitHubリポジトリの「Settings > Secrets and variables > Actions」で、リポジトリ変数`PACKAGE_NAME`に`com.mecaota.spider-cocoon`を設定（初回のみ）
2. 「Settings > Pages > Source」を「GitHub Actions」に設定（初回のみ）
3. `package.json`の`version`を上げてコミット
4. Actionsタブから「Build Release」workflowを手動実行→zip / unitypackage付きのReleaseが作成され、続けて「Build Repo Listing」がGitHub Pagesのリスティングを更新

## ライセンス

[MIT License](LICENSE)
