# Claude Code開発環境構築マニュアル

## 📱 できるようになること
クラウド上に ClaudeCode 環境を作って、いつでも何処でも ClaudeCode で開発できるようになります。
<img width="30%" height="1711" alt="Screenshot_20250717-125014~2" src="https://github.com/user-attachments/assets/74c7c098-a7a0-47b0-87b2-20bdc3b63f13" />
<img width="30%" height="1783" alt="Screenshot_20250717-225940~2" src="https://github.com/user-attachments/assets/315b26c8-543e-45d7-9f84-06c182539492" />

## 📋 概要

このマニュアルでは、TerraformとAWSを使用してClaude Code開発環境を構築する手順を説明します。構築される環境には以下が含まれます：

- **セキュアなEC2インスタンス**（カスタムSSHポート、UFW、fail2ban）
- **開発ツール**（mise、Node.js、Python、Claude Code、tmux）
- **SSH認証**（keychain、GitHub連携）
- **日本語環境**（ja_JP.UTF-8ロケール、uim日本語入力）
- **Git便利エイリアス**（効率的なGit操作）

## 🛠️ 前提条件
- Mac
- AWS CLIがインストール・設定済み
- ローカルマシンにSSHクライアント

### Terraformのインストール（macOS）

```bash
# HashiCorp tapを追加
brew tap hashicorp/tap

# Terraformをインストール
brew install hashicorp/tap/terraform

# インストール確認
terraform version
```

または、シンプルに：

```bash
# 直接インストール（推奨）
brew install terraform

# インストール確認
terraform version
```

## 📁 必要なファイル

以下の4つのファイルを同じディレクトリに配置してください：

1. `main.tf` - メインのTerraform設定
2. `variables.tf` - 変数定義
3. `terraform.tfvars` - 環境固有の設定値
4. `README.md` - このマニュアル

## 📝 STEP 1: 設定ファイルの準備

### 1.1 terraform.tfvars の作成

サンプルファイルをコピーして設定ファイルを作成します：

```bash
# サンプルファイルをコピー
cp terraform.tfvars.sample terraform.tfvars

# 設定ファイルを編集
vim terraform.tfvars
```

以下の項目を**必ず**あなたの情報に変更してください：

```hcl
# 必須変更項目
github_username = "your-username"  # あなたのGitHubユーザー名
github_email = "your@email.com"    # あなたのメールアドレス

# キー設定（デフォルトで自動生成、カスタマイズする場合のみ設定）
# key_name = ""                    # 空の場合、SSH慣例に従った名前を自動生成
# ssh_key_algorithm = "ed25519"    # デフォルト。rsa, ecdsa も選択可能
# environment_name = "dev"         # デフォルト。test, project-a など任意の名前
```

その他の設定はお好みで調整してください。

### 1.2 設定値の説明

`terraform.tfvars.sample` に記載されている設定項目の説明：

| 設定項目 | 説明 | 推奨値 |
|---------|------|--------|
| `aws_region` | AWSリージョン | `ap-northeast-1` (東京) |
| `instance_type` | EC2インスタンスタイプ | `t3.medium` (開発用途) |
| `ssh_port` | カスタムSSHポート | `10022` (セキュリティ向上) |
| `node_versions` | インストールするNode.jsバージョン | お好みで選択 |
| `python_versions` | インストールするPythonバージョン | お好みで選択 |

## 🔐 STEP 2: AWSキーペアの作成

terraform.tfvarsの設定に基づいて、対応するSSHキーペアを作成します。

### デフォルト設定（推奨）

デフォルトでは、SSH慣例に従った自動キー生成を使用します：

```bash
# デフォルト設定でのキー作成（ED25519、環境名: dev）
aws ec2 create-key-pair \
  --key-name id_ed25519_claude_dev_key \
  --key-type ed25519 \
  --region ap-northeast-1 \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/id_ed25519_claude_dev_key.pem

# 権限設定
chmod 600 ~/.ssh/id_ed25519_claude_dev_key.pem
```

### 環境名やアルゴリズムをカスタマイズした場合

`terraform.tfvars`で設定を変更した場合のキー作成例：

**例1: 環境名を"test"に変更**
```hcl
# terraform.tfvars
environment_name = "test"
```
```bash
# 対応するキー作成コマンド
aws ec2 create-key-pair \
  --key-name id_ed25519_claude_test_key \
  --key-type ed25519 \
  --region ap-northeast-1 \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/id_ed25519_claude_test_key.pem

chmod 600 ~/.ssh/id_ed25519_claude_test_key.pem
```

