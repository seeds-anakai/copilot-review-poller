# copilot-review-poller

EventBridgeから5分ごとに起動し、対象リポジトリのopenなPull Requestに対して、最新コミットへのGitHub Copilotレビューがなければレビューを依頼するLambdaです。

## 判定

- draft Pull Requestは対象外
- Dependabot (`dependabot[bot]`) が作成したPull Requestは対象外
- Copilotが依頼中なら再依頼しない
- `copilot-pull-request-reviewer[bot]` のレビューが最新の `head.sha` に対して存在すれば再依頼しない
- 古いコミットへのレビューしかない場合は再依頼する

## Lambda環境変数

```text
GH_TOKEN=<Pull Request write権限を持つGitHub Token>
TARGET_REPOSITORY=<owner>/<repository>
```

## デプロイ

1. DockerイメージをARM64向けにビルドしてECRへpushする
2. Lambdaをコンテナイメージから作成する
3. `GH_TOKEN`と`TARGET_REPOSITORY`を設定する
4. EventBridgeのScheduled Ruleに `rate(5 minutes)` を設定する
5. EventBridgeからLambdaを呼び出す権限をLambdaへ追加する

Lambdaのタイムアウトは、Pull Request数に応じて30〜60秒を目安に設定します。

## 必要なGitHub権限

Tokenは `TARGET_REPOSITORY` に設定したリポジトリへのPull Request write権限が必要です。
