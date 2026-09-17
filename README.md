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

## 手順

1. プルリクエストの書き込み権限を持つパーソナルアクセストークンを発行する。

2. `GH_TOKEN`と対象リポジトリを環境変数に設定し、`deploy.sh`を実行する。

   ```bash
   export GH_TOKEN
   export TARGET_REPOSITORY=owner/repository
   ./deploy.sh
   ```

   - AWS CLIのprofileは`default`、リージョンは`ap-northeast-1`を使用します。必要な場合は`AWS_PROFILE`と`AWS_REGION`で変更できます。
   - `deploy.sh`はDockerイメージのbuildとECRへのpush、IAMロール、Lambda、CloudWatch Logsのロググループ、5分間隔のEventBridge Scheduled Rule、Lambdaの呼び出し権限を作成または更新します。

   - Lambdaのタイムアウトは`30秒`に設定します。

## 必要なGitHub権限

Tokenは `TARGET_REPOSITORY` に設定したリポジトリへのPull Request write権限が必要です。
