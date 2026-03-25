# -----------------------------------------
# Config
# -----------------------------------------
# Official Ubuntu image does NOT include /sbin/init or /lib/systemd/systemd.
# Official CentOS image does NOT include /sbin/init or /usr/lib/systemd/systemd.
# Custom build images are required for systemd support.
UBUNTU_IMAGE=ubuntu-systemd:latest
CENTOS_IMAGE=centos-systemd:latest

# Number of nodes per distro
UBUNTU_NODES=1
CENTOS_NODES=1

# Names will be ubuntu-1..N, centos-1..N
ANSIBLE_INVENTORY ?= inventory.yml
PLAYBOOK ?= playbook.yml

# SSH user for backup server (log transfer test)
BACKUP_SERVER_SSH_USER ?= backup-for-dest

# file backup settings
FILE_BACKUP_USER ?= log-backup
FILE_BACKUP_GROUP ?= log-backup
FILE_BACKUP_DEST_DIR ?= ''

FILE_BACKUP_S3_TRANSFER_AWS_CLI_PROFILE=default
FILE_BACKUP_S3_TRANSFER_BUCKET=my-backup-bucket

FILE_BACKUP_LOG_TRANSFER_DEST_DIR=/backup
FILE_BACKUP_LOG_TRANSFER_SSH_USER=$(BACKUP_SERVER_SSH_USER)

# -----------------------------------------
# Lint: ansible-lint for playbook and roles
# -----------------------------------------
.PHONY: lint
lint:
	@echo "==> Running ansible-lint on key role files and directories"
	ansible-lint tasks/
	ansible-lint handlers/
	ansible-lint defaults/
	ansible-lint vars/
	ansible-lint meta/

# -----------------------------------------
# Tools existence check (fail fast)
# -----------------------------------------
.PHONY: check
check:
	@command -v podman >/dev/null 2>&1 || { echo "podman not found"; exit 1; }
	@command -v ansible-playbook >/dev/null 2>&1 || { echo "ansible-playbook not found"; exit 1; }
	@command -v ansible-galaxy >/dev/null 2>&1 || { echo "ansible-galaxy not found"; exit 1; }

# -----------------------------------------
# Prepare: install required Ansible collection for Podman connection
# -----------------------------------------
.PHONY: deps
deps: check
	# Install the connection plugin for Podman containers
	ansible-galaxy collection install containers.podman --force

# -----------------------------------------
# Create systemd-enabled containers
# -----------------------------------------
.PHONY: build-ubuntu-image
build-ubuntu-image:
	@echo "==> Building Ubuntu systemd image"
	# Official Ubuntu image does NOT include /sbin/init or /lib/systemd/systemd.
	# Error example:
	# podman run -d --name ubuntu --privileged --systemd=always ubuntu:24.04 /sbin/init
	# Error: executable file `/sbin/init` not found in $PATH: No such file or directory
	# podman run -d --name ubuntu --privileged --systemd=always ubuntu:24.04 /lib/systemd/systemd
	# Error: executable file `/lib/systemd/systemd` not found in $PATH: No such file or directory
	# Therefore, custom Dockerfile.ubuntu-systemd is used.
	podman build -t ubuntu-systemd:latest -f Dockerfile.ubuntu-systemd .

.PHONY: build-centos-image
build-centos-image:
	@echo "==> Building CentOS systemd image"
	# Official CentOS image does NOT include /sbin/init or /usr/lib/systemd/systemd.
	# Therefore, custom Dockerfile.centos-systemd is used.
	podman build -t centos-systemd:latest -f Dockerfile.centos-systemd .

