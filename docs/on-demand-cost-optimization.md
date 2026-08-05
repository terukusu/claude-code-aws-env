# オンデマンド化によるコスト最適化（AI向け実行手順書）

このドキュメントは、本リポジトリで構築した Claude Code 開発環境を
**「使うときだけ起動する」構成に変更する**ための手順書です。
AI エージェントが上から順に実行できるよう、判断基準・検証方法・失敗時の挙動まで記述しています。

## 何が変わるか

| | 変更前 | 変更後 |
|---|---|---|
| 稼働 | 24時間365日 | 使うときだけ（自動停止・自動起動） |
| 起動操作 | 不要（常時起動） | スマホ/PC から1コマンド。**打鍵数は変わらない** |
| 停止操作 | 不要 | 不要（30分無活動で自動停止） |
| 月額（東京・t3.medium・月88時間利用の場合） | 約 $48 | 約 $13 |

削減の内訳は後述の「コスト根拠」を参照。

停止は二段構えにします。

| | 仕組み | 発火条件 | 役割 |
|---|---|---|---|
| 主 | インスタンス内の systemd timer | 30分無活動 かつ load が低い。停止前にバックアップ | 通常はこれだけで止まる |
| 保険 | EventBridge Scheduler | 毎日決まった時刻に無条件 | **主機構そのものが壊れた場合**を拾う |

主機構はインスタンス内部で動くため、それ自体が壊れると誰も止められません。
外部の保険はそこだけを守ります。

## 全体の流れ

この環境は2段構えで作ります。本書は2段目だけを扱います。

| 段階 | 手段 | 実行主体 |
|---|---|---|
| 1. 基盤（EC2・SG・EIP・開発環境一式） | `terraform apply` | 人 or AI |
| 2. 本書 0〜3章（安全確認・バックアップ・アイドル検知・保険） | 本書 | **AI が単独で実行可能** |
| 3. 本書 4.1（起動専用 IAM ユーザー） | 本書 | AI が実行。発行したキーの受け渡しは人が判断 |
| 4. 本書 4.2（スマホ側の設定） | 本書 | **実機が要るため人が実施** |

1 の `root_volume_size` は既定 50GB です。30GB でも新規構築は通りますが、
リポジトリ・`node_modules`・コンテナイメージが積み上がると足りなくなります。

## 前提

- 本リポジトリの `terraform apply` が完了し、インスタンスが稼働していること
- 対象インスタンスに SSH 接続できること
- 実行者（またはAIエージェント）が対象 AWS アカウントに対する管理権限を持つこと
- スマホから使う場合、Android + Termux を想定（iOS は「起動トリガー」の章で代替案を記載）

---

## 0. 作業用パラメータの決定

以降のコマンドは、すべて以下の環境変数を前提とします。
**AWS プロファイル名はハードコードせず、必ず環境変数で与えてください。**
本リポジトリの `provider "aws"` はプロファイルを固定していないため、`AWS_PROFILE` がそのまま効きます。

```bash
# 自分の環境に合わせて設定する
export AWS_PROFILE=<あなたのプロファイル名>      # 例: default, myaccount
export AWS_REGION=ap-northeast-1                 # terraform.tfvars の aws_region と合わせる
export ENV_NAME=dev                              # terraform.tfvars の environment_name と合わせる
export SSH_HOST=claude                           # ~/.ssh/config の Host 名（未作成なら下記で作る）
```

### SSH 接続の準備

本書は全編で `ssh "$SSH_HOST"` を使います。`~/.ssh/config` に Host 定義が無い場合は
先に作ってください。接続情報は `terraform output` から取れます。

```bash
cd /path/to/terraform/dir
terraform output -raw ssh_command
# => ssh -i ~/.ssh/id_ed25519_claude_dev_key.pem -p 10022 ubuntu@xxx.xxx.xxx.xxx
```

この内容を `~/.ssh/config` に書き写します。

```
Host claude
    HostName        <terraform output の IP>
    Port            10022
    User            ubuntu
    IdentityFile    ~/.ssh/<terraform output のキー名>.pem
    IdentitiesOnly  yes
```

**`IdentityFile` は実在するファイルを指すこと。** 存在しないパスを書いても
ssh-agent 経由でたまたま接続できてしまう場合があり、後から原因を追いにくくなります。
鍵とAWS側キーペアの一致は、フィンガープリントで確認できます。

```bash
ssh-keygen -lf ~/.ssh/<キー名>.pem
aws ec2 describe-key-pairs --key-names <キー名> --query 'KeyPairs[].KeyFingerprint' --output text
```

**検証**: `ssh "$SSH_HOST" 'hostname'` が応答すること。

インスタンスIDは `Name` タグから引きます（`main.tf` が `claude-code-${environment_name}` を付与）。

```bash
export INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=claude-code-${ENV_NAME}" \
            "Name=instance-state-name,Values=running,stopped,stopping,pending" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "PROFILE=$AWS_PROFILE  REGION=$AWS_REGION  INSTANCE=$INSTANCE_ID  ACCOUNT=$ACCOUNT_ID"
```

**検証**: `INSTANCE_ID` が `i-` で始まる1個のIDであること。
複数出た場合は環境が複数あるので `ENV_NAME` を見直すこと。

