# Debian Node.js development bootstrap

这份仓库用于在新安装的 Debian 上，快速恢复到可工作的 Node.js 开发环境。

目标：

- 可重复执行，不是一次性脚本
- 代理配置集中管理，方便首次安装和后续修改
- dotfiles 与机器私有配置分离，仓库可直接复用到下一台机器
- 优先使用 Debian 官方包，减少外部依赖链

## 仓库结构

```text
.
|-- config/
|   `-- setup.env.example
|-- dotfiles/
|   |-- git/gitconfig
|   |-- shell/profile
|   |-- tmux/tmux.conf
|   |-- tmux/tmux.conf.local
|   `-- zsh/zshrc
`-- setup.sh
```

## 全新 Debian 的推荐顺序

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

### 4. 准备本地配置

先复制一份本地配置：

```bash
cp config/setup.env.example config/setup.env
```

然后按你的网络与账号情况修改 `config/setup.env`。

这个文件默认被 `.gitignore` 忽略，适合放：

- 代理地址
- 用户名
- npm registry
- 是否给用户开 sudo
- 是否把默认 shell 改成 zsh

### 5. 手动安装你自己的 Node.js / npm

这个仓库现在不负责安装 `nodejs` 和 `npm`，由你自己决定安装方式，比如：

- Debian 官方 `apt`
- `nvm`
- `fnm`
- Node 官方 tarball

如果你之后安装好了 `npm`，可以再运行一次：

```bash
bash setup.sh apply-proxy --config config/setup.env
```

这样脚本会把 npm 代理和 registry 也配置上。

### 6. 首次执行 setup

如果当前用户还没有 sudo，先切 root 执行：

```bash
su -
cd /path/to/debian-env-setup
bash setup.sh init --config config/setup.env
```

如果当前用户已经能 sudo：

```bash
cd /path/to/debian-env-setup
sudo bash setup.sh init --config config/setup.env
```

### 7. 后续只改代理

```bash
bash setup.sh apply-proxy --config config/setup.env
```

### 8. 清理代理

```bash
bash setup.sh clear-proxy --config config/setup.env
```

## 脚本会做什么

`init` 默认会按配置执行以下步骤：

1. 为目标用户授予 sudo 权限（可选）
2. 写入 apt 代理配置
3. 写入 shell 代理环境文件
4. 配置 git 的 HTTP(S) 代理
5. 如果系统里已经安装了 npm，则配置 npm 的代理与 registry
6. 安装基础开发包
7. 安装 `Oh My Zsh` 与 `Oh My Tmux`
8. 链接 dotfiles
9. 可选地把默认 shell 切到 zsh

## 已覆盖的代理配置

当前脚本已经处理：

- `apt`
- shell 环境变量：`http_proxy`、`https_proxy`、`all_proxy`、`no_proxy`
- `git`
- `npm`：仅当系统里已经有 `npm` 时配置

其中：

- `curl`、`wget`、大多数 CLI 会直接读取 shell 里的代理变量
- `apt` 只支持 HTTP/HTTPS 代理；如果你只有 `socks5://`，通常还需要本地再套一层 HTTP 代理

## dotfiles 说明

脚本会把以下文件链接到目标用户家目录：

- `~/.profile`
- `~/.zshrc`
- `~/.gitconfig`
- `~/.tmux.conf.local`

如果安装了 Oh My Tmux，还会把：

- `~/.tmux.conf -> ~/.tmux/.tmux.conf`

如果目标位置已有同名文件，脚本会先备份为：

```text
<filename>.bak.<timestamp>
```

## 常用命令

```bash
# 全量初始化
bash setup.sh init --config config/setup.env

# 只安装基础软件包
bash setup.sh install-base --config config/setup.env

# 只安装 shell 环境
bash setup.sh install-shell --config config/setup.env

# 只重新链接 dotfiles
bash setup.sh link-dotfiles --config config/setup.env

# 只应用代理
bash setup.sh apply-proxy --config config/setup.env

# 清理代理配置
bash setup.sh clear-proxy --config config/setup.env

# 查看脚本解析后的关键配置
bash setup.sh doctor --config config/setup.env
```

## 建议你确认的扩展项

这几个我认为很值得纳入下一版，但先不默认写死：

1. `pnpm` / `yarn` / `corepack` 的代理与镜像
2. Docker daemon 代理
3. Git over SSH 的代理方案
4. 公司或自签 CA 证书导入
5. `pip` / `uv` / `cargo` 等其他开发工具链代理
6. Neovim / Vim / VS Code Remote 的基础开发配置

如果你确认要这些，我可以在下一步把它们一起纳入脚本和 dotfiles。
