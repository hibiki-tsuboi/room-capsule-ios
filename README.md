# Room Capsule

いま目の前にある部屋を iPhone でスキャンして、**ミニチュア AR・実寸 AR・写真のような 3D 空間・2D 間取り図**として保存し、あとから再体験できる iOS アプリ。

> 部屋を保存して、呼び出して、のぞいて、時間を戻せる。

同じ部屋を何度もスキャンして「バージョン」として重ねられるのが特徴で、引っ越し・模様替え・内見の Before / After をスライダーで見比べられます。

## 機能

- **RoomPlan スキャン** — 部屋を LiDAR でスキャンして「部屋カプセル」として保存(部屋名・バージョン名はデフォルト入力済みでそのまま保存可)
- **3D プレビュー** — オービットカメラで模型を回して眺める。模型 / 高品質(USDZ)/ 寸法 / X線 / 家具だけ / 構造だけ / メモ / 写真 / 線画 の表示モード切替
- **ミニチュア AR** — 机の上に手のひらサイズのドールハウスを設置。ピンチ拡大・回転・移動、壁や家具のタップで情報表示、シャッターで写真共有。**実寸トグル**で 1:1 スケールに切り替え、部屋の中を歩ける(透明度スライダーで現実に重ねて透かせる)
- **部屋の中に入る** — 部屋全体の俯瞰から中へ降りていくカメラ演出で入室し、ドラッグで見回し・ピンチで前後移動して中を歩ける 3D ビュー(シミュレータでも動作)
- **写真っぽく見る** — Metal による Gaussian Splatting 実レンダリングのハブ画面。模型⇄写真のクロスフェード表示、「**AR で置く**」で現実空間にスプラットの部屋を設置して中に入って歩ける。データがなければその場で用意できる: 「この部屋をスキャンして作る(LiDAR)」で外部アプリなしに Splat 化(法線推定つきの面スプラット・リアルタイムプレビュー付き)、`.ply` / `.splat` の取り込み(`.spz` は描画未対応のため対象外)、サンプル生成。差し替え・削除・上下反転は画面内の「…」メニューから
- **メモ管理** — 空間メモピン(カテゴリ・写真添付・3D プレビューや実寸 AR でのタップ配置)
- **家具ゴースト** — 半透明の家具プリセットを配置しサイズ/位置/回転を編集。ミニチュア AR・実寸 AR・3D プレビュー内では**ゴーストを指で掴んでドラッグ移動**(自動保存)
- **時間を比べる** — 同じ部屋の 2 バージョンをスライダーでクロスフェード(自動ピンポン再生付き)。**スキャンごとに異なる座標系の向きは自動で位置合わせ**される
- **図面で見る** — SwiftUI Canvas の 2D 間取り図(寸法・凡例・ピンチズーム)。スキャン開始時の端末の向きによらず**壁が水平・垂直になるよう自動で正立化**
- **採寸サマリー / USDZ 共有** — 床面積(㎡・畳)・天井高・壁の総延長を表示。USDZ は共有メニューから送れて、受け取った人は AR Quick Look でそのまま閲覧可
- **完全ローカル保存** — クラウド送信・ログインなし。削除ボタンでファイルごと完全削除

v1 では Gaussian Splatting・ポータル AR・メモピン・家具ゴーストの導線を `FeatureFlags.swift` で非表示にしていましたが、**v1 リリース後に再有効化済み**です(スコープを絞りたいときは bool を戻すだけ)。ポータル AR のみ、その後「部屋の中に入る」ビューに置き換えて導線を廃止しました(実装は残置)。

## 必要な環境

| 用途 | 要件 |
|---|---|
| ビルド | Xcode 26 以降 / デプロイターゲット iOS 26.0 / Metal Toolchain(下記) |
| 部屋スキャン(RoomPlan) | LiDAR 搭載の iPhone / iPad(Pro 系)+ iOS 16 以降 |
| ミニチュア / 実寸 / Splat の AR 設置 | ARKit ワールドトラッキング対応端末 |
| LiDAR スプラットキャプチャ | LiDAR 搭載の iPhone / iPad(Pro 系) |
| デモモード | **シミュレータ含むすべての環境**(RoomPlan / AR 不要) |

RoomPlan や AR が使えない環境では、自動的にフォールバック画面(デモモード誘導・3D プレビュー)へ案内されます。

## ビルドと実行

初回のみ: Xcode 26 は Metal コンパイラが別配布のため、`.metal` を含む本プロジェクトのビルドには Metal Toolchain が必要です。

```sh
xcodebuild -downloadComponent MetalToolchain   # 未導入のマシンのみ(約 700MB)
```

```sh
xcodebuild -project "Room Capsule.xcodeproj" -scheme "Room Capsule" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' build

xcrun simctl boot "iPhone 17 Pro"   # 未起動なら
xcrun simctl install booted <ビルド成果物の Room Capsule.app>
xcrun simctl launch booted jp.hibiki.roomcapsule -seedDemo
```

開発用の起動引数(すべて **DEBUG ビルド限定**):

- `-seedDemo` … 起動時にデモ部屋を自動投入(データが空のときのみ)
- `-autoPreview` … 最初のカプセルの 3D プレビューを自動表示(`-previewMode <rawValue>` で初期モード指定可)
- `-autoDetail` … 最初のカプセルの詳細画面を自動表示(`-autoInside` 併用で「部屋の中に入る」、`-autoPhotoMode` 併用で「写真っぽく見る」まで自動遷移)
- `-autoTimeline` … 最初のカプセルの Before / After 比較を自動表示
- `-autoSettings` … 設定シートを自動表示
- `-autoSplat` / `-autoSplatAR` / `-autoSplatCapture` … Splat 系スタックのスモークテスト用(サンプル Splat 生成 → ビューア / Splat AR / LiDAR キャプチャを自動表示)