**例2: アルゴリズムをRSAに変更**
```hcl
# terraform.tfvars
ssh_key_algorithm = "rsa"
```
```bash
# 対応するキー作成コマンド
aws ec2 create-key-pair \
  --key-name id_rsa_claude_dev_key \
  --key-type rsa \
  --region ap-northeast-1 \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/id_rsa_claude_dev_key.pem

chmod 600 ~/.ssh/id_rsa_claude_dev_key.pem
```

**例3: 両方をカスタマイズ**
```hcl
# terraform.tfvars
environment_name = "project-a"
ssh_key_algorithm = "ecdsa"
```
```bash
# 対応するキー作成コマンド
aws ec2 create-key-pair \
  --key-name id_ecdsa_claude_project-a_key \
  --key-type ecdsa \
  --region ap-northeast-1 \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/id_ecdsa_claude_project-a_key.pem

chmod 600 ~/.ssh/id_ecdsa_claude_project-a_key.pem
```

### 手動でキー名を指定した場合

```hcl
# terraform.tfvars
key_name = "my-custom-key"
```
```bash
# 指定したキー名でキー作成
aws ec2 create-key-pair \
  --key-name my-custom-key \
  --key-type ed25519 \
  --region ap-northeast-1 \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/my-custom-key.pem

chmod 600 ~/.ssh/my-custom-key.pem
```

### キーペア確認

```bash
# キーペアが存在することを確認（デフォルト設定の場合）
aws ec2 describe-key-pairs --key-names id_ed25519_claude_dev_key --region ap-northeast-1

# カスタマイズした場合の例
# aws ec2 describe-key-pairs --key-names id_rsa_claude_test_key --region ap-northeast-1
# aws ec2 describe-key-pairs --key-names my-custom-key --region ap-northeast-1
```

### AWS Management Consoleでの作成（代替方法）

