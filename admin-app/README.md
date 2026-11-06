# 邗上课表管理端

Flutter 管理端，通过 SSH 隧道在本机回环地址打开管理后台。

## 本地配置

1. 在 `lib/main.dart` 中把 `your-server.example` 和 `your-ssh-user` 改为自己的服务器与**低权限 SSH 用户**。
2. 自行准备仅用于该管理端的受限私钥，保存为 `assets/admin_tunnel`。
3. 私钥不得提交到 Git，也不应使用 root 或项目主私钥。

仓库故意不包含任何可用私钥。缺少 `assets/admin_tunnel` 时，应用会提示连接失败；这是预期的安全配置。

```bash
flutter pub get
flutter analyze
flutter run
```

生产部署还应限制该密钥的源地址、权限和可执行命令，并定期轮换。历史构建物可能打包过旧资源，请只在确认私钥已轮换后分发。