## 使い方

1. ホームの「**部屋をスキャン**」で RoomPlan スキャン。iPhone をゆっくり動かして部屋全体を映し、完了したらデフォルトの名前のまま(または書き換えて)保存。
2. 部屋カードを開くと、サムネイル(タップで 3D プレビュー)・バージョン切替・採寸サマリーと、**3D プレビュー / ミニチュアで見る / 部屋の中に入る / 写真っぽく見る / 時間を比べる / 図面で見る / メモ管理 / 家具管理**のグリッドが並びます。
3. 「バージョンを追加」で同じ部屋を時間をおいて再スキャンすると、「時間を比べる」で Before / After を行き来できます。
4. 「写真っぽく見る」の「**サンプルデータで試す**」で、実データがなくても Gaussian Splatting の実レンダリングをその場で体験できます。

## アーキテクチャ

```
Room Capsule/
├── FeatureFlags.swift   リリーススコープの制御(導線スイッチ。現在は全機能有効)
├── Models/              RoomCapsule / RoomScanVersion / SimplifiedRoomGeometry / SplatAsset など(すべて Codable)
├── Services/
│   ├── RoomCapsuleStore.swift        JSON + Documents のローカル永続化ストア(ObservableObject)
│   ├── RoomGeometryAlignment.swift   スキャン間の回転推定(タイムライン位置合わせ・間取り図の正立化)
│   ├── DemoRoomFactory.swift         デモ部屋(2 バージョン)生成
│   ├── CapturedRoomConverter.swift   RoomPlan CapturedRoom → 簡易ジオメトリ変換
│   ├── AppFiles.swift                Documents 相対パス管理
│   └── Splat*.swift                  Gaussian Splatting 一式(ローダ / レンダラ / LiDAR キャプチャ)
├── Shaders/GaussianSplat.metal       楕円ガウス投影シェーダ
├── AR/
│   ├── RoomEntityFactory.swift       簡易ジオメトリ → RealityKit エンティティ(全表示モード共通)
│   └── ARSupport.swift               対応判定・ハプティクス・タップ選択・ゴーストドラッグ
└── Views/               ホーム / 詳細 / スキャン / ミニチュア(実寸トグル込み)/
                         3Dプレビュー(部屋の中に入る兼用)/ 間取り / タイムライン /
                         メモ / ゴースト / Splat / 設定
```

設計のポイント:

- **簡易ジオメトリ中心**: RoomPlan の生データ(JSON)と USDZ も保存しつつ、描画の基本は「箱の集まり」(`SimplifiedRoomGeometry`)。USDZ を使うのは「高品質」モードだけで、読めない場合も箱モデルへフォールバックするため、どの環境でも表示が崩れない。
- **永続化はバージョン付き JSON**: `capsules.json` は `{schemaVersion, capsules}` の封筒形式。スキーマを変えるときは `schemaVersion` を上げて `load()` に移行を足す(新フィールドは Optional が原則)。
- **座標系の扱い**: RoomPlan の座標はスキャン開始時の端末の向きが基準。`RoomGeometryAlignment` が壁方向から回転を推定し、間取り図・サムネイルの正立化と、タイムライン比較の 2 スキャン位置合わせを行う。
- **サムネイル**は 2D 間取り Canvas を `ImageRenderer` で PNG 化して生成(AR 不要)。
- **ダークモード固定**: 配色(`Theme`)・白文字はダーク前提でハードコードしており、ルートと各シートで `.preferredColorScheme(.dark)` を指定。システム設定に追従しない意図的な設計。
- **アプリ設定**: 表示名は「Room Capsule」、App カテゴリはライフスタイル、iPhone は縦向き固定(iPad は全方向・コンテンツ幅は最大 700pt で中央寄せ)。いずれも pbxproj の `INFOPLIST_KEY_*` で管理。
- **プライバシー**: すべてローカル保存。クラウド送信・ログインなし。削除ボタンでファイルごと完全削除。詳細は[プライバシーポリシー](docs/privacy-policy.md)([公開ページ](https://hibiki-tsuboi.github.io/room-capsule-ios/privacy-policy.html))を参照。

## 制限事項

- Before / After は透明度クロスフェード(形状補間はしない)。窓・ドア・家具が検出されなかった真四角の空部屋どうしでは、比較時の 180° の向き判別が原理的に曖昧。
- 「高品質(USDZ)」モードは実スキャンした(USDZ を持つ)バージョンのみ。RoomPlan はテクスチャを取得しないため、形状は正確ですが色は付きません。初回読み込み時に一瞬止まることがあります(以降はキャッシュ)。
- RoomPlan スキャンの実機確認は LiDAR 端末が必要(シミュレータではフォールバックを確認済み)。
- Gaussian Splatting: 高速にカメラを回すと一瞬だけ合成順が古いことがある(非同期ソートのため)。高次 SH 付きデータはメモリを多めに使う(100 万スプラットで約 +90MB)。LiDAR キャプチャ・`.splat` 形式は SH を持たないため DC 色のみ。`.spz` は gzip 展開未実装のためメタデータ表示のみ。
- LiDAR スプラットキャプチャは学習(最適化)を行わないサーフェル方式のため、品質は Scaniverse などの学習済み 3DGS には及ばない。

## 今後の改善アイデア

- 間取り図の画像共有(内見メモを家族に送るユースケース)
- カプセルの書き出し/読み込み(.roomcapsule で AirDrop 共有・バックアップ)
- 複数部屋の結合(StructureBuilder で「家まるごとカプセル」)
- `.spz` の gzip 展開(Scaniverse のデフォルト形式)
