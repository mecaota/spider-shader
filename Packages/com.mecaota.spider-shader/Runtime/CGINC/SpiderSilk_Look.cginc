#ifndef SPIDERSILK_LOOK_INCLUDED
#define SPIDERSILK_LOOK_INCLUDED

// ---------------------------------------------------------------------------
// SpiderSilk_Look.cginc
// 蜘蛛糸の「質感（Look）」21 個の uniform を、ここ 1 か所でだけ宣言する。
//
// SpiderSilk（継承元の蜘蛛糸）/ SpiderWeb / Cocoon /
// CocoonDecal / SpiderWebDrape（蜘蛛の巣ドレープ）の 5 シェーダーが同じ意味で使う値。
// （繭プロジェクター CocoonProjector は色を描かないので使わない）
// 巣・繭・繭デカール・蜘蛛の巣ドレープのマテリアルには、エディタ拡張が「継承元の蜘蛛糸マテリアル」の
// 値をそのまま書き写す（実行時の処理は無い。Editor/SpiderSilkLook.cs）。
//
// ※ uniform = マテリアルの値をシェーダーへ渡す変数（Web の CSS 変数のようなもの）。
//   同じ名前を 2 回宣言するとコンパイルエラーになるので、宣言は必ずここだけ。
// ★ 一覧の正本は C# の Editor/SpiderSilkLook.cs（SpiderSilkLook.Props）。
//   1 個足す・消すときは次の 3 か所を一緒に直す:
//     1. このファイル  2. SpiderSilkLook.cs
//     3. 対応する全 .shader の Properties（名前・型・範囲・既定値を完全に同じに）
//   ズレるとシェーダーの読み込み後に Console へ日本語の警告が出る
//   （メニュー Tools/SpiderShader/質感プロパティの一致チェック でも確認できる）。
//
// 読み込み: SpiderCocoon_Common.cginc と SpiderGoo_Shading.cginc から include
// （include ガードで 1 回だけ有効。.shader 側の include は変えなくてよい）。
// ---------------------------------------------------------------------------

// ---- 粘液感（全体のつまみ） ----
float  _GooAmount;        // 粘液感 0..1。0 に近いほど乾いた細い糸（ツヤ・透け・太り・膜が消える）

// ---- 粘液の色と陰影 ----
float4 _GooColor;         // 明部の色
float4 _GooShadowColor;   // 影部の色
float  _GooShade;         // 影の広さ（-0.5..0.5。+で影が広がる）
float4 _GooOutlineColor;  // 輪郭線の色（a=輪郭線の不透明度）
float  _GooOutline;       // 輪郭線の太さ（束の半径に対する割合）
float  _GooOpacity;       // 全体の不透明度
float  _GooClarity;       // 中心の透け具合（0=不透明なミルク状 / 1=中心が透ける）

// ---- 粘液のハイライト ----
float4 _GooGlossColor;    // ハイライト色（a=不透明度）
float  _GooGloss;         // ハイライトの強さ
float  _GooGlossWidth;    // ハイライトの筋の太さ（束の半径に対する割合）
float  _GooGlossOffset;   // ハイライトを光源側へ寄せる量
float  _GooGlossBreak;    // ハイライトの途切れ（0=連続した筋 / 1=点々）

// ---- トゥーン陰影 ----
float  _ToonSteps;        // 陰影の段階数 1..8
float  _ToonSmooth;       // 段差の柔らかさ
float  _AmbientBoost;     // 環境光の底上げ
float  _LightInfluence;   // シーン光の反映度（0=完全発光, 1=光に大きく依存）

// ---- シルエットのリムライト ----
float4 _RimColor;         // リムライト色
float  _RimPower;         // リムの幅／鋭さ（大きいほど細い）
float  _RimStrength;      // リムの強さ
float  _RimFloor;         // リムの下限（>0で正面中央にも発光を乗せる）

#endif // SPIDERSILK_LOOK_INCLUDED