---

## 1. 事前の安全確認（必須）

自動停止を仕込む前に、**OS内からの `shutdown` がインスタンスを削除しないこと**を確認します。
ここが `terminate` だと、自動停止がそのまま環境の破壊になります。

```bash
aws ec2 describe-instance-attribute --instance-id "$INSTANCE_ID" \
  --attribute instanceInitiatedShutdownBehavior \
  --query 'InstanceInitiatedShutdownBehavior.Value' --output text
```

**期待値**: `stop`

`terminate` が返った場合は、先に修正すること。

```bash
aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" \
  --instance-initiated-shutdown-behavior stop
```

### ルートボリュームを削除保護する

デフォルトでは `DeleteOnTermination = true` です。
誤って terminate した際に作業内容ごと消えるため、`false` に変更します。**稼働中に無停止で変更できます。**

```bash
ROOT_DEV=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].RootDeviceName' --output text)

aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" \
  --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEV\",\"Ebs\":{\"DeleteOnTermination\":false}}]"

# 検証
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.DeleteOnTermination' --output text
```

**期待値**: `False`

### ディスク空き容量を確保する

停止と起動を繰り返す前に、ディスクが逼迫していないことを確認します。

> `terraform apply` 直後の新品インスタンスには回収対象が溜まっていないため、この節は空振りします。既に使い込まれた環境に対して実施する場合のみ意味があります。

```bash
ssh "$SSH_HOST" 'df -h / | tail -1'
```

使用率が 85% を超えている場合は、以下の順で回収します（効果が大きい順）。

```bash
ssh "$SSH_HOST" 'bash -s' <<'EOF'
# 1. 未使用の docker イメージ（数GB回収できることが多い）
if command -v docker >/dev/null; then
  sudo docker system df
  sudo docker image prune -a -f
fi
# 2. systemd journal
sudo journalctl --vacuum-size=100M
# 3. 無効化された古い snap リビジョン
snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read n r; do
  sudo snap remove "$n" --revision="$r"
done
df -h / | tail -1
EOF
```

> `/tmp` は `tmpfiles.d` の `D /tmp` 指定により**次回ブート時に自動で空になります**。
> 稼働中の Claude Code セッションが作業領域として使っているため、手動で消さないこと。

---

## 2. バックアップ基盤（自動停止の前提）

自動停止を入れる前に、**失って困るものを外部に逃がす**仕組みを先に作ります。
順序を逆にしないこと。

### 2.1 S3 バケット

```bash
BUCKET="claude-code-${ENV_NAME}-backup-${ACCOUNT_ID}"

aws s3api create-bucket --bucket "$BUCKET" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [{
    "ID": "expire-noncurrent",
    "Status": "Enabled",
    "Filter": {"Prefix": ""},
    "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
    "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
  }]
}'
```

バージョニングを有効にするのは、バックアップスクリプトが `--delete` 付き同期をするためです。
誤って消えても30日は旧バージョンから復元できます。

### 2.2 インスタンスプロファイル

インスタンス上に静的アクセスキーを置かず、IMDS 経由で権限を得ます。

```bash
ROLE="claude-code-${ENV_NAME}-role"
PROFILE_NAME="claude-code-${ENV_NAME}-profile"

aws iam create-role --role-name "$ROLE" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam put-role-policy --role-name "$ROLE" --policy-name s3-backup --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":\"arn:aws:s3:::$BUCKET\"},
    {\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\",\"s3:DeleteObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}
  ]
}"

# SSH を使わない運用に移行する場合に備えて SSM も付けておく（任意）
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME"
aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE"
sleep 10
aws ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID" \
  --iam-instance-profile Name="$PROFILE_NAME"
```

**検証**（インスタンス上で実行）:

```bash
ssh "$SSH_HOST" 'aws sts get-caller-identity --query Arn --output text'
```

**期待値**: `arn:aws:sts::<account>:assumed-role/claude-code-<env>-role/i-...`

> 注意: `~/.aws/credentials` に `default` プロファイルの静的キーが書かれていると、
> そちらが優先されてインスタンスプロファイルが使われません。上記検証で
> `assumed-role/` 以外が返る場合は、静的キーを削除するか、
> バックアップスクリプト内で `AWS_SHARED_CREDENTIALS_FILE=/dev/null` を指定してください。

### 2.3 バックアップスクリプト

**何をバックアップするか**の方針:

| 対象 | 判断 | 理由 |
|---|---|---|
| `~/.claude`（会話履歴・設定・スキル） | **する** | 失うと復元不能。数十MB程度で軽い |
| origin 未設定の git リポジトリ | **する（全ツリー）** | ここにしか存在しない |
| 未コミット変更のあるリポジトリ | **する（差分のみ）** | 履歴はリモートにある |
| クリーンな git リポジトリ | しない | リモートから再取得できる |
| 認証情報（各種トークン・`.aws/credentials`） | **しない** | 再発行できる一方、S3 に置くと露出面が増える |

`origin` が無いリポジトリは `git ls-files --others --exclude-standard` では
**gitignore 対象が漏れます**。`.clasp.json` や `.env` のような「gitignore されているが復元不能な設定」を
落とさないため、全ツリーを対象にします。

