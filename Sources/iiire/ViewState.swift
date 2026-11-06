import SwiftUI

/// SwiftUI の `State` プロパティラッパーの別名。`@State` の代わりに使う。
///
/// macOS 27 SDK では `@State` がマクロとして宣言され、その実装 (SwiftUIMacros) は
/// Xcode にしか入っていない。Command Line Tools だけでビルドすると
/// "plugin for module 'SwiftUIMacros' not found" で失敗する。
/// 別名で書くとマクロとして解決されず、従来のプロパティラッパーとして扱われる
typealias ViewState = SwiftUI.State