1. [EC2コンソール](https://console.aws.amazon.com/ec2/) にアクセス
2. 左メニューの「キーペア」をクリック
3. 「キーペアを作成」をクリック
4. 名前：上記で決定したキー名（例：`id_ed25519_claude_dev_key`）
5. キータイプ：対応するタイプ（`ED25519`/`RSA`/`ECDSA`）
6. プライベートキーファイル形式：`.pem`
7. 「キーペアを作成」をクリック
8. ダウンロードされたファイルを適切なパスに配置
9. 権限設定：`chmod 600 ~/.ssh/<キーファイル名>`

**注意**: `key_name`を手動で指定した場合、`environment_name`や`ssh_key_algorithm`の設定は無視されます。

## 🚀 STEP 3: インフラストラクチャのデプロイ

### 3.1 Terraformの初期化

```bash
# プロジェクトディレクトリに移動
cd /path/to/your/terraform/project

# Terraformを初期化
terraform init
```

### 3.2 設定の確認

```bash
# デプロイ内容を確認
terraform plan
```

出力内容を確認し、想定通りのリソースが作成されることを確認してください。

### 3.3 デプロイ実行

```bash
# インフラストラクチャをデプロイ
terraform apply

# "yes" と入力して実行確認
```

### 3.4 出力値の確認

デプロイ完了後、以下の情報が出力されます：

```bash
instance_public_ip = "xxx.xxx.xxx.xxx"
ssh_command = "ssh -i ~/.ssh/id_ed25519_claude_dev_key.pem -p 10022 ubuntu@xxx.xxx.xxx.xxx"
setup_status = "Check setup status: ssh -i ~/.ssh/id_ed25519_claude_dev_key.pem -p 10022 ubuntu@xxx.xxx.xxx.xxx 'cat setup_complete.txt'"
github_ssh_setup = "Run GitHub SSH setup: ssh -i ~/.ssh/id_ed25519_claude_dev_key.pem -p 10022 ubuntu@xxx.xxx.xxx.xxx './setup-github-ssh.sh'"
```

## 🔗 STEP 4: EC2インスタンスへの接続

### 4.1 SSH接続
※ 接続可能になるまで 3〜5分くらいかかります。セットアップ処理が色々実行されるので
```bash
# 出力されたSSHコマンドを使用（デフォルト設定の場合）
ssh -i ~/.ssh/id_ed25519_claude_dev_key.pem -p 10022 ubuntu@xxx.xxx.xxx.xxx

# カスタマイズした場合の例
# ssh -i ~/.ssh/id_rsa_claude_test_key.pem -p 10022 ubuntu@xxx.xxx.xxx.xxx
# ssh -i ~/.ssh/my-custom-key.pem -p 10022 ubuntu@xxx.xxx.xxx.xxx
```

### 4.2 セットアップ状況の確認

```bash
# セットアップ完了を確認
cat setup_complete.txt
```

以下のような出力が表示されれば成功です：

```
Setup completed successfully at [日時]
Service status check:
- UFW: Status: active
- SSH: active
- SSH Port: 10022
- fail2ban: active
```

## 🔑 STEP 5: GitHub SSH認証の設定

### 5.1 GitHub SSH設定スクリプトの実行

```bash
# GitHub SSH設定を実行
./setup-github-ssh.sh
```

### 5.2 パスフレーズの入力

```bash
Enter passphrase (empty for no passphrase): [強固なパスフレーズを入力]
Enter same passphrase again: [同じパスフレーズを再入力]
```

### 5.3 公開鍵のコピー

スクリプト実行後、以下のような公開鍵が表示されます：

```
=== GitHub SSH Public Key ===
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx your-email@example.com

📋 Copy the above public key to GitHub SSH settings:
   https://github.com/settings/ssh/new
```

### 5.4 GitHubへの公開鍵登録

1. [GitHub SSH設定ページ](https://github.com/settings/ssh/new) にアクセス
2. **Title**: `Claude Dev Environment - [日付]`
3. **Key**: 上記で表示された公開鍵をコピー&ペースト
4. 「Add SSH key」をクリック

### 5.5 SSH接続テスト

```bash
# GitHub SSH接続をテスト
ssh -T git@github.com
```

成功すると以下のメッセージが表示されます：

```
Hi [your-username]! You've successfully authenticated, but GitHub does not provide shell access.
```

### 5.4 Git便利エイリアステスト

```bash
# Git便利エイリアスの動作確認
git graph               # ブランチ履歴をグラフで表示
git one                 # 履歴を1行で表示
git br                  # ブランチ一覧（更新日順）
git bc                  # 現在のブランチ確認
git st                  # ステータス短縮表示

# ファイル操作テスト
echo "test" > test.txt
git aa                  # 全変更をステージング
git st                  # 変更状況確認
```

## 🧪 STEP 6: 動作確認

### 6.1 開発環境の確認

```bash
# Node.js バージョン確認
node --version

# Python バージョン確認
python --version

# Claude Code確認
claude-code --version

# mise確認
mise list
```

### 6.2 Git操作テスト

```bash
# テスト用のディレクトリ作成
cd ~/workspace
mkdir test-repo
cd test-repo

# Gitリポジトリ初期化
git init
echo "# Test Repository" > README.md
git add README.md
git commit -m "Initial commit"

# GitHubに新しいリポジトリを作成してプッシュテスト
# (事前にGitHubでリポジトリを作成しておく)
git remote add origin git@github.com:your-username/test-repo.git
git push -u origin main
```

**⚠️ 重要**: リポジトリURLは**SSH形式**（`git@github.com:`）を使用してください。HTTPS形式だとSSH認証が働きません。

## 🔧 STEP 7: 開発作業の開始

### 7.1 プロジェクトのクローン

```bash
# SSH形式でクローン（推奨）
git clone git@github.com:username/repository.git

# プロジェクトディレクトリに移動
cd repository
```

### 7.2 Claude Codeの使用

```bash
# Claude Codeを起動
claude-code

# または特定のファイルで起動
claude-code filename.js
```

### 7.3 日本語入力の使用

```bash
# 日本語入力モードを開始
uim-fep

# または短縮コマンド
jp
japanese

# 日本語入力モード中
# Ctrl+Space で 日本語⇔英語 切り替え
```

### 7.4 Node.jsバージョン切り替え

```bash
# 利用可能なバージョン一覧
mise list node

# バージョン切り替え
mise use node@20.16.0

# プロジェクト固有の設定
echo "node 20.16.0" > .tool-versions
```

## 🛡️ セキュリティ設定

### 設定済みの環境機能

- **ロケール**: ja_JP.UTF-8（日本語環境）
- **タイムゾーン**: Asia/Tokyo（日本時間）
- **日本語入力**: uim + Anthy（Ctrl+Spaceで切り替え）
- **セキュリティ**: カスタムSSHポート、UFW、fail2ban
- **開発環境**: mise + Node.js + Python + Claude Code
- **ターミナル**: tmux（マルチプレクサー）
- **Git便利エイリアス**: 8つの効率的なGitコマンド
- **ログイン時ヘルプ**: 基本ツールの使い方を自動表示

### 追加セキュリティ対策（推奨）

```bash
# SSH接続ログの確認
sudo tail -f /var/log/auth.log

# fail2ban状況確認
sudo fail2ban-client status sshd

# UFW設定確認
sudo ufw status verbose
```

### 7.5 ログイン時のヘルプ表示

環境にログインすると、自動で基本ツールの使い方が表示されます：

```
=== 基本ツール使用方法 ===
【tmux - ターミナルマルチプレクサー】
セッション管理:
  tmux                    # 新しいセッション開始
  tmux new -s myname      # 名前付きセッション作成
  tmux ls                 # セッション一覧
  tmux attach -t myname   # セッションにアタッチ
  tmux kill-session -t myname # セッション終了

tmuxのキーバインド (Ctrl+b がプレフィックス):
  Ctrl+b d - セッションをデタッチ
  Ctrl+b c - 新しいウィンドウ作成
  Ctrl+b n/p - 次/前のウィンドウ
  Ctrl+b w - ウィンドウ一覧
  Ctrl+b % - 縦に分割
  Ctrl+b " - 横に分割
  Ctrl+b o - ペイン間移動
  Ctrl+b x - ペイン削除
  Ctrl+b z - ペイン最大化切り替え

【日本語入力 (uim-fep)】
  jp                      # 日本語入力開始 (uim-fep のエイリアス)
  Ctrl+Space              # 日本語↔英語切り替え

【開発環境】
  mise list               # インストール済み言語バージョン一覧
  mise use node@18        # Node.jsバージョン切り替え
  mise use python@3.11    # Pythonバージョン切り替え
  claude-code             # Claude Code開始

【Git便利エイリアス】
  git graph               # ブランチ履歴をグラフで表示
  git one                 # 履歴を1行で表示
  git br                  # ブランチ一覧（更新日順）
  git bc                  # 現在のブランチ確認
  git st                  # ステータス短縮表示
  git co <branch>         # ブランチ切り替え
  git cob <branch>        # ブランチ作成&切り替え
  git aa                  # 全変更をステージング
  git conflicts           # コンフリクトファイル一覧
=================================
```

このヘルプ表示を無効にしたい場合は、`~/.bashrc` を編集してください。

## 🔄 メンテナンス

### アップデート

```bash
# システムアップデート
sudo apt update && sudo apt upgrade -y

# Node.jsの新バージョンインストール
mise install node@latest

# Pythonの新バージョンインストール
mise install python@latest
```

### バックアップ

重要なデータは定期的にGitリポジトリにコミットしてください：

```bash
# 定期的なコミット
git add .
git commit -m "Work in progress"
git push
```

## 🧹 環境の削除

作業完了後、環境を削除する場合：

```bash
# Terraformで作成したリソースを削除
terraform destroy

# "yes" と入力して削除確認
```

## ❗ トラブルシューティング

### よくある問題と解決法

#### 1. SSH接続できない

```bash
# セキュリティグループの確認
aws ec2 describe-security-groups --filters "Name=group-name,Values=claude-code-*"

# SSHポートが正しく開いているか確認
# 10022番ポートが許可されていることを確認
```

#### 2. git pushでパスワードを求められる

```bash
# リモートURLを確認
git remote -v

# SSH形式に変更
git remote set-url origin git@github.com:username/repository.git
```

#### 3. セットアップスクリプトが完了しない

```bash
# user-dataログを確認
sudo cat /var/log/user-data.log

# 手動でスクリプトを再実行
sudo bash /var/lib/cloud/instance/scripts/*
```

#### 4. keychainが動作しない

```bash
# bashrcの再読み込み
source ~/.bashrc

# keychainを手動実行（デフォルト設定の場合）
keychain ~/.ssh/id_ed25519_claude_dev_key.pem
source ~/.keychain/$(hostname)-sh

# カスタマイズした場合は対応するキーファイルを使用
# keychain ~/.ssh/id_rsa_claude_test_key.pem
# keychain ~/.ssh/my-custom-key.pem
```

## 📚 参考資料

- [Terraform AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Claude Code Documentation](https://docs.anthropic.com/claude-code)
- [mise Documentation](https://mise.jdx.dev/)
- [tmux Documentation](https://github.com/tmux/tmux/wiki)
- [GitHub SSH Authentication](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)
- [uim Documentation](https://github.com/uim/uim/wiki)
- [Anthy Documentation](https://github.com/netsphere-labs/anthy)