インスタンス上に `/usr/local/bin/devbox-backup.sh` として配置します。

```bash
ssh "$SSH_HOST" "sudo tee /usr/local/bin/devbox-backup.sh >/dev/null" <<BACKUP
#!/bin/bash
set -uo pipefail
BUCKET="s3://$BUCKET"
STAGE="\$(mktemp -d /tmp/devbox-backup.XXXXXX)"
trap 'rm -rf "\$STAGE"' EXIT
export AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=3
log() { printf '%s %s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\$*"; }

log "sync ~/.claude"
aws s3 sync "\$HOME/.claude" "\$BUCKET/claude/" \\
  --exclude 'cache/*' --exclude 'shell-snapshots/*' --exclude 'downloads/*' \\
  --exclude 'plugins/cache/*' --exclude '.credentials.json' --exclude '*.lock' \\
  --delete --only-show-errors

log "collect git safety net"
: > "\$STAGE/manifest.txt"
while IFS= read -r gitdir; do
  repo="\$(dirname "\$gitdir")"; name="\$(basename "\$repo")"
  origin="\$(git -C "\$repo" remote get-url origin 2>/dev/null || true)"
  dirty="\$(git -C "\$repo" status --porcelain 2>/dev/null | wc -l)"
  [ -n "\$origin" ] && [ "\$dirty" -eq 0 ] && continue
  mkdir -p "\$STAGE/\$name"
  git -C "\$repo" status --porcelain > "\$STAGE/\$name/status.txt" 2>/dev/null
  if [ -z "\$origin" ]; then
    ( cd "\$repo" && tar -czf "\$STAGE/\$name/worktree.tar.gz" \\
        --exclude='./.git' --exclude='./node_modules' --exclude='./.venv' . 2>/dev/null ) || true
    log "  staged \$name (origin=NONE dirty=\$dirty) full tree"
  else
    if git -C "\$repo" rev-parse HEAD >/dev/null 2>&1; then
      git -C "\$repo" bundle create "\$STAGE/\$name/all.bundle" --all >/dev/null 2>&1 || true
      git -C "\$repo" diff HEAD > "\$STAGE/\$name/uncommitted.patch" 2>/dev/null
    fi
    ( cd "\$repo" && git ls-files --others --exclude-standard -z 2>/dev/null \\
        | tar --null -T - -czf "\$STAGE/\$name/untracked.tar.gz" 2>/dev/null ) || true
    log "  staged \$name (dirty=\$dirty)"
  fi
  printf '%s origin=%s dirty=%s\n' "\$repo" "\${origin:-NONE}" "\$dirty" >> "\$STAGE/manifest.txt"
done < <(find "\$HOME" -maxdepth 3 -name .git -type d 2>/dev/null)

aws s3 sync "\$STAGE" "\$BUCKET/git/" --delete --only-show-errors
log "done"
BACKUP

ssh "$SSH_HOST" 'sudo chmod 755 /usr/local/bin/devbox-backup.sh && bash -n /usr/local/bin/devbox-backup.sh && /usr/local/bin/devbox-backup.sh'
```

**検証**: エラーなく完了し、`aws s3 ls s3://$BUCKET --recursive --summarize | tail -2` でオブジェクトが存在すること。
`origin=NONE` のリポジトリがある場合、`worktree.tar.gz` の中身に gitignore 対象のファイルが含まれることを確認すること。

### 2.4 定期実行

```bash
ssh "$SSH_HOST" 'bash -s' <<'EOF'
sudo tee /etc/systemd/system/devbox-backup.service >/dev/null <<'UNIT'
[Unit]
Description=Back up irreplaceable devbox state to S3
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=ubuntu
ExecStart=/usr/local/bin/devbox-backup.sh
TimeoutStartSec=900
UNIT

sudo tee /etc/systemd/system/devbox-backup.timer >/dev/null <<'UNIT'
[Unit]
Description=Daily devbox backup

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now devbox-backup.timer
systemctl list-timers devbox-backup.timer --no-pager
EOF
```

`Persistent=true` が重要です。オンデマンド運用では実行時刻にインスタンスが停止していることが多く、
これが無いとバックアップが永久に実行されません。停止を跨いだ場合、起動直後に実行されます。

---

## 3. アイドル検知による自動停止

### 設計の要点

**「無活動が N 分続いたら停止」を状態ファイルで積算する方式にしないこと。**
SSH が異常切断すると tmux クライアントが張り付いたまま残り、「常にアクティブ」と誤判定されて
**永久に停止しなくなります**。

代わりに、**各シグナルの「最終活動時刻」の最大値**から経過時間を求めます。
この方式なら、張り付いたクライアントも活動時刻が古くなるため正しく停止します。

参照するシグナル:

