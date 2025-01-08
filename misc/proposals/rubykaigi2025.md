# RubyKaigi 2025 Proposal

## title:

Implementing WASM Runtime in Ruby - ruby.wasm works on Ruby?

## Abstract

<!--

Create an abstract of talk in English, following below:

- 作者はWarditeというRubyのWASMランタイムを開発した
- WarditeはPure Rubyで、RBSに完全対応している
- Warditeでruby.wasmを動かすことをマイルストーンにしており、その取り組みについて報告する。
- 例えば、WASI preview 1 対応、パフォーマンス改善など。

-->

The author has developed a WASM runtime named Wardite, which is implemented entirely in pure Ruby and fully annotated by RBS. The primary milestone for Wardite is to successfully run ruby.wasm. This presentation will dive deeply into the various efforts and challenges encountered in reaching this milestone. Key topics will include the implementation of support for WASI preview 1, performance enhancements, and other technical advancements. Attendees will gain insights into the current status of Wardite, its architecture, and the approaches taken to eficciently implement WebAssembly runtime in Ruby. The talk aims to provide a comprehensive overview of the progress made so far and the future directions for Wardite, highlighting its potential impact on the Ruby and WebAssembly ecosystems.

## Details

現在、以下のような内容を考えています

- なぜ、Warditeを作ったか？
    - Pure Rubyであることのメリット
    - cf. wazero in Go
- 簡単なWarditeの紹介
    - 動作のデモ
- Warditeの実装
    - WASM Core 1.0を動かすために必要な仕様の解説
        - 簡単な内部設計
        - 命令の概要
    - RBSによる型情報の利用
- Wardite開発上の技術的チャレンジ
    - パフォーマンス改善の取り組み
        - 基本的な計測（ruby-prof、perf）
        - オブジェクト生成の低減・最適化
- Warditeでruby.wasmを動かすための取り組み
    - WASI preview 1 対応
- 今後の展望
    - 更なるパフォーマンス改善
    - Component 対応

## Pitch