.PHONY: create-nodes
create-nodes: check build-ubuntu-image build-centos-image
	@echo "==> Creating Ubuntu nodes"
	@for i in $$(seq 1 $(UBUNTU_NODES)); do \
		name=ubuntu-$$i; \
		podman rm -f $$name >/dev/null 2>&1 || true; \
		echo "[create] $$name ($(UBUNTU_IMAGE))"; \
		podman run -d --name $$name --network podman --privileged --systemd=always $(UBUNTU_IMAGE); \
		# comm: Shows only the executable file name, truncated to 16 characters if longer. ; \
		podman exec $$name bash -lc 'ps -p 1 -o comm=' ; \
	done;
	@echo "==> Creating CentOS nodes"
	@for i in $$(seq 1 $(CENTOS_NODES)); do \
		name=centos-$$i; \
		podman rm -f $$name >/dev/null 2>&1 || true; \
		echo "[create] $$name ($(CENTOS_IMAGE))"; \
		podman run -d --name $$name --network podman --privileged --systemd=always $(CENTOS_IMAGE); \
		podman exec $$name bash -lc 'ps -p 1 -o comm=' ; \
	done

.PHONY: create-minio

MINIO_ACCESS_KEY ?= minioadmin
MINIO_SECRET_KEY ?= minioadminpass
MINIO_PORT ?= 9000
MINIO_CONSOLE_PORT ?= 9001

create-minio:
	@echo "==> Creating MinIO server for S3 transfer test"
	@podman rm -f minio >/dev/null 2>&1 || true
	@podman run -d --name minio --network podman \
		-p $(MINIO_PORT):$(MINIO_PORT) -p $(MINIO_CONSOLE_PORT):$(MINIO_CONSOLE_PORT) \
		-e MINIO_ROOT_USER=$(MINIO_ACCESS_KEY) \
	  -e MINIO_ROOT_PASSWORD=$(MINIO_SECRET_KEY) \
	  quay.io/minio/minio server /data --console-address ":$(MINIO_CONSOLE_PORT)"

.PHONY: create-backup-server
create-backup-server: generate-ssh-key
	@echo "==> Creating backup server for log transfer test"
	@podman rm -f backup-server >/dev/null 2>&1 || true
	@podman run -d --name backup-server --network podman -p 2222:22 ubuntu:24.04 sleep infinity
	@podman exec backup-server apt-get update
	@podman exec backup-server apt-get install -y openssh-server rsync sudo
	@podman exec backup-server useradd -m -s /bin/bash $(BACKUP_SERVER_SSH_USER) || true
	@podman exec backup-server mkdir -p /home/$(BACKUP_SERVER_SSH_USER)/.ssh
	@podman cp $(SSH_KEY_ID_BACKUP_SERVER).pub backup-server:/tmp/backup_server_key.pub
	@podman exec backup-server bash -c 'cat /tmp/backup_server_key.pub >> /home/$(BACKUP_SERVER_SSH_USER)/.ssh/authorized_keys'
	@podman exec backup-server rm /tmp/backup_server_key.pub
	@podman exec backup-server chown -R $(BACKUP_SERVER_SSH_USER):$(BACKUP_SERVER_SSH_USER) /home/$(BACKUP_SERVER_SSH_USER)/.ssh
	@podman exec backup-server chmod 700 /home/$(BACKUP_SERVER_SSH_USER)/.ssh
	@podman exec backup-server chmod 600 /home/$(BACKUP_SERVER_SSH_USER)/.ssh/authorized_keys
	@podman exec backup-server service ssh start

.PHONY: create-others-components
create-others-components: create-minio create-backup-server

# -----------------------------------------
# SSH key generation for log transfer test
# -----------------------------------------
.PHONY: generate-ssh-key

SSH_KEY_ID_BACKUP_SERVER ?= id_backup_server

generate-ssh-key:
	@echo "==> Generating SSH key for backup-server access"
	@if [ ! -f ./$(SSH_KEY_ID_BACKUP_SERVER) ]; then \
	  ssh-keygen -t ed25519 -N '' -f ./$(SSH_KEY_ID_BACKUP_SERVER); \
	  echo "SSH key generated: $(SSH_KEY_ID_BACKUP_SERVER), $(SSH_KEY_ID_BACKUP_SERVER).pub"; \
	else \
	  echo "SSH key already exists: $(SSH_KEY_ID_BACKUP_SERVER), $(SSH_KEY_ID_BACKUP_SERVER).pub"; \
	fi