| シグナル | 取得方法 | 目的 |
|---|---|---|
| tmux クライアント活動 | `tmux list-clients -F '#{client_activity}'` | 対話操作の検出 |
| tmux セッション活動 | `tmux list-sessions -F '#{session_activity}'` | デタッチ中の出力検出 |
| Claude Code の会話記録 | `~/.claude/projects/**/*.jsonl` の mtime | エージェント動作の検出 |
| クライアント tty | `atime` のみ | SSH セッションでの人間の在席。**mtime はステータスバーで汚染される** |
| ペイン tty | `atime` と `mtime` | ペイン内で走る処理の活動。**長時間の自動処理を守る** |
| load average | `/proc/loadavg` | **停止の抑止**（ビルド中を殺さない） |

### 3.1 スクリプト配置

```bash
ssh "$SSH_HOST" "sudo tee /usr/local/bin/devbox-idle-check.sh >/dev/null" <<'IDLE'
#!/bin/bash
set -uo pipefail
IDLE_MIN="${IDLE_MIN:-30}"      # この分数、全シグナルが無活動なら停止
LOAD_MAX="${LOAD_MAX:-0.30}"    # この load average 以上なら停止しない
DRY_RUN="${DRY_RUN:-0}"
OWNER=ubuntu

now=$(date +%s); last=0; detail=""
note() {
  [ -z "${2:-}" ] && return
  [ "$2" -le 0 ] 2>/dev/null && return
  detail="${detail}$(printf '  %-22s %s (%ds ago)' "$1" "$(date -d @"$2" '+%F %T')" "$((now-$2))")
"
  [ "$2" -gt "$last" ] && last="$2"
  return 0
}

if command -v tmux >/dev/null; then
  for t in $(runuser -u "$OWNER" -- tmux list-clients -F '#{client_activity}' 2>/dev/null); do
    note "tmux client" "$t"; done
  for t in $(runuser -u "$OWNER" -- tmux list-sessions -F '#{session_activity}' 2>/dev/null); do
    note "tmux session" "$t"; done
fi

j=$(find "/home/$OWNER/.claude/projects" -name '*.jsonl' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
note "claude jsonl" "${j%.*}"

# ペイン tty の一覧（クライアント tty と区別するため）
PANE_TTYS=$(runuser -u "$OWNER" -- tmux list-panes -a -F '#{pane_tty}' 2>/dev/null)

for p in /dev/pts/*; do
  [ -c "$p" ] || continue
  case "$p" in */ptmx) continue;; esac
  # tty は2種類あり mtime の意味が違う（理由は本節末尾）
  a=$(stat -c %X "$p" 2>/dev/null)
  if printf '%s\n' "$PANE_TTYS" | grep -qx "$p"; then
    m=$(stat -c %Y "$p" 2>/dev/null)
    [ "${m:-0}" -gt "${a:-0}" ] 2>/dev/null && a="$m"
    note "pane $(basename "$p")" "$a"
  else
    note "tty $(basename "$p") atime" "$a"
  fi
done

idle=$(( now - last ))
load1=$(awk '{print $1}' /proc/loadavg)
busy_by_load=0
awk -v l="$load1" -v m="$LOAD_MAX" 'BEGIN{exit !(l+0 >= m+0)}' && busy_by_load=1

printf '=== devbox idle check ===\n'
printf '%b' "$detail"
printf '  %-22s %ss (%dmin)\n' "idle for" "$idle" "$((idle/60))"
printf '  %-22s %s (max %s, %s)\n' "load average(1m)" "$load1" "$LOAD_MAX" \
  "$([ "$busy_by_load" = 1 ] && echo BUSY || echo ok)"

# 安全側に倒す: シグナルが1つも取れないときは停止しない
[ "$last" -eq 0 ]                    && { echo "  -> no signal, not stopping"; exit 0; }
[ "$busy_by_load" = 1 ]              && { echo "  -> load high, not stopping"; exit 0; }
[ "$idle" -lt $(( IDLE_MIN * 60 )) ] && { echo "  -> below threshold, not stopping"; exit 0; }

echo "  -> idle ${idle}s, stopping"
[ "$DRY_RUN" = "1" ] && { echo "  DRY_RUN=1: not actually stopping"; exit 0; }

logger -t devbox-idle "idle ${idle}s (load $load1) - backup then shutdown"
runuser -u "$OWNER" -- /usr/local/bin/devbox-backup.sh 2>&1 | logger -t devbox-backup
/sbin/shutdown -h +1 "auto-stop after ${idle}s idle"
IDLE

ssh "$SSH_HOST" 'sudo chmod 755 /usr/local/bin/devbox-idle-check.sh && bash -n /usr/local/bin/devbox-idle-check.sh'
```

#### tty は2種類ある。どちらを混同しても壊れる

**この構成で最も踏みやすい罠です。** tmux を使うと tty が2種類でき、
`mtime` の意味がそれぞれ違います。

| | 何の tty か | mtime が動く契機 | 扱い |
|---|---|---|---|
| クライアント tty | SSH セッション側 | **tmux のステータスバー再描画**（既定 `status-interval 15`） | **mtime は使えない**。atime だけ見る |
| ペイン tty | tmux ペインの中身 | ペイン内のプログラムが書いたとき | **mtime も見る**。長時間の自動処理を拾う |

実測（`claude` がアイドルで待機中、287秒間 無入力）:

```
/dev/pts/0 (client)  atime=287s前   mtime=  7s前   ← ステータスバーが15秒毎に更新
/dev/pts/2 (pane)    atime=287s前   mtime=167s前   ← 更新されない
```

