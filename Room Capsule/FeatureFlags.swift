/// リリーススコープ制御。
/// 実装コードは残したまま UI の導線だけをここで隠す。機能を戻すときは true に変えるだけ。
/// (v1 では全機能 false で出荷。v1 リリース後にすべて復活済み)
enum FeatureFlags {
    /// Gaussian Splatting 一式(写真っぽく見る = 表示・AR 設置・データ取得のハブ / LiDAR キャプチャ / 表示モード「写真」)
    static let splat = true
    /// メモピン(一覧・空間への配置・表示モード「メモ」)
    static let memoPins = true
    /// 家具ゴースト(一覧・ドラッグ移動の案内文)
    static let furnitureGhosts = true
}