# -----------------------------------------
# Generate test playbook
# -----------------------------------------
.PHONY: generate-playbook
generate-playbook: generate-ssh-key create-minio
	@echo "==> Generating playbooks for each transfer case"

	# 1. s3_transfer: false, log_transfer: false (default)
	@echo "---" > $(PLAYBOOK)
	@echo "- name: Test file-backup role (no transfer)" >> $(PLAYBOOK)
	@echo "  hosts: all" >> $(PLAYBOOK)
	@echo "  become: yes" >> $(PLAYBOOK)
	@echo "  vars:" >> $(PLAYBOOK)
	@echo "    file_backup_user: $(FILE_BACKUP_USER)" >> $(PLAYBOOK)
	@echo "    file_backup_group: $(FILE_BACKUP_GROUP)" >> $(PLAYBOOK)
	@echo "    file_backup_dest_dir: $(FILE_BACKUP_DEST_DIR)" >> $(PLAYBOOK)
	@echo "    file_backup_s3_transfer_enable: false" >> $(PLAYBOOK)
	@echo "    file_backup_log_transfer_enable: false" >> $(PLAYBOOK)
	@echo "  roles:" >> $(PLAYBOOK)
	@echo "    - file-backup" >> $(PLAYBOOK)

	# 2. s3_transfer: true, log_transfer: false
	@echo "---" > playbook.s3_only.yml
	@echo "- name: Test file-backup role (S3 transfer only)" >> playbook.s3_only.yml
	@echo "  hosts: all" >> playbook.s3_only.yml
	@echo "  become: yes" >> playbook.s3_only.yml
	@echo "  vars:" >> playbook.s3_only.yml
	@echo "    file_backup_s3_transfer_enable: true" >> playbook.s3_only.yml
	@echo "    file_backup_log_transfer_enable: false" >> playbook.s3_only.yml
	@echo "    file_backup_user: $(FILE_BACKUP_USER)" >> playbook.s3_only.yml
	@echo "    file_backup_group: $(FILE_BACKUP_GROUP)" >> playbook.s3_only.yml
	@echo "    file_backup_dest_dir: $(FILE_BACKUP_DEST_DIR)" >> playbook.s3_only.yml
	@echo "    file_backup_s3_transfer_aws_cli_profile: $(FILE_BACKUP_S3_TRANSFER_AWS_CLI_PROFILE)" >> playbook.s3_only.yml
	@echo "    file_backup_s3_transfer_bucket: $(FILE_BACKUP_S3_TRANSFER_BUCKET)" >> playbook.s3_only.yml
	@echo "    aws:" >> playbook.s3_only.yml
	@echo "      config:" >> playbook.s3_only.yml
	@echo "        content: |" >> playbook.s3_only.yml
	@echo "          [$(FILE_BACKUP_S3_TRANSFER_AWS_CLI_PROFILE)]" >> playbook.s3_only.yml
	@echo "          region = us-east-1" >> playbook.s3_only.yml
	@echo "          output = json" >> playbook.s3_only.yml
	@MINIO_IP=""; \
	for i in $$(seq 1 15); do \
	  MINIO_IP=$$(podman inspect minio | grep -A 10 '"Networks"' | grep '"IPAddress"' | head -1 | awk -F '"' '{print $$4}'); \
	  if [ -n "$$MINIO_IP" ]; then \
			break; \
		fi; \
	  echo "Waiting for MinIO IP... ($$i)"; \
	  sleep 2; \
	done ; \
	if [ -z "$$MINIO_IP" ]; then \
		echo "[ERROR] MinIO IPアドレスが取得できませんでした"; \
		exit 1; \
	fi ; \
	echo "          endpoint_url = http://$${MINIO_IP}:$(MINIO_PORT)" >> playbook.s3_only.yml
	@echo "      credential:" >> playbook.s3_only.yml
	@echo "        content: |" >> playbook.s3_only.yml
	@echo "          [$(FILE_BACKUP_S3_TRANSFER_AWS_CLI_PROFILE)]" >> playbook.s3_only.yml
	@echo "          aws_access_key_id = $(MINIO_ACCESS_KEY)" >> playbook.s3_only.yml
	@echo "          aws_secret_access_key = $(MINIO_SECRET_KEY)" >> playbook.s3_only.yml
	@echo "  roles:" >> playbook.s3_only.yml
	@echo "    - file-backup" >> playbook.s3_only.yml

	# 3. s3_transfer: true, log_transfer: true
	@echo "---" > playbook.s3_and_log.yml
	@echo "- name: Test file-backup role (S3 & log transfer)" >> playbook.s3_and_log.yml
	@echo "  hosts: all" >> playbook.s3_and_log.yml
	@echo "  become: yes" >> playbook.s3_and_log.yml
	@echo "  vars:" >> playbook.s3_and_log.yml
	@echo "    file_backup_s3_transfer_enable: true" >> playbook.s3_and_log.yml
	@echo "    file_backup_log_transfer_enable: true" >> playbook.s3_and_log.yml
	@echo "    file_backup_user: $(FILE_BACKUP_USER)" >> playbook.s3_and_log.yml
	@echo "    file_backup_group: $(FILE_BACKUP_GROUP)" >> playbook.s3_and_log.yml
	@echo "    file_backup_dest_dir: $(FILE_BACKUP_DEST_DIR)" >> playbook.s3_and_log.yml
	@echo "    file_backup_s3_transfer_aws_cli_profile: $(FILE_BACKUP_S3_TRANSFER_AWS_CLI_PROFILE)" >> playbook.s3_and_log.yml
	@echo "    file_backup_s3_transfer_bucket: $(FILE_BACKUP_S3_TRANSFER_BUCKET)" >> playbook.s3_and_log.yml
	@echo "    aws:" >> playbook.s3_and_log.yml
	@echo "      config:" >> playbook.s3_and_log.yml
	@echo "        content: |" >> playbook.s3_and_log.yml
	@echo "          [$(FILE_BACKUP_S3_TRANSFER_AWS_CLI_PROFILE)]" >> playbook.s3_and_log.yml
	@echo "          region = us-east-1" >> playbook.s3_and_log.yml
	@echo "          output = json" >> playbook.s3_and_log.yml
	@MINIO_IP=""; \
	for i in $$(seq 1 15); do \
	  MINIO_IP=$$(podman inspect minio | grep -A 10 '"Networks"' | grep '"IPAddress"' | head -1 | awk -F '"' '{print $$4}'); \
	  if [ -n "$$MINIO_IP" ]; then \
			break; \
		fi; \
	  echo "Waiting for MinIO IP... ($$i)"; \
	  sleep 2; \
	done ; \
	if [ -z "$$MINIO_IP" ]; then \
		echo "[ERROR] MinIO IPアドレスが取得できませんでした"; \
		exit 1; \
	fi ; \
	echo "          endpoint_url = http://$${MINIO_IP}:$(MINIO_PORT)" >> playbook.s3_and_log.yml
	@echo "      credential:" >> playbook.s3_and_log.yml
	@echo "        content: |" >> playbook.s3_and_log.yml
	@echo "          [$(FILE_BACKUP_S3_TRANSFER_AWS_CLI_PROFILE)]" >> playbook.s3_and_log.yml
	@echo "          aws_access_key_id = $(MINIO_ACCESS_KEY)" >> playbook.s3_and_log.yml
	@echo "          aws_secret_access_key = $(MINIO_SECRET_KEY)" >> playbook.s3_and_log.yml
	@BACKUP_SERVER_IP=""; \
	for i in $$(seq 1 15); do \
	  BACKUP_SERVER_IP=$$(podman inspect backup-server | grep -A 10 '"Networks"' | grep '"IPAddress"' | head -1 | awk -F '"' '{print $$4}'); \
	  if [ -n "$$BACKUP_SERVER_IP" ]; then \
			break; \
		fi; \
	  echo "Waiting for backup server IP... ($$i)"; \
	  sleep 2; \
	done ; \
	if [ -z "$$BACKUP_SERVER_IP" ]; then \
		echo "[ERROR] Backup server IPアドレスが取得できませんでした"; \
		exit 1; \
	fi ; \
	echo  "    file_backup_log_transfer_hosts: $${BACKUP_SERVER_IP}" >> playbook.s3_and_log.yml
	@echo "    file_backup_log_transfer_dest_dir: $(FILE_BACKUP_LOG_TRANSFER_DEST_DIR)" >> playbook.s3_and_log.yml
	@echo "    file_backup_log_transfer_ssh_user: $(BACKUP_SERVER_SSH_USER)" >> playbook.s3_and_log.yml
	@echo "    file_backup_log_transfer_ssh_key: \"{{ lookup('file', '$(SSH_KEY_ID_BACKUP_SERVER)', errors='ignore') }}\"" >> playbook.s3_and_log.yml
	@echo "  roles:" >> playbook.s3_and_log.yml
	@echo "    - file-backup" >> playbook.s3_and_log.yml

	# 4. s3_transfer: false, log_transfer: true
	@echo "---" > playbook.log_only.yml
	@echo "- name: Test file-backup role (log transfer only)" >> playbook.log_only.yml
	@echo "  hosts: all" >> playbook.log_only.yml
	@echo "  become: yes" >> playbook.log_only.yml
	@echo "  vars:" >> playbook.log_only.yml
	@echo "    file_backup_s3_transfer_enable: false" >> playbook.log_only.yml
	@echo "    file_backup_log_transfer_enable: true" >> playbook.log_only.yml
	@echo "    file_backup_user: $(FILE_BACKUP_USER)" >> playbook.log_only.yml
	@echo "    file_backup_group: $(FILE_BACKUP_GROUP)" >> playbook.log_only.yml
	@echo "    file_backup_dest_dir: $(FILE_BACKUP_DEST_DIR)" >> playbook.log_only.yml
	@BACKUP_SERVER_IP=""; \
	for i in $$(seq 1 15); do \
	  BACKUP_SERVER_IP=$$(podman inspect backup-server | grep -A 10 '"Networks"' | grep '"IPAddress"' | head -1 | awk -F '"' '{print $$4}'); \
	  if [ -n "$$BACKUP_SERVER_IP" ]; then \
			break; \
		fi; \
	  echo "Waiting for backup server IP... ($$i)"; \
	  sleep 2; \
	done ; \
	if [ -z "$$BACKUP_SERVER_IP" ]; then \
		echo "[ERROR] Backup server IPアドレスが取得できませんでした"; \
		exit 1; \
	fi ; \
	echo  "    file_backup_log_transfer_hosts: $${BACKUP_SERVER_IP}" >> playbook.log_only.yml
	@echo "    file_backup_log_transfer_dest_dir: $(FILE_BACKUP_LOG_TRANSFER_DEST_DIR)" >> playbook.log_only.yml
	@echo "    file_backup_log_transfer_ssh_user: $(BACKUP_SERVER_SSH_USER)" >> playbook.log_only.yml
	@echo "    file_backup_log_transfer_ssh_key: \"{{ lookup('file', '$(SSH_KEY_ID_BACKUP_SERVER)', errors='ignore') }}\"" >> playbook.log_only.yml
	@echo "  roles:" >> playbook.log_only.yml
	@echo "    - file-backup" >> playbook.log_only.yml