同じ構成で `claude` が作業中:

```
/dev/pts/0 (client)  atime= 95s前   mtime=  1s前
/dev/pts/2 (pane)    ...            mtime=  7s前   ← 働いている間だけ新しい
```

**両方向の間違いがあります。**

- **クライアント tty の mtime を混ぜる** → ステータスバーで常に「今」になり、
  **アイドル判定が永久に成立しません**。インスタンスは静かに動き続け、
  保険（3.4）が発火して初めて止まります
- **ペイン tty の mtime を捨てる** → キー入力を伴わない長時間の自動処理
  （AI エージェントの実行、長いツール呼び出し）を「無活動」と誤判定し、
  **作業中に停止させます**

`load average` の閾値は CPU を使う処理しか守れません。ネットワーク待ちのような
低負荷の待機は、ペイン tty の mtime でしか拾えません。

**どちらの壊れ方もエラーを出しません。** 前者は課金が続くだけ、後者は作業が飛ぶだけで、
ログには異常が残りません。必ず 3.2 のドライランで、クライアントとペインが別々に
表示されることを確認してください。

なお tmux の `client_activity` / `session_activity` は再描画では更新されないため、
そのまま使えます（実測で確認済み）。

### 3.2 ドライランで検証（必須）

**タイマーを有効化する前に、必ずドライランで判定値を確認してください。**
いきなり有効化すると、作業中のセッションごと停止させる恐れがあります。

```bash
ssh "$SSH_HOST" 'sudo DRY_RUN=1 /usr/local/bin/devbox-idle-check.sh'
```

確認すること:

1. 各シグナルの時刻が妥当か（極端に古い/新しいものが無いか）
2. `idle for` が実際の無操作時間と一致しているか
3. 判定が期待どおりか

> **注意**: このコマンドを SSH 経由で実行している間は、自分の SSH セッション自体が
> tty シグナルとして「たった今活動した」ことになります。したがって作業中は必ず
> `below threshold` と判定されます。これは正常な挙動です。

### 3.3 タイマー有効化

```bash
ssh "$SSH_HOST" 'bash -s' <<'EOF'
sudo tee /etc/systemd/system/devbox-idle.service >/dev/null <<'UNIT'
[Unit]
Description=Stop the instance when idle

[Service]
Type=oneshot
ExecStart=/usr/local/bin/devbox-idle-check.sh
UNIT

sudo mkdir -p /etc/systemd/system/devbox-idle.service.d
sudo tee /etc/systemd/system/devbox-idle.service.d/override.conf >/dev/null <<'UNIT'
[Service]
Environment=IDLE_MIN=30
Environment=LOAD_MAX=0.30
UNIT

sudo tee /etc/systemd/system/devbox-idle.timer >/dev/null <<'UNIT'
[Unit]
Description=Idle check every 5 minutes

[Timer]
OnBootSec=15min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now devbox-idle.timer
systemctl list-timers 'devbox-*' --no-pager
EOF
```

閾値は `override.conf` の `IDLE_MIN` で変更できます。変更後は `sudo systemctl daemon-reload`。

`OnBootSec=15min` は、起動直後に「まだ何もしていない」状態で即停止するのを防ぐための猶予です。

---

### 3.4 最後の砦（EventBridge Scheduler）

3.3 のアイドル検知は**インスタンス内部で動きます**。したがって、systemd の不調・
ディスク逼迫・スクリプトの破損などで検知そのものが止まると、誰もインスタンスを
停止できません。これを拾えるのは外部の仕組みだけです。

EventBridge Scheduler で、無条件の日次停止を保険として置きます。

**ロールは停止専用・対象1台に絞ること。** AWS コンソールのウィザードで作ると
`AmazonEC2FullAccess` が付くことがありますが、この用途には過剰です
（terminate を含む EC2 全操作が可能になります）。

```bash
SCHED_ROLE="claude-code-${ENV_NAME}-scheduler-role"

aws iam create-role --role-name "$SCHED_ROLE" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam put-role-policy --role-name "$SCHED_ROLE" --policy-name stop-only \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"ec2:StopInstances\",
      \"Resource\": \"arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:instance/${INSTANCE_ID}\"
    }]
  }"

SCHED_ROLE_ARN=$(aws iam get-role --role-name "$SCHED_ROLE" --query 'Role.Arn' --output text)
sleep 10   # ロール伝播待ち
```

これで起動用（4.1）と停止用が対称になります。**どちらも対象は1台、片方は起動のみ、
もう片方は停止のみ**です。

続けてスケジュールを作ります。時刻は自分の生活時間に合わせてください。

```bash
aws scheduler create-schedule --name "claude-code-${ENV_NAME}-backstop" \
  --schedule-expression 'cron(0 2 * * ? *)' \
  --schedule-expression-timezone 'Asia/Tokyo' \
  --flexible-time-window Mode=OFF \
  --description 'Last-resort backstop. Primary stop is the in-instance idle detector.' \
  --target "{
    \"Arn\": \"arn:aws:scheduler:::aws-sdk:ec2:stopInstances\",
    \"RoleArn\": \"${SCHED_ROLE_ARN}\",
    \"Input\": \"{\\\"InstanceIds\\\":[\\\"${INSTANCE_ID}\\\"]}\",
    \"RetryPolicy\": {\"MaximumEventAgeInSeconds\": 86400, \"MaximumRetryAttempts\": 0}
  }"
```

