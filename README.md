# Debian Node.js development bootstrap

这份仓库用于在新安装的 Debian 上，快速恢复到可工作的 Node.js 开发环境。

目标：

- 可重复执行，不是一次性脚本
- 通过交互式提问配置，避免维护 `.env`
- dotfiles 与机器私有配置分离，仓库可直接复用到下一台机器

## 仓库结构

```text
.
|-- dotfiles/
|   |-- git/gitconfig
|   |-- shell/profile
|   |-- tmux/tmux.conf
|   |-- tmux/tmux.conf.local
|   `-- zsh/zshrc
`-- setup.sh
```

## 全新 Debian 的推荐顺序

### 0. 直接进入菜单

```bash
bash setup.sh
```

输入数字选择动作：

- `1` `init`
- `2` `install-base`
- `3` `install-shell`
- `4` `link-dotfiles`
- `5` `apply-proxy`
- `6` `clear-proxy`
- `7` `install-docker`
- `8` `docker-proxy`
- `9` `doctor`
- `10` `exit`

### 1. 先临时配置 apt 代理

如果你的网络不能直接访问 Debian 软件源，先用 root 写一个临时 apt 代理：

```bash
su -
cat >/etc/apt/apt.conf.d/80proxy <<'EOF'
Acquire::http::Proxy "http://127.0.0.1:7890";
Acquire::https::Proxy "http://127.0.0.1:7890";
EOF
apt update
apt install -y git ca-certificates curl
```

把 `127.0.0.1:7890` 改成你实际可用的 HTTP 代理。

### 2. 配置 git 代理

为了能 `git clone` 这个仓库，先给当前用户配置 git 代理：

```bash
git config --global http.proxy http://127.0.0.1:7890
git config --global https.proxy http://127.0.0.1:7890
git config --global url."https://".insteadOf git://
```

验证：

```bash
git config --global --get http.proxy
git ls-remote https://github.com/ohmyzsh/ohmyzsh.git HEAD
```

### 3. clone 这个仓库

```bash
git clone <your-repo-url> ~/debian-env-setup
cd ~/debian-env-setup
```

### 4. 手动安装你自己的 Node.js / npm

这个仓库不负责安装 `nodejs` 和 `npm`，由你自己决定安装方式，比如：

- Debian 官方 `apt`
- `nvm`
- `fnm`
- Node 官方 tarball

安装好 npm 后，可执行 `apply-proxy` 让脚本写入 npm 代理和 registry。

### 5. 首次执行 setup

如果当前用户已经能 sudo：

```bash
sudo bash setup.sh
```

如果当前用户还没有 sudo，先切 root：

```bash
su -
cd /path/to/debian-env-setup
bash setup.sh
```

执行过程中脚本会逐项询问：

- 目标用户
- 是否授予 sudo
- 是否配置代理，以及各工具代理值
- 是否安装基础包
- 是否安装 Oh My Zsh / Oh My Tmux
- 是否切换默认 shell 到 zsh

### 6. 安装 Docker（官方仓库方式）

菜单选 `7`，或直接运行：

```bash
bash setup.sh install-docker
```

脚本会按 Docker 官方 Debian 仓库方式安装：

- 添加 Docker apt keyring
- 配置 Docker 官方 apt repository
- 安装 `docker-ce`、`docker-ce-cli`、`containerd.io`、`docker-buildx-plugin`、`docker-compose-plugin`
- 可选把目标用户加入 `docker` 组

### 7. 开启/关闭 Docker 拉镜像代理

菜单选 `8`，或直接运行：

```bash
bash setup.sh docker-proxy
```

脚本会交互询问是启用还是关闭代理：

- 启用时写入 `/etc/systemd/system/docker.service.d/http-proxy.conf`
- 关闭时删除该文件
- 最后执行 `systemctl daemon-reload` + `systemctl restart docker`

## 常用命令

```bash
# 菜单模式（推荐）
bash setup.sh

# 全量初始化（交互式）
bash setup.sh init

# 只安装基础软件包（交互式）
bash setup.sh install-base

# 只安装 shell 环境（交互式）
bash setup.sh install-shell

# 只重新链接 dotfiles（交互式）
bash setup.sh link-dotfiles

# 只应用代理（交互式）
bash setup.sh apply-proxy

# 清理代理配置（交互式）
bash setup.sh clear-proxy

# 安装 Docker（官方 Debian 仓库方式，交互式）
bash setup.sh install-docker

# 开启/关闭 Docker daemon 代理（交互式）
bash setup.sh docker-proxy

# 打印当前交互输入结果（不落盘）
bash setup.sh doctor

# 预演模式（只显示将执行的命令）
bash setup.sh init --dry-run
```

## 注意事项

- `apt` 仅支持 HTTP/HTTPS 代理；`socks5://` 不能直接用于 apt。
- `npm` 代理仅在系统里已安装 `npm` 时才会写入。
- Docker 代理配置作用于 Docker daemon（影响 `docker pull`），不是 shell 当前会话代理。
- dotfiles 会链接到用户 home，若已有同名文件会先备份为 `*.bak.<timestamp>`。
