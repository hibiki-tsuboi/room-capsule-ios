# Room Capsule

いま目の前にある部屋を iPhone でスキャンして、**ミニチュア・実寸 AR・ポータル・写真のような 3D 空間**として保存し、あとから再体験できる iOS アプリ。

> 部屋を保存して、呼び出して、のぞいて、時間を戻せる。

## 必要な環境

| 用途 | 要件 |
|---|---|
| ビルド | Xcode 26 以降 / デプロイターゲット iOS 26.0 / Metal Toolchain(下記) |
| 部屋スキャン(RoomPlan) | LiDAR 搭載の iPhone / iPad(Pro 系)+ iOS 16 以降 |
| ミニチュア / 実寸 / ポータル AR | ARKit ワールドトラッキング対応端末 |
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
xcrun simctl launch booted jp.hibiki.roomcapsule.Room-Capsule
```

開発用の起動引数:

- `-seedDemo` … 初回起動時にデモ部屋を自動投入(データが空のときのみ)
- `-autoPreview` … 起動直後に最初のカプセルの 3D プレビューを自動表示(動作確認用)
- `-autoSplat` … サンプル Splat を生成・添付して実レンダリングビューアを自動表示(動作確認用)
- `-autoSplatAR` … サンプル Splat でスプラット AR 画面を自動表示(動作確認用)
- `-autoSplatCapture` … LiDAR 簡易スキャン画面を自動表示(非対応環境ではフォールバック表示)
- `-previewMode <rawValue>` … `-autoPreview` の初期表示モードを指定(例: `-previewMode scanModel`)
- `-autoDetail` … 起動直後に最初のカプセルの詳細画面を自動表示(動作確認用)

## 使い方

1. ホームの「**部屋を保存する**」で RoomPlan スキャン(非対応端末は「**デモ部屋を追加**」)。
2. 部屋詳細には**採寸サマリー**(床面積 ㎡/畳・天井高・壁の総延長)が表示され、右上メニューから **USDZ を共有**できます(受け取った人はアプリなしでも AR Quick Look で閲覧可)。
3. 部屋カードを開くと各モードへ:
   - **ミニチュアで見る** — 机の上にドールハウスを AR 設置。ピンチ拡大・回転・移動、壁/家具タップで情報表示。シャッターボタンで**ミニチュアの写真を撮って共有**。スキャン済みバージョンでは「**高品質**」モードで RoomPlan の USDZ(家具の形状モデル付き)をそのまま表示
   - **実寸で呼び出す** — 床タップで原点を決め 1:1 表示。透明度スライダー、ミニチュア⇄実寸切替
   - **ポータルを開く** — AR のドアの向こうに部屋が見える(遮蔽シェル使用)。ドアをタップすると光のバースト → 白フェード → ドアから歩き入るカメラ演出で部屋の中へ。退出時も白フェード
   - **写真っぽく見る** — 模型がフェードアウトし、Metal による Gaussian Splatting 実レンダリングへクロスフェード
   - **スプラット AR** — 写真のようなスプラットの部屋を**現実空間に置く**。床タップで設置、ピンチ拡大縮小・回転・移動、ミニチュア⇄実寸切替(実寸なら中に入って歩ける)
   - **時間を比べる** — Before / After をスライダーでクロスフェード
   - **図面で見る** — SwiftUI Canvas の 2D 間取り(寸法・凡例・ピンチズーム)
   - **メモを浮かべる** — 空間メモピン(カテゴリ・写真添付・3D プレビューでのタップ配置)
   - **家具ゴースト** — 半透明の家具プリセットを配置しサイズ/位置/回転を編集。ミニチュア AR・実寸 AR・3D プレビュー内では**ゴーストを指で掴んでドラッグ移動**(離すと自動保存)
   - **X線・分解** — X線 / 構造だけ / 家具だけ / 線画 などの表示モード
   - **Splat 管理** — **「この部屋をスプラット化(LiDAR)」で外部アプリなしに自分の部屋を Splat 化**(法線推定つきの面スプラット)。`.ply` / `.splat` / `.spz` の取り込み・バージョン紐づけ・削除、「サンプル Splat を生成」も

## Gaussian Splatting の状態

- **Metal による実レンダリングを実装済み**(`Shaders/GaussianSplat.metal` + `MetalSplatView`)。
  - 3D 共分散(Σ = R·diag(s²)·Rᵀ)は読み込み時に CPU で事前計算し、GPU で毎フレーム 2D へ投影 → 固有分解した楕円クアッドをインスタンス描画。
  - 奥→手前のアルファ合成順は 16bit カウンティングソートで作り、カメラが一定以上回転したときだけバックグラウンドで再ソート。
  - 色は SH の DC 成分のみ(視線依存の高次 SH は未対応)。
- 対応形式: `.splat`(32 バイトレコード)と 3DGS の `.ply`(`scale_0..2` / `rot_0..3` / `opacity` / `f_dc_*`、ASCII / binary_little_endian)。
- フォールバック: 3DGS 属性のない普通の `.ply` 点群は SceneKit の**点群プレビュー**表示、`.spz` は gzip 展開未実装のためメタデータ表示のみ。
- Splat 管理画面の「**サンプル Splat を生成**」で、手続き生成したサンプルルームの `.splat` を作ってその場で実レンダリングを体験できます(実データがなくても OK)。
- **LiDAR スプラットスキャン**: LiDAR 深度から法線を推定し、**面に沿った扁平ガウス**として書き出すサーフェル方式(1cm ボクセル・最大 100 万点・距離重み付き色・フローター除去つき)。学習(最適化)は行わないため、Scaniverse などの学習済み 3DGS には及ばないが、面が連続して見える品質になります。
- **AR 表示に対応**: ARView(カメラ映像・平面検出)の上に透明な MTKView を重ね、毎フレーム ARFrame のカメラ行列でスプラットを描画。モデル行列(配置・回転・一様スケール)はビュー行列に合成され、共分散投影に s²·Σ として自然に伝播するためシェーダは共通です。
- レンダラーは `SplatRenderable` プロトコルで抽象化されており(`SplatRendererRegistry.active`)、別実装への差し替えも可能です。

## アーキテクチャ

```
Room Capsule/
├── Models/          RoomCapsule / RoomScanVersion / SimplifiedRoomGeometry / SplatAsset など(すべて Codable)
├── Services/
│   ├── RoomCapsuleStore.swift      JSON + Documents のローカル永続化ストア(ObservableObject)
│   ├── DemoRoomFactory.swift       デモ部屋(2 バージョン・ピン・ゴースト)生成
│   ├── CapturedRoomConverter.swift RoomPlan CapturedRoom → 簡易ジオメトリ変換
│   ├── SplatImportService.swift    Splat ファイル取り込み
│   ├── GaussianSplatLoader.swift   .splat / 3DGS .ply → 共分散付き Gaussian データ
│   ├── MetalSplatView.swift        Metal 実レンダラー(MTKView + 深度ソート)
│   ├── SplatPointCloudLoader.swift PLY 共通パーサ + 点群フォールバック
│   ├── SplatRendering.swift        レンダラー抽象化(SplatRenderable / Registry)
│   ├── SampleSplatFactory.swift    サンプルルーム .splat の手続き生成
│   └── AppFiles.swift              Documents 相対パス管理
├── Shaders/
│   └── GaussianSplat.metal         楕円ガウス投影シェーダ
├── AR/
│   ├── RoomEntityFactory.swift     簡易ジオメトリ → RealityKit エンティティ(全表示モード共通)
│   └── ARSupport.swift             対応判定・ハプティクス・タップ選択
└── Views/           ホーム / 詳細 / スキャン / ミニチュア / 実寸 / ポータル / 3Dプレビュー /
                     間取り / タイムライン / メモ / ゴースト / Splat / 設定