**保険が実際に効くか必ず確認してください。** 権限不足やターゲット定義の誤りがあると
**静かに失敗**し、「保険がある」と思い込んだまま常時起動が続きます。これは保険が
無いことより悪い状態です。数分後に発火する一時スケジュールを作って検証し、
確認後に削除するのが確実です。

```bash
# 例: 5分後に一度だけ発火させて、インスタンスが stopped になるか見る
aws scheduler create-schedule --name tmp-backstop-test \
  --schedule-expression "at($(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%S))" \
  --flexible-time-window Mode=OFF \
  --target "{...上と同じ...}"

# 確認後
aws scheduler delete-schedule --name tmp-backstop-test
```

**課金**: EventBridge Scheduler は月1400万実行まで無料枠のため、日次実行では発生しません。
実績でも8ヶ月にわたり `CloudWatch Events` の課金額は $0 でした。

**トレードオフ**: 無条件停止なので、その時刻に作業していれば落とされます。
ただし復帰は「起動コマンド + 約40秒 + `claude --continue`」で済むため、
巻き込まれたときの損失は小さく抑えられています。

---

## 4. 起動トリガー

自動停止を入れたので、次は**使いたいときに起動する手段**が必要です。

### 4.1 起動専用の IAM ユーザー

スマホに管理者権限のキーを置いてはいけません。
**「対象1台を起動する」以外に何もできない**ユーザーを作ります。

```bash
STARTER="claude-code-${ENV_NAME}-starter"

aws iam create-user --user-name "$STARTER" \
  --tags Key=Purpose,Value="Start dev instance from mobile"

aws iam put-user-policy --user-name "$STARTER" --policy-name start-only --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Action\": \"ec2:StartInstances\",
    \"Resource\": \"arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:instance/${INSTANCE_ID}\"
  }]
}"

aws iam create-access-key --user-name "$STARTER" --output json > /tmp/starter-key.json
chmod 600 /tmp/starter-key.json
```

**権限が閉じていることの検証**（発行したキーで実行し、以下の結果になること）:

| 操作 | 期待される結果 |
|---|---|
| `StartInstances`（対象、`DryRun=true`） | `DryRunOperation` |
| `StopInstances` | `UnauthorizedOperation` |
| `TerminateInstances` | `UnauthorizedOperation` |
| `DescribeInstances` | `UnauthorizedOperation` |
| `CreateSnapshot` | `UnauthorizedOperation` |

紛失時は以下で即座に無効化できます。

```bash
aws iam delete-access-key --user-name "$STARTER" --access-key-id <AccessKeyId>
```

### 4.2 Termux 側の設定（Android）

**`aws-cli` は入れません。** Python 込みで 100MB を超えるためです。
SigV4 署名は `curl` と `openssl` だけで生成できます（数MB）。

```bash
pkg install curl openssl-tool coreutils    # 未導入の場合のみ
```

資格情報を `~/.aws_devstart` に置きます（`chmod 600`）。

```
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
```

`~/.bashrc` に追記します。`DEV_*` の値は自分の環境に合わせてください。

```bash
DEV_INSTANCE=i-xxxxxxxxxxxxxxxxx
DEV_ADDR=<Elastic IP>
DEV_PORT=10022
DEV_REGION=ap-northeast-1
DEV_CRED=~/.aws_devstart
DEV_TMUX=claude              # tmux セッション名
DEV_DIR=/home/ubuntu/workspace   # tmux 新規作成時の開始ディレクトリ。**絶対パスで書くこと**（下記参照）

# ssh の後ろに書く内容をそのまま。~/.ssh/config に Host 定義があるなら "myhost" だけでよい
DEV_SSH="-i $HOME/.ssh/<your-key> -p 10022 ubuntu@<Elastic IP>"

_dev_sha()  { printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.*[ =]//'; }
_dev_hmac() { printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "$1" | sed 's/^.*[ =]//'; }

_dev_start() {
  local AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY   # 関数ローカル。環境変数に漏らさない
  . "$DEV_CRED" || return 1
  local host="ec2.${DEV_REGION}.amazonaws.com"
  local ct="application/x-www-form-urlencoded; charset=utf-8"
  local d s body scope k sig canon sts
  d=$(date -u +%Y%m%dT%H%M%SZ); s=${d%%T*}
  body="Action=StartInstances&Version=2016-11-15&InstanceId.1=${DEV_INSTANCE}"
  canon="POST
/

content-type:${ct}
host:${host}
x-amz-date:${d}

content-type;host;x-amz-date
$(_dev_sha "$body")"
  scope="${s}/${DEV_REGION}/ec2/aws4_request"
  sts="AWS4-HMAC-SHA256
${d}
${scope}
$(_dev_sha "$canon")"
  k=$(_dev_hmac "key:AWS4${AWS_SECRET_ACCESS_KEY}" "$s")
  k=$(_dev_hmac "hexkey:$k" "$DEV_REGION")
  k=$(_dev_hmac "hexkey:$k" ec2)
  k=$(_dev_hmac "hexkey:$k" aws4_request)
  sig=$(_dev_hmac "hexkey:$k" "$sts")
  curl -sS -X POST "https://${host}/" -H "Content-Type: ${ct}" -H "X-Amz-Date: ${d}" \
    -H "Authorization: AWS4-HMAC-SHA256 Credential=${AWS_ACCESS_KEY_ID}/${scope}, SignedHeaders=content-type;host;x-amz-date, Signature=${sig}" \
    --data "$body"
}

_dev_up() { timeout 3 bash -c "exec 3<>/dev/tcp/${DEV_ADDR}/${DEV_PORT}" 2>/dev/null; }

# d : 停止していれば起動してから繋ぐ。起動済みならそのまま繋ぐ。
d() {
  if ! _dev_up; then
    echo "起動中..."
    _dev_start >/dev/null || { echo "起動要求に失敗"; return 1; }
    local i=0
    until _dev_up; do
      i=$((i+1)); [ $i -gt 40 ] && { echo "タイムアウト"; return 1; }
      sleep 3
    done
    echo "起動完了"
  fi
  ssh $DEV_SSH -t "tmux attach -t $DEV_TMUX || tmux new -s $DEV_TMUX -c $DEV_DIR"
}
```

