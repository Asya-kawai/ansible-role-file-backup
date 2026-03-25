# Ansible Role For Backup web server settings

[![CI](https://github.com/Asya-kawai/ansible-role-backup/actions/workflows/ci.yml/badge.svg)](https://github.com/Asya-kawai/ansible-role-file-backup/actions/workflows?query=workflow%3ACI)

## 概要

このAnsibleロールは、サーバ上の各種ログファイルやディレクトリを定期的にバックアップし、必要に応じてS3や他サーバへ転送する仕組みを構築します。
バックアップ・転送処理はsystemdサービス/タイマーで自動実行されます。

## 仕組み・特徴

- バックアップ対象のログやディレクトリを指定し、指定ユーザーでバックアップスクリプトを実行します。
- S3転送やサーバ間転送も同一ユーザー（デフォルト: root）で行います。
- S3転送時はsudoでroot権限となるため、AWS CLIはrootユーザーの`/root/.aws/credentials`および`/root/.aws/config`を参照します。
  - S3転送を有効化する場合は、必ずAWSクレデンシャル/コンフィグを配置してください。
- systemdタイマーで定期実行され、失敗時はログで確認できます。

## 変数例

`defaults/main.yml` も参照してください。

```yaml
# バックアップユーザー/グループ
file_backup_user: root
file_backup_group: root

# バックアップ先ディレクトリ（空の場合は元ファイルと同じ場所）
file_backup_dest_dir: ''

# S3転送有効化
file_backup_s3_transfer_enable: true
file_backup_s3_transfer_bucket: my-backup-bucket
file_backup_s3_transfer_aws_cli_profile: default

# AWSクレデンシャル（S3転送時はrootの~/.aws/配下に設置）
# /root/.aws/credentials, /root/.aws/config
aws:
  config:
    content: |
      [default]
      region = us-east-1
      output = json
      endpoint_url = https://s3.amazonaws.com
  credential:
    content: |
      [default]
      aws_access_key_id = AKIAIOSFODNN7EXAMPLE
      aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# バックアップスケジュール例
file_backup_auditlog_backup_on_calendar: '*-*-* 00:00:00'
file_backup_authlog_backup_on_calendar: '*-*-* 00:10:00'
file_backup_dmesg_backup_on_calendar: '*-*-* 00:20:00'
file_backup_journallog_backup_on_calendar: '*-*-* 00:30:00'
```

## 注意事項

- バックアップユーザーとサーバ転送ユーザーは同じです（デフォルト: root）。
- systemdタイマー/サービスが有効なことを確認してください。
- バックアップ対象ファイル/ディレクトリのパーミッションに注意してください。

## 実行例

## 一連の確認作業コマンド例

このロールの動作確認やデバッグのために、以下の手順で一連のコマンドを実行できます。

```
# バックアップサーバコンテナに入る
podman exec -it backup-server bash

# バックアップ先ディレクトリの作成（初回のみ）
mkdir /backup
# 所有者・グループの変更（ユーザー・グループはplaybookのvarsに合わせてください）
chown -R backup-for-dest:backup-for-dest /backup

# ノードコンテナに入る
podman exec -it ubuntu-1 bash
# S3バケットの作成（初回のみ）
aws s3 mb s3://my-backup-bucket

# systemdサービスの手動起動（バックアップ・転送処理のテスト）
systemctl start authlog_backup.service
systemctl start logs_transfer@authlog.service
```

これにより、スクリプトの動作やエラー出力（journalctl -e で確認可能）を手動で検証できます。

Dry Run

```
ansible-playbook -i inventory --private-key="~/.ssh/your_private_key" --check --diff playbook.yml --tags backup
```

Apply

```
ansible-playbook -i inventory --private-key="~/.ssh/your_private_key" playbook.yml --tags backup
```

## Known Issues / 注意事項

### awscliインストールタスクの失敗について

Ansibleのawscliインストールタスク（`install_aws_cli.yml`）は、まれに以下のようなエラーで失敗することがあります：

```
MODULE FAILURE: No end of json char found
```

この問題はAnsibleのunarchiveモジュールがawscliのインストール時に予期しない出力を受け取ることで発生します。環境やタイミングに依存し、再現性が低いですが、**再実行することで正常に完了する場合がほとんどです**。

### Galaxy用パッケージング時のtar圧縮失敗について

Ansible Galaxy用に `tar` でロールを圧縮する際、圧縮対象のファイルが直前に変更された場合などに「ファイル変更が検知されて失敗」することがあります。

この場合も、**再度 `make test-role` を実行することで解消される場合が多い**です。

#### 対応方法
- `make test-role` 実行時にtar圧縮エラーが発生した場合は、**`make ansible` を実行するか、再度 `make test-role` を実行してください**。
  - `make ansbile`ならコンテナの再起動が発生しないため楽です。
- それでも解決しない場合は、ファイルの変更タイミングや権限、ディスク容量等をご確認ください。

---

Dry Run

```
ansible-playbook -i inventory --private-key="~/.ssh/your_private_key" --check --diff webservers.yml --tags file-backup
```

Apply

```
ansible-playbook -i inventory --private-key="~/.ssh/your_private_key" webservers.yml --tags file-backup
```

## Troubleshooting & Tips

- If backups are not created, check systemd timer status (`systemctl status backup.timer`).
- Ensure all target directories exist and are readable by the backup user.
- Review logs in `/var/backup/` for errors.
- If `dir_backup.sh` is missing, verify internet connectivity and GitHub access.

## License & Author

See LICENSE for details. Role maintained by Asya-kawai.