```

設計のポイント:

- **簡易ジオメトリ中心**: RoomPlan の生データ(JSON)と USDZ も保存しつつ、描画の基本は「箱の集まり」(`SimplifiedRoomGeometry`)。USDZ を使うのは「高品質」モードだけで、読めない場合も箱モデルへフォールバックするため、どの環境でも表示が崩れない。
- **サムネイル**は 2D 間取り Canvas を `ImageRenderer` で PNG 化して生成(AR 不要)。
- **プライバシー**: すべてローカル保存。クラウド送信・ログインなし。削除ボタンでファイルごと完全削除。

## 制限事項

- Gaussian Splatting の色は SH の DC 成分のみ(視線依存の反射などは出ない)。高速にカメラを回すと一瞬だけ合成順が古いことがある(非同期ソートのため)。
- `.spz` はプレビュー不可(メタデータ表示のみ)。
- 「高品質(USDZ)」モードは実スキャンした(USDZ を持つ)バージョンのみ。デモ部屋にはありません。RoomPlan はテクスチャを取得しないため、形状は正確ですが色は付きません。初回読み込み時に一瞬止まることがあります(以降はキャッシュ)。
- RoomPlan スキャンの実機確認は LiDAR 端末が必要(シミュレータではフォールバックを確認済み)。
- Before / After は透明度クロスフェード(形状補間はしない)。
- スキーマ移行の仕組みはなし(JSON に手動でフィールドを足す場合は Optional 推奨)。

## 実機で確認すべきポイント

基本フロー(スキャン → ミニチュア / 実寸 / ポータル)は実機確認済み。現時点で未確認・要チェックなのは:

0. **スプラット AR** — 床タップ設置、ミニチュア⇄実寸切替、実寸で部屋の中を歩く。カメラを速く動かしたときのソート追従と、カメラ映像とのズレがないか
1. **高品質(USDZ)モード** — 部屋をスキャンし直すと `.model` 形式(家具の形状モデル付き)で USDZ が保存される。ミニチュア AR / 3D プレビューで「模型」と「高品質」を見比べる
2. **LiDAR スプラットスキャン** — 部屋を見回してスプラットが増えること、完了後に面が連続して見えること(壁・床がボテボテの球ではなく面に見えるか、色ズレ・位置ズレがないか)
3. **実データの Gaussian Splatting** — Scaniverse 等で書き出した `.ply` / `.splat` を取り込み、実レンダリングの見え方(色味・ノイズ・ソート挙動)を確認
3. 実寸 AR の「高品質」モードで透明度スライダーが効くこと(OpacityComponent 経由)
4. **ゴーストのドラッグ移動** — ミニチュア AR / 実寸 AR / 3D プレビューでゴーストを掴んで動かし、離した位置が保存されること(カメラ操作と競合しないこと)
5. **ポータルのトランジション** — ドアタップで光バースト → 白フェード → ドリーイン、閉じるときの白フェード

## 今後の改善アイデア

- Gaussian Splatting の高次 SH(視線依存色)対応と `.spz` の gzip 展開
- 高品質(USDZ)モードでのパーツタップ情報表示(現在は模型モードのみ対応)
- メモピンの AR 画面での直接配置(現在は 3D プレビューで配置)
- ゴーストのドラッグ中の回転ハンドル(現在は回転のみエディタ操作)
- ピンや窓のガラス表現などのマテリアル強化