関数名は好みで構いません。実運用では1文字の `d` にしています。
既存の接続用エイリアス（`~/bin/c` など）があるなら、それを置き換える形になります。

**`DEV_DIR` は必ず絶対パスで書いてください。** `DEV_DIR=~/workspace` と書くと、
bash は変数代入の右辺でチルダ展開を行うため、**手元の端末側のホームパス**が入ります。
Termux なら `/data/data/com.termux/files/home/workspace` になり、それがそのまま
`tmux new -c` に渡ります。リモートに存在しないパスなので tmux は黙ってホームで起動し、
一見動いているのに開始ディレクトリだけ違う、という分かりにくい壊れ方をします。

確認方法:

```bash
ssh "$SSH_HOST" "tmux list-sessions -F '#{session_name} #{session_path}'"
```

`session_path` が端末側のパスになっていたらこの罠を踏んでいます。

`-c $DEV_DIR` は**新規セッション作成時のみ**効きます。既存セッションにアタッチする場合は、
各ペインの現在ディレクトリがそのまま維持されます。

**設計の要点**: 最初に疎通チェックを行い、**起動済みなら AWS API を一切叩きません**。
したがって起動中の体感は従来と完全に同じで、停止中のときだけ約40秒待ちます。
「起動」を別操作として分離せず、接続動作そのものをトリガーにしています。

**検証**:

```bash
_dev_start | head -c 200     # <StartInstancesResponse ...> が返れば署名は正常
d                            # 起動中なら即接続、停止中なら起動して接続
```

### 4.3 iOS の場合

iOS Shortcuts は SigV4 署名（HMAC-SHA256 の連鎖）を実装できません。代替案:

1. **AWS Console モバイルアプリ**で起動 → 既存の SSH クライアントで接続（実装ゼロ、MFA 保護、2ステップ）
2. **a-Shell / iSH** など shell が使えるアプリで上記スクリプトを流用

Lambda Function URL を `AuthType=NONE` + 共有シークレットで公開する方法もありますが、
**公開エンドポイントと自作の認証を増やすことになるため推奨しません**。
上記1で同等の目的を、より強い認証（IAM + MFA）で達成できます。

---

## 5. 全体の検証

1. 作業を終えて SSH を切断する
2. 30分以上待つ
3. インスタンスが `stopped` になっていることを確認

```bash
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].State.Name' --output text
```

4. スマホ/PC から `d` を実行し、「起動中... → 約40秒 → 起動完了 → tmux」となること
5. 起動後にログを確認

```bash
ssh "$SSH_HOST" 'journalctl -u devbox-idle -u devbox-backup --since -1d --no-pager | tail -40'
```

停止前にバックアップが実行された記録があること。

---

## 6. コスト根拠

東京リージョン、実測単価（Pricing API から取得）に基づく月額試算です。

| 項目 | 単価 | 24/7 | 月88時間（4h×22日） |
|---|---|---|---|
| EC2 t3.medium | $0.0544/h | $39.71 | $4.79 |
| EBS gp3 50GB | $0.096/GB月 | $4.80 | $4.80 |
| Elastic IP | $0.005/h（**停止中も課金**） | $3.65 | $3.65 |
| S3 バックアップ（~100MB） | — | — | ~$0.01 |
| **合計** | | **$48.16** | **$13.25** |

- **EIP は停止中も課金されます。** 解放して自動割当IPにすれば月 $3.2 ほど下がりますが、
  起動のたびに IP が変わり、スマホの SSH 設定を毎回書き換えることになります。
  接続できないと作業自体ができないため、信頼性を優先して**維持を推奨**します。
- EventBridge Scheduler は月1400万実行まで無料枠のため、日次スケジュール程度では課金されません。

---

## 7. 設計判断の記録

