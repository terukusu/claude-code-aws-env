# devbox-connect.sh — 停止していれば起動し、繋ぐ。
#
# macOS(zsh/bash) と Termux(bash) の両方で同じものを読む。
# シェル設定から source して使う:
#     source ~/.devbox-connect.sh
#
# 起動要求の出し方だけ環境で変える。
#   aws CLI がある  -> aws ec2 start-instances（Mac 想定）
#   aws CLI が無い  -> curl + openssl で SigV4 を自前生成（Termux 想定。
#                      aws-cli は Python 込みで 100MB 超になるため入れない）

# ---- 設定 ------------------------------------------------------------------
DEV_INSTANCE=${DEV_INSTANCE:-}          # i-xxxxxxxx
DEV_ADDR=${DEV_ADDR:-}                  # Elastic IP
DEV_PORT=${DEV_PORT:-10022}
DEV_REGION=${DEV_REGION:-ap-northeast-1}
DEV_TMUX=${DEV_TMUX:-claude}
DEV_DIR=${DEV_DIR:-/home/ubuntu/workspace}   # リモート側の絶対パス。~ を書くと手元で展開される
# ssh の後ろに置く内容。zsh は展開結果を単語分割しないため、必ず配列で持つこと。
#   例) DEV_SSH_ARGS=(claude)
#   例) DEV_SSH_ARGS=(-i ~/.ssh/mykey.pem -p 10022 ubuntu@203.0.113.10)
[ ${#DEV_SSH_ARGS[@]} -eq 0 ] 2>/dev/null && DEV_SSH_ARGS=()
DEV_PROFILE=${DEV_PROFILE:-}            # aws CLI 用プロファイル名
DEV_CRED=${DEV_CRED:-$HOME/.aws_devstart}    # aws CLI が無い環境で使う資格情報

# ---- 疎通チェック ----------------------------------------------------------
# zsh に /dev/tcp は無く、macOS に timeout は無い。使える方を選ぶ。
_dev_up() {
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 2 "$DEV_ADDR" "$DEV_PORT" >/dev/null 2>&1
  elif command -v timeout >/dev/null 2>&1; then
    timeout 3 bash -c "exec 3<>/dev/tcp/${DEV_ADDR}/${DEV_PORT}" >/dev/null 2>&1
  else
    bash -c "exec 3<>/dev/tcp/${DEV_ADDR}/${DEV_PORT}" >/dev/null 2>&1
  fi
}

# ---- 起動要求 --------------------------------------------------------------
_dev_sha()  { printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.*[ =]//'; }
_dev_hmac() { printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "$1" | sed 's/^.*[ =]//'; }

_dev_start_sigv4() {
  local AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY   # 関数ローカル。環境に漏らさない
  . "$DEV_CRED" || return 1
  local host="ec2.${DEV_REGION}.amazonaws.com"
  local ct="application/x-www-form-urlencoded; charset=utf-8"
  local ts ds body scope k sig canon sts
  ts=$(date -u +%Y%m%dT%H%M%SZ); ds=${ts%%T*}
  body="Action=StartInstances&Version=2016-11-15&InstanceId.1=${DEV_INSTANCE}"
  canon="POST
/

content-type:${ct}
host:${host}
x-amz-date:${ts}

content-type;host;x-amz-date
$(_dev_sha "$body")"
  scope="${ds}/${DEV_REGION}/ec2/aws4_request"
  sts="AWS4-HMAC-SHA256
${ts}
${scope}
$(_dev_sha "$canon")"
  k=$(_dev_hmac "key:AWS4${AWS_SECRET_ACCESS_KEY}" "$ds")
  k=$(_dev_hmac "hexkey:$k" "$DEV_REGION")
  k=$(_dev_hmac "hexkey:$k" ec2)
  k=$(_dev_hmac "hexkey:$k" aws4_request)
  sig=$(_dev_hmac "hexkey:$k" "$sts")
  curl -sS -X POST "https://${host}/" -H "Content-Type: ${ct}" -H "X-Amz-Date: ${ts}" \
    -H "Authorization: AWS4-HMAC-SHA256 Credential=${AWS_ACCESS_KEY_ID}/${scope}, SignedHeaders=content-type;host;x-amz-date, Signature=${sig}" \
    --data "$body"
}

# ${VAR:+--profile "$VAR"} は zsh で1語になり aws が解釈できない。分岐で書く。
_dev_start() {
  if command -v aws >/dev/null 2>&1; then
    if [ -n "$DEV_PROFILE" ]; then
      aws --profile "$DEV_PROFILE" --region "$DEV_REGION" \
          ec2 start-instances --instance-ids "$DEV_INSTANCE" --output text
    else
      aws --region "$DEV_REGION" ec2 start-instances --instance-ids "$DEV_INSTANCE" --output text
    fi
  else
    _dev_start_sigv4
  fi
}

# ---- 本体 ------------------------------------------------------------------
d() {
  if [ -z "$DEV_INSTANCE" ] || [ -z "$DEV_ADDR" ] || [ ${#DEV_SSH_ARGS[@]} -eq 0 ]; then
    echo "DEV_INSTANCE / DEV_ADDR / DEV_SSH_ARGS が未設定です" >&2; return 1
  fi
  if ! _dev_up; then
    echo "起動中..."
    _dev_start >/dev/null || { echo "起動要求に失敗" >&2; return 1; }
    local i=0
    until _dev_up; do
      i=$((i+1)); [ "$i" -gt 40 ] && { echo "タイムアウト" >&2; return 1; }
      sleep 3
    done
    echo "起動完了"
  fi
  ssh "${DEV_SSH_ARGS[@]}" -t "tmux attach -t $DEV_TMUX || tmux new -s $DEV_TMUX -c $DEV_DIR"
}