# -----------------------------------------
# Generate dynamic Ansible inventory (Podman connection → SSH is not needed)
# -----------------------------------------
.PHONY: generate-inventory
generate-inventory:
	@echo "==> Generating $(ANSIBLE_INVENTORY) for test"
	@echo "# generated" > $(ANSIBLE_INVENTORY)
	@echo "all:" >> $(ANSIBLE_INVENTORY)
	@echo "  children:" >> $(ANSIBLE_INVENTORY)
	@echo "    ubuntu:" >> $(ANSIBLE_INVENTORY)
	@echo "      hosts:" >> $(ANSIBLE_INVENTORY)
	@for i in $$(seq 1 $(UBUNTU_NODES)); do \
		echo "        ubuntu-$$i:" >> $(ANSIBLE_INVENTORY); \
		echo "          ansible_connection: containers.podman.podman" >> $(ANSIBLE_INVENTORY); \
		echo "          ansible_python_interpreter: /usr/bin/python3" >> $(ANSIBLE_INVENTORY); \
	done;
	@echo "    centos:" >> $(ANSIBLE_INVENTORY)
	@echo "      hosts:" >> $(ANSIBLE_INVENTORY)
	@for i in $$(seq 1 $(CENTOS_NODES)); do \
		echo "        centos-$$i:" >> $(ANSIBLE_INVENTORY); \
		echo "          ansible_connection: containers.podman.podman" >> $(ANSIBLE_INVENTORY); \
		# CentOS Stream 9 has /usr/libexec/platform-python for system tools, but we install python3 in playbook anyway  ; \
		echo "          ansible_python_interpreter: /usr/bin/python3" >> $(ANSIBLE_INVENTORY); \
	done