**この節は、後から「もっと良い方法があるのでは」と再検討する際の手戻りを防ぐためのものです。**
以下は検討済みで、いずれも却下または見送りとしています。

### ECS / Fargate + EFS への移行 — 却下

「コンテナなら使った分だけ課金」という直感は、この用途では成立しません。
**停止中の EC2 は compute 課金がゼロ**であり、EC2 の stop/start は既に従量課金モデルです。

| | 単価 | EC2 比 |
|---|---|---|
| Fargate x86（2vCPU/4GB 相当） | $0.12324/h | **2.27倍** |
| Fargate ARM（同） | $0.09858/h | **2.28倍** |
| EFS Standard | $0.36/GB月 | EBS gp3 の **3.75倍** |
| EFS One Zone | $0.192/GB月 | 同 **2.0倍** |

compute も storage も高くなります。加えて:

- EFS は NFS のため、`node_modules` のような小ファイル大量のツリーで `npm install` や `git status` が著しく遅くなる
- Fargate のエフェメラルストレージはタスク停止で消えるため、ツールチェーンもキャッシュも全て EFS に載る
- コールドスタートは速くならない（Fargate 30〜90秒 vs EC2 約40秒）

なお「セッションごとに作業ディレクトリを分ける」という発想自体は有効で、
これは **git worktree** でコンテナ無しに実現できます。

### terminate して都度作り直す — 却下

stop/start との差はスナップショット保管費との差額で月 $6 程度。
数十GBの作業環境を毎回復元するコストに見合いません。

### Claude Code の resume 機能を前提にした設計 — 誤り

EC2 の stop/start は**ルート EBS をそのまま保持する**ため、
`~/.claude/projects/**/*.jsonl` は無傷で残り、`claude --continue` は**追加実装なしで動きます**。
resume は stop/start の実現要件ではありません。

resume が実際に効くのは別の箇所です。アイドル判定を誤って停止してしまった場合の
復帰コストが「1コマンド + 40秒 + `claude --continue`」で済むため、
**閾値を短く設定できる**という点で価値があります。

### 固定時刻での自動停止 — 主機構としては却下、保険としては採用

`cron(0 2 * * ? *)` のような固定時刻停止は実装が簡単ですが、
利用時間が不定期な場合、作業中に落とします。**主たる停止機構にはできません。**

一方で、保険としては価値があります。アイドル検知はインスタンス内部で動くため、
**その仕組み自体が壊れた場合（systemd の不調、ディスク逼迫、スクリプトの破損）は
誰も止められません**。これを拾えるのは外部の仕組みだけです。
詳細は「3.4 最後の砦」を参照してください。

### Graviton（t4g）移行・ハイバネーション・Spot — 見送り

いずれもインスタンスの作り直しが必要です。
**オンデマンド化後は compute が月$5程度まで下がるため、これらの削減効果は月$1〜3にしかなりません。**
労力は自動化に振るべきです。

- Graviton: 約20%安いが再構築が必要
- ハイバネーション: tmux やプロセスを保ったまま復帰できるが、**起動時にしか有効化できず**後付け不可
- Spot: 約60%安いが、2分予告での中断は対話的作業に不向き

---

## 8. 既知の落とし穴

| 症状 | 原因 | 対処 |
|---|---|---|
| 永久に自動停止しない | `~/.aws/credentials` の静的キーが優先され、S3 バックアップが失敗して停止処理に到達しない | `sts get-caller-identity` で `assumed-role/` が返るか確認 |
| 同上 | tmux クライアントが張り付いている | 本手順の「最終活動時刻の最大値」方式なら発生しない。積算方式に改変しないこと |
| 作業中に停止される | 長時間 tmux をデタッチしたまま考えていた | `IDLE_MIN` を伸ばす。または諦めて `d` で再開（40秒） |
| ビルド中に停止される | load average の閾値が高すぎる | `LOAD_MAX` を下げる |
| バックアップが実行されない | `Persistent=true` が無い | オンデマンド運用では必須 |
| `origin` 無しリポジトリの設定ファイルが復元できない | `--exclude-standard` が gitignore 対象を除外した | 本手順のとおり全ツリー退避にする |
| 起動できない（`InvalidInstanceID.NotFound`） | `DEV_INSTANCE` の値が古い | インスタンスを作り直した場合は ID とポリシーの ARN を更新する |
| tmux が意図したディレクトリで始まらない | `DEV_DIR=~/...` と書いて手元の端末側でチルダ展開された | `DEV_DIR` を絶対パスにする。`tmux list-sessions -F '#{session_path}'` で確認できる |
| 保険の日次停止が発火しない | スケジューラ用ロールの権限不足やターゲット定義の誤り。**静かに失敗する** | 一時スケジュールで実発火を確認する（3.4） |
| **アイドル停止が永久に発火しない** | **クライアント** tty の `mtime` を混ぜた。tmux のステータスバー再描画で常時更新される | クライアント tty は `atime` のみ（3.1） |
| **作業中に停止される** | **ペイン** tty の `mtime` を捨てた。キー入力を伴わない長時間の自動処理を拾えない | ペイン tty は `mtime` も見る（3.1）。`load` 閾値だけでは低負荷の待機を守れない |