# -----------------------------------------
# Run Ansible playbook
# -----------------------------------------
.PHONY: ansible
# Options: set via environment or command line
DRYRUN ?= 0
VERBOSE ?= 0
TAGS ?=

# Compose ansible-playbook options
ANSIBLE_OPTS =
ifneq ($(DRYRUN),0)
ANSIBLE_OPTS += --check --diff
endif
ifneq ($(VERBOSE),0)
ANSIBLE_OPTS += -vvv
endif
ifneq ($(TAGS),)
ANSIBLE_OPTS += --tags $(TAGS)
endif

ansible: generate-playbook generate-inventory
	ansible-playbook -i $(ANSIBLE_INVENTORY) $(PLAYBOOK) $(ANSIBLE_OPTS)

# -----------------------------------------
# Destroy all containers
# -----------------------------------------
.PHONY: destroy
destroy: destroy-others-components
	@echo "==> Removing Ubuntu nodes"
	@for i in $$(seq 1 $(UBUNTU_NODES)); do \
		name=ubuntu-$$i; \
		echo "[rm] $$name"; \
		podman rm -f $$name >/dev/null 2>&1 || true; \
	 done;
	@echo "==> Removing CentOS nodes"
	@for i in $$(seq 1 $(CENTOS_NODES)); do \
		name=centos-$$i; \
		echo "[rm] $$name"; \
		podman rm -f $$name >/dev/null 2>&1 || true; \
	 done;
	@echo "==> Removing roles directory, tar.gz, inventory, playbook, and test files"
	rm -rf roles file-backup.tar.gz
	rm -rf *.retry
	rm -rf *.log
	rm -rf tmp test-output
	rm -f $(ANSIBLE_INVENTORY) $(PLAYBOOK) playbook.s3_only.yml playbook.s3_and_log.yml playbook.log_only.yml

.PHONY: destroy-others-components
destroy-others-components: destroy-minio destroy-backup-server

.PHONY: destroy-minio
destroy-minio:
	@echo "==> Removing MinIO server"
	@podman rm -f minio >/dev/null 2>&1 || true;

.PHONY: destroy-backup-server
destroy-backup-server:
	@echo "==> Removing backup server"
	@podman rm -f backup-server >/dev/null 2>&1 || true;

.PHONY: clean
clean: destroy

# -----------------------------------------
# Test Ansible Galaxy role install & execution
# -----------------------------------------
.PHONY: test-role
test-role: deps create-nodes create-others-components generate-playbook generate-inventory
	@echo "==> Packaging role for Galaxy install"
	rm -f file-backup.tar.gz
	tar czf file-backup.tar.gz --exclude=file-backup.tar.gz --exclude=.git --exclude=*.pyc --exclude=__pycache__ .
	@echo "==> Installing role via ansible-galaxy"
	rm -rf roles
	mkdir -p roles/file-backup
	tar xzf file-backup.tar.gz -C roles/file-backup
	@echo "==> Running test playbook"
	ansible-playbook -i $(ANSIBLE_INVENTORY) $(PLAYBOOK) $(ANSIBLE_OPTS) -e 'roles_path=./roles'
	@echo "==> Test completed"

# E2E test: environment setup, role test, cleanup
.PHONY: test-e2e
test-e2e: destroy test-role destroy
	@echo "Done."